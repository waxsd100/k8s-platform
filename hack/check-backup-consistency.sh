#!/bin/bash
# バックアップやクラスタ全体の設定のうち、仕組み上複数か所に書くしかないものや
# kubeconform では抜ける不整合を確かめる。cargo make validate（CI）から呼ばれる。
#
#   1. DB と見なすポート: scripts/targets.rb の DB_PORTS と、
#      Kyverno の db-backup-exec-scope（exec 先の制限）の jmesPath
#      → ずれると、取ろうとした DB への exec が拒否される / 取らない DB に exec できる
#   2. restic の版の固定: backup/base/kustomization.yaml の images の 1 か所だけにあること
#   3. 共通ユーティリティイメージの固定と一致: backup / vela-promote の 2 か所の
#      ruby および alpine/kubectl が sha256 ダイジェスト付きで完全に一致していること
#      → ずれると昇格ジョブやバックアップだけ古い / 未検証のイメージで動く
#   4. クラスタ全体のリソース（Namespace・ClusterRole・CRD・ClusterPolicy・DeletingPolicy など）に
#      トップレベルの metadata.namespace が付いていないこと（addons / components / clusters/platform）
#      → kustomize の namespace: は CRD のスコープを知らずに付けてしまい、
#        Config Sync が KNV1052 で同期全体を止める（kubeconform はスキーマが無く素通しする）
#   5. Terraform の CIDR（pods_cidr / master_ipv4_cidr_block / subnet_main_cidr）と
#      マニフェストに書き写した値の一致
#      → ずれると、送信元 IP の偽装を許す / Webhook・API が疎通不能になる
#   6. addons の Helm チャートのイメージの pin（images の newTag）と、チャートの描画するタグの一致
#      → チャートの版だけ上げて pin を直し忘れると、古いタグと digest が新しいチャートに無言で載る
#   7. clusters/platform の全ワークロード・postgres-extensions・dev-port-forward.sh の
#      イメージが有効な @sha256: ダイジェストで固定され、backup / vela-promote の 5 CronJob の
#      描画済みユーティリティイメージ（ruby / alpine/kubectl）が #3 と一致していること
#   8. Kyverno の webhookConfiguration.matchConditions と各ルールの exclude.namespaces が一致し、
#      gke-* および必須プラットフォーム Namespace（vela-system / velaux-store）が抜け落ちていないこと
#   9. Kyverno 生成 NetworkPolicy 名（KYVERNO_NETWORK_POLICIES）の 3 か所一致と、
#      予約・除外 Namespace 一覧（terraform/gke.tf・promote.rb・cronjob.yaml・
#      dev-port-forward.sh・manifest-backup）の整合性
set -euo pipefail
cd "$(dirname "$0")/.."

# NOTE: 標準入力のスクリプトと読み込む YAML はロケール既定の文字コードで解釈されるため、
#       LANG=C / POSIX の端末でも落ちないよう UTF-8 を明示する。
exec ruby -E UTF-8:UTF-8 - <<'RUBY'
# encoding: utf-8
# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "open3"
require "ripper"
require "set"
require "time"
require "tmpdir"
require "yaml"

BASE = "components/infrastructure/backup/base"
TARGETS_RB = "#{BASE}/scripts/targets.rb"
BACKUP_KUST = "#{BASE}/kustomization.yaml"
POLICY = "addons/kyverno/base/clusterpolicy-db-backup-exec.yaml"
UTILITY_KUSTOMIZATIONS = %w[
  components/infrastructure/backup/base/kustomization.yaml
  components/infrastructure/vela-promote/base/kustomization.yaml
].freeze
SHARED_UTILITY_IMAGES = %w[
  ruby
  alpine/kubectl
].freeze

