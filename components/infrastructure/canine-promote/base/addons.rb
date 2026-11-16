#!/usr/bin/env ruby
# frozen_string_literal: true

# Canine のアドオン（PostgreSQL・Redis などの Helm チャート）の Namespace と、それを使うアプリの
# Namespace を対応づける。昇格ジョブがアプリと一緒にアドオンも本番（prod-<app>）へ持ち込むため。
#
# Canine はアドオンを、プロジェクトとは別の Namespace に必ず入れる（同じ Namespace は拒否する）。
# Canine 側にもアドオンとプロジェクトの結び付きは無いので、名前で決める:
#   アドオンの Namespace が <アプリの Namespace>-<何か> なら、そのアプリのもの
#   （例: robopolice-postgres・robopolice-redis は robopolice のもの）
# 見分け方:
#   - プロジェクト: ワークロードに caninemanaged=true が付く（Canine のテンプレートが必ず付ける）
#   - アドオン    : ワークロードはあるが、どれにも caninemanaged=true が付いていない（外部の Helm チャート）
#   - 持ち主      : 名前が「<持ち主>-」で始まるプロジェクトのうち、いちばん長いもの
#                   （robopolice-admin-db は robopolice-admin のもの。robopolice のものではない）
#   - <持ち主>-<数字> は PR プレビュー（Canine のフォーク）なのでアドオンにしない
#   - システム・プラットフォーム・本番（prod-*）・Config Sync 管理下の Namespace は対象外にする
#     （canine-system は caninemanaged=true で cert-manager 等を動かすが、dev のアドオンではない）
#
# 入力 : ARGV[0] = kubectl get ns -l caninemanaged=true -o json
#        ARGV[1] = kubectl get deployments,statefulsets,daemonsets,cronjobs -A -o json
# 出力 : 1 行に 1 つ「<アドオンの Namespace> <持ち主のアプリの Namespace>」
require "json"

DNS_LABEL_RE = /\A[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\z/
RESERVED_NS_RE = /\A(?:
  default |
  kube-.* |
  canine | canine-.* |
  infra |
  kyverno |
  external-secrets |
  reloader |
  headlamp |
  dev-access |
  config-management-.* |
  resource-group-system |
  gmp-.* |
  gke-.* |
  prod | prod-.*
)\z/x

ns_items = Array(JSON.parse(File.read(ARGV.fetch(0), encoding: "UTF-8"))["items"])
namespaces = ns_items.filter_map do |n|
  next unless n.is_a?(Hash)
  next if n.dig("metadata", "labels", "app.kubernetes.io/managed-by") == "configmanagement.gke.io"

  name = n.dig("metadata", "name").to_s
  name if name.match?(DNS_LABEL_RE) && !name.match?(RESERVED_NS_RE)
end

workloads = Array(JSON.parse(File.read(ARGV.fetch(1), encoding: "UTF-8"))["items"])

by_ns = Hash.new { |h, k| h[k] = [] }
workloads.each do |w|
  next unless w.is_a?(Hash)

  ns = w.dig("metadata", "namespace").to_s
  by_ns[ns] << w unless ns.empty?
end

canine_workload = ->(w) { w.dig("metadata", "labels", "caninemanaged") == "true" }

addons = namespaces.select { |ns| by_ns[ns].any? && by_ns[ns].none?(&canine_workload) }
projects = namespaces - addons

addons.sort.each do |addon|
  owner = projects
          .select { |p| addon.start_with?("#{p}-") && !addon.delete_prefix("#{p}-").match?(/\A\d+\z/) }
          .max_by(&:length)
  puts "#{addon} #{owner}" if owner
end
