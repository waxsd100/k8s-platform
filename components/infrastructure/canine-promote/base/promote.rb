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
#
# 終了コード: 0 = 生成した / 3 = 昇格対象が無い（正常） / それ以外 = 失敗
require "yaml"
require "date"
require "fileutils"
require "digest"

APP = ENV.fetch("APP")
OUT = ENV.fetch("OUT")
NOTES = ENV["NOTES"]
APPS_DOMAIN = ENV.fetch("APPS_DOMAIN", "apps.wax100.io")

# APP は dev Namespace 名そのもので、Kubernetes が DNS ラベルとして検証済みのはず。
# それでも生成物の Namespace 名 (prod-<APP>) やホスト名に埋め込むので、ここでも確かめる。
# prod- を付けて 63 文字に収まる長さまでに限る。
unless APP.match?(/\A[a-z0-9]([-a-z0-9]{0,56}[a-z0-9])?\z/)
  abort "APP が Namespace 名として不正です: #{APP.inspect}"
end

EXIT_NOTHING_TO_DO = 3

# ---------------------------------------------------------------------------
# 何を持ち込むか
# ---------------------------------------------------------------------------

# **許可したものだけ**を Git に書き出す。
# CronJob の KINDS と RBAC でも絞っているが、Git に書き出す当人がここで絞るのが
# 最後の砦。KINDS や入力が変わっても、Secret（機密）や Endpoints / Lease のような
# クラスタが作る動的なリソース、未知の CRD が公開リポジトリに入らない。
#
# Ingress は含めない。dev のホスト名をそのまま持ち込むと、dev と本番で同じホストを
# 取り合う（ingress-nginx はどちらか一方にしか流さない）。本番の Ingress は
# overlays/production/ingress.yaml として別に生成する。
ALLOWED_KINDS = %w[
  Deployment StatefulSet DaemonSet CronJob
  Service ConfigMap PersistentVolumeClaim
  HorizontalPodAutoscaler ServiceAccount NetworkPolicy
].freeze

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

# 本番の入口は Cloudflare Tunnel → ingress-nginx だけ。Service を外に出す設定は
# 持ち込まない（LoadBalancer は GCP に外部 LB を作り、Access を通らない入口と
# 固定費ができる）。type は ClusterIP に落とす。
EXTERNAL_SERVICE_FIELDS = %w[
  loadBalancerIP loadBalancerSourceRanges loadBalancerClass
  allocateLoadBalancerNodePorts externalTrafficPolicy externalIPs
].freeze

$dropped = Hash.new { |h, k| h[k] = [] } # kind => [name]
$downgraded_services = []                 # [name, 元の type]
$dev_ingress_hosts = []
$manual_pvcs = []

def clean(obj)
  return nil unless obj.is_a?(Hash)

  kind = obj["kind"]
  meta = obj["metadata"] || {}
  name = meta["name"]

  unless ALLOWED_KINDS.include?(kind)
    $dropped[kind.to_s] << name
    (obj.dig("spec", "rules") || []).each { |r| $dev_ingress_hosts << r["host"] if r["host"] } if kind == "Ingress"
    return nil
  end
  # 他リソースが所有しているもの（Deployment が作った ReplicaSet、CronJob が作った Job など）は
  # 親から再生成されるので持ち込まない。許可リストの kind はどれも通常は所有者を持たない。
  return nil if meta.key?("ownerReferences") && !Array(meta["ownerReferences"]).empty?
  # 既定の ServiceAccount は Kubernetes が作るので持ち込まない
  return nil if kind == "ServiceAccount" && name == "default"

  obj.delete("status")
  VOLATILE_META.each { |k| meta.delete(k) }
  if (anno = meta["annotations"]).is_a?(Hash)
    VOLATILE_ANNO.each { |k| anno.delete(k) }
    meta.delete("annotations") if anno.empty?
  end

  spec = obj["spec"]
  if (keys = VOLATILE_SPEC[kind]) && spec.is_a?(Hash)
    # Headless Service (clusterIP: None) は採番ではなく「IP を振らない」という指定。
    # 消すと本番で通常の Service になり、StatefulSet の Pod ごとの DNS 名が引けなくなる。
    headless = kind == "Service" && spec["clusterIP"] == "None"
    keys.each { |k| spec.delete(k) }
    spec["clusterIP"] = "None" if headless
  end

  # Canine の Volume は、ノードのディスク (/data/volumes/<id>) を指す hostPath の PV と、
  # storageClassName: manual の PVC の組で作られる。PV は持ち込まないので、本番で manual の
  # ままだと PVC が永遠に Pending になる。クラスタの既定 (GKE は Persistent Disk) に任せる。
  if kind == "PersistentVolumeClaim" && spec.is_a?(Hash) && spec["storageClassName"] == "manual"
    spec.delete("storageClassName")
    $manual_pvcs << name
  end

  if kind == "Service" && spec.is_a?(Hash)
    type = spec["type"]
    if %w[LoadBalancer NodePort].include?(type)
      $downgraded_services << [name, type]
      spec["type"] = "ClusterIP"
      EXTERNAL_SERVICE_FIELDS.each { |k| spec.delete(k) }
    end
    Array(spec["ports"]).each { |p| p.delete("nodePort") if p.is_a?(Hash) }
  end

  obj