# JMESPath のプレフィックス比較（'restic/restic:' や 'restic/restic@sha256:'）や正規表現を除外しつつ、
# 任意の記号タグ（:stable / :main / :edge 等）や短縮・破損ダイジェスト（@sha256:... / @...）をすべて検出する。
RESTIC_PIN_REGEX = /\brestic\/restic(?::[A-Za-z0-9_-][A-Za-z0-9._-]*|@(?![A-Za-z0-9_+.-]+:['"\[\.(])[A-Za-z0-9_-])/i

# Kubernetes 標準および本リポジトリが扱う CRD のうち、クラスタスコープ（scope: Cluster）のもの。
# NOTE: Kyverno の PolicyException（kyverno.io / policies.kyverno.io）は Namespaced なので含めない。
CLUSTER_SCOPED_KINDS = Set.new(%w[
  Namespace
  Node
  PersistentVolume
  ClusterRole
  ClusterRoleBinding
  StorageClass
  CSIDriver
  CSINode
  VolumeAttachment
  PriorityClass
  RuntimeClass
  IngressClass
  ValidatingWebhookConfiguration
  MutatingWebhookConfiguration
  ValidatingAdmissionPolicy
  ValidatingAdmissionPolicyBinding
  MutatingAdmissionPolicy
  MutatingAdmissionPolicyBinding
  CustomResourceDefinition
  APIService
  CertificateSigningRequest
  FlowSchema
  PriorityLevelConfiguration
  ClusterTrustBundle
  IPAddress
  ServiceCIDR
  VolumeSnapshotClass
  VolumeSnapshotContent
  ClusterPolicy
  ClusterCleanupPolicy
  GlobalContextEntry
  DeletingPolicy
  GeneratingPolicy
  ImageValidatingPolicy
  MutatingPolicy
  ValidatingPolicy
  ClusterEphemeralReport
  ClusterPolicyReport
  ClusterReport
  ClusterSecretStore
  ClusterExternalSecret
  ClusterGenerator
  ClusterPushSecret
  ClusterIssuer
  ResourceTracker
]).freeze

def safe_load_all(yaml_text)
  loader = Psych::ClassLoader::Restricted.new(%w[Date Time Symbol], [])
  scanner = Psych::ScalarScanner.new(loader)
  stream = YAML.parse_stream(yaml_text)
  return [] unless stream.respond_to?(:children)

  stream.children.filter_map do |doc|
    Psych::Visitors::ToRuby.new(scanner, loader).accept(doc)
  end
end

def load_yaml_docs(yaml_text, source_label)
  safe_load_all(yaml_text)
rescue Psych::Exception, ArgumentError => e
  puts "NG: #{source_label} の YAML 読み込みに失敗しました (#{e.class}): #{e.message}"
  nil
end

def unwrap_k8s_objects(doc, out = [])
  return out unless doc.is_a?(Hash)

  kind = doc["kind"]
  if kind.is_a?(String) && kind.end_with?("List") && doc["items"].is_a?(Array)
    doc["items"].each { |item| unwrap_k8s_objects(item, out) }
  elsif kind.is_a?(String)
    out << doc
  end
  out
end

def unwrap_hash_sexp(node)
  return nil unless node.is_a?(Array)

  case node[0]
  when :hash
    node
  when :call
    if node.dig(3, 0) == :@ident && node.dig(3, 1) == "freeze" && node[4].nil?
      unwrap_hash_sexp(node[1])
    end
  when :paren
    stmts = node[1]
    stmts.is_a?(Array) && stmts.size == 1 ? unwrap_hash_sexp(stmts[0]) : nil
  end
end

def collect_db_ports_assigns(node, out = [])
  return out unless node.is_a?(Array)

  if node[0] == :assign && node[1].is_a?(Array) &&
     %i[var_field top_const_field].include?(node[1][0]) &&
     node.dig(1, 1, 0) == :@const && node.dig(1, 1, 1) == "DB_PORTS"
    out << node[2]
  end
  node.each { |child| collect_db_ports_assigns(child, out) if child.is_a?(Array) }
  out
end

def extract_rb_db_ports(ruby_src)
  sexp = Ripper.sexp(ruby_src)
  return [:invalid, "Ruby 構文エラー"] if sexp.nil?

  assigns = collect_db_ports_assigns(sexp)
  return [:invalid, "DB_PORTS 定数が見つかりません"] if assigns.empty?
  return [:invalid, "DB_PORTS が複数回定義されています"] if assigns.size > 1

  hash_node = unwrap_hash_sexp(assigns.first)
  return [:invalid, "DB_PORTS が Hash リテラルではありません"] if hash_node.nil?

  assoc_list = hash_node[1]
  return [:ok, ""] if assoc_list.nil?
  return [:invalid, "DB_PORTS の Hash 構造を解析できません"] unless assoc_list.is_a?(Array) && assoc_list[0] == :assoclist_from_args

  ports = []
  Array(assoc_list[1]).each do |pair|
    unless pair.is_a?(Array) && pair[0] == :assoc_new &&
           pair[1].is_a?(Array) && pair[1][0] == :@int
      return [:invalid, "DB_PORTS に整数リテラル以外のキーが含まれています"]
    end

    port = Integer(pair[1][1])
    return [:invalid, "DB_PORTS のポート番号が範囲外です: #{port}"] unless port.between?(1, 65_535)

    ports << port
  end

  [:ok, ports.uniq.sort.join(" ")]
rescue ArgumentError => e
  [:invalid, e.message]
end

def collect_condition_strings(cond_block, out = [])
  case cond_block
  when Array
    cond_block.each { |item| collect_condition_strings(item, out) }
  when Hash
    if cond_block.key?("any") || cond_block.key?("all")
      collect_condition_strings(cond_block["any"], out)
      collect_condition_strings(cond_block["all"], out)
    else
      out << cond_block["key"].to_s if cond_block.key?("key")
      out << cond_block["value"].to_s if cond_block.key?("value")
    end
  end
  out
end

def collect_rule_expressions(rule_like, out = [])
  return out unless rule_like.is_a?(Hash)

  Array(rule_like["context"]).each do |ctx|
    next unless ctx.is_a?(Hash)

    jmes = ctx.dig("apiCall", "jmesPath") || ctx.dig("variable", "jmesPath")
    out << jmes.to_s if jmes
    val = ctx.dig("variable", "value")
    out << val.to_json if val
  end

  collect_condition_strings(rule_like["preconditions"], out)
  collect_condition_strings(rule_like.dig("validate", "deny", "conditions"), out)
  collect_condition_strings(rule_like.dig("deny", "conditions"), out)

  Array(rule_like.dig("validate", "cel", "expressions")).each do |cel|
    out << cel["expression"].to_s if cel.is_a?(Hash) && cel["expression"]
  end
  Array(rule_like.dig("cel", "expressions")).each do |cel|
    out << cel["expression"].to_s if cel.is_a?(Hash) && cel["expression"]
  end

  Array(rule_like.dig("validate", "foreach")).each do |fe|
    collect_rule_expressions(fe, out)
  end
  out
end

def extract_ports_from_expr(expr)
  ports = []
  expr.scan(/containerPort\s*(?:==|!=)\s*`(\d+)`/).each { |m| ports << m[0].to_i }
  expr.scan(/`(\d+)`\s*(?:==|!=)\s*(?:@\.)?containerPort\b/).each { |m| ports << m[0].to_i }
  expr.scan(/contains\(\s*`\[([0-9,\s]+)\]`\s*,\s*(?:@\.)?containerPort\b\s*\)/).each do |m|
    m[0].scan(/\d+/).each { |d| ports << d.to_i }
  end
  expr.scan(/containerPort\s*(?:==|!=)\s*(\d+)\b/).each { |m| ports << m[0].to_i }
  expr.scan(/\b(\d+)\s*(?:==|!=)\s*[A-Za-z0-9_.]*containerPort\b/).each { |m| ports << m[0].to_i }
  expr.scan(/containerPort\s+in\s+\[([0-9,\s]+)\]/).each do |m|
    m[0].scan(/\d+/).each { |d| ports << d.to_i }
  end
  ports
end

def strip_line_comment(line, ext)
  in_single = false
  in_double = false
  escaped = false
  i = 0
  len = line.length
  while i < len
    ch = line[i]
    if escaped
      escaped = false
    elsif in_single
      if ext == ".rb" && ch == "\\"
        escaped = true
      elsif ch == "'"
        in_single = false
      end
    elsif in_double
      if ch == "\\"
        escaped = true
      elsif ch == '"'
        in_double = false
      end
    elsif ch == "'"
      in_single = true
    elsif ch == '"'
      in_double = true
    elsif ch == "#" && (ext == ".rb" || i.zero? || line[i - 1].match?(/\s/))
      return line[0...i]
    end
    i += 1
  end
  line
end

def uncommented_lines_for_scan(file)
  src = File.read(file)
  ext = File.extname(file)
  if ext == ".rb" && !Ripper.sexp(src).nil?
    comment_events = %i[on_comment on_embdoc_beg on_embdoc on_embdoc_end]
    by_line = Hash.new { |h, k| h[k] = +"" }
    Ripper.lex(src).each do |(lineno, _col), event, tok, _state|
      next if comment_events.include?(event)

      by_line[lineno] << tok
    end
    raw_lines = src.lines(chomp: true)
    return raw_lines.each_with_index.map { |raw, idx| [idx + 1, by_line[idx + 1], raw] }
  end

  src.lines(chomp: true).each_with_index.map do |raw, idx|
    [idx + 1, strip_line_comment(raw, ext), raw]
  end
end

# <repository>[:<tag>]@sha256:<64-hex> を不変識別子 <repository>@sha256:<64-hex> に正規化する。
# Helm の image.tag ("latest@sha256:...") と Kustomize images の digest / newTag 表記差を吸収しつつ、
# リポジトリ名と 64 桁 sha256 ダイジェストの完全一致を厳密に検査する。
def canonical_image_ref(ref)
  return nil unless ref.is_a?(String)

  m = ref.match(/\A([^:@\s]+)(?::[A-Za-z0-9_][A-Za-z0-9._-]{0,127})?@(sha256:[0-9a-f]{64})\z/)
  m ? "#{m[1]}@#{m[2]}" : nil
end

def resolve_restic_image(kust_doc)
  entries = Array(kust_doc["images"]).select do |i|
    i.is_a?(Hash) && (
      i["name"].to_s.strip == "restic/restic" ||
      i["newName"].to_s.strip == "restic/restic" ||
      i["name"].to_s.strip.end_with?("/restic/restic") ||
      i["newName"].to_s.strip.end_with?("/restic/restic")
    )
  end
  return [:missing, ""] if entries.empty?
  return [:conflict, "複数の restic/restic エントリがあります (#{entries.size} 件)"] if entries.size > 1

  entry = entries.first
  name = entry["name"].to_s.strip
  return [:invalid_repo, "name=#{name}"] unless name == "restic/restic"

  repo = entry.key?("newName") ? entry["newName"].to_s.strip : name
  new_tag = entry["newTag"].to_s.strip
  digest = entry["digest"].to_s.strip
  if new_tag.include?("@") && !digest.empty?
    return [:conflict, "newTag (#{new_tag}) と digest (#{digest}) が重複指定されています"]
  end

  ref =
    if !new_tag.empty? && !digest.empty?
      "#{repo}:#{new_tag}@#{digest}"
    elsif !digest.empty?
      "#{repo}@#{digest}"
    elsif !new_tag.empty?
      "#{repo}:#{new_tag}"
    else
      repo
    end

  [:ok, ref]
end

def resolve_utility_image(kust_doc, target_name)
  entries = Array(kust_doc["images"]).select do |entry|
    entry.is_a?(Hash) && (
      entry["name"].to_s.strip == target_name ||
      entry["newName"].to_s.strip == target_name ||
      entry["name"].to_s.strip.end_with?("/#{target_name}") ||
      entry["newName"].to_s.strip.end_with?("/#{target_name}")
    )
  end
  return [:missing, nil] if entries.empty?
  return [:conflict, "複数の #{target_name} エントリがあります (#{entries.size} 件)"] if entries.size > 1

  entry = entries.first
  name = entry["name"].to_s.strip
  return [:invalid_repo, "name=#{name}"] unless name == target_name

  new_name = entry["newName"].to_s.strip
  repo = new_name.empty? ? name : new_name
  new_tag = entry["newTag"].to_s.strip
  digest = entry["digest"].to_s.strip
  if new_tag.include?("@") && !digest.empty?
    return [:conflict, "images newTag (#{new_tag}) と digest (#{digest}) が重複指定されています"]
  end

  ref =
    if !new_tag.empty? && !digest.empty?
      "#{repo}:#{new_tag}@#{digest}"
    elsif !digest.empty?
      "#{repo}@#{digest}"
    elsif !new_tag.empty?
      "#{repo}:#{new_tag}"
    else
      repo
    end

  [:ok, ref]
end

failed = false

# -----------------------------------------------------------------------------
# 1. targets.rb の DB_PORTS のキーと、Kyverno の containerPort 条件を比べる
# -----------------------------------------------------------------------------
if !File.file?(TARGETS_RB)
  puts "NG: #{TARGETS_RB} が見つかりません"
  failed = true
elsif !File.file?(POLICY)
  puts "NG: #{POLICY} が見つかりません"
  failed = true
else
  rb_state, rb_ports = extract_rb_db_ports(File.read(TARGETS_RB))
  policy_docs = load_yaml_docs(File.read(POLICY), POLICY)
  if rb_state != :ok
    puts "NG: #{TARGETS_RB} の DB_PORTS を解析できません: #{rb_ports}"
    failed = true
  elsif policy_docs.nil?
    failed = true
  else
    exprs = policy_docs.flat_map do |doc|
      next [] unless doc.is_a?(Hash)

      Array(doc.dig("spec", "rules")).flat_map { |rule| collect_rule_expressions(rule) }
    end
    kyverno_ports = exprs.flat_map { |e| extract_ports_from_expr(e) }.uniq.sort.join(" ")

    if rb_ports.empty? || rb_ports != kyverno_ports
      puts "NG: DB のポートが揃っていません: targets.rb DB_PORTS=[#{rb_ports}] #{POLICY}=[#{kyverno_ports}]"
      failed = true
    else
      puts "ok: DB のポート (#{rb_ports})"
    end
  end
end

# -----------------------------------------------------------------------------
# 2. 版（タグや digest）付きの restic/restic は backup/base/kustomization.yaml の 1 か所だけ
# -----------------------------------------------------------------------------
if !File.file?(BACKUP_KUST)
  puts "NG: #{BACKUP_KUST} が見つかりません"
  failed = true
else
  backup_kust_docs = load_yaml_docs(File.read(BACKUP_KUST), BACKUP_KUST)
  if backup_kust_docs.nil?
    failed = true
  else
    backup_kust = backup_kust_docs.first.is_a?(Hash) ? backup_kust_docs.first : {}
    restic_state, restic_ref = resolve_restic_image(backup_kust)
    restic_canon = restic_state == :ok ? canonical_image_ref(restic_ref) : nil

    pinned = []
    non_images_json = backup_kust.reject { |k, _| k == "images" }.to_json
    if non_images_json.match?(RESTIC_PIN_REGEX)
      pinned << "#{BACKUP_KUST}: images 以外に restic/restic の版指定があります"
    end

    scan_files = (
      Dir.glob("{components,addons,clusters}/**/*.{yaml,yml,rb,sh}") +
      Dir.glob("{components,addons,clusters}/**/Kustomization")
    ).uniq.sort

    kust_basenames = %w[kustomization.yaml kustomization.yml Kustomization]
    restic_kust_err = false

    scan_files.each do |file|
      next if file == BACKUP_KUST || file.include?("/charts/")

      uncommented_lines_for_scan(file).each do |lineno, code_line, raw_line|
        if code_line.match?(RESTIC_PIN_REGEX)
          pinned << "#{file}:#{lineno}:#{raw_line}"
        end
      end

      next unless kust_basenames.include?(File.basename(file))

      other_docs = load_yaml_docs(File.read(file), file)
      if other_docs.nil?
        restic_kust_err = true
        next
      end
      other_kust = other_docs.first.is_a?(Hash) ? other_docs.first : {}
      has_restic_image = Array(other_kust["images"]).any? do |i|
        i.is_a?(Hash) && (
          i["name"].to_s.strip == "restic/restic" ||
          i["newName"].to_s.strip == "restic/restic" ||
          i["name"].to_s.strip.end_with?("/restic/restic") ||
          i["newName"].to_s.strip.end_with?("/restic/restic")
        )
      end
      pinned << "#{file}: images に restic/restic が指定されています" if has_restic_image
    end

    if restic_kust_err
      failed = true
    elsif restic_state == :conflict
      puts "NG: #{BACKUP_KUST} の restic/restic 指定が不正です: #{restic_ref}"
      failed = true
    elsif restic_canon.nil? || !restic_canon.start_with?("restic/restic@sha256:")
      puts "NG: #{BACKUP_KUST} の restic/restic に有効な sha256 ダイジェストが付いていません: #{restic_ref}"
      failed = true
    elsif pinned.any?
      puts "NG: restic/restic の版が #{BACKUP_KUST} の images 以外にあります:"
      pinned.each { |hit| puts hit }
      failed = true
    else
      puts "ok: restic/restic の版は #{BACKUP_KUST} だけ"
    end
  end
end

# -----------------------------------------------------------------------------
# 3. 共通ユーティリティイメージ（ruby / alpine/kubectl）のタグ・sha256 ダイジェストが
#    backup / vela-promote の 2 か所で完全一致していること
# -----------------------------------------------------------------------------
utility_kust_docs = {}
utility_err = false
UTILITY_KUSTOMIZATIONS.each do |file|
  unless File.file?(file)
    puts "NG: 共通ユーティリティイメージを確認するファイルが見つかりません: #{file}"
    utility_err = true
    next
  end

  docs = load_yaml_docs(File.read(file), file)
  if docs.nil?
    utility_err = true
    next
  end

  utility_kust_docs[file] = docs.first.is_a?(Hash) ? docs.first : {}
end

shared_utility_canon = {}
shared_utility_raw = {}
SHARED_UTILITY_IMAGES.each do |img_name|
  refs_by_file = {}
  raw_by_file = {}
  img_err = false

  UTILITY_KUSTOMIZATIONS.each do |file|
    doc = utility_kust_docs[file]
    next if doc.nil?

    state, ref = resolve_utility_image(doc, img_name)
    case state
    when :missing
      puts "NG: #{file} に #{img_name} のイメージ定義がありません"
      img_err = true
    when :conflict
      puts "NG: #{file} の #{img_name} イメージ定義が不正です: #{ref}"
      img_err = true
    when :invalid_repo
      puts "NG: #{file} の #{img_name} エントリ名が不正です: #{ref}"
      img_err = true
    when :ok
      canon = canonical_image_ref(ref)
      if canon
        refs_by_file[file] = canon
        raw_by_file[file] = ref
      else
        puts "NG: #{file} の #{img_name} に有効な sha256 ダイジェストが付いていません: #{ref}"
        img_err = true
      end
    end
  end

  if img_err
    utility_err = true
    next
  end

  next unless refs_by_file.size == UTILITY_KUSTOMIZATIONS.size

  if refs_by_file.values.uniq.size != 1 || raw_by_file.values.uniq.size != 1
    puts "NG: #{img_name} のイメージ定義（タグ・sha256 ダイジェスト）が #{UTILITY_KUSTOMIZATIONS.size} か所で一致していません:"
    UTILITY_KUSTOMIZATIONS.each do |file|
      puts "  #{file}: #{raw_by_file[file]} (canonical: #{refs_by_file[file]})"
    end
    utility_err = true
  else
    shared_utility_canon[img_name] = refs_by_file.values.first
    shared_utility_raw[img_name] = raw_by_file.values.first
  end
end

if utility_err
  failed = true
else
  puts "ok: 共通ユーティリティイメージのダイジェスト一致 (#{SHARED_UTILITY_IMAGES.map { |n| shared_utility_raw[n] }.join(', ')})"
end

# -----------------------------------------------------------------------------
# 4. クラスタ全体のリソースにトップレベルの metadata.namespace が付いていないこと
#    Pass 1: 全 kustomization を描画してキャッシュしつつ、scope: Cluster の CRD を全体集約する
#    Pass 2: 全描画済みオブジェクトを CLUSTER_SCOPED_KINDS + 集約済み CRD で検査する
# -----------------------------------------------------------------------------
kust_dirs = Dir.glob("{addons,components,clusters}/**/{kustomization.yaml,kustomization.yml,Kustomization}")
               .reject { |f| f.include?("/charts/") }
               .map { |f| File.dirname(f) }
               .uniq
               .sort

ns_err = false
rendered_by_dir = {}
dynamic_cluster_kinds = Set.new

kust_dirs.each do |dir|
  begin
    stdout, stderr, status = Open3.capture3("kustomize", "build", "--enable-helm", dir)
  rescue Errno::ENOENT
    puts "NG: kustomize コマンドが見つかりません"
    ns_err = true
    break
  end

  unless status.success?
    puts "NG: kustomize build --enable-helm #{dir} に失敗しました:"
    puts stderr
    ns_err = true
    next
  end

  docs = load_yaml_docs(stdout, "kustomize build --enable-helm #{dir}")
  if docs.nil?
    ns_err = true
    next
  end

  objs = docs.flat_map { |doc| unwrap_k8s_objects(doc) }
  rendered_by_dir[dir] = objs

  objs.each do |obj|
    next unless obj["kind"] == "CustomResourceDefinition" && obj.dig("spec", "scope") == "Cluster"

    crd_group = obj.dig("spec", "group").to_s.strip
    crd_kind = obj.dig("spec", "names", "kind").to_s.strip
    dynamic_cluster_kinds << [crd_group, crd_kind] unless crd_kind.empty?
  end
end

rendered_by_dir.each do |dir, objs|
  bad = []
  objs.each do |obj|
    kind = obj["kind"].to_s.strip
    api_version = obj["apiVersion"].to_s.strip
    api_group = api_version.include?("/") ? api_version.split("/", 2).first : ""
    next unless CLUSTER_SCOPED_KINDS.include?(kind) || dynamic_cluster_kinds.include?([api_group, kind])

    meta = obj["metadata"]
    next unless meta.is_a?(Hash)

    ns = meta["namespace"].to_s.strip
    next if ns.empty?

    bad << "  #{kind}/#{meta['name']} (namespace=#{ns})"
  end

  next if bad.empty?

  puts "NG: #{dir} のクラスタ全体のリソースに metadata.namespace が付いています（cluster-resources に分ける）:"
  bad.each { |line| puts line }
  ns_err = true
end

if ns_err
  failed = true
else
  puts "ok: クラスタ全体のリソースに namespace が付いていない (#{kust_dirs.size} kustomizations)"
end

# --- 5. Terraform の CIDR とマニフェストに書き写した CIDR の一致 ---
# マニフェストは Terraform の変数を参照できないので、同じ値を複数か所に書いている。
# 片方だけ変えると、送信元 IP の偽装を許す・Webhook や API 通信が落ちる。
TF_VARIABLES = "terraform/variables.tf"
NGINX_BASE_DIR = "components/infrastructure/nginx-ingress/base"
WEBHOOK_NETPOLS = {
  "addons/kyverno/base/networkpolicy.yaml" => "kyverno-allow-webhooks",
  "addons/external-secrets/base/networkpolicy.yaml" => "eso-allow-webhook",
  "addons/kubevela/base/networkpolicy.yaml" => "vela-core-allow-webhook"
}.freeze
CONTROL_PLANE_EGRESS_NETPOLS = {
  "components/infrastructure/nginx-ingress/base/networkpolicy.yaml" => "ingress-nginx-egress-restrict",
  "addons/kubevela/base/networkpolicy.yaml" => "vela-core-egress-restrict",
  "components/infrastructure/velaux/base/networkpolicy.yaml" => "velaux-egress-restrict",
  "components/infrastructure/vela-promote/base/networkpolicy.yaml" => "vela-promote-egress-restrict",
  "components/infrastructure/backup/base/networkpolicy.yaml" => "manifest-backup-egress"
}.freeze

def tf_variable_default(src, name)
  block = src[/^variable\s+"#{Regexp.escape(name)}"\s*\{.*?^\}/m]
  block && block[/^\s*default\s*=\s*"([^"]*)"/, 1]
end

cidr_err = false
missing_cidr_files = [
  TF_VARIABLES,
  *WEBHOOK_NETPOLS.keys,
  *CONTROL_PLANE_EGRESS_NETPOLS.keys
].uniq.reject { |f| File.file?(f) }

if missing_cidr_files.any?
  missing_cidr_files.each { |f| puts "NG: CIDR 整合性チェックの対象ファイルが見つかりません: #{f}" }
  cidr_err = true
else
  tf_src = File.read(TF_VARIABLES)
  pods_cidr = tf_variable_default(tf_src, "pods_cidr")
  master_cidr = tf_variable_default(tf_src, "master_ipv4_cidr_block")
  subnet_cidr = tf_variable_default(tf_src, "subnet_main_cidr")

  if [pods_cidr, master_cidr, subnet_cidr].any?(&:nil?)
    puts "NG: Terraform から CIDR（pods_cidr / master_ipv4_cidr_block / subnet_main_cidr）を読み取れません"
    cidr_err = true
  else
    nginx_objs = rendered_by_dir[NGINX_BASE_DIR]
    nginx_cm = Array(nginx_objs).find do |o|
      o.is_a?(Hash) && o["kind"] == "ConfigMap" && o.dig("metadata", "name") == "ingress-nginx-controller"
    end
    nginx_cidr = nginx_cm.is_a?(Hash) && nginx_cm["data"].is_a?(Hash) ? nginx_cm["data"]["proxy-real-ip-cidr"] : nil
    unless nginx_cidr == pods_cidr
      puts "NG: #{NGINX_BASE_DIR} の描画済み ConfigMap/ingress-nginx-controller の proxy-real-ip-cidr " \
           "(#{nginx_cidr.inspect}) が #{TF_VARIABLES} の pods_cidr (#{pods_cidr}) と一致しません"
      cidr_err = true
    end

    # Webhook 着信 NetworkPolicy の許可 CIDR が master_ipv4_cidr_block / subnet_main_cidr と一致すること
    expected_webhook_cidrs = [master_cidr, subnet_cidr].sort
    WEBHOOK_NETPOLS.each do |file, np_name|
      np_docs = load_yaml_docs(File.read(file), file)
      if np_docs.nil?
        cidr_err = true
        next
      end
      np = np_docs.flat_map { |d| unwrap_k8s_objects(d) }
                  .find { |o| o["kind"] == "NetworkPolicy" && o.dig("metadata", "name") == np_name }
      actual_cidrs = np ? Array(np.dig("spec", "ingress"))
                          .flat_map { |r| Array(r["from"]) }
                          .filter_map { |f| f.is_a?(Hash) ? f.dig("ipBlock", "cidr") : nil }
                          .sort : []
      next if actual_cidrs == expected_webhook_cidrs

      puts "NG: #{file} (#{np_name}) の ingress ipBlock (#{actual_cidrs.inspect}) が " \
           "Terraform の master_ipv4_cidr_block / subnet_main_cidr (#{expected_webhook_cidrs.inspect}) と一致しません"
      cidr_err = true
    end

    # コントロールプレーン API 向け Egress NetworkPolicy が master_ipv4_cidr_block を含むこと
    CONTROL_PLANE_EGRESS_NETPOLS.each do |file, np_name|
      np_docs = load_yaml_docs(File.read(file), file)
      if np_docs.nil?
        cidr_err = true
        next
      end
      np = np_docs.flat_map { |d| unwrap_k8s_objects(d) }
                  .find { |o| o["kind"] == "NetworkPolicy" && o.dig("metadata", "name") == np_name }
      egress_cidrs = np ? Array(np.dig("spec", "egress"))
                          .flat_map { |r| Array(r["to"]) }
                          .filter_map { |t| t.is_a?(Hash) ? t.dig("ipBlock", "cidr") : nil } : []
      next if egress_cidrs.include?(master_cidr)

      puts "NG: #{file} (#{np_name}) の egress ipBlock (#{egress_cidrs.inspect}) に " \
           "Terraform の master_ipv4_cidr_block (#{master_cidr}) が含まれていません"
      cidr_err = true
    end
  end
end

if cidr_err
  failed = true
else
  puts "ok: Pod / Control Plane / Subnet の CIDR が Terraform と一致 " \
       "(#{pods_cidr} / #{master_cidr} / #{subnet_cidr})"
end

# -----------------------------------------------------------------------------
# 6. addons の Helm チャートのイメージの pin（images の newTag）が、チャートの描画するタグと一致すること
#    pin はチャートの版と一緒に直す必要がある。版だけ上げて pin を直し忘れると、古いタグと digest が
#    新しいチャートに無言で載るため、pin を外した複製をチャートで描画して照合する。
#    版上げで新しく増えたイメージに pin が無い場合も検出する。
# -----------------------------------------------------------------------------
ADDON_PIN_KUSTOMIZATIONS = %w[
  addons/kyverno/base/kustomization.yaml
  addons/external-secrets/base/kustomization.yaml
  addons/reloader/base/kustomization.yaml
  addons/headlamp/base/kustomization.yaml
  addons/kubevela/base/kustomization.yaml
].freeze
POD_TEMPLATE_KINDS = %w[Pod Deployment StatefulSet DaemonSet ReplicaSet Job CronJob].freeze

# <name>[:<tag>][@<digest>] を [name, tag] に分ける（タグが無ければ ""）
def split_image_ref(ref)
  m = ref.split("@", 2).first.match(/\A(.+?)(?::([^\/:]+))?\z/)
  [m[1], m[2].to_s]
end

# Pod テンプレートを持つオブジェクトの initContainers / containers / ephemeralContainers のイメージ参照を返す
def pod_template_images(objs)
  objs.flat_map do |o|
    next [] unless POD_TEMPLATE_KINDS.include?(o["kind"])

    spec =
      case o["kind"]
      when "Pod" then o["spec"]
      when "CronJob" then o.dig("spec", "jobTemplate", "spec", "template", "spec")
      else o.dig("spec", "template", "spec")
      end
    next [] unless spec.is_a?(Hash)

    %w[initContainers containers ephemeralContainers].flat_map { |k| Array(spec[k]) }
                                                     .filter_map { |c| c["image"] if c.is_a?(Hash) && c["image"].is_a?(String) }
  end
end

# kustomization の images を外した複製を一時ディレクトリで --enable-helm 描画する（リポジトリ内には書かない）
# 戻り値: [:ok, オブジェクト配列] / [:error, 標準エラー] / [:missing, nil]
def render_without_images(kust_file)
  docs = load_yaml_docs(File.read(kust_file), kust_file)
  return [:error, "#{kust_file} の YAML を読めません"] if docs.nil?

  kust = docs.first.is_a?(Hash) ? docs.first : {}
  kust.delete("images")
  dir = File.dirname(kust_file)

  Dir.mktmpdir("addon-pin-") do |tmp|
    Dir.children(dir).each do |child|
      next if child == "charts"

      FileUtils.cp_r(File.join(dir, child), tmp)
    end
    File.write(File.join(tmp, File.basename(kust_file)), kust.to_yaml)

    begin
      stdout, stderr, status = Open3.capture3("kustomize", "build", "--enable-helm", tmp)
    rescue Errno::ENOENT
      return [:missing, nil]
    end
    return [:error, stderr] unless status.success?

    rendered = load_yaml_docs(stdout, "kustomize build --enable-helm #{dir} (images なし)")
    return [:error, "描画結果の YAML を読めません"] if rendered.nil?

    [:ok, rendered.flat_map { |doc| unwrap_k8s_objects(doc) }]
  end
end

pin_err = false
pin_count = 0
ADDON_PIN_KUSTOMIZATIONS.each do |file|
  unless File.file?(file)
    puts "NG: #{file} が見つかりません"
    pin_err = true
    next
  end

  docs = load_yaml_docs(File.read(file), file)
  if docs.nil?
    pin_err = true
    next
  end
  kust = docs.first.is_a?(Hash) ? docs.first : {}

  # 名前 => { tag:, digest:, raw: }。digest は newTag の @ 以降（無ければ digest: の値）
  pins = {}
  Array(kust["images"]).each do |entry|
    next unless entry.is_a?(Hash)

    name = entry["name"].to_s.strip
    new_tag_str = entry["newTag"].to_s.strip
    digest_field = entry["digest"].to_s.strip
    tag, digest_in_tag = new_tag_str.split("@", 2)
    if digest_in_tag && !digest_field.empty?
      puts "NG: #{file} の images (#{name}) で newTag の @digest (#{new_tag_str}) と digest (#{digest_field}) が重複指定されています"
      pin_err = true
      next
    end
    if pins.key?(name)
      puts "NG: #{file} の images に #{name} が重複しています"
      pin_err = true
      next
    end
    pins[name] = {
      tag: tag.to_s,
      digest: (digest_in_tag || digest_field).to_s.strip,
      raw: "#{entry['newTag']}#{entry['digest'] ? " digest=#{entry['digest']}" : ''}"
    }
  end

  state, payload = render_without_images(file)
  if state == :missing
    puts "NG: kustomize コマンドが見つかりません"
    pin_err = true
    break
  elsif state == :error
    puts "NG: #{file} の images を外した複製を描画できません:"
    puts payload
    pin_err = true
    next
  end

  # 描画結果のイメージ名 => タグの一覧
  native = {}
  pod_template_images(payload).each do |ref|
    name, tag = split_image_ref(ref)
    (native[name] ||= []) << tag unless (native[name] || []).include?(tag)
  end

  if native.empty?
    puts "NG: #{file} の描画結果に Pod のイメージがありません"
    pin_err = true
    next
  end

  native.each do |name, tags|
    pin = pins[name]
    if pin.nil?
      puts "NG: #{file} のチャートが描画する #{name}:#{tags.join(', ')} に images の pin がありません" \
           "（版上げで増えたイメージなら digest 付きで images に追加してください）"
      pin_err = true
      next
    end

    tags.each do |tag|
      next if tag == pin[:tag]

      puts "NG: #{file} の #{name} の pin のタグ (#{pin[:tag]}) が、チャートの描画するタグ (#{tag}) と一致しません" \
           "（images の newTag を描画に合わせて更新してください）"
      pin_err = true
    end
  end

  (pins.keys - native.keys).each do |name|
    puts "NG: #{file} の images に #{name} がありますが、チャートはこのイメージを描画していません（削除してください）"
    pin_err = true
  end

  pins.each do |name, pin|
    next if pin[:digest].match?(/\Asha256:[0-9a-f]{64}\z/)

    puts "NG: #{file} の #{name} に有効な sha256 ダイジェストが付いていません: #{pin[:raw]}"
    pin_err = true
  end

  pin_count += native.size
end

if pin_err
  failed = true
else
  puts "ok: addon のイメージ pin がチャートの描画するタグと一致 (#{pin_count} イメージ / #{ADDON_PIN_KUSTOMIZATIONS.size} kustomizations)"
end

# -----------------------------------------------------------------------------
# 7. プラットフォーム全イメージの @sha256: ダイジェスト固定と共通ユーティリティ CronJob 一致検査
#    Section 6 は Helm addon のみ対象のため、clusters/platform 全体の描画結果
#    （kubevela-vela-core / velaux-server / ingress-nginx / cloudflared / backrest /
#      rest-server / vela-promote / backup 等）、
#    postgres-extensions ConfigMap、hack/dev-port-forward.sh も一括で検証する。
# -----------------------------------------------------------------------------
PG_EXT_CM = "addons/kyverno/base/configmap-postgres-extensions.yaml"
DEV_PF_SCRIPT = "hack/dev-port-forward.sh"
UTILITY_CRONJOBS = %w[
  backup-watchdog
  db-backup
  manifest-backup
  pvc-backup
  vela-promote
].freeze

digest_err = false
checked_images = 0

platform_objs = rendered_by_dir["clusters/platform"]
if platform_objs.nil? || platform_objs.empty?
  puts "NG: clusters/platform の描画結果が空のためイメージダイジェスト検査を実行できません"
  digest_err = true
else
  utility_cronjob_ruby = Hash.new { |h, k| h[k] = [] }
  utility_cronjob_kubectl = Hash.new { |h, k| h[k] = [] }

  platform_objs.each do |obj|
    next unless obj.is_a?(Hash) && POD_TEMPLATE_KINDS.include?(obj["kind"])

    ns = obj.dig("metadata", "namespace").to_s
    # 昇格済みユーザーアプリ（prod-*）はプラットフォーム管理外のため除外する
    next if ns.start_with?("prod-")

    name = obj.dig("metadata", "name").to_s
    spec =
      case obj["kind"]
      when "Pod" then obj["spec"]
      when "CronJob" then obj.dig("spec", "jobTemplate", "spec", "template", "spec")
      else obj.dig("spec", "template", "spec")
      end
    next unless spec.is_a?(Hash)

    %w[initContainers containers ephemeralContainers].each do |field|
      Array(spec[field]).each do |c|
        next unless c.is_a?(Hash)

        img = c["image"].to_s.strip
        checked_images += 1
        canon = canonical_image_ref(img)
        if canon.nil?
          puts "NG: clusters/platform #{ns}/#{obj['kind']}/#{name} (#{field}/#{c['name']}) のイメージに " \
               "有効な @sha256: ダイジェストが付いていません: #{img.inspect}"
          digest_err = true
        elsif ns == "infra" && obj["kind"] == "CronJob" && UTILITY_CRONJOBS.include?(name)
          utility_cronjob_ruby[name] << canon if field == "containers"
          utility_cronjob_kubectl[name] << canon if field == "initContainers" && c["name"] == "kubectl"
        end
      end
    end
  end

  [
    ["ruby", "containers", utility_cronjob_ruby],
    ["alpine/kubectl", "initContainers/kubectl", utility_cronjob_kubectl]
  ].each do |img_name, slot_label, rendered_map|
    missing_cjs = UTILITY_CRONJOBS.reject { |cj| rendered_map[cj].any? }
    if missing_cjs.any?
      puts "NG: infra の共通ユーティリティ CronJob に #{slot_label} (#{img_name}) が見つかりません: #{missing_cjs.join(', ')}"
      digest_err = true
      next
    end

    expected = shared_utility_canon[img_name]
    all_rendered = rendered_map.values.flatten.uniq
    if expected
      mismatched = UTILITY_CRONJOBS.reject { |cj| rendered_map[cj].uniq == [expected] }
      if mismatched.any?
        puts "NG: infra の CronJob の描画済み #{slot_label} が Section 3 の #{img_name} (#{expected}) と一致しません:"
        mismatched.each { |cj| puts "  #{cj}: #{rendered_map[cj].inspect}" }
        digest_err = true
      end
    elsif all_rendered.size != 1
      puts "NG: infra の CronJob 間で描画済み #{slot_label} (#{img_name}) が一致していません: #{rendered_map.inspect}"
      digest_err = true
    end
  end
end

if !File.file?(PG_EXT_CM)
  puts "NG: #{PG_EXT_CM} が見つかりません"
  digest_err = true
else
  pg_docs = load_yaml_docs(File.read(PG_EXT_CM), PG_EXT_CM)
  if pg_docs.nil?
    digest_err = true
  else
    cm = pg_docs.flat_map { |d| unwrap_k8s_objects(d) }
                .find { |o| o["kind"] == "ConfigMap" && o.dig("metadata", "name") == "postgres-extensions" }
    data = cm.is_a?(Hash) && cm["data"].is_a?(Hash) ? cm["data"] : {}
    if data.empty?
      puts "NG: #{PG_EXT_CM} の ConfigMap/postgres-extensions にエントリがありません"
      digest_err = true
    else
      data.each do |ext_name, img|
        checked_images += 1
        next if canonical_image_ref(img.to_s.strip)

        puts "NG: #{PG_EXT_CM} の拡張 #{ext_name} に有効な @sha256: ダイジェストが付いていません: #{img.inspect}"
        digest_err = true
      end
    end
  end
end

if !File.file?(DEV_PF_SCRIPT)
  puts "NG: #{DEV_PF_SCRIPT} が見つかりません"
  digest_err = true
else
  socat_imgs = File.read(DEV_PF_SCRIPT).scan(/^\s*image:\s*(\S+)/).flatten
  if socat_imgs.empty?
    puts "NG: #{DEV_PF_SCRIPT} から中継 Pod のイメージ行を読み取れません"
    digest_err = true
  else
    socat_imgs.each do |img|
      checked_images += 1
      next if canonical_image_ref(img)

      puts "NG: #{DEV_PF_SCRIPT} のイメージに有効な @sha256: ダイジェストが付いていません: #{img.inspect}"
      digest_err = true
    end
  end
end

if digest_err
  failed = true
else
  puts "ok: プラットフォーム全イメージに有効な @sha256: ダイジェストが付与され共通ユーティリティ CronJob #{UTILITY_CRONJOBS.size} 本も一致 (#{checked_images} 件)"
end

# -----------------------------------------------------------------------------
# 8. Kyverno の webhookConfiguration.matchConditions と exclude.namespaces の整合性
#    matchConditions の除外一覧と各ルールの exclude.namespaces がずれると、
#    Kyverno 障害時にプラットフォーム Pod が巻き添えで止まる・意図しない Namespace に適用される。
#    また gke-managed-* のみ除外すると gke-system / gke-connect を誤マッチするため gke-* を要求する。
# -----------------------------------------------------------------------------
KYVERNO_MATCH_CONDITION_POLICIES = {
  "addons/kyverno/base/clusterpolicy-app-scheduling.yaml" => {},
  "addons/kyverno/base/clusterpolicy-dev-gvisor.yaml" => {},
  "addons/kyverno/base/clusterpolicy-app-hardening.yaml" => {},
  "addons/kyverno/base/clusterpolicy-ingress-hosts.yaml" => { "dev-hosts" => ["prod-*"] }
}.freeze

def parse_match_condition_excluded_namespaces(expr)
  ns_set = Set.new
  expr.scan(/request\.namespace\s+in\s+\[([^\]]+)\]/m).each do |m|
    m[0].scan(/'([^']+)'/).each { |q| ns_set << q[0] }
  end
  expr.scan(/request\.namespace\.startsWith\(\s*'([^']+)'\s*\)/).each do |m|
    ns_set << "#{m[0]}*"
  end
  ns_set
