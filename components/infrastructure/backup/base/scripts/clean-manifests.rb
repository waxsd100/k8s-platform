#!/usr/bin/env ruby
# frozen_string_literal: true

# kubectl get -o json の List から、クラスタや Kyverno が自動生成するリソースおよび
# KubeVela Application が生成する子リソースを除き、status と更新・バインドのたびに変わる
# メタデータや採番済みの値を落として YAML で出す。
# そのまま kubectl apply で戻せる形にする。定義が 1 つも無ければ終了コード 3。

require "json"
require "set"
require "yaml"

VOLATILE_METADATA = %w[
  resourceVersion uid creationTimestamp generation selfLink managedFields
  ownerReferences finalizers
].freeze
VOLATILE_ANNOTATIONS = %w[
  deployment.kubernetes.io/revision
  kubectl.kubernetes.io/last-applied-configuration
  kubectl.kubernetes.io/restartedAt
  app.oam.dev/publishVersion
  app.oam.dev/deployVersion
  app.oam.dev/workflowVersion
  app.oam.dev/last-applied-configuration
  app.oam.dev/last-applied-time
  config.k8s.io/owning-inventory
].freeze
VOLATILE_ANNOTATION_PREFIXES = /\A(?:(?:pv|volume|volume\.beta)\.kubernetes\.io|config(?:sync|management)\.gke\.io)\//
KYVERNO_NETWORK_POLICIES = %w[environment-isolation dev-access-relay dev-to-dev].freeze

def safe_dig(obj, *keys)
  cur = obj
  keys.each do |k|
    return nil unless cur.is_a?(Hash)

    cur = cur[k]
  end
  cur
end

def safe_hash(val)
  val.is_a?(Hash) ? val : {}
end

def safe_array(val)
  val.is_a?(Array) ? val : []
end

def generated_resource?(obj, vela_apps)
  kind = obj["kind"]
  meta = safe_hash(obj["metadata"])
  name = meta["name"]
  labels = safe_hash(meta["labels"])

  return true if kind == "ServiceAccount" && name == "default"
  return true if kind == "ConfigMap" && name == "kube-root-ca.crt"
  return true if labels["app.kubernetes.io/managed-by"] == "kyverno"
  return true unless labels["generate.kyverno.io/policy-name"].to_s.empty?
  return true if kind == "NetworkPolicy" && KYVERNO_NETWORK_POLICIES.include?(name)

  # 同じ List 内に親の KubeVela Application がある場合、vela-core が生成した子リソースを
  # 同時にリストアすると ResourceTracker 不整合（ownership conflict）で再同期が止まるため除く。
  is_vela_app = kind == "Application" && obj["apiVersion"].to_s.start_with?("core.oam.dev/")
  if !is_vela_app && vela_apps.include?(labels["app.oam.dev/name"].to_s) &&
     (!labels["app.oam.dev/appRevision"].to_s.empty? || !labels["app.oam.dev/component"].to_s.empty?)
    return true
  end

  false
end

def clean_annotations(meta, strip_volume_prefixes: false)
  return unless meta.is_a?(Hash)

  annotations = meta["annotations"]
  return unless annotations.is_a?(Hash)

  VOLATILE_ANNOTATIONS.each { |k| annotations.delete(k) }
  annotations.delete_if { |k, _| k.to_s.match?(VOLATILE_ANNOTATION_PREFIXES) } if strip_volume_prefixes
  meta.delete("annotations") if annotations.empty?
end

def clean_template_metadata(tmpl_meta, strip_volume_prefixes: false)
  return unless tmpl_meta.is_a?(Hash)

  tmpl_meta.delete("creationTimestamp")
  clean_annotations(tmpl_meta, strip_volume_prefixes: strip_volume_prefixes)
end

begin
  list = JSON.parse($stdin.read)
rescue JSON::ParserError => e
  if ENV["REDACT_PARSE_ERRORS"] == "true"
    abort "マニフェスト JSON が読めません"
  else
    abort "マニフェスト JSON が読めません: #{e.message}"
  end
end
abort "マニフェスト JSON のルートがオブジェクトではありません" unless list.is_a?(Hash)

raw_items = list["items"]
abort "マニフェスト JSON の items が配列ではありません" unless raw_items.nil? || raw_items.is_a?(Array)

vela_apps = Set.new
safe_array(raw_items).each do |o|
  next unless o.is_a?(Hash) && o["kind"] == "Application" && o["apiVersion"].to_s.start_with?("core.oam.dev/")

  app_name = safe_dig(o, "metadata", "name")
  vela_apps << app_name if app_name.is_a?(String) && !app_name.empty?
end

items = safe_array(raw_items).reject { |o| !o.is_a?(Hash) || generated_resource?(o, vela_apps) }
exit 3 if items.empty?

list["items"] = items
if list["metadata"].is_a?(Hash)
  list["metadata"].delete("resourceVersion")
  list["metadata"].delete("selfLink")
end

items.each do |o|
  o.delete("status")
  meta = o["metadata"]
  if meta.is_a?(Hash)
    VOLATILE_METADATA.each { |k| meta.delete(k) }
    clean_annotations(meta, strip_volume_prefixes: true)
  end

  spec = o["spec"]
  next unless spec.is_a?(Hash)

  clean_template_metadata(safe_dig(spec, "template", "metadata"))
  clean_template_metadata(safe_dig(spec, "jobTemplate", "metadata"))
  clean_template_metadata(safe_dig(spec, "jobTemplate", "spec", "template", "metadata"))
  safe_array(spec["volumeClaimTemplates"]).each do |vct|
    next unless vct.is_a?(Hash)

    vct.delete("status")
    clean_template_metadata(vct["metadata"], strip_volume_prefixes: true)
    vct["spec"].delete("volumeName") if vct["spec"].is_a?(Hash)
  end

  case o["kind"]
  when "Service"
    if spec["clusterIP"] == "None"
      spec.delete("clusterIPs") unless spec["clusterIPs"] == ["None"]
    else
      spec.delete("clusterIP")
      spec.delete("clusterIPs")
    end
    spec.delete("healthCheckNodePort")
  when "PersistentVolumeClaim"
    spec.delete("volumeName")
  end
end
print list.to_yaml