end

# ---------------------------------------------------------------------------
# 参照している Secret を集める
# ---------------------------------------------------------------------------

# Pod テンプレートを持つリソースと ServiceAccount から、参照している Secret の
# 名前とキーを集める。Secret 本体は読まない（RBAC 上も読めない）。参照だけを見て雛形を作る。
#   keys  : 特定のキーだけ使っている
#   whole : Secret を丸ごと使っている（envFrom / volume）
#   pull  : イメージ取得用（imagePullSecrets）。型が kubernetes.io/dockerconfigjson である必要がある
def collect_secret_refs(resources)
  refs = Hash.new { |h, k| h[k] = { keys: [], whole: false, pull: false } }

  pod_specs = resources.filter_map do |r|
    r.dig("spec", "template", "spec") ||
      r.dig("spec", "jobTemplate", "spec", "template", "spec")
  end

  pod_specs.each do |spec|
    Array(spec["imagePullSecrets"]).each do |s|
      refs[s["name"]][:pull] = true if s["name"]
    end

    containers = Array(spec["containers"]) + Array(spec["initContainers"])
    containers.each do |c|
      Array(c["env"]).each do |e|
        ref = e.dig("valueFrom", "secretKeyRef")
        refs[ref["name"]][:keys] << ref["key"] if ref && ref["name"] && ref["key"]
      end
      Array(c["envFrom"]).each do |e|
        name = e.dig("secretRef", "name")
        refs[name][:whole] = true if name
      end
    end

    Array(spec["volumes"]).each do |v|
      secret_sources = [v["secret"]&.then { |s| { "name" => s["secretName"], "items" => s["items"] } }]
      secret_sources += Array(v.dig("projected", "sources")).map { |src| src["secret"] }
      secret_sources.compact.each do |s|
        next unless s["name"]

        if s["items"]
          s["items"].each { |i| refs[s["name"]][:keys] << i["key"] if i["key"] }
        else
          refs[s["name"]][:whole] = true
        end
      end
    end
  end

  # ServiceAccount に付いた imagePullSecrets は、その SA を使う Pod すべてに効く。
  # NOTE: SA の `secrets` (mountable secrets) は見ない。古いクラスタが自動生成した
  #       トークン Secret で、外部から与えるものではない。
  resources.select { |r| r["kind"] == "ServiceAccount" }.each do |sa|
    Array(sa["imagePullSecrets"]).each do |s|
      refs[s["name"]][:pull] = true if s["name"]
    end
  end

  refs.each_value { |v| v[:keys].uniq! }
  refs
end