end

mc_err = false
KYVERNO_MATCH_CONDITION_POLICIES.each do |file, extra_by_rule|
  unless File.file?(file)
    puts "NG: #{file} が見つかりません"
    mc_err = true
    next
  end

  docs = load_yaml_docs(File.read(file), file)
  if docs.nil?
    mc_err = true
    next
  end

  cp = docs.flat_map { |d| unwrap_k8s_objects(d) }.find { |o| o["kind"] == "ClusterPolicy" }
  if cp.nil?
    puts "NG: #{file} に ClusterPolicy が見つかりません"
    mc_err = true
    next
  end

  mcs = Array(cp.dig("spec", "webhookConfiguration", "matchConditions"))
  if mcs.empty?
    puts "NG: #{file} に spec.webhookConfiguration.matchConditions がありません"
    mc_err = true
    next
  end

  mc_expr = mcs.filter_map { |m| m["expression"] if m.is_a?(Hash) }.join("\n")
  mc_set = parse_match_condition_excluded_namespaces(mc_expr)

  if !mc_set.include?("gke-*") || mc_set.include?("gke-managed-*")
    puts "NG: #{file} の matchConditions は gke-managed-* ではなく gke-* を除外してください: #{mc_set.to_a.sort.inspect}"
    mc_err = true
  end

  missing_platform_ns = %w[vela-system velaux-store].reject { |ns| mc_set.include?(ns) }
  if missing_platform_ns.any?
    puts "NG: #{file} の matchConditions に必須プラットフォーム Namespace (#{missing_platform_ns.join(', ')}) がありません"
    mc_err = true
  end

  Array(cp.dig("spec", "rules")).each do |rule|
    next unless rule.is_a?(Hash)

    rule_name = rule["name"].to_s
    excl_ns = Array(rule.dig("exclude", "any"))
              .flat_map { |e| e.is_a?(Hash) ? Array(e.dig("resources", "namespaces")) : [] }
    next if excl_ns.empty?

    expected_set = mc_set | Set.new(Array(extra_by_rule[rule_name]))
    actual_set = Set.new(excl_ns)
    if !actual_set.include?("gke-*") || actual_set.include?("gke-managed-*")
      puts "NG: #{file} ルール #{rule_name} の exclude.namespaces は gke-* を含み gke-managed-* を含まないようにしてください"
      mc_err = true
    end

    if actual_set != expected_set
      missing = (expected_set - actual_set).to_a.sort
      extra = (actual_set - expected_set).to_a.sort
      puts "NG: #{file} ルール #{rule_name} の exclude.namespaces が matchConditions と一致しません " \
           "(不足=#{missing.inspect}, 余剰=#{extra.inspect})"
      mc_err = true
    end
  end
