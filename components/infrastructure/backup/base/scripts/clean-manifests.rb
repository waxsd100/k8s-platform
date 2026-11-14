#!/usr/bin/env ruby
# frozen_string_literal: true

# kubectl get -o json の List から、クラスタや Kyverno が自動生成するリソースを除き、
# status と更新・バインドのたびに変わるメタデータや採番済みの値を落として YAML で出す。
# そのまま kubectl apply で戻せる形にする。定義が 1 つも無ければ終了コード 3。

require "json"
require "yaml"

VOLATILE_METADATA = %w[
  resourceVersion uid creationTimestamp generation selfLink managedFields
  ownerReferences finalizers
].freeze
VOLATILE_ANNOTATIONS = %w[
  deployment.kubernetes.io/revision
  kubectl.kubernetes.io/last-applied-configuration
  kubectl.kubernetes.io/restartedAt
].freeze
VOLATILE_ANNOTATION_PREFIXES = /\A(?:pv|volume|volume\.beta)\.kubernetes\.io\//
KYVERNO_NETWORK_POLICIES = %w[environment-isolation dev-access-relay dev-to-dev].freeze

def generated_resource?(obj)
  kind = obj["kind"]
  meta = obj["metadata"] || {}
  name = meta["name"]
  labels = meta["labels"] || {}

  return true if kind == "ServiceAccount" && name == "default"
  return true if kind == "ConfigMap" && name == "kube-root-ca.crt"
  return true if labels["app.kubernetes.io/managed-by"] == "kyverno"
  return true unless labels["generate.kyverno.io/policy-name"].to_s.empty?
  return true if kind == "NetworkPolicy" && KYVERNO_NETWORK_POLICIES.include?(name)

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

list = JSON.parse($stdin.read)
items = Array(list["items"]).reject { |o| !o.is_a?(Hash) || generated_resource?(o) }
exit 3 if items.empty?

list["items"] = items
list["metadata"]&.delete("resourceVersion")
list["metadata"]&.delete("selfLink")

items.each do |o|
  o.delete("status")
  meta = o["metadata"] ||= {}
  VOLATILE_METADATA.each { |k| meta.delete(k) }
  clean_annotations(meta, strip_volume_prefixes: true)

  spec = o["spec"]
  next unless spec.is_a?(Hash)

  clean_template_metadata(spec.dig("template", "metadata"))
  clean_template_metadata(spec.dig("jobTemplate", "metadata"))
  clean_template_metadata(spec.dig("jobTemplate", "spec", "template", "metadata"))
  if spec["volumeClaimTemplates"].is_a?(Array)
    spec["volumeClaimTemplates"].each do |vct|
      next unless vct.is_a?(Hash)

      vct.delete("status")
      clean_template_metadata(vct["metadata"], strip_volume_prefixes: true)
      vct["spec"]&.delete("volumeName") if vct["spec"].is_a?(Hash)
    end
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