# Secret Manager のシークレット ID。使える文字は [A-Za-z0-9_-]、長さは 255 まで。
# 大文字・小文字・アンダースコアはそのまま残す（DB_PASSWORD と db_password を区別する）。
# それ以外の文字（Secret 名やキーに入りうるのは '.'）だけを '-' にする。
# 置き換えで衝突したとき、長すぎるときは、元の文字列のハッシュを付けて一意にする。
SECRET_ID_MAX = 255

def secret_id_for(parts, taken)
  raw = (["prod", APP] + parts).join("-")
  id = raw.gsub(/[^A-Za-z0-9_-]/, "-")
  if taken.include?(id) || id.length > SECRET_ID_MAX
    suffix = "-" + Digest::SHA256.hexdigest(raw)[0, 8]
    id = id[0, SECRET_ID_MAX - suffix.length] + suffix
  end
  raise "シークレット ID が衝突しました: #{id}" if taken.include?(id)

  taken << id
  id
end

# ---------------------------------------------------------------------------
# Ingress を当てる Service を選ぶ
# ---------------------------------------------------------------------------

# http という名前のポート > 80 > 3000 > 最初のポート、の順で判断する。
# Headless（clusterIP: None）と ExternalName は Ingress の転送先に向かないので除外する
# （clean で clusterIP を消す前の値を見るため、呼び出し元は clean 前の値を渡す）。
def pick_web_service(services)
  scored = services.filter_map do |svc|
    ports = Array(svc.dig("spec", "ports"))
    port = ports.find { |p| p["name"] == "http" } ||
           ports.find { |p| p["port"].to_i == 80 } ||
           ports.find { |p| p["port"].to_i == 3000 } ||
           ports.first
    next nil unless port

    score = if port["name"] == "http" then 0
            elsif port["port"].to_i == 80 then 1
            elsif port["port"].to_i == 3000 then 2
            else 3
            end
    [score, svc["metadata"]["name"], port["port"].to_i]
  end

  scored.min_by { |s| [s[0], s[1]] }
end

# ---------------------------------------------------------------------------
# YAML の出力
# ---------------------------------------------------------------------------

# 値を文字列展開で YAML に埋め込まない。Psych に組み立てさせれば、`yes` / `true` /
# `123` のような Secret 名やキーも文字列として正しくクォートされる。
def yaml_doc(hash)
  hash.to_yaml.sub(/\A---\n/, "")
end

def external_secret_for(name, info, taken, notes)
  base = {
    "apiVersion" => "external-secrets.io/v1",
    "kind" => "ExternalSecret",
    "metadata" => { "name" => name },
    "spec" => {
      "refreshInterval" => "1h",
      "secretStoreRef" => { "name" => "gcp-secret-store", "kind" => "ClusterSecretStore" },
      "target" => { "name" => name, "creationPolicy" => "Owner" }
    }
  }
  spec = base["spec"]

  if info[:pull]
    # イメージ取得用。kubelet は kubernetes.io/dockerconfigjson 型の Secret しか使わないので、
    # 型を指定して .dockerconfigjson キーに入れる（ESO の公式の書き方）。
    id = secret_id_for([name], taken)
    spec["target"]["template"] = {
      "type" => "kubernetes.io/dockerconfigjson",
      "data" => { ".dockerconfigjson" => "{{ .dockerconfig | toString }}" }
    }
    spec["data"] = [{ "secretKey" => "dockerconfig", "remoteRef" => { "key" => id } }]
    notes << "  - `#{id}`（Secret `#{name}`: レジストリ認証。docker の config.json の中身をそのまま）"
    if info[:whole] || info[:keys].any?
      notes << "    - NOTE: `#{name}` はイメージ取得以外にも参照されています。dockerconfigjson 型として作ります。"
    end
  elsif info[:whole] || info[:keys].empty?
    id = secret_id_for([name], taken)
    spec["dataFrom"] = [{ "extract" => { "key" => id } }]
    notes << "  - `#{id}`（Secret `#{name}` を丸ごと。キーと値の JSON オブジェクトで登録）"
  else
    spec["data"] = info[:keys].map do |key|
      id = secret_id_for([name, key], taken)
      notes << "  - `#{id}`（Secret `#{name}` のキー `#{key}`）"
      { "secretKey" => key, "remoteRef" => { "key" => id } }
    end
  end

  yaml_doc(base)