end

if mc_err
  failed = true
else
  puts "ok: Kyverno の matchConditions と exclude.namespaces が一致 (#{KYVERNO_MATCH_CONDITION_POLICIES.size} policies)"
end

# -----------------------------------------------------------------------------
# 9. Kyverno 生成 NetworkPolicy 名（KYVERNO_NETWORK_POLICIES）の 3 か所一致と、
#    予約・除外 Namespace 一覧の整合性
# -----------------------------------------------------------------------------
ENV_ISOLATION_POLICY = "addons/kyverno/base/clusterpolicy-environment-isolation.yaml"
CLEAN_MANIFESTS_RB = "#{BASE}/scripts/clean-manifests.rb"
PROMOTE_RB = "components/infrastructure/vela-promote/base/promote.rb"
PROMOTE_CRONJOB = "components/infrastructure/vela-promote/base/cronjob.yaml"
TF_GKE = "terraform/gke.tf"
MANIFEST_BACKUP_YAML = "#{BASE}/manifest-backup.yaml"
MANIFEST_BACKUP_SH = "#{BASE}/scripts/manifest-backup.sh"

def parse_rb_word_array_const(src, const_name)
  m = src.match(/^\s*#{Regexp.escape(const_name)}\s*=\s*%w\[([^\]]+)\]/m)
  m ? m[1].split.uniq.sort : nil
end

def normalize_ns_patterns(raw_patterns)
  raw_patterns.map { |p| p.strip.sub(/\.\*\z/, "*") }.reject(&:empty?).uniq.sort
end

parity_err = false
missing_parity_files = [
  ENV_ISOLATION_POLICY,
  CLEAN_MANIFESTS_RB,
  PROMOTE_RB,
  PROMOTE_CRONJOB,
  TF_GKE,
  DEV_PF_SCRIPT,
  MANIFEST_BACKUP_YAML,
  MANIFEST_BACKUP_SH
].uniq.reject { |f| File.file?(f) }

if missing_parity_files.any?
  missing_parity_files.each { |f| puts "NG: 整合性チェック対象ファイルが見つかりません: #{f}" }
  parity_err = true
else
  # 9a. KYVERNO_NETWORK_POLICIES 3-way parity
  iso_docs = load_yaml_docs(File.read(ENV_ISOLATION_POLICY), ENV_ISOLATION_POLICY)
  if iso_docs.nil?
    parity_err = true
  else
    kyverno_gen_nps = iso_docs
                      .flat_map { |d| unwrap_k8s_objects(d) }
                      .select { |o| o["kind"] == "ClusterPolicy" }
                      .flat_map { |o| Array(o.dig("spec", "rules")) }
                      .filter_map do |r|
                        gen = r.is_a?(Hash) ? r["generate"] : nil
                        gen["name"].to_s.strip if gen.is_a?(Hash) && gen["kind"] == "NetworkPolicy"
                      end
                      .reject(&:empty?)
                      .uniq
                      .sort
    clean_nps = parse_rb_word_array_const(File.read(CLEAN_MANIFESTS_RB), "KYVERNO_NETWORK_POLICIES")
    promote_nps = parse_rb_word_array_const(File.read(PROMOTE_RB), "KYVERNO_NETWORK_POLICIES")

    if kyverno_gen_nps.empty? || clean_nps.nil? || promote_nps.nil?
      puts "NG: KYVERNO_NETWORK_POLICIES を読み取れません: " \
           "kyverno=#{kyverno_gen_nps.inspect}, clean=#{clean_nps.inspect}, promote=#{promote_nps.inspect}"
      parity_err = true
    elsif [kyverno_gen_nps, clean_nps, promote_nps].uniq.size != 1
      puts "NG: KYVERNO_NETWORK_POLICIES が 3 か所で一致していません:"
      puts "  #{ENV_ISOLATION_POLICY}: #{kyverno_gen_nps.inspect}"
      puts "  #{CLEAN_MANIFESTS_RB}: #{clean_nps.inspect}"
      puts "  #{PROMOTE_RB}: #{promote_nps.inspect}"
      parity_err = true
    end
  end

  # 9b. Reserved / platform namespaces 4-way exact parity + manifest-backup coverage
  tf_gke_m = File.read(TF_GKE).match(/NOT\s+resource\.labels\.namespace_name=~\s*"\^\(([^)]+)\)\$"/)
  tf_reserved = tf_gke_m ? normalize_ns_patterns(tf_gke_m[1].split("|")) : nil

  promote_re_m = File.read(PROMOTE_RB).match(/RESERVED_NS_RE\s*=\s*\/\\A\(\?:(.*?)\)\\z\/x/m)
  promote_reserved = promote_re_m ? normalize_ns_patterns(promote_re_m[1].split("|")) : nil

  cron_m = File.read(PROMOTE_CRONJOB).match(/is_reserved_namespace\(\)\s*\{\s*case\s+"\$1"\s+in\s*\n\s*([^)]+)\)/m)
  cron_reserved = cron_m ? normalize_ns_patterns(cron_m[1].gsub(/\\\n/, " ").split("|")) : nil

  pf_m = File.read(DEV_PF_SCRIPT).match(/case\s+"\$\{namespace\}"\s+in\s*\n(.*?)\)/m)
  pf_reserved = pf_m ? normalize_ns_patterns(pf_m[1].gsub(/\\\n/, " ").split("|")) : nil

  reserved_sources = {
    TF_GKE => tf_reserved,
    PROMOTE_RB => promote_reserved,
    PROMOTE_CRONJOB => cron_reserved,
    DEV_PF_SCRIPT => pf_reserved
  }

  if reserved_sources.values.any? { |v| v.nil? || v.empty? }
    puts "NG: 予約 Namespace 一覧を読み取れないファイルがあります:"
    reserved_sources.each { |file, vals| puts "  #{file}: #{vals.inspect}" }
    parity_err = true
  elsif reserved_sources.values.uniq.size != 1
    puts "NG: 予約 Namespace 一覧が 4 か所で一致していません:"
    reserved_sources.each { |file, vals| puts "  #{file}: #{vals.inspect}" }
    parity_err = true
  else
    canonical_reserved = reserved_sources.values.first

    mb_docs = load_yaml_docs(File.read(MANIFEST_BACKUP_YAML), MANIFEST_BACKUP_YAML)
    if mb_docs.nil?
      parity_err = true
    else
      mb_cj = mb_docs.flat_map { |d| unwrap_k8s_objects(d) }
                     .find { |o| o["kind"] == "CronJob" && o.dig("metadata", "name") == "manifest-backup" }
      mb_env = mb_cj ? Array(mb_cj.dig("spec", "jobTemplate", "spec", "template", "spec", "containers"))
                       .flat_map { |c| c.is_a?(Hash) ? Array(c["env"]) : [] }
                       .find { |e| e.is_a?(Hash) && e["name"] == "EXCLUDED_NAMESPACES" } : nil
      mb_env_set = mb_env ? mb_env["value"].to_s.split : []

      mb_sh_m = File.read(MANIFEST_BACKUP_SH).match(/case\s+"\$\{ns\}"\s+in\s*\n\s*([^)]+)\)/m)
      mb_sh_patterns = mb_sh_m ? mb_sh_m[1].gsub(/\\\n/, " ").split("|").map(&:strip).reject { |p| p.include?("$") } : []

      if mb_env_set.empty? || mb_sh_patterns.empty?
        puts "NG: manifest-backup の除外 Namespace 設定を読み取れません " \
             "(env=#{mb_env_set.inspect}, sh=#{mb_sh_patterns.inspect})"
        parity_err = true
      else
        mb_union = Set.new(mb_env_set + mb_sh_patterns)
        uncovered = canonical_reserved.reject { |pat| mb_union.include?(pat) }
        if uncovered.any?
          puts "NG: manifest-backup の除外設定（EXCLUDED_NAMESPACES ∪ manifest-backup.sh）が " \
               "予約 Namespace を網羅していません: 不足=#{uncovered.inspect}"
          parity_err = true
        end
      end
    end
  end
end

if parity_err
  failed = true
else
  puts "ok: KYVERNO_NETWORK_POLICIES（3 か所）と予約・除外 Namespace 一覧（5 か所）が整合"
end

exit(failed ? 1 : 0)
RUBY
