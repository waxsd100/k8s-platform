#!/bin/bash
# バックアップやクラスタ全体の設定のうち、仕組み上複数か所に書くしかないものや
# kubeconform では抜ける不整合を確かめる。cargo make validate（CI）から呼ばれる。
#
#   1. DB と見なすポート: scripts/targets.rb の DB_PORTS と、
#      Kyverno の db-backup-exec-scope（exec 先の制限）の jmesPath
#      → ずれると、取ろうとした DB への exec が拒否される / 取らない DB に exec できる
#   2. restic の版の固定: backup/base/kustomization.yaml の images の 1 か所だけにあること
#   3. Canine イメージの固定と一致: canine / canine-promote / backup の 3 か所の
#      ghcr.io/caninehq/canine が sha256 ダイジェスト付きで完全に一致していること
#      → ずれると昇格ジョブやバックアップだけ古い / 未検証のイメージで動く
#   4. クラスタ全体のリソース（Namespace・ClusterRole・CRD・ClusterPolicy・DeletingPolicy など）に
#      トップレベルの metadata.namespace が付いていないこと（addons / components / clusters/platform）
#      → kustomize の namespace: は CRD のスコープを知らずに付けてしまい、
#        Config Sync が KNV1052 で同期全体を止める（kubeconform はスキーマが無く素通しする）
set -euo pipefail
cd "$(dirname "$0")/.."

exec ruby - <<'RUBY'
# frozen_string_literal: true

require "date"
require "json"
require "open3"
require "ripper"
require "set"
require "time"
require "yaml"

BASE = "components/infrastructure/backup/base"
TARGETS_RB = "#{BASE}/scripts/targets.rb"
BACKUP_KUST = "#{BASE}/kustomization.yaml"
POLICY = "addons/kyverno/base/clusterpolicy-db-backup-exec.yaml"
CANINE_KUSTOMIZATIONS = [
  "components/infrastructure/canine/base/kustomization.yaml",
  "components/infrastructure/canine-promote/base/kustomization.yaml",
  "components/infrastructure/backup/base/kustomization.yaml"
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

def resolve_canine_image(kust_doc)
  helm_refs = []
  helm_repo = nil
  helm_suffix = nil
  Array(kust_doc["helmCharts"]).each do |chart|
    next unless chart.is_a?(Hash)

    img = chart.dig("valuesInline", "image")
    next unless img.is_a?(Hash)
    next unless chart["name"] == "canine" || img["repository"].to_s.include?("caninehq/canine")

    repo = img["repository"].to_s.strip
    tag = img["tag"].to_s.strip
    digest = img["digest"].to_s.strip
    next if repo.empty?

    if tag.include?("@") && !digest.empty?
      return [:conflict, "helmCharts image.tag (#{tag}) と image.digest (#{digest}) が重複指定されています"]
    end

    helm_repo = repo
    helm_suffix =
      if !tag.empty? && !digest.empty?
        ":#{tag}@#{digest}"
      elsif !digest.empty?
        "@#{digest}"
      elsif !tag.empty?
        ":#{tag}"
      else
        ""
      end
    helm_refs << "#{helm_repo}#{helm_suffix}"
  end
  return [:conflict, "複数の helmCharts canine エントリがあります"] if helm_refs.size > 1

  helm_ref = helm_refs.first

  img_entries = Array(kust_doc["images"]).select do |entry|
    entry.is_a?(Hash) && (
      entry["name"].to_s.strip == "ghcr.io/caninehq/canine" ||
      entry["newName"].to_s.strip.include?("caninehq/canine") ||
      (!helm_repo.to_s.empty? && entry["name"].to_s.strip == helm_repo)
    )
  end
  return [:conflict, "複数の images canine エントリがあります"] if img_entries.size > 1

  img_entry = img_entries.first
  if img_entry
    repo = img_entry.key?("newName") ? img_entry["newName"].to_s.strip : img_entry["name"].to_s.strip
    new_tag = img_entry["newTag"].to_s.strip
    digest = img_entry["digest"].to_s.strip
    if new_tag.include?("@") && !digest.empty?
      return [:conflict, "images newTag (#{new_tag}) と digest (#{digest}) が重複指定されています"]
    end

    images_ref =
      if !new_tag.empty? && !digest.empty?
        "#{repo}:#{new_tag}@#{digest}"
      elsif !digest.empty?
        "#{repo}@#{digest}"
      elsif !new_tag.empty?
        "#{repo}:#{new_tag}"
      elsif helm_suffix
        "#{repo}#{helm_suffix}"
      else
        repo
      end
    if helm_ref && helm_ref.include?("@") && (!digest.empty? || !new_tag.empty?)
      helm_canon = canonical_image_ref(helm_ref)
      img_canon = canonical_image_ref(images_ref)
      if !img_entry.key?("newName") || img_entry["newName"].to_s.strip.empty?
        if helm_canon.nil? || img_canon.nil? || helm_canon != img_canon
          return [:conflict, "#{helm_ref} vs #{images_ref}"]
        end
      elsif helm_canon.nil? || img_canon.nil? || helm_canon.split("@", 2).last != img_canon.split("@", 2).last
        return [:conflict, "#{helm_ref} vs #{images_ref}"]
      end
    end

    [:ok, images_ref]
  elsif helm_ref
    [:ok, helm_ref]
  else
    [:missing, nil]
  end
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
# 3. ghcr.io/caninehq/canine のイメージと sha256 ダイジェストが 3 か所で完全一致していること
# -----------------------------------------------------------------------------
canine_refs = {}
canine_raw_refs = {}
canine_err = false
CANINE_KUSTOMIZATIONS.each do |file|
  unless File.file?(file)
    puts "NG: Canine イメージを確認するファイルが見つかりません: #{file}"
    canine_err = true
    next
  end

  docs = load_yaml_docs(File.read(file), file)
  if docs.nil?
    canine_err = true
    next
  end

  doc = docs.first.is_a?(Hash) ? docs.first : {}
  state, ref = resolve_canine_image(doc)
  case state
  when :missing
    puts "NG: #{file} に ghcr.io/caninehq/canine のイメージ定義がありません"
    canine_err = true
  when :conflict
    puts "NG: #{file} 内で helmCharts と images の ghcr.io/caninehq/canine 指定が食い違っています: #{ref}"
    canine_err = true
  when :ok
    canon = canonical_image_ref(ref)
    if canon
      canine_refs[file] = canon
      canine_raw_refs[file] = ref
    else
      puts "NG: #{file} の ghcr.io/caninehq/canine に有効な sha256 ダイジェストが付いていません: #{ref}"
      canine_err = true
    end
  end
end

if canine_err
  failed = true
elsif canine_refs.values.uniq.size != 1
  puts "NG: ghcr.io/caninehq/canine のイメージ定義が 3 か所で一致していません:"
  canine_refs.each { |file, canon| puts "  #{file}: #{canine_raw_refs[file]} (canonical: #{canon})" }
  failed = true
else
  puts "ok: ghcr.io/caninehq/canine のダイジェスト一致 (#{canine_refs.values.first})"
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

exit(failed ? 1 : 0)
RUBY