end

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

# 入力はクラスタから取った YAML。任意のクラスを復元させないよう safe_load で読む。
# NOTE: YAML.safe_load_stream は Canine のイメージ (Ruby 3.3 / Psych 5.1) に無いので、
#       ドキュメントごとに 1 本のストリームへ入れ直して safe_load する
#       （Document 単体は to_yaml できない）。Date を許可するには require "date" が要る。
docs = YAML.parse_stream(STDIN.read).children.map do |doc|
  stream = Psych::Nodes::Stream.new
  stream.children << doc
  YAML.safe_load(stream.to_yaml, permitted_classes: [Time, Date, Symbol])
end
items = docs.flat_map { |d| d.is_a?(Hash) && d["items"] ? d["items"] : [d] }

# Ingress の転送先は、clean で clusterIP を消す前の値で選ぶ
web_candidates = items.select do |i|
  i.is_a?(Hash) && i["kind"] == "Service" &&
    i.dig("spec", "clusterIP") != "None" && i.dig("spec", "type") != "ExternalName" &&
    !Array(i.dig("metadata", "ownerReferences")).any?
end

resources = items.filter_map { |i| clean(i) }

# 昇格できるものが 1 つも無いのは異常ではない (アプリを消した直後、
# Namespace だけ作られた状態、Canine が再デプロイしている最中など)。
# 本番をここから消すことはしない。dev から一瞬リソースが消えただけで
# 「本番を全部消す PR」が立つのを防ぐため。本番を止めるときは、人が
# components/apps/ から消す PR を出す。
if resources.empty?
  if Dir.exist?(OUT)
    warn "昇格対象のリソースがありません (#{APP})。本番の定義は変更しません。" \
         "本番から外す場合は components/apps/#{APP} を削除する PR を手で出してください。"
  else
    warn "昇格対象のリソースがありません (#{APP})。何もしません。"
  end
  exit EXIT_NOTHING_TO_DO
end

# ReadWriteOnce の PVC を付けた Deployment は 1 台でしか動かせない（ディスクは 1 ノードにしか
# 付かない）。HPA を付けず、更新方法も Recreate にする。Canine の既定の RollingUpdate
# (maxSurge 1 / maxUnavailable 0) のままだと、新しい Pod が別ノードに載ったときにディスクを
# 付けられず、古い Pod も消えないまま更新が止まる。
rwo_pvcs = resources.select do |r|
  r["kind"] == "PersistentVolumeClaim" &&
    (Array(r.dig("spec", "accessModes")) & %w[ReadWriteOnce ReadWriteOncePod]).any?
end.map { |r| r["metadata"]["name"] }
single_deployments = resources.select { |r| r["kind"] == "Deployment" }.select do |d|
  Array(d.dig("spec", "template", "spec", "volumes")).any? do |v|
    rwo_pvcs.include?(v.dig("persistentVolumeClaim", "claimName"))
  end
end
single_deployments.each do |d|
  d["spec"]["strategy"] = { "type" => "Recreate" }
  d["spec"]["replicas"] = 1
end
single_names = single_deployments.map { |d| d["metadata"]["name"] }

base = File.join(OUT, "base")
prod = File.join(OUT, "overlays", "production")
FileUtils.mkdir_p(base)
FileUtils.mkdir_p(prod)

File.write(File.join(base, "resources.yaml"), resources.map { |r| r.to_yaml }.join)

File.write(File.join(base, "kustomization.yaml"), <<~YAML)
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization

  # NOTE: このディレクトリは Canine の dev 環境から昇格されたものです。
  #       base/resources.yaml は再昇格のたびに上書きされます。
  #       環境固有の調整は overlays/ 側で行ってください。
  resources:
    - resources.yaml
YAML

File.write(File.join(prod, "namespace.yaml"),
           yaml_doc({ "apiVersion" => "v1", "kind" => "Namespace", "metadata" => { "name" => "prod-#{APP}" } }))

