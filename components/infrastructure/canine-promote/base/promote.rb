#!/usr/bin/env ruby
# Canine が dev Namespace にデプロイした実体を、
# components/apps/<app>/{base,overlays/production} の形に整形する。
#
# 入力 : STDIN に kubectl get ... -o yaml (List)
# 引数 : APP=アプリ名  OUT=出力先ディレクトリ (components/apps/<app>)
require "yaml"
require "fileutils"

APP = ENV.fetch("APP")
OUT = ENV.fetch("OUT")

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

docs = YAML.load_stream(STDIN.read)
items = docs.flat_map { |d| d.is_a?(Hash) && d["items"] ? d["items"] : [d] }
resources = items.map { |i| clean(i) }.compact

abort "no resources found" if resources.empty?

FileUtils.mkdir_p(File.join(OUT, "base"))
FileUtils.mkdir_p(File.join(OUT, "overlays", "production"))

File.write(
  File.join(OUT, "base", "resources.yaml"),
  resources.map(&:to_yaml).join
)

File.write(File.join(OUT, "base", "kustomization.yaml"), <<~YAML)
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization

  # NOTE: このディレクトリは Canine の dev 環境から昇格されたものです。
  #       手で書き換えても構いませんが、再昇格すると base/resources.yaml は
  #       上書きされます。環境固有の調整は overlays/ 側で行ってください。
  resources:
    - resources.yaml
YAML

File.write(File.join(OUT, "overlays", "production", "namespace.yaml"), <<~YAML)
  apiVersion: v1
  kind: Namespace
  metadata:
    name: prod-#{APP}
YAML

overlay = File.join(OUT, "overlays", "production", "kustomization.yaml")
unless File.exist?(overlay)
  File.write(overlay, <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    namespace: prod-#{APP}

    resources:
      - namespace.yaml
      - ../../base

    # 本番固有の差分はここに書く（レプリカ数、リソース、HPA など）。
    # 再昇格してもこのファイルは上書きされません。
    # patches:
    #   - path: replicas-patch.yaml
  YAML
end

puts "generated #{OUT} (#{resources.size} resources)"
