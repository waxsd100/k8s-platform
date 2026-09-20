#!/usr/bin/env ruby
# Canine が dev Namespace にデプロイした実体を、
# components/apps/<app>/{base,overlays/production} の形に整形する。
#
# 入力 : STDIN に kubectl get ... -o yaml (List)
# 引数 : APP=アプリ名  OUT=出力先ディレクトリ  NOTES=PR 本文に差し込むメモの出力先
#        APPS_DOMAIN=公開ドメイン (既定 apps.wax100.io)
#
# 生成物:
#   base/resources.yaml            dev の実体（再昇格で上書きする）
#   base/kustomization.yaml
#   overlays/production/kustomization.yaml   初回のみ。以降は人が書いた内容を尊重する
#   overlays/production/namespace.yaml
#   overlays/production/ingress.yaml         初回のみ。<app>.<APPS_DOMAIN> で公開する
#   overlays/production/external-secret.yaml 初回のみ。値は Secret Manager に入れる
require "yaml"
require "fileutils"

APP = ENV.fetch("APP")
OUT = ENV.fetch("OUT")
NOTES = ENV["NOTES"]
APPS_DOMAIN = ENV.fetch("APPS_DOMAIN", "apps.wax100.io")

VOLATILE_META = %w[
  resourceVersion uid creationTimestamp generation selfLink managedFields
  ownerReferences finalizers namespace
].freeze

VOLATILE_ANNO = %w[
  deployment.kubernetes.io/revision
  kubectl.kubernetes.io/last-applied-configuration
  kubectl.kubernetes.io/restartedAt
  meta.helm.sh/release-namespace
].freeze

# 新しい Namespace では再採番されるため持ち込まない
VOLATILE_SPEC = {
  "Service" => %w[clusterIP clusterIPs ipFamilies ipFamilyPolicy healthCheckNodePort],
  "PersistentVolumeClaim" => %w[volumeName]
}.freeze

def clean(obj)
  return nil unless obj.is_a?(Hash)

  meta = obj["metadata"] || {}
  # 他リソースが所有しているもの（CronJob が作った Job など）は昇格しない
  return nil if meta.key?("ownerReferences") && !meta["ownerReferences"].empty?
  # 既定の ServiceAccount は Kubernetes が作るので持ち込まない
  return nil if obj["kind"] == "ServiceAccount" && meta["name"] == "default"

  obj.delete("status")
  VOLATILE_META.each { |k| meta.delete(k) }
  if (anno = meta["annotations"]).is_a?(Hash)
    VOLATILE_ANNO.each { |k| anno.delete(k) }
    meta.delete("annotations") if anno.empty?
  end

  if (keys = VOLATILE_SPEC[obj["kind"]]) && obj["spec"].is_a?(Hash)
    keys.each { |k| obj["spec"].delete(k) }
    if obj["kind"] == "Service" && obj["spec"]["ports"].is_a?(Array)
      obj["spec"]["ports"].each { |p| p.delete("nodePort") }
    end
  end

  obj
end

# Pod テンプレートを持つリソースから、参照している Secret の名前とキーを集める。
# Secret 本体は読まない（RBAC 上も読めない）。参照だけを見て雛形を作る。
def collect_secret_refs(resources)
  refs = Hash.new { |h, k| h[k] = { keys: [], whole: false } }

  pod_specs = resources.filter_map do |r|
    r.dig("spec", "template", "spec") ||
      r.dig("spec", "jobTemplate", "spec", "template", "spec")
  end

  pod_specs.each do |spec|
    containers = (spec["containers"] || []) + (spec["initContainers"] || [])
    containers.each do |c|
      (c["env"] || []).each do |e|
        ref = e.dig("valueFrom", "secretKeyRef")
        refs[ref["name"]][:keys] << ref["key"] if ref && ref["name"] && ref["key"]
      end
      (c["envFrom"] || []).each do |e|
        name = e.dig("secretRef", "name")
        refs[name][:whole] = true if name
      end
    end
    (spec["volumes"] || []).each do |v|
      name = v.dig("secret", "secretName")
      refs[name][:whole] = true if name
    end
  end

  refs.each_value { |v| v[:keys].uniq! }
  refs
end

# 公開用の Ingress を当てる Service を選ぶ。
# http という名前のポート > 80 > 3000 > 最初のポート、の順で判断する。
def pick_web_service(resources)
  services = resources.select { |r| r["kind"] == "Service" }
  return nil if services.empty?

  scored = services.map do |svc|
    ports = svc.dig("spec", "ports") || []
    port = ports.find { |p| p["name"] == "http" } ||
           ports.find { |p| p["port"] == 80 } ||
           ports.find { |p| p["port"] == 3000 } ||
           ports.first
    next nil unless port

    score = if port["name"] == "http" then 0
            elsif port["port"] == 80 then 1
            elsif port["port"] == 3000 then 2
            else 3
            end
    [score, svc["metadata"]["name"], port["port"]]
  end.compact

  scored.min_by(&:first)
end

docs = YAML.load_stream(STDIN.read)
items = docs.flat_map { |d| d.is_a?(Hash) && d["items"] ? d["items"] : [d] }
resources = items.map { |i| clean(i) }.compact

abort "no resources found" if resources.empty?

base = File.join(OUT, "base")
prod = File.join(OUT, "overlays", "production")
FileUtils.mkdir_p(base)
FileUtils.mkdir_p(prod)

File.write(File.join(base, "resources.yaml"), resources.map(&:to_yaml).join)