notes = []
overlay_extra = []

# --- 公開用 Ingress（初回のみ生成） ---
ingress_path = File.join(prod, "ingress.yaml")
web = pick_web_service(web_candidates)

if web
  _score, svc_name, svc_port = web
  unless File.exist?(ingress_path)
    ingress = {
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "Ingress",
      "metadata" => { "name" => APP },
      "spec" => {
        "ingressClassName" => "nginx",
        "rules" => [{
          "host" => "#{APP}.#{APPS_DOMAIN}",
          "http" => { "paths" => [{
            "path" => "/", "pathType" => "Prefix",
            "backend" => { "service" => { "name" => svc_name, "port" => { "number" => svc_port } } }
          }] }
        }]
      }
    }
    File.write(ingress_path, <<~HEAD + yaml_doc(ingress))
      # cloudflared は *.#{APPS_DOMAIN} をまとめて ingress-nginx に流している。
      # このリソースがあるだけで https://#{APP}.#{APPS_DOMAIN} が生える。
      # Cloudflare 側の設定も DNS レコードの追加も不要。
    HEAD
  end
  notes << "- 公開 URL: `https://#{APP}.#{APPS_DOMAIN}`（`#{svc_name}:#{svc_port}` へ転送）"
elsif !File.exist?(ingress_path)
  notes << "- Ingress の転送先になる Service が見つからなかったため、Ingress は生成していません。公開が必要なら手で追加してください。"
end
overlay_extra << "  - ingress.yaml" if File.exist?(ingress_path)

unless $dev_ingress_hosts.empty?
  notes << "- dev の Ingress（#{$dev_ingress_hosts.uniq.map { |h| "`#{h}`" }.join(', ')}）は持ち込んでいません。" \
           "本番は `overlays/production/ingress.yaml` のホストで公開されます。"
end

# --- ExternalSecret の雛形（初回のみ生成） ---
secret_refs = collect_secret_refs(resources)
es_path = File.join(prod, "external-secret.yaml")

if secret_refs.any?
  secret_notes = []
  taken = []
  blocks = secret_refs.map { |name, info| external_secret_for(name, info, taken, secret_notes) }

  unless File.exist?(es_path)
    header = <<~YAML
      # 昇格時に自動生成された雛形です（Secret の値は読んでいません。
      # Pod が参照している Secret 名とキーだけから組み立てています）。
      #
      # **値は Secret Manager に登録してください。** 下の remoteRef.key が
      # そのままシークレット ID です。dev と本番で別の値を入れられます。
      #
      # 初回のみ生成され、再昇格でも上書きされません。
    YAML
    File.write(es_path, header + blocks.join("---\n"))
    notes << "- **Secret Manager に登録が必要**:"
    notes.concat(secret_notes)
    notes << "  登録するまで本番の Pod は起動しません。"
  else
    notes << "- `overlays/production/external-secret.yaml` は既にあるため上書きしていません。" \
             "dev で参照する Secret が増えていないか確認してください（dev の参照: #{secret_refs.keys.map { |n| "`#{n}`" }.join(', ')}）。"
  end
end
overlay_extra << "  - external-secret.yaml" if File.exist?(es_path)

# --- HPA（初回のみ生成） ---
# 本番のアプリは実際の負荷（CPU 使用率）で台数を変える。
#   - 最小 2: apps-pool は Spot。1 本だとノードの回収でアプリごと止まる
#   - CPU 70%: 使用率は requests に対する割合。requests が無いと計算できない
#     （requests も limits も無いコンテナには Kyverno が既定値を入れる）
#   - メモリは指標にしない。使ったメモリを返さないランタイム（Ruby など）が多く、
#     増えたまま減らなくなる
# 対象は Deployment だけ。StatefulSet（DB など）を負荷で増やすと壊れうる。
# dev に HPA があるものはそれを使い、ここでは作らない。
#
# HPA を付けた Deployment は overlay で spec.replicas を消す。base に残すと
# Config Sync が replicas を書き戻し、HPA と取り合いになる。
HPA_MIN = 2
HPA_MAX = 5
HPA_CPU = 70

