#!/usr/bin/env ruby
# frozen_string_literal: true

# kubectl get -o json の List から、status と更新のたびに変わるメタデータを落として YAML で出す。
# そのまま kubectl apply で戻せる形にする。定義が 1 つも無ければ終了コード 3。

require "json"
require "yaml"

VOLATILE_METADATA = %w[resourceVersion uid creationTimestamp generation selfLink managedFields].freeze
VOLATILE_ANNOTATIONS = %w[
  deployment.kubernetes.io/revision
  kubectl.kubernetes.io/last-applied-configuration
  kubectl.kubernetes.io/restartedAt
].freeze

list = JSON.parse($stdin.read)
exit 3 if list["items"].empty?

list["items"].each do |o|
  o.delete("status")
  meta = o["metadata"]
  VOLATILE_METADATA.each { |k| meta.delete(k) }
  next unless (annotations = meta["annotations"])

  VOLATILE_ANNOTATIONS.each { |k| annotations.delete(k) }
  meta.delete("annotations") if annotations.empty?
end
print list.to_yaml