File.write(File.join(base, "kustomization.yaml"), <<~YAML)
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization

  # NOTE: このディレクトリは Canine の dev 環境から昇格されたものです。
  #       base/resources.yaml は再昇格のたびに上書きされます。
  #       環境固有の調整は overlays/ 側で行ってください。
  resources:
    - resources.yaml
YAML

File.write(File.join(prod, "namespace.yaml"), <<~YAML)
  apiVersion: v1
  kind: Namespace
  metadata:
    name: prod-#{APP}
YAML

notes = []

# --- 公開用 Ingress（初回のみ生成） ---
ingress_path = File.join(prod, "ingress.yaml")
web = pick_web_service(resources)
overlay_extra = []

if web
  _score, svc_name, svc_port = web
  unless File.exist?(ingress_path)
    File.write(ingress_path, <<~YAML)
      # cloudflared は *.#{APPS_DOMAIN} をまとめて ingress-nginx に流している。
      # このリソースがあるだけで https://#{APP}.#{APPS_DOMAIN} が生える。
      # Cloudflare 側の設定も DNS レコードの追加も不要。
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata:
        name: #{APP}
      spec:
        ingressClassName: nginx
        rules:
          - host: #{APP}.#{APPS_DOMAIN}
            http:
              paths:
                - path: /
                  pathType: Prefix
                  backend:
                    service:
                      name: #{svc_name}
                      port:
                        number: #{svc_port}
    YAML
  end
  overlay_extra << "  - ingress.yaml"
  notes << "- 公開 URL: `https://#{APP}.#{APPS_DOMAIN}`（`#{svc_name}:#{svc_port}` へ転送）"
else
  notes << "- Service が見つからなかったため Ingress は生成していません。公開が必要なら手で追加してください。"
end

# --- ExternalSecret の雛形（初回のみ生成） ---
secret_refs = collect_secret_refs(resources)
es_path = File.join(prod, "external-secret.yaml")

if secret_refs.any?
  unless File.exist?(es_path)
    blocks = secret_refs.map do |name, info|
      if info[:whole] || info[:keys].empty?
        <<~YAML
          apiVersion: external-secrets.io/v1beta1
          kind: ExternalSecret
          metadata:
            name: #{name}
          spec:
            refreshInterval: "1h"
            secretStoreRef:
              name: gcp-secret-store
              kind: ClusterSecretStore
            target:
              name: #{name}
              creationPolicy: Owner
            # Secret Manager 側に JSON で入れた値を丸ごと展開する
            dataFrom:
              - extract:
                  key: prod-#{APP}-#{name}
        YAML
      else
        data = info[:keys].map do |key|
          "    - secretKey: #{key}\n" \
          "      remoteRef:\n" \
          "        key: prod-#{APP}-#{name}-#{key.downcase.gsub(/[^a-z0-9-]/, '-')}\n"
        end.join
        <<~YAML
          apiVersion: external-secrets.io/v1beta1
          kind: ExternalSecret
          metadata:
            name: #{name}
          spec:
            refreshInterval: "1h"
            secretStoreRef:
              name: gcp-secret-store
              kind: ClusterSecretStore
            target:
              name: #{name}
              creationPolicy: Owner
            data:
          #{data.chomp}
        YAML
      end
    end

    header = <<~YAML
      # 昇格時に自動生成された雛形です（Secret の値は読んでいません。
      # Deployment が参照している Secret 名とキーだけから組み立てています）。
      #
      # **値は Secret Manager に登録してください。** 下の remoteRef.key が
      # そのままシークレット ID です。dev と本番で別の値を入れられます。
      #
      # 初回のみ生成され、再昇格でも上書きされません。
    YAML
    File.write(es_path, header + blocks.join("---\n"))
  end
  overlay_extra << "  - external-secret.yaml"

  notes << "- **Secret Manager に登録が必要**:"
  secret_refs.each do |name, info|
    if info[:whole] || info[:keys].empty?
      notes << "  - `prod-#{APP}-#{name}`（JSON で丸ごと。Secret `#{name}` の展開用）"
    else
      info[:keys].each do |key|
        notes << "  - `prod-#{APP}-#{name}-#{key.downcase.gsub(/[^a-z0-9-]/, '-')}`（Secret `#{name}` のキー `#{key}`）"
      end
    end
  end
  notes << "  登録するまで本番の Pod は起動しません。"
end

# --- PVC の警告 ---
pvcs = resources.select { |r| r["kind"] == "PersistentVolumeClaim" }
if pvcs.any?
  notes << "- **PVC があります**（#{pvcs.map { |p| p['metadata']['name'] }.join(', ')}）。" \
           "定義だけが昇格され、中身は空で作られます。データ移行が要る場合は別途。"
end

# --- overlay の kustomization（初回のみ生成） ---
overlay = File.join(prod, "kustomization.yaml")
unless File.exist?(overlay)
  File.write(overlay, <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    namespace: prod-#{APP}

    resources:
      - namespace.yaml
      - ../../base
    #{overlay_extra.join("\n")}

    # 本番固有の差分はここに書く（レプリカ数、リソース、HPA など）。
    # 再昇格してもこのファイルは上書きされません。
    # patches:
    #   - path: replicas-patch.yaml
  YAML
end

File.write(NOTES, notes.join("\n") + "\n") if NOTES && !notes.empty?

puts "generated #{OUT} (#{resources.size} resources, #{secret_refs.size} secret refs)"