hpa_path = File.join(prod, "hpa.yaml")

unless single_names.empty?
  notes << "- **1 台で動かします**（#{single_names.map { |n| "`#{n}`" }.join(', ')}）。ReadWriteOnce の PVC を付けているため、" \
           "HPA を付けず、replicas: 1・更新方法 Recreate にしました（更新時は数十秒止まります）。"
end

deployments = resources.select { |r| r["kind"] == "Deployment" }.map { |d| d["metadata"]["name"] } - single_names
dev_hpa_targets = resources.select { |r| r["kind"] == "HorizontalPodAutoscaler" }
                           .map { |h| h.dig("spec", "scaleTargetRef", "name") }
hpa_targets = deployments - dev_hpa_targets
unscaled_targets = []

if !File.exist?(File.join(prod, "kustomization.yaml")) && hpa_targets.any? && !File.exist?(hpa_path)
  hpas = hpa_targets.map do |name|
    yaml_doc({
      "apiVersion" => "autoscaling/v2",
      "kind" => "HorizontalPodAutoscaler",
      "metadata" => { "name" => name },
      "spec" => {
        "scaleTargetRef" => { "apiVersion" => "apps/v1", "kind" => "Deployment", "name" => name },
        "minReplicas" => HPA_MIN,
        "maxReplicas" => HPA_MAX,
        "metrics" => [{
          "type" => "Resource",
          "resource" => { "name" => "cpu", "target" => { "type" => "Utilization", "averageUtilization" => HPA_CPU } }
        }]
      }
    })
  end
  File.write(hpa_path, <<~HEAD + hpas.join("---\n"))
    # 昇格時に自動生成（初回のみ）。本番は CPU 使用率で台数を変える。
    # 最小・最大・目標値は自由に変えてよい。HPA を外すときは、kustomization.yaml の
    # 「replicas を消すパッチ」も一緒に外すこと（外さないと 1 台で動く）。
  HEAD
end
overlay_extra << "  - hpa.yaml" if File.exist?(hpa_path)
file_hpa_targets =
  if File.exist?(hpa_path)
    YAML.parse_stream(File.read(hpa_path, encoding: "UTF-8")).children.filter_map do |doc|
      stream = Psych::Nodes::Stream.new
      stream.children << doc
      YAML.safe_load(stream.to_yaml)&.dig("spec", "scaleTargetRef", "name")
    end
  else
    []
  end
scaled = (file_hpa_targets + dev_hpa_targets).uniq & deployments
conflicting_hpa = (file_hpa_targets + dev_hpa_targets).uniq & single_names
unless conflicting_hpa.empty?
  notes << "- **HPA が 1 台でしか動かせない Deployment を指しています**（#{conflicting_hpa.map { |n| "`#{n}`" }.join(', ')}）。" \
           "`overlays/production/hpa.yaml` と kustomization.yaml の replicas を消すパッチから外してください（dev の HPA なら dev 側で外す）。"
end
missing_hpa = deployments - scaled
if File.exist?(File.join(prod, "kustomization.yaml")) && missing_hpa.any? && scaled.any?
  notes << "- HPA が無い Deployment があります（#{missing_hpa.map { |n| "`#{n}`" }.join(', ')}）。" \
           "負荷で台数を変えるなら `overlays/production/hpa.yaml` に追加し、replicas を消すパッチも足してください。"
end

if scaled.any?
  notes << "- **本番は CPU 使用率で台数が変わります**（#{scaled.map { |n| "`#{n}`" }.join(', ')}: " \
           "最小 #{HPA_MIN} / 最大 #{HPA_MAX} / 目標 #{HPA_CPU}%）。調整は `overlays/production/hpa.yaml` で。"
end

# CPU の requests が無いコンテナがあると、HPA は使用率を計算できない。
# requests も limits も無いものは Kyverno が既定値を入れるので、問題になるのは
# 「メモリだけ書いて CPU を書いていない」ようなコンテナ。
resources.select { |r| r["kind"] == "Deployment" && scaled.include?(r["metadata"]["name"]) }.each do |d|
  Array(d.dig("spec", "template", "spec", "containers")).each do |c|
    res = c["resources"] || {}
    has_any = (res["requests"] || {}).any? || (res["limits"] || {}).any?
    has_cpu = res.dig("requests", "cpu") || res.dig("limits", "cpu")
    unscaled_targets << "#{d['metadata']['name']}/#{c['name']}" if has_any && !has_cpu
  end
end
unless unscaled_targets.empty?
  notes << "- **CPU の requests が無いコンテナがあります**（#{unscaled_targets.join(', ')}）。" \
           "このままでは HPA が CPU 使用率を計算できず、台数が変わりません。overlay で `resources.requests.cpu` を足してください。"
end

# --- 持ち込まなかったもの / 変えたもの ---
unless $downgraded_services.empty?
  notes << "- **Service の type を ClusterIP に変えました**（" \
           "#{$downgraded_services.map { |n, t| "`#{n}`: #{t}" }.join(', ')}）。" \
           "本番の入口は Cloudflare Tunnel → ingress-nginx だけです。LoadBalancer は外部 LB（固定費と、Access を通らない入口）を作ります。"
end

other_dropped = $dropped.reject { |k, _| k == "Ingress" }
unless other_dropped.empty?
  notes << "- 昇格の対象外として除外: " +
           other_dropped.map { |k, names| "#{k.empty? ? '(kind 無し)' : k} (#{names.compact.join(', ')})" }.join(" / ")
end

# --- ConfigMap の警告 ---
# Secret は許可リストに無いので書き出さないが、ConfigMap は中身ごと Git に入る。
# アプリが誤ってトークンを ConfigMap に置いていると、そのまま公開される。
cms = resources.select { |r| r["kind"] == "ConfigMap" }
if cms.any?
  notes << "- **ConfigMap が中身ごとコミットされます**（#{cms.map { |c| c['metadata']['name'] }.join(', ')}）。" \
           "機密が混ざっていないかレビューで確認してください。混ざっている場合は Secret に移し、" \
           "`overlays/production/external-secret.yaml` 経由で渡してください。"
end

# --- PVC の警告 ---
pvcs = resources.select { |r| r["kind"] == "PersistentVolumeClaim" }
unless $manual_pvcs.empty?
  notes << "- **PVC の StorageClass を既定に変えました**（#{$manual_pvcs.map { |n| "`#{n}`" }.join(', ')}）。" \
           "dev の `manual` は Canine がノードのディスクに作る hostPath の PV 用で、本番には PV が無いためです。本番は Persistent Disk になります。"
end
if pvcs.any?
  notes << "- **PVC があります**（#{pvcs.map { |p| p['metadata']['name'] }.join(', ')}）。" \
           "定義だけが昇格され、中身は空で作られます。データ移行が要る場合は別途。" \
           "容量や StorageClass を本番だけ変えるときは `overlays/production` でパッチを当ててください" \
           "（作成後の PVC は容量の拡張しかできません）。"
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

    # 本番固有の差分はここに書く（リソース、HPA、PVC の容量など）。
    # 再昇格してもこのファイルは上書きされません。
  YAML
  # HPA を付けた Deployment の replicas を消す（Config Sync と HPA の取り合いを防ぐ）
  unless scaled.empty?
    patches = scaled.map do |name|
      {
        "target" => { "kind" => "Deployment", "name" => name },
        "patch" => "- op: remove\n  path: /spec/replicas\n"
      }
    end
    File.write(overlay, File.read(overlay, encoding: "UTF-8") + <<~HEAD + yaml_doc({ "patches" => patches }))

      # HPA が台数を持つので、base の replicas を消す。HPA を外すならこれも外す。
    HEAD
  end
end

File.write(NOTES, notes.join("\n") + "\n") if NOTES && !notes.empty?

puts "generated #{OUT} (#{resources.size} resources, #{secret_refs.size} secret refs)"
