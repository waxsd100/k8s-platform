#!/usr/bin/env ruby
# frozen_string_literal: true

# KubeVela / VelaUX の dev Namespace にデプロイされた Application と補助リソースを、
# components/apps/<app>/{base,overlays/production} の形に整形する。
#
# 入力 : STDIN に kubectl get ... -o yaml (List)
# 引数 : APP=アプリ名（dev の Namespace dev-<app> から dev- を外したもの。1〜49 文字）
#        SOURCE_NAMESPACE=アプリの dev の Namespace
#        OUT=出力先ディレクトリ  NOTES=PR 本文に差し込むメモの出力先
#        APPS_DOMAIN=公開ドメイン (既定 wax100.io)
#        SINGLE_REPLICA=true なら Deployment 系コンポーネント (webservice / worker) をすべて
#                       1 台固定 (scaler: replicas 1 + k8s-update-strategy: Recreate) にする
#        PUBLIC_INGRESS=true なら dev に Ingress / gateway trait が無くても
#                       overlays/production/ingress.yaml を初回生成する
#
# 生成物:
#   base/application.yaml                    サニタイズ済み KubeVela Application CR（再昇格で上書き）
#   base/resources.yaml                      非所有の補助リソース（存在するときのみ。無ければ削除）
#   base/kustomization.yaml
#   overlays/production/kustomization.yaml   初回のみ（NamespaceTransformer / unsetOnly: true）
#   overlays/production/namespace.yaml       毎回上書き
#   overlays/production/velaux-sync.yaml     毎回上書き（VelaUX Production 読取専用可視化用）
#   overlays/production/ingress.yaml         初回のみ（dev に Ingress/gateway があるか PUBLIC_INGRESS=true のとき）
#   overlays/production/external-secret.yaml 初回のみ。値は Secret Manager に入れる
#   overlays/production/hpa.yaml             初回のみ。CPU 使用率で Deployment の台数を変える
#   overlays/production/pdb.yaml             初回のみ。ノードの入れ替え時も最低 1 台を残す
#
# 終了コード: 0 = 生成した / 3 = 昇格対象が無い（正常） / それ以外 = 失敗
require "yaml"
require "json"
require "date"
require "fileutils"
require "digest"
require "set"

APP = ENV.fetch("APP")
OUT = ENV.fetch("OUT")
NOTES = ENV["NOTES"]
APPS_DOMAIN = ENV.fetch("APPS_DOMAIN", "wax100.io")
SOURCE_NAMESPACE = ENV["SOURCE_NAMESPACE"].to_s
SINGLE_REPLICA = ENV["SINGLE_REPLICA"].to_s == "true"
PUBLIC_INGRESS = ENV["PUBLIC_INGRESS"].to_s == "true"

DNS_LABEL_RE = /\A[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\z/
RESERVED_NS_RE = /\A(?:
  default |
  kube-.* |
  vela-system |
  velaux-store |
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
# プラットフォーム管理 UI・予約 Namespace が使用する予約名（PROJECT.md / terraform/cloudflare-tunnel.tf）
RESERVED_APP_NAMES = %w[
  vela velaux kubevela dashboard backup
  infra kyverno headlamp reloader dev-access default prod
].freeze

EXIT_NOTHING_TO_DO = 3

# ---------------------------------------------------------------------------
# 何を持ち込むか（KubeVela curated definitions との 1:1 許可リスト）
# ---------------------------------------------------------------------------

# 許可した Kind のみを Git に書き出す。KubeVela Application が生成する子リソース
# (Deployment / Service / ConfigMap / PVC / SA 等) は ownerReferences または OAM ラベルで除外し、
# Application CR 自体と非所有の補助 ConfigMap / ServiceAccount / PersistentVolumeClaim のみを昇格する。
ALLOWED_KINDS = %w[
  Application ConfigMap ServiceAccount PersistentVolumeClaim
].freeze

# addons/kubevela/base/definitions/ の 5 ComponentDefinitions
ALLOWED_COMPONENT_TYPES = %w[
  webservice worker task cron-task statefulset
].freeze
DEPLOYMENT_COMPONENT_TYPES = %w[webservice worker].freeze

# Dev のホスト名を持つ Ingress 系 trait は除去し、必要に応じて ClusterIP の expose trait を合成する
INGRESS_TRAIT_TYPES = %w[
  gateway ingress ingress-1-20 pure-ingress
].freeze

# addons/kubevela/base/definitions/ の 25 TraitDefinitions から Ingress 系を除いた許可リスト
ALLOWED_TRAIT_TYPES = %w[
  scaler env storage volumes pvc resource cpuscaler hpa expose command
  init-container sidecar startup-probe lifecycle labels annotations
  securitycontext podsecuritycontext service-account k8s-update-strategy
  affinity topologyspreadconstraints hostalias
].freeze

# addons/kubevela/base/definitions/ の 6 PolicyDefinitions
ALLOWED_POLICY_TYPES = %w[
  topology override apply-once read-only garbage-collect shared-resource
].freeze

# addons/kubevela/base/definitions/ の 7 WorkflowStepDefinitions
ALLOWED_WORKFLOW_STEP_TYPES = %w[
  deploy apply-component apply-application suspend step-group
  clean-jobs print-message-in-status
].freeze

# Kyverno の generate ルール（clusterpolicy-environment-isolation.yaml）が配る NetworkPolicy。
KYVERNO_NETWORK_POLICIES = %w[
  environment-isolation
  dev-access-relay
  dev-to-dev
].freeze

VOLATILE_META = %w[
  resourceVersion uid creationTimestamp generation selfLink managedFields
  ownerReferences finalizers namespace
].freeze

VELA_VOLATILE_ANNO = %w[
  deployment.kubernetes.io/revision
  kubectl.kubernetes.io/last-applied-configuration
  kubectl.kubernetes.io/restartedAt
  meta.helm.sh/release-namespace
  app.oam.dev/deployVersion
  app.oam.dev/publishVersion
  app.oam.dev/workflowVersion
  app.oam.dev/appName
  app.oam.dev/appAlias
  app.oam.dev/workflowName
  app.oam.dev/kubevela-version
  oam.dev/kubevela-version
  app.oam.dev/restart-workflow
  app.oam.dev/username
  app.oam.dev/group
  app.oam.dev/service-account-name
  app.oam.dev/last-applied-configuration
  app.oam.dev/last-applied-time
  config.k8s.io/owning-inventory
].freeze

VOLATILE_ANNO_PREFIX = /\A(?:(?:pv|volume\.beta|volume)\.kubernetes\.io|config(?:sync|management)\.gke\.io)\//

VELA_VOLATILE_LABELS = %w[
  app.oam.dev/source-of-truth
  app.oam.dev/appName
  app.oam.dev/name
].freeze
VELA_VOLATILE_LABEL_PREFIX = /\Aux\.oam\.dev\//

VOLATILE_PVC_FIELDS = %w[volumeName dataSource dataSourceRef selector].freeze
RWO_ACCESS_MODES = %w[ReadWriteOnce ReadWriteOncePod].freeze

# addons/kyverno/base/clusterpolicy-app-hardening.yaml (deny-dangerous-capabilities) と完全一致する
# Baseline PSS 許可 capability 12 種（CAP_ 接頭辞あり/なし両対応、大文字比較）
ALLOWED_BASELINE_CAPABILITIES = %w[
  AUDIT_WRITE CAP_AUDIT_WRITE
  CHOWN CAP_CHOWN
  FOWNER CAP_FOWNER
  FSETID CAP_FSETID
  KILL CAP_KILL
  MKNOD CAP_MKNOD
  NET_BIND_SERVICE CAP_NET_BIND_SERVICE
  SETFCAP CAP_SETFCAP
  SETGID CAP_SETGID
  SETPCAP CAP_SETPCAP
  SETUID CAP_SETUID
  SYS_CHROOT CAP_SYS_CHROOT
].to_set.freeze

ESO_DEPENDS_ON = "apps/namespaces/external-secrets/Deployment/external-secrets," \
                 "apps/namespaces/external-secrets/Deployment/external-secrets-webhook," \
                 "apps/namespaces/external-secrets/Deployment/external-secrets-cert-controller," \
                 "external-secrets.io/ClusterSecretStore/gcp-secret-store"

VELAUX_SYNC_TIMESTAMP = "2026-01-01T00:00:00Z"

# ---------------------------------------------------------------------------
# 機密らしい値の検出（当たったら昇格を止める。値そのものは表示しない）
# ---------------------------------------------------------------------------
SECRET_VALUE_PATTERNS = {
  "PEM 形式の秘密鍵" => /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,
  "PGP 秘密鍵ブロック" => /-----BEGIN PGP PRIVATE KEY BLOCK-----/,
  "AWS アクセスキー ID" => /(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])/,
  "GitHub トークン" => /(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_\w{22,})/,
  "Slack トークン" => /(?<![A-Za-z0-9])xox[bpars]-[A-Za-z0-9-]{10,}/,
  "Discord Bot トークン" => /(?<![A-Za-z0-9])[MNO][A-Za-z\d]{23,25}\.[A-Za-z\d_-]{6}\.[A-Za-z\d_-]{27,}(?![A-Za-z0-9_-])/,
  "Discord Webhook URL" => %r{https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]+},
  "OpenAI API キー" => /(?<![A-Za-z0-9])sk-(?!ant-)(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])/,
  "Anthropic API キー" => /(?<![A-Za-z0-9])sk-ant-[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])/,
  "Stripe の本番キー" => /(?<![A-Za-z0-9])(?:sk|rk)_live_[A-Za-z0-9]{16,}/,
  "Google API キー" => /(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{35}/,
  "JWT トークン" => /(?<![A-Za-z0-9])eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?![A-Za-z0-9_-])/,
  "認証ヘッダ (Bearer / Basic)" => /(?:(?<![A-Za-z0-9])Authorization(?>\s*):(?>\s*)(?:Bearer|Basic)(?>\s+)[A-Za-z0-9._~+\/=-]{10,}|(?<![A-Za-z0-9])Bearer(?>\s+)[A-Za-z0-9._~+\/=-]{20,})/i,
  "サービスアカウントの秘密鍵（JSON）" => /"private_key"(?>\s*):/,
  "パスワード入りの URL" => %r{(?<![a-zA-Z0-9])[a-zA-Z][a-zA-Z0-9+.-]{0,31}://[^/\s@:]*:[^/\s@]+@}
}.freeze

SECRET_NAME_TOKEN_RE = /(?:^|_)(?:PASSWORD|PASSWD|PASS|PWD|SECRET|SECRET_KEY_BASE|TOKEN|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|SECRET_?KEY|MASTER_?KEY|ENCRYPTION_?KEY|SIGNING_?KEY|CREDENTIALS?|PASSPHRASE|WEBHOOK_URL)(?:$|_)/i
SECRET_NAME_BENIGN_SUFFIX_RE = /_(?:TTL|TIMEOUT|EXPIR(?:Y|ES|ATION)|MAX_AGE|LENGTH|MIN_LENGTH|MAX_LENGTH|HEADER|PATH|FILE|DIR|ENABLED|DISABLED|MODE|TYPE|FORMAT|ALGO(?:RITHM)?|ENCRYPTION|ENCODING|POLICY|SCHEME|METHOD|ISSUER|AUDIENCE|SCOPES?|PREFIX|SUFFIX|NAME|COUNT|LIMIT|SIZE|INTERVAL|SECONDS|MS|MINUTES|HOURS|DAYS|ENDPOINT)\z/i
SECRET_HTTP_HEADER_RE = /\A(?:(?:proxy[-_.])?authorization|cookie|x[-_.](?:api[-_.]?key|auth(?:[-_.].*)?|token))\z/i

PLACEHOLDER_VALUE_RE = /\A(?:
  \$\{[!#]?(?>[A-Za-z_][A-Za-z0-9_.]*)(?:\}|[:#%\/^,?+=-](?>(?:(?!\$\()[^}`])*)\}) |
  \$\([A-Za-z_][A-Za-z0-9_.-]*\) |
  \$[A-Za-z_][A-Za-z0-9_]* |
  <[^>"'=]+> |
  \{\{[^}"'=]+\}\} |
  changeme |
  replace[_-]?me |
  your[_-][A-Za-z0-9_.-]* |
  example |
  dummy |
  placeholder |
  null | ~ | true | false
)\z/ix

# K8s 参照名のみを格納するスキーマキー（キー名判定のみ対象外とし、値パターン検査は必ず実施する）
SAFE_REF_META_KEYS = %w[
  secretKey configMapKey secretName cmName claimName envName key name ref existingServiceName
  secret.reloader.stakater.com/reload
  nginx.ingress.kubernetes.io/auth-secret
  nginx.ingress.kubernetes.io/auth-tls-secret
  nginx.ingress.kubernetes.io/proxy-ssl-secret
].freeze

STRICT_BASE64_RE = /\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/

$dropped = Hash.new { |h, k| h[k] = [] }
$dropped_externalname_services = []
$downgraded_services = []
$synthesized_expose_services = []
$updated_component_expose_ports = []
$stripped_external_revisions = []
$forced_secret_mount_only = []
$gateway_secret_refs = Set.new
$gateway_existing_services = [] # [svc_name, [ports]]
$gateway_preferred_ports = Hash.new { |h, k| h[k] = Set.new } # svc_name => Set<Integer>
$dev_has_ingress = false
$dev_ingress_hosts = []
$manual_pvcs = []

def non_empty_str(val)
  val.is_a?(String) && !val.empty? ? val : nil
end

def safe_dig(obj, *keys)
  cur = obj
  keys.each do |k|
    return nil unless cur.is_a?(Hash)

    cur = cur[k]
  end
  cur
end

def safe_array(val)
  val.is_a?(Array) ? val : []
end

def valid_port_int(raw)
  num = if raw.is_a?(Integer)
          raw
        elsif raw.is_a?(String) && raw.match?(/\A\d+\z/)
          raw.to_i
        end
  num if num && num.between?(1, 65_535)
end

def normalize_utf8(str)
  if str.encoding == Encoding::UTF_8
    str.valid_encoding? ? str : str.scrub
  elsif str.encoding == Encoding::ASCII_8BIT
    u = String.new(str, encoding: Encoding::UTF_8)
    u.valid_encoding? ? u : str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  else
    str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  end
end

# 値に当たる検出パターンの名前だけを返す（当たらなければ空）。値そのものは返さない。
# SECRET_VALUE_PATTERNS の最短一致は "a://:b@" の 7 バイトのため、7 バイト未満は即座に除外する。
def secret_value_rules(str)
  return [] unless str.is_a?(String) && str.bytesize >= 7

  text = normalize_utf8(str)
  SECRET_VALUE_PATTERNS.filter_map { |label, re| label if text.match?(re) }
end

def string_contains_dotenv_secret?(str)
  return false unless str.is_a?(String) && str.bytesize >= 5 && respond_to?(:dotenv_secret_rules, true)

  text = normalize_utf8(str)
  return false unless text.include?("{") || text.include?("[") || text.include?(":") || text.include?("=")

  !dotenv_secret_rules(text, redact_keys: false).empty?
end

def redact_secret_label(str, replacement: "<redacted>")
  unless str.is_a?(String) || str.is_a?(Symbol) || str.is_a?(Numeric) ||
         str.nil? || str == true || str == false || str.is_a?(Date) || str.is_a?(Time)
    return replacement
  end

  s = str.to_s
  return s if s.bytesize < 5
  return replacement unless secret_value_rules(s).empty?
  return replacement if string_contains_dotenv_secret?(s)

  s
end

def value_contains_secret?(val, depth = 0)
  return true if depth > 16

  case val
  when String
    !secret_value_rules(val).empty? || string_contains_dotenv_secret?(val)
  when Symbol
    s = val.to_s
    !secret_value_rules(s).empty? || string_contains_dotenv_secret?(s)
  when Array
    val.any? { |el| value_contains_secret?(el, depth + 1) }
  when Hash
    val.any? do |k, v|
      ks = k.is_a?(String) || k.is_a?(Symbol) ? normalize_utf8(k.to_s).tr("\uFFFD", "_") : nil
      placeholder_fn = respond_to?(:secret_value_placeholder?, true) ? :secret_value_placeholder? : :secret_placeholder?
      key_secret = ks && secret_name?(ks) &&
                   ((v.is_a?(String) && !send(placeholder_fn, normalize_utf8(v))) ||
                    (v.is_a?(Symbol) && !send(placeholder_fn, normalize_utf8(v.to_s))) ||
                    v.is_a?(Numeric) ||
                    (v.is_a?(Hash) && !v.empty?) ||
                    (v.is_a?(Array) && !v.empty?))
      key_secret || value_contains_secret?(k, depth + 1) || value_contains_secret?(v, depth + 1)
    end
  else
    raw = val.inspect
    !secret_value_rules(raw).empty? || string_contains_dotenv_secret?(raw)
  end
end

def redact_inspect(val, replacement: "<redacted>")
  if val.is_a?(Hash) || val.is_a?(Array)
    return value_contains_secret?(val) ? replacement.inspect : "<#{val.class}>"
  end

  if val.is_a?(String)
    redact_secret_label(val, replacement: replacement).inspect
  elsif value_contains_secret?(val)
    replacement.inspect
  else
    raw = val.inspect
    redact_secret_label(raw, replacement: replacement) == raw ? raw : replacement.inspect
  end
end

APP_DEPENDS_ON = "/namespaces/velaux-store/ConfigMap/tg-local-prod-#{APP}," \
                 "/namespaces/velaux-store/ConfigMap/ev-prod-#{APP}," \
                 "apps/namespaces/vela-system/Deployment/kubevela-vela-core"

def decode_strict_base64(b64)
  return nil unless b64.is_a?(String) && !b64.empty? && b64.match?(STRICT_BASE64_RE)

  b64.unpack1("m0")
rescue ArgumentError
  nil
end

# 厳密な RFC 4648 base64 検証のうえ復号し、検出規則にかける（値そのものは返さない）。
def secret_binary_rules(b64)
  return ["binaryData を復号できない"] unless b64.is_a?(String)
  return [] if b64.empty?

  raw_bytes = decode_strict_base64(b64)
  return ["binaryData を復号できない"] if raw_bytes.nil?

  rules = secret_value_rules(b64)
  utf8 = String.new(raw_bytes, encoding: Encoding::UTF_8)
  decoded_text = utf8.valid_encoding? ? utf8 : normalize_utf8(raw_bytes)
  rules = (rules + secret_value_rules(decoded_text)).uniq
  if utf8.valid_encoding? && !utf8.include?("\x00")
    rules = (rules + dotenv_secret_rules(utf8)).uniq
  end
  rules
end

def secret_name?(name)
  s = name.to_s.strip.tr(". \t/:-", "_").squeeze("_")
  return false if s.empty?
  return false if s.match?(SECRET_NAME_BENIGN_SUFFIX_RE)

  s.match?(SECRET_NAME_TOKEN_RE)
end

def secret_placeholder?(val)
  s = val.to_s.strip
  if (s.start_with?('"') && s.end_with?('"') && s.length >= 2) ||
     (s.start_with?("'") && s.end_with?("'") && s.length >= 2)
    s = s[1..-2].to_s.strip
  end
  s.empty? || s.match?(PLACEHOLDER_VALUE_RE)
end

MAX_YAML_AST_BYTES = 262_144
MAX_LARGE_JSON_BYTES = 1_048_576
MAX_NESTED_LEAF_BYTES = 65_536
MAX_AST_NODES = 20_000
MAX_AST_DEPTH = 32
MAX_YAML_FLOW_PREGUARD = 512
MAX_YAML_TAG_DIRECTIVES = 32
MAX_LEAF_NEST_DEPTH = 8
MAX_SCALAR_ANCHORS = MAX_AST_NODES

PLAIN_YAML_KEY_RE = /\A[A-Za-z0-9_][A-Za-z0-9_.\/:-]*\z/
PLAIN_YAML_SPACE_KEY_RE = /\A[A-Za-z0-9_][A-Za-z0-9_. \t\/-]{0,63}\z/
ENGLISH_PROSE_KEY_WORD_RE = /\b(?:do|not|dont|never|always|please|note|warning|warn|info|debug|notice|hint|tip|about|for|to|the|a|an|this|that|your|how|when|where|if|use|see|remember|hardcode|commit|error|failed|loading|unable|cannot|configure|rotate)\b/i
YAML_RUBY_SYM_KEY_RE = /\A:[A-Za-z_][A-Za-z0-9_.-]*\z/
YAML_PLAIN_BOOL_RE = /\A(?:yes|no|on|off)\z/i
YAML_NON_SCALAR_MARKERS = %w[{ } [ ] {} [] | > |- >- |+ >+].freeze
YAML_BLOCK_SCALAR_MARKER_RE = /\A[|>](?:[1-9][+-]?|[+-][1-9]?)?(?:(?>[ \t]*)#.*)?\z/
YAML_NODE_PROP_PREFIX_RE = /\A(?:(?:&[A-Za-z0-9_-]+|![^\s,}\]]+)(?>[ \t]+)){1,2}/
YAML_EMPTY_SPACE_KEY_TAIL_RE = /\A(?:(?>[ \t]+)(?>&[A-Za-z0-9_-]+|![^\s,}\]]+)){1,2}\z/
FLOW_CONTAINER_LOOKAHEAD_RE = /(?:\{(?!\{)(?>\s{0,64})(?:\}|"[^"\r\n]{1,64}"(?>\s{0,16}):|'[^'\r\n]{1,64}'(?>\s{0,16}):|(?>[A-Za-z_][A-Za-z0-9_.\/-]{0,63})(?>\s{0,16}):(?:\s|["']))|\[(?>\s{0,64})(?:\]|\{|\[))/
YAML_FLOW_CONTAINER_PREFIX_RE = /\A#{FLOW_CONTAINER_LOOKAHEAD_RE}/

# クォート付きキー本体: Ruby Onigmo の真のアトミックグループ (?>...)＋排他原子＋上限 64 原子で厳密 O(N) を保証
# （注意: Onigmo では {m,n}+ が所有量指定子ではなく (X{m,n})+ となり ReDoS を起こすため使用禁止）
QUOTED_KV_KEY_ATOM = /(?>(?:[A-Za-z0-9_:]|\\u[0-9A-Fa-f]{4})(?:[A-Za-z0-9_. \t\/:-]|\\u[0-9A-Fa-f]{4}|\\[nrt]){0,63})/

# 行頭代入（dotenv / INI / YAML 行）: 未クォートの ":" は後ろに空白またはクォートを必須とし
# コンテナイメージ "token:v1.2.3" 等の誤検知を防ぐ。アトミック [ \t] + 貪欲 (.+)\z で O(N^2) バックトラックを排除。
LINE_KV_RE = /\A(?:(export)(?>[ \t]+))?(?:
  "[\t\x20]{0,8}(#{QUOTED_KV_KEY_ATOM})"(?>[ \t]*)([:=])(?>[ \t]*) |
  '[\t\x20]{0,8}(#{QUOTED_KV_KEY_ATOM})'(?>[ \t]*)([:=])(?>[ \t]*) |
  ([A-Za-z_][A-Za-z0-9_.-]*)(?>[ \t]*)(\+?=)(?>[ \t]*) |
  :?([A-Za-z_][A-Za-z0-9_.\/-]*)(?>[ \t]*)(:)(?:(?>[ \t]+)|(?=["']))
)(.+)\z/x
YAML_EMPTY_KEY_LINE_RE = /\A(?:
  "[\t\x20]{0,8}(#{QUOTED_KV_KEY_ATOM})" |
  '[\t\x20]{0,8}(#{QUOTED_KV_KEY_ATOM})' |
  :?([A-Za-z_][A-Za-z0-9_.\/-]{0,63})
)(?>[ \t]*):(?:(?>[ \t]+)(?>&[A-Za-z0-9_-]+|![^\s,}\]]+)){0,2}\z/x
SHELL_PLACEHOLDER_CMD_RE = /\A(?:"(?:\$\{(?>(?:(?!\$\()[^}\s{`]){1,128})\}|\$\([A-Za-z_][A-Za-z0-9_.-]{0,127}\)|\$[A-Za-z_][A-Za-z0-9_]*)"|\$\{(?>(?:(?!\$\()[^}\s{`]){1,128})\}|\$\([A-Za-z_][A-Za-z0-9_.-]{0,127}\)|\$[A-Za-z_][A-Za-z0-9_]*)\s+(?:(?:&&|\|\|)\s+[A-Za-z_.\/]|(?:\.?\/[A-Za-z0-9._\/-]+|(?:exec|node(?:js)?|python\d*(?:\.\d+)?|ruby|sh|bash|env|java|go|php|perl|dotnet)\s|[A-Za-z_][A-Za-z0-9_]*=))/

# 線形時間 O(N) のインライン KV 走査（dotenv_secret_rules と shell/script スキャナで共有）:
# - クォート付きキー: 空白・"/"・":"・\uXXXX エスケープ対応（上限 64 原子、アトミックグループでバックトラックなし）
# - 未クォートキー + "=" / "+=": ゼロ幅境界 (?<=[\s{,\[\(;&?'"`]) で区切り文字を消費せず検出
# - 未クォートキー + ":": 行頭または構造区切り・クォートの直後のみ（英文中の "password: use ESO" を除外）
# - 単一クォート値は POSIX / YAML 仕様どおり '([^']*)' とし、\' によるクォート飲み込みを防ぐ
# - 裸値は真の構造化オブジェクト/配列先頭（{}, {k:...}, [], [{, [[）のみ O(1) 有界先読みで除外し、
#   {leaked} / {"leaked"} / [leaked] / ["leaked"] 等のリテラル値を確実に捕捉する
INLINE_KV_RE = /
  (?:
    (?:^|(?<=[\s{,\[\(;&?'"]))"[\t\x20]{0,8}(#{QUOTED_KV_KEY_ATOM})"\s*[:=]\s* |
    (?:^|(?<=[\s{,\[\(;&?'"]))'[\t\x20]{0,8}(#{QUOTED_KV_KEY_ATOM})'\s*[:=]\s* |
    (?:^|(?<=[\s{,\[\(;&?'"`]))([A-Za-z_][A-Za-z0-9_.-]*)\s*\+?=\s* |
    (?:^(?>[ \t-]*)(?=[A-Za-z_:])|(?<=[{,\[\(;'"`])(?>\s*)):?([A-Za-z_][A-Za-z0-9_.\/-]*)\s*(?::\s+|:(?=["']))
  )
  (?:
    "((?>[^"\\]*(?:\\.[^"\\]*)*))" |
    '([^']*)' |
    ((?:\$\{[^}\s{]{1,128}\}|\{\{[^}\r\n{"'=]{1,128}\}\}|\$\([^)\s(]{1,128}\)|<[^>\r\n<"'=:;]{1,128}>)(?=$|[\s,}\];"')&])|(?!#{FLOW_CONTAINER_LOOKAHEAD_RE})(?:[\{\[](?>\s{0,16})(?:"(?>[^"\\]*(?:\\.[^"\\]*)*)"|'[^']*')(?>[^\s,}\];"')&]*)|(?>(?:[^\s,}\];"')&${]+|\$\{[^}\s{]{1,128}\}|\{\{[^}\r\n{"'=]{1,128}\}\}|\$\([^)\s(]{1,128}\)|[${])+)))
  )
/x

def decode_quoted_kv_key(raw)
  return raw unless raw.include?("\\")

  raw.gsub(/\\u([0-9A-Fa-f]{4})|\\([nrt])/) do
    if Regexp.last_match(1)
      cp = Regexp.last_match(1).to_i(16)
      cp.between?(0x20, 0xD7FF) || cp.between?(0xE000, 0xFFFF) ? cp.chr(Encoding::UTF_8) : " "
    else
      " "
    end
  end
end

def strip_unquoted_inline_comment(line)
  return line unless line.include?("#")

  quote = nil
  pos = 0
  len = line.length
  while pos < len
    idx = line.index(/["'\\#]/, pos)
    break unless idx

    ch = line[idx]
    if quote == '"'
      if ch == "\\"
        pos = idx + 2
        next
      elsif ch == '"'
        quote = nil
      end
    elsif quote == "'"
      quote = nil if ch == "'"
    else
      if ch == '"'
        quote = '"'
      elsif ch == "'"
        # 単語中のアポストロフィ ("it's", "don't") は単一クォート開始とみなさない
        prev = idx > 0 ? line[idx - 1] : nil
        quote = "'" unless prev && prev.match?(/[A-Za-z0-9_]/)
      elsif ch == "#"
        return "" if idx == 0

        prev = line[idx - 1]
        return line[0...idx] if prev == " " || prev == "\t" || prev == ";"
      end
    end
    pos = idx + 1
  end
  line
end

def extract_valid_yaml_ast_key(k_node, v_node = nil)
  return [false, nil] unless k_node.is_a?(Psych::Nodes::Scalar)

  raw = k_node.value.to_s
  if k_node.tag == "!ruby/symbol"
    norm = raw.sub(/\A:/, "").tr("\r\n", " ").strip
    return [true, norm] unless norm.empty?

    return [false, nil]
  end

  unless k_node.plain
    norm = raw.tr("\r\n", " ").strip
    return [true, norm] unless norm.empty?

    return [false, nil]
  end

  return [true, raw] if raw == "<<"
  return [true, raw[1..]] if raw.match?(YAML_RUBY_SYM_KEY_RE)
  return [true, raw] if raw.match?(PLAIN_YAML_KEY_RE) && !raw.include?("://")

  if raw.match?(PLAIN_YAML_SPACE_KEY_RE) && !raw.match?(/\s-/)
    if v_node.is_a?(Psych::Nodes::Scalar) && v_node.plain
      v_str = v_node.value.to_s.strip
      words = raw.split(/[ \t]+/)
      if v_str.match?(/[ \t]/) && (raw.match?(ENGLISH_PROSE_KEY_WORD_RE) || words.length >= 4)
        return [false, nil]
      end
    end
    return [true, raw]
  end

  [false, nil]
end

def record_scalar_anchor(scalar_node, state)
  anchor = scalar_node.anchor
  return true if anchor.nil? || anchor.empty?

  if state[:scalar_anchors].key?(anchor) || state[:scalar_anchors].size < MAX_SCALAR_ANCHORS
    state[:scalar_anchors][anchor] = scalar_node
    true
  else
    state[:truncated] = true
    false
  end
end

def yaml_scalar_placeholder?(scalar_node)
  val = scalar_node.value.to_s
  return true if secret_value_placeholder?(val)
  return true if scalar_node.plain && val.strip.match?(YAML_PLAIN_BOOL_RE)

  false
end

def yaml_stage3_unquote_key(raw)
  s = raw.strip
  if s.length >= 2 && s.start_with?('"') && s.end_with?('"')
    decode_quoted_kv_key(s[1..-2]).strip
  elsif s.length >= 2 && s.start_with?("'") && s.end_with?("'")
    s[1..-2].gsub("''", "'").strip
  else
    s.sub(/\A:/, "").strip
  end
end

def yaml_stage3_space_key_prose?(raw_key, val_no_props)
  return false unless val_no_props.match?(/[ \t]/)

  quoted = val_no_props.length >= 2 &&
           ((val_no_props.start_with?('"') && val_no_props.end_with?('"')) ||
            (val_no_props.start_with?("'") && val_no_props.end_with?("'")))
  return false if quoted

  raw_key.match?(ENGLISH_PROSE_KEY_WORD_RE) || raw_key.split(/[ \t]+/).length >= 4
end

# Stage 3 用: 空白を含む未クォート YAML キー（例: "api key: <SECRET>" / "api key: |-" / "api key:"）を
# 厳密 O(N)・UTF-8 安全（先頭〜":" 間を 7-bit ASCII バイト走査）で解析する。
def parse_stage3_space_yaml_line(line_body)
  n = line_body.bytesize
  return nil if n < 4

  b0 = line_body.getbyte(0)
  return nil unless (b0 >= 65 && b0 <= 90) || (b0 >= 97 && b0 <= 122) || (b0 >= 48 && b0 <= 57) || b0 == 95

  i = 1
  last_non_ws = 0
  while i < n
    b = line_body.getbyte(i)
    break if b == 58 # ':'

    if b == 32 || b == 9
      i += 1
    elsif (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) ||
          b == 95 || b == 46 || b == 47 || b == 45 # '_' '.' '/' '-'
      return nil if i >= 64

      last_non_ws = i
      i += 1
    else
      return nil
    end
  end
  return nil if i >= n || line_body.getbyte(i) != 58

  key_end = last_non_ws + 1
  return nil if key_end < 3 || key_end > 64

  # 0..i は全て 7-bit ASCII のため byte offset == UTF-8 char offset
  raw_key = line_body[0...key_end]
  return nil unless raw_key.include?(" ") || raw_key.include?("\t")
  return nil unless raw_key.match?(PLAIN_YAML_SPACE_KEY_RE)
  return nil if raw_key.match?(/\s-/)

  after_colon = line_body[(i + 1)..]
  return [:empty, raw_key, nil] if after_colon.empty? || after_colon.match?(YAML_EMPTY_SPACE_KEY_TAIL_RE)
  return nil unless after_colon.start_with?(" ", "\t")

  raw_val = after_colon.strip.sub(/,\z/, "").rstrip
  return [:empty, raw_key, nil] if raw_val.empty?

  val_no_props = raw_val.sub(YAML_NODE_PROP_PREFIX_RE, "")
  return [:block, raw_key, nil] if val_no_props.match?(YAML_BLOCK_SCALAR_MARKER_RE)
  return nil if yaml_stage3_space_key_prose?(raw_key, val_no_props)

  [:kv, raw_key, raw_val]
end

def yaml_stage3_nested_structure_line?(clean)
  return true if clean == "-" || clean.start_with?("- ", "-\t")
  return true if clean == "?" || clean.start_with?("? ", "?\t")
  return true if clean == "{" || clean == "[" || clean.match?(YAML_FLOW_CONTAINER_PREFIX_RE)
  return true if clean.match?(YAML_EMPTY_KEY_LINE_RE)

  if (nm = clean.match(LINE_KV_RE))
    op = nm[3] || nm[5] || nm[7] || nm[9]
    return true if op == ":"
  end
  return true if parse_stage3_space_yaml_line(clean)

  false
end

def scan_text_lines_and_inline_kv(text, found_keys, inner_depth = 0, whole_line: true)
  return if text.empty? || inner_depth > 2

  pending_block_key = nil
  pending_block_indent = -1
  pending_block_lines = nil
  pending_block_bytes = 0
  pending_block_overflow = false

  pending_nextline_key = nil
  pending_nextline_indent = -1
  pending_nextline_is_space_key = false

  pending_explicit_key = nil
  pending_explicit_indent = -1
  pending_explicit_key_block = false
  pending_explicit_key_lines = nil
  pending_explicit_key_bytes = 0

  flush_pending_block = lambda do
    if pending_block_key
      if pending_block_overflow
        found_keys << pending_block_key
      else
        body = pending_block_lines.join("\n").strip
        if !body.empty? && !secret_value_placeholder?(body) && !body.match?(YAML_PLAIN_BOOL_RE)
          found_keys << pending_block_key
        end
      end
      pending_block_key = nil
      pending_block_indent = -1
      pending_block_lines = nil
      pending_block_bytes = 0
      pending_block_overflow = false
    end
  end

  start_pending_block = lambda do |key, indent|
    if secret_name?(key)
      pending_block_key = key
      pending_block_indent = indent
      pending_block_lines = []
      pending_block_bytes = 0
      pending_block_overflow = false
    end
  end

  norm_text = if text.include?("\r") || text.include?("\u0085") || text.include?("\u2028") || text.include?("\u2029")
                text.gsub(/\r\n?|\u0085|\u2028|\u2029/, "\n")
              else
                text
              end

  norm_text.each_line do |line|
    raw_line = line.sub(/\A[\uFEFF\uFFFD]+/, "").chomp
    leading_indent = 0
    raw_len = raw_line.length
    leading_indent += 1 while leading_indent < raw_len && raw_line.getbyte(leading_indent) == 32
    stripped = raw_line.strip

    is_doc_marker = whole_line && leading_indent == 0 && raw_len >= 3 &&
                    (raw_line.start_with?("---") || raw_line.start_with?("...")) &&
                    (raw_len == 3 || raw_line.getbyte(3) == 32 || raw_line.getbyte(3) == 9)

    if whole_line && pending_block_key
      if stripped.empty?
        next
      elsif !is_doc_marker && leading_indent > pending_block_indent
        if !pending_block_overflow
          if pending_block_bytes + stripped.bytesize > 4096
            pending_block_overflow = true
          else
            pending_block_lines << stripped
            pending_block_bytes += stripped.bytesize + 1
          end
        end
        next
      else
        flush_pending_block.call
      end
    end

    if whole_line && pending_explicit_key_block
      if stripped.empty?
        next
      elsif !is_doc_marker && leading_indent > pending_explicit_indent
        if pending_explicit_key_bytes < 256
          pending_explicit_key_lines << stripped
          pending_explicit_key_bytes += stripped.bytesize + 1
        end
        next
      else
        pending_explicit_key = yaml_stage3_unquote_key(pending_explicit_key_lines.join(" "))
        pending_explicit_key = nil if pending_explicit_key.empty?
        pending_explicit_key_block = false
        pending_explicit_key_lines = nil
        pending_explicit_key_bytes = 0
      end
    end

    next if stripped.empty? || stripped.start_with?("#", ";", "//")

    if is_doc_marker
      pending_nextline_key = nil
      pending_nextline_is_space_key = false
      pending_explicit_key = nil
      next
    end

    clean = strip_unquoted_inline_comment(stripped).strip
    next if clean.empty?

    whole_line_verified_placeholder = false
    consumed_nextline = false

    if whole_line && pending_nextline_key
      if leading_indent > pending_nextline_indent
        nk = pending_nextline_key
        ni = pending_nextline_indent
        nk_space = pending_nextline_is_space_key
        pending_nextline_key = nil
        pending_nextline_indent = -1
        pending_nextline_is_space_key = false
        val_no_props = clean.sub(YAML_NODE_PROP_PREFIX_RE, "")
        if val_no_props.match?(YAML_BLOCK_SCALAR_MARKER_RE)
          start_pending_block.call(nk, ni)
          next
        elsif !yaml_stage3_nested_structure_line?(clean)
          is_prose = nk_space && yaml_stage3_space_key_prose?(nk, val_no_props)
          if clean.match?(YAML_PLAIN_BOOL_RE)
            whole_line_verified_placeholder = true
          elsif !is_prose && !secret_value_placeholder?(clean)
            found_keys << nk
          end
          consumed_nextline = true
        end
      else
        pending_nextline_key = nil
        pending_nextline_indent = -1
        pending_nextline_is_space_key = false
      end
    end

    if whole_line && !consumed_nextline
      dash_match = clean.match(/\A(?>-[ \t]+)+/)
      key_indent = dash_match ? leading_indent + dash_match[0].length : leading_indent
      line_body = dash_match ? clean[dash_match[0].length..] : clean
      consumed_explicit_val = false

      if pending_explicit_key
        if leading_indent == pending_explicit_indent &&
           (line_body == ":" || line_body.start_with?(": ", ":\t"))
          exp_key = pending_explicit_key
          pending_explicit_key = nil
          pending_explicit_indent = -1
          consumed_explicit_val = true
          raw_val = line_body.sub(/\A:[ \t]*/, "").strip.sub(/,\z/, "").rstrip
          val_no_props = raw_val.sub(YAML_NODE_PROP_PREFIX_RE, "")
          if val_no_props.empty?
            if secret_name?(exp_key)
              pending_nextline_key = exp_key
              pending_nextline_indent = key_indent
              pending_nextline_is_space_key = false
            end
            next
          elsif val_no_props.match?(YAML_BLOCK_SCALAR_MARKER_RE)
            start_pending_block.call(exp_key, key_indent)
            next
          elsif !raw_val.match?(YAML_FLOW_CONTAINER_PREFIX_RE) && !YAML_NON_SCALAR_MARKERS.include?(raw_val)
            if secret_name?(exp_key)
              if raw_val.match?(YAML_PLAIN_BOOL_RE)
                whole_line_verified_placeholder = true
              elsif !secret_value_placeholder?(raw_val)
                found_keys << exp_key
              end
            end
          end
        elsif leading_indent <= pending_explicit_indent
          pending_explicit_key = nil
          pending_explicit_indent = -1
        end
      end

      if !consumed_explicit_val && (line_body == "?" || line_body.start_with?("? ", "?\t"))
        raw_exp = line_body.sub(/\A\?[ \t]*/, "").strip
        exp_no_props = raw_exp.sub(YAML_NODE_PROP_PREFIX_RE, "")
        if exp_no_props.empty? || exp_no_props.match?(YAML_BLOCK_SCALAR_MARKER_RE)
          pending_explicit_key_block = true
          pending_explicit_indent = key_indent
          pending_explicit_key_lines = []
          pending_explicit_key_bytes = 0
        else
          exp_k = yaml_stage3_unquote_key(exp_no_props)
          unless exp_k.empty?
            pending_explicit_key = exp_k
            pending_explicit_indent = key_indent
          end
        end
        next
      elsif !consumed_explicit_val && (m = line_body.match(LINE_KV_RE))
        is_export = !m[1].nil?
        raw_key = if m[2] || m[4]
                    decode_quoted_kv_key(m[2] || m[4]).strip
                  else
                    m[6] || m[8]
                  end
        op = m[3] || m[5] || m[7] || m[9]
        raw_val = m[10].strip.sub(/,\z/, "").rstrip
        val_no_props = op == ":" ? raw_val.sub(YAML_NODE_PROP_PREFIX_RE, "") : raw_val

        if op == ":" && val_no_props.match?(YAML_BLOCK_SCALAR_MARKER_RE)
          start_pending_block.call(raw_key, key_indent)
          next
        end

        skip_whole_line = ((op == "=" || op == "+=" || is_export) && raw_val.match?(SHELL_PLACEHOLDER_CMD_RE)) ||
                          raw_val.match?(YAML_FLOW_CONTAINER_PREFIX_RE)
        unless skip_whole_line || raw_val.empty? || YAML_NON_SCALAR_MARKERS.include?(raw_val)
          if secret_name?(raw_key)
            if op == ":" && raw_val.match?(YAML_PLAIN_BOOL_RE)
              whole_line_verified_placeholder = true
            elsif !secret_value_placeholder?(raw_val)
              found_keys << raw_key
            end
          end
        end
      elsif !consumed_explicit_val && (em = line_body.match(YAML_EMPTY_KEY_LINE_RE))
        raw_key = if em[1] || em[2]
                    decode_quoted_kv_key(em[1] || em[2]).strip
                  else
                    em[3]
                  end
        if secret_name?(raw_key)
          pending_nextline_key = raw_key
          pending_nextline_indent = key_indent
          pending_nextline_is_space_key = false
        end
        next
      elsif !consumed_explicit_val && (sp = parse_stage3_space_yaml_line(line_body))
        sp_kind, raw_key, raw_val = sp
        if sp_kind == :block
          start_pending_block.call(raw_key, key_indent)
          next
        elsif sp_kind == :empty
          if secret_name?(raw_key)
            pending_nextline_key = raw_key
            pending_nextline_indent = key_indent
            pending_nextline_is_space_key = true
          end
          next
        else
          skip_whole_line = raw_val.match?(YAML_FLOW_CONTAINER_PREFIX_RE)
          unless skip_whole_line || raw_val.empty? || YAML_NON_SCALAR_MARKERS.include?(raw_val)
            if secret_name?(raw_key)
              if raw_val.match?(YAML_PLAIN_BOOL_RE)
                whole_line_verified_placeholder = true
              elsif !secret_value_placeholder?(raw_val)
                found_keys << raw_key
              end
            end
          end
        end
      end
    end

    next if whole_line_verified_placeholder
    next unless clean.include?("=") || clean.include?(":")

    balanced_checks = 0
    clean.scan(INLINE_KV_RE) do |qkey_dq, qkey_sq, eqkey, colkey, dq, sq, bare|
      lm = Regexp.last_match
      raw_key = if qkey_dq || qkey_sq
                  decode_quoted_kv_key(qkey_dq || qkey_sq).strip
                else
                  eqkey || colkey
                end
      val = dq || sq || bare.to_s
      next if val.empty? || YAML_NON_SCALAR_MARKERS.include?(val)

      if secret_name?(raw_key)
        # 厳密 O(1) 有界窓・回数上限付きで "$(echo -n "$VAR")" / $(cat /run/secrets/...) を完全取得
        is_ph = secret_value_placeholder?(val)
        if !is_ph && (dq || bare) && (val.start_with?("$(") || val.start_with?("${")) && balanced_checks < 64
          val_start = dq ? lm.begin(5) : lm.begin(7)
          if val_start
            win = clean[val_start, 512]
            close_ch = win && win[1] == "(" ? ")" : "}"
            if win && win.include?(close_ch)
              balanced_checks += 1
              st = { unbalanced: false }
              end_i = read_balanced_dollar(win, 0, String.new, [], st, in_outer_dq: !dq.nil? && win[1] == "{")
              if !st[:unbalanced] && end_i > 0
                after = clean[val_start + end_i]
                valid_end = dq ? (after == '"') : (after.nil? || after.match?(/[\s,}\];"')&]/))
                is_ph = secret_value_placeholder?(win[0...end_i]) if valid_end
              end
            end
          end
        end
        found_keys << raw_key unless is_ph
      elsif inner_depth < 2 && val.bytesize <= MAX_NESTED_LEAF_BYTES
        if (dq || sq) && (val.include?("=") || val.include?(":"))
          inner = dq ? val.gsub('\\"', '"').gsub("\\\\", "\\") : val
          scan_text_lines_and_inline_kv(inner, found_keys, inner_depth + 1, whole_line: whole_line)
        elsif bare && (val.include?("=") || (val.start_with?("{", "[") && val.include?(":")))
          scan_text_lines_and_inline_kv(val, found_keys, inner_depth + 1, whole_line: false)
        end
      end
    end
  end

  flush_pending_block.call
end

def scan_structured_string_leaf(str, found_keys, value_rules, depth, state)
  return if str.empty?

  if str.bytesize >= 7
    rules = secret_value_rules(str)
    value_rules.concat(rules) unless rules.empty?
  end

  nested_parsed_cleanly = false
  if depth < MAX_LEAF_NEST_DEPTH && str.bytesize <= MAX_NESTED_LEAF_BYTES && !state[:truncated]
    trimmed = str.lstrip
    looks_nested_struct = trimmed.start_with?("{", "[") || (str.include?("\n") && str.include?(":"))
    if looks_nested_struct
      nested_parsed_cleanly = parse_and_walk_yaml_stream(str, found_keys, value_rules, depth + 1, state)
    end
  end

  if !nested_parsed_cleanly && (str.include?("=") || str.include?(":"))
    scan_text_lines_and_inline_kv(str, found_keys)
  end
end

def walk_yaml_ast_node(node, found_keys, value_rules, depth, state)
  return if node.nil? || state[:truncated]

  if depth > MAX_AST_DEPTH
    state[:truncated] = true
    return
  end

  state[:nodes] += 1
  if state[:nodes] > MAX_AST_NODES
    state[:truncated] = true
    return
  end

  case node
  when Psych::Nodes::Mapping
    (node.children || []).each_slice(2) do |k_node, v_node|
      break if state[:truncated]
      next if k_node.nil?

      resolved_k = k_node.is_a?(Psych::Nodes::Alias) ? state[:scalar_anchors][k_node.anchor] : k_node

      if k_node.is_a?(Psych::Nodes::Mapping) || k_node.is_a?(Psych::Nodes::Sequence)
        walk_yaml_ast_node(k_node, found_keys, value_rules, depth + 1, state)
        k_valid = false
        norm_k = nil
      elsif k_node.is_a?(Psych::Nodes::Alias) && resolved_k.nil?
        k_valid = false
        norm_k = nil
      else
        if resolved_k.is_a?(Psych::Nodes::Scalar)
          k_str = resolved_k.value.to_s
          if k_str.bytesize >= 7
            kr = secret_value_rules(k_str)
            value_rules.concat(kr) unless kr.empty?
          end
          break unless record_scalar_anchor(resolved_k, state)
        end
        k_valid, norm_k = extract_valid_yaml_ast_key(resolved_k, v_node)
        state[:had_invalid_key] = true unless k_valid
      end

      break if state[:truncated]
      next if v_node.nil?

      case v_node
      when Psych::Nodes::Scalar
        state[:nodes] += 1
        if state[:nodes] > MAX_AST_NODES
          state[:truncated] = true
          break
        end
        break unless record_scalar_anchor(v_node, state)
        val = v_node.value.to_s
        found_keys << norm_k if k_valid && secret_name?(norm_k) && !yaml_scalar_placeholder?(v_node)
        scan_structured_string_leaf(val, found_keys, value_rules, depth + 1, state)
      when Psych::Nodes::Alias
        # コレクション Alias は展開せず O(1) でスキップ（YAML アンカー爆弾対策）。
        # スカラー単体アンカーのみ O(1) 参照し、password: *pw 経由の秘匿値も捕捉する。
        anchored = state[:scalar_anchors][v_node.anchor]
        if anchored.is_a?(Psych::Nodes::Scalar) && k_valid && secret_name?(norm_k) && !yaml_scalar_placeholder?(anchored)
          found_keys << norm_k
        end
      when Psych::Nodes::Mapping, Psych::Nodes::Sequence
        walk_yaml_ast_node(v_node, found_keys, value_rules, depth + 1, state)
      end
    end
  when Psych::Nodes::Sequence
    (node.children || []).each do |el|
      break if state[:truncated]

      case el
      when Psych::Nodes::Scalar
        state[:nodes] += 1
        if state[:nodes] > MAX_AST_NODES
          state[:truncated] = true
          break
        end
        break unless record_scalar_anchor(el, state)
        scan_structured_string_leaf(el.value.to_s, found_keys, value_rules, depth + 1, state)
      when Psych::Nodes::Alias
        next
      when Psych::Nodes::Mapping, Psych::Nodes::Sequence
        walk_yaml_ast_node(el, found_keys, value_rules, depth + 1, state)
      end
    end
  end
end

# libyaml (Psych::Parser) は (1) flow_level が深い入力で yaml_parser_stale_simple_keys が O(N^2)、
# (2) 多数の一意な %TAG ディレクティブで yaml_parser_append_tag_directive が O(K^2) となる。
# ただし libyaml のトークン先読みは simple_key の 1024 文字・同一行上限で厳密に打ち切られるため、
# %TAG 件数の O(N) 事前検査＋Psych::Parser 直結の BoundedYamlTreeBuilder（深さ・ノード数・
# 文書数・flow_depth>8 の累積作業量をイベント単位で即時遮断）により、libyaml 自身と完全に同一の
# 字句・構文解釈でパーサ差分ゼロかつ誤検知ゼロの DoS 対策を実現する。
class YamlStreamLimitError < StandardError; end
class YamlNestingDepthError < YamlStreamLimitError; end
class YamlNodeLimitError < YamlStreamLimitError; end
class YamlDirectiveLimitError < YamlStreamLimitError; end

def exceeds_yaml_tag_directive_limit?(text, max_tags = MAX_YAML_TAG_DIRECTIVES)
  return false unless text.is_a?(String)
  return false unless text.b.include?("%TAG")

  norm = text.encoding == Encoding::UTF_8 && text.valid_encoding? ? text : normalize_utf8(text)
  if norm.include?("\r") || norm.include?("\u0085") || norm.include?("\u2028") || norm.include?("\u2029")
    norm = norm.gsub(/\r\n?|\u0085|\u2028|\u2029/, "\n")
  end
  b = norm.b
  count = 0
  pos = 0
  len = b.bytesize
  while pos < len
    line_end = b.index("\n", pos) || len
    p = pos
    while p + 2 < line_end &&
          b.getbyte(p) == 0xEF &&
          b.getbyte(p + 1) == 0xBB &&
          b.getbyte(p + 2) == 0xBF
      p += 3
    end
    if p + 4 < line_end &&
       b.getbyte(p) == 37 && b.getbyte(p + 1) == 84 && b.getbyte(p + 2) == 65 && b.getbyte(p + 3) == 71 &&
       ((sep = b.getbyte(p + 4)) == 32 || sep == 9)
      count += 1
      return true if count > max_tags
    end
    pos = line_end + 1
  end
  false
end

class BoundedYamlTreeBuilder < Psych::TreeBuilder
  def initialize(max_depth:, max_flow_depth: max_depth, max_nodes:, max_docs:, max_flow_work:)
    super()
    @max_depth = max_depth
    @max_flow_depth = max_flow_depth
    @max_nodes = max_nodes
    @max_docs = max_docs
    @max_flow_work = max_flow_work
    @depth = 0
    @flow_depth = 0
    @nodes = 0
    @docs = 0
    @flow_work = 0
    @flow_stack = []
    @doc_has_root = false
  end

  def start_document(version, tag_directives, implicit)
    @docs += 1
    raise YamlNodeLimitError, "YAML document count limit exceeded" if @docs > @max_docs

    @doc_has_root = false
    super
  end

  def end_document(implicit_end = !streaming?)
    unless @doc_has_root
      @nodes += 1
      raise YamlNodeLimitError, "YAML node limit exceeded" if @nodes > @max_nodes
    end
    super
  end

  def start_mapping(anchor, tag, implicit, style)
    @depth += 1
    raise YamlNestingDepthError, "YAML nesting depth limit exceeded" if @depth > @max_depth

    is_flow = (style == Psych::Nodes::Mapping::FLOW)
    @flow_stack.push(is_flow)
    if is_flow
      @flow_depth += 1
      raise YamlNestingDepthError, "YAML flow depth limit exceeded" if @flow_depth > @max_flow_depth
    end
    charge_node!
    super
  end

  def end_mapping
    @depth -= 1
    @flow_depth -= 1 if @flow_stack.pop
    charge_flow_work!
    super
  end

  def start_sequence(anchor, tag, implicit, style)
    @depth += 1
    raise YamlNestingDepthError, "YAML nesting depth limit exceeded" if @depth > @max_depth

    is_flow = (style == Psych::Nodes::Sequence::FLOW)
    @flow_stack.push(is_flow)
    if is_flow
      @flow_depth += 1
      raise YamlNestingDepthError, "YAML flow depth limit exceeded" if @flow_depth > @max_flow_depth
    end
    charge_node!
    super
  end

  def end_sequence
    @depth -= 1
    @flow_depth -= 1 if @flow_stack.pop
    charge_flow_work!
    super
  end

  def scalar(value, anchor, tag, plain, quoted, style)
    charge_node!
    super
  end

  def alias(anchor)
    charge_node!
    super
  end

  private

  def charge_node!
    @doc_has_root = true
    @nodes += 1
    raise YamlNodeLimitError, "YAML node limit exceeded" if @nodes > @max_nodes

    charge_flow_work!
  end

  def charge_flow_work!
    return unless @flow_depth > 8

    @flow_work += @flow_depth
    raise YamlNestingDepthError, "YAML flow work limit exceeded" if @flow_work > @max_flow_work
  end
end

class YamlFlowDepthProbe < Psych::Handler
  def initialize(max_flow_depth:, max_flow_work: 1_000_000)
    super()
    @max_flow_depth = max_flow_depth
    @max_flow_work = max_flow_work
    @flow_depth = 0
    @flow_work = 0
    @flow_stack = []
  end

  def start_mapping(_anchor, _tag, _implicit, style)
    is_flow = (style == Psych::Nodes::Mapping::FLOW)
    @flow_stack.push(is_flow)
    if is_flow
      @flow_depth += 1
      raise YamlNestingDepthError if @flow_depth > @max_flow_depth

      charge_flow_work!
    end
  end

  def end_mapping
    @flow_depth -= 1 if @flow_stack.pop
    charge_flow_work!
  end

  def start_sequence(_anchor, _tag, _implicit, style)
    is_flow = (style == Psych::Nodes::Sequence::FLOW)
    @flow_stack.push(is_flow)
    if is_flow
      @flow_depth += 1
      raise YamlNestingDepthError if @flow_depth > @max_flow_depth

      charge_flow_work!
    end
  end

  def end_sequence
    @flow_depth -= 1 if @flow_stack.pop
    charge_flow_work!
  end

  def scalar(_value, _anchor, _tag, _plain, _quoted, _style)
    charge_flow_work!
  end

  def alias(_anchor)
    charge_flow_work!
  end

  private

  def charge_flow_work!
    return unless @flow_depth > 8

    @flow_work += @flow_depth
    raise YamlNestingDepthError if @flow_work > @max_flow_work
  end
end

def parse_yaml_stream_bounded(text, max_depth: 65, max_flow_depth: max_depth, max_nodes: 200_000, max_docs: 10_000, max_flow_work: 1_000_000, max_tag_directives: MAX_YAML_TAG_DIRECTIVES)
  return Psych::Nodes::Stream.new unless text.is_a?(String)
  raise YamlDirectiveLimitError, "YAML %TAG directive limit exceeded" if exceeds_yaml_tag_directive_limit?(text, max_tag_directives)

  builder = BoundedYamlTreeBuilder.new(
    max_depth: max_depth,
    max_flow_depth: max_flow_depth,
    max_nodes: max_nodes,
    max_docs: max_docs,
    max_flow_work: max_flow_work
  )
  Psych::Parser.new(builder).parse(text)
  builder.root
end

def exceeds_yaml_flow_depth?(text, max_depth = MAX_YAML_FLOW_PREGUARD)
  return false unless text.is_a?(String)
  return false if text.b.count("{[") <= max_depth
  return true if exceeds_yaml_tag_directive_limit?(text, MAX_YAML_TAG_DIRECTIVES)

  norm = text.encoding == Encoding::UTF_8 && text.valid_encoding? ? text : normalize_utf8(text)
  probe = YamlFlowDepthProbe.new(max_flow_depth: max_depth)
  Psych::Parser.new(probe).parse(norm)
  false
rescue YamlNestingDepthError
  true
rescue Psych::Exception, StandardError, SystemStackError
  false
end

def parse_and_walk_yaml_stream(text, found_keys, value_rules, depth, state)
  stream = parse_yaml_stream_bounded(
    text,
    max_depth: 64,
    max_flow_depth: 64,
    max_nodes: MAX_AST_NODES * 3,
    max_docs: 2_000,
    max_flow_work: 500_000,
    max_tag_directives: MAX_YAML_TAG_DIRECTIVES
  )
  return false unless stream.is_a?(Psych::Nodes::Stream) && stream.children && !stream.children.empty?

  local_state = {
    nodes: state[:nodes],
    truncated: state[:truncated],
    had_invalid_key: false,
    scalar_anchors: {}
  }

  structured_docs = 0
  all_structured_or_empty = true
  stream.children.each do |doc|
    break if local_state[:truncated]
    next unless doc.is_a?(Psych::Nodes::Document)

    root = doc.root
    if root.nil?
      next
    elsif root.is_a?(Psych::Nodes::Mapping) || root.is_a?(Psych::Nodes::Sequence)
      structured_docs += 1
      walk_yaml_ast_node(root, found_keys, value_rules, depth, local_state)
    elsif root.is_a?(Psych::Nodes::Scalar)
      all_structured_or_empty = false
      v = root.value.to_s
      if v.bytesize >= 7
        vr = secret_value_rules(v)
        value_rules.concat(vr) unless vr.empty?
      end
    else
      all_structured_or_empty = false
    end
  end

  state[:nodes] = local_state[:nodes]
  state[:truncated] = true if local_state[:truncated]

  structured_docs > 0 && all_structured_or_empty && !local_state[:truncated] && !local_state[:had_invalid_key]
rescue Psych::Exception, StandardError, SystemStackError
  false
end

def scan_json_obj_fallback(obj, found_keys, value_rules, depth, state)
  return if state[:truncated]

  if depth > MAX_AST_DEPTH
    state[:truncated] = true
    return
  end

  state[:nodes] += 1
  if state[:nodes] > MAX_AST_NODES
    state[:truncated] = true
    return
  end

  case obj
  when Hash
    obj.each do |k, v|
      break if state[:truncated]

      state[:nodes] += 1
      if state[:nodes] > MAX_AST_NODES
        state[:truncated] = true
        break
      end

      ks = k.to_s
      if ks.bytesize >= 7
        kr = secret_value_rules(ks)
        value_rules.concat(kr) unless kr.empty?
      end
      if v.is_a?(String)
        next if v.empty?

        found_keys << ks if secret_name?(ks) && !secret_value_placeholder?(v)
        scan_structured_string_leaf(v, found_keys, value_rules, depth + 1, state)
      elsif v.is_a?(Numeric)
        found_keys << ks if secret_name?(ks)
      elsif v.is_a?(Hash) || v.is_a?(Array)
        scan_json_obj_fallback(v, found_keys, value_rules, depth + 1, state)
      end
    end
  when Array
    obj.each do |el|
      break if state[:truncated]

      state[:nodes] += 1
      if state[:nodes] > MAX_AST_NODES
        state[:truncated] = true
        break
      end

      if el.is_a?(String)
        scan_structured_string_leaf(el, found_keys, value_rules, depth + 1, state) unless el.empty?
      elsif el.is_a?(Hash) || el.is_a?(Array)
        scan_json_obj_fallback(el, found_keys, value_rules, depth + 1, state)
      end
    end
  end
end

def dotenv_secret_rules(str, redact_keys: true)
  return [] unless str.is_a?(String) && !str.empty?

  text = normalize_utf8(str)
  return [] unless text.include?("{") || text.include?("[") || text.include?(":") || text.include?("=")

  found_keys = []
  value_rules = []
  state = { nodes: 0, truncated: false }
  parsed_structured = false

  # 1. Psych.parse_stream AST 走査（JSON / YAML 1.2 を重複キー落ち無し・アンカー爆弾耐性付きで統一走査）
  if text.bytesize <= MAX_YAML_AST_BYTES
    parsed_structured = parse_and_walk_yaml_stream(text, found_keys, value_rules, 0, state)
  end

  # 2. >262 KiB の大規模 JSON や UTF-16 サロゲート対を含む JSON 向けフォールバック
  #    （parsed_structured は false のままにし、Step 3 で重複キーも確実に補完走査する）
  if !parsed_structured && text.bytesize <= MAX_LARGE_JSON_BYTES
    trimmed = text.lstrip
    if trimmed.start_with?("{", "[")
      begin
        parsed_json = JSON.parse(text, max_nesting: MAX_AST_DEPTH)
        if parsed_json.is_a?(Hash) || parsed_json.is_a?(Array)
          scan_json_obj_fallback(parsed_json, found_keys, value_rules, 0, state)
        end
      rescue JSON::ParserError, JSON::NestingError, SystemStackError
        # Step 3 にフォールバック
      end
    end
  end

  # 3. コメント除去・バランス済みプレースホルダ対応の行＆インライン KV 走査
  scan_text_lines_and_inline_kv(text, found_keys) unless parsed_structured

  return (value_rules.uniq + found_keys.uniq) unless redact_keys

  (value_rules.uniq + found_keys.uniq.map { |k| "設定テキスト内の機密項目 (#{redact_secret_label(k)})" }).uniq
end

SHELL_CMD_RE = /\A(?:.*\/)?(?:sh|bash|ash|dash|zsh|ksh|csh|tcsh|fish|su|eval)\z/
PYTHON_CMD_RE = /\A(?:.*\/)?python(?:\d+(?:\.\d+)*)?\z/
RUBY_CMD_RE = /\A(?:.*\/)?ruby(?:\d+(?:\.\d+)*)?\z/
NODE_CMD_RE = /\A(?:.*\/)?node(?:js)?\z/
PERL_CMD_RE = /\A(?:.*\/)?perl(?:\d+(?:\.\d+)*)?\z/
PHP_CMD_RE = /\A(?:.*\/)?php(?:\d+(?:\.\d+)*)?\z/
LUA_CMD_RE = /\A(?:.*\/)?lua(?:\d+(?:\.\d+)*)?\z/
AWK_CMD_RE = /\A(?:.*\/)?(?:g|m)?awk\z/
JQ_CMD_RE = /\A(?:.*\/)?jq\z/
CURL_CMD_RE = /\A(?:.*\/)?curl\z/
TRANSPARENT_CMD_PREFIX_RE = /\A(?:.*\/)?(?:env|exec|nohup|nice|ionice|timeout|setsid|stdbuf|chroot|gosu|su-exec|tini|dumb-init|busybox|time|command|builtin|xargs|sudo)\z/
SHELL_C_FLAG_RE = /\A(?:-[A-Za-z]*c|--command)\z/
HTTP_HEADER_FLAG_RE = /\A(?:-(?>[A-GI-Za-z0-9]*)H|--?(?:proxy-)?header)\z/
USER_AUTH_FLAG_RE = /\A(?:-(?>[A-TV-Za-tv-z0-9]*)[uU]|--?(?:proxy-)?user)\z/
CLI_FLAG_TOKEN_RE = /\A--?[A-Za-z0-9_][A-Za-z0-9_.-]*\z/
BENIGN_NEXT_FLAG_RE = /\A(?:-[A-Za-z]|--[a-z][a-z0-9-]+|--)\z/
FORM_URLENCODED_RE = /\A[A-Za-z_][A-Za-z0-9_.-]*=[^&\s]+(?:&[A-Za-z_][A-Za-z0-9_.-]*=[^&\s]*)+\z/
LEVEL0_SHELL_PLACEHOLDER_CMD_RE = /\A(?:"(?:\$\{(?>(?:(?!\$\()[^}\s{`]){1,128})\}|\$\([A-Za-z_][A-Za-z0-9_.-]*\)|\$[A-Za-z_][A-Za-z0-9_]*)"|(?:\$\{(?>(?:(?!\$\()[^}\s{`]){1,128})\}|\$\([A-Za-z_][A-Za-z0-9_.-]*\)|\$[A-Za-z_][A-Za-z0-9_]*))\s+\S/
CMD_BOUNDARY_OPS = %w[; | || & && ( ) ;;].to_set.add("\n").freeze
SHELL_CMD_START_KEYWORDS = %w[if then else elif do while until case ! {].to_set.freeze
MAX_SHELL_DEPTH = 6
MAX_SHELL_WORK_BYTES = 1_048_576

CLI_FLAG_SPACE_RE = /(?:^|(?<=[\s;|&('"=`]))--?([A-Za-z_][A-Za-z0-9_.-]*)\s+(?:"((?>[^"\\]*(?:\\.[^"\\]*)*))"|'([^']*)'|((?:\$\([^)\r\n(]{1,128}\)|\$\{[^}\s{]{1,128}\})(?=$|[\s"'`;|&)])|[^\s\-"';|&)][^\s"';|&)]*))/
CLI_FLAG_EQ_RE = /(?:^|(?<=[\s;|&('"=`]))(--?)([A-Za-z0-9][A-Za-z0-9._-]*)=(?:"((?>[^"\\]*(?:\\.[^"\\]*)*))"|'([^']*)'|((?:\$\([^)\r\n(]{1,128}\)|\$\{[^}\s{]{1,128}\})(?=$|[\s"'`;|&)])|[^\s"'`;|&)]+))/
CLI_USER_AUTH_RE = /(?:^|(?<=[\s;|&('"=`]))(?:(?:-(?>[A-TV-Za-tv-z0-9]*)[uU]|--?(?:proxy-)?user)(?>\s+|=)(?:"((?>[^"\\]*(?:\\.[^"\\]*)*))"|'([^']*)'|([^\s"'`;|&)]+))|-(?>[A-TV-Za-tv-z0-9]*)[uU](?:"((?>[^"\\]*(?:\\.[^"\\]*)*))"|'([^']*)'|((?>[^:\s="'`;|&)]*):[^\s"'`;|&)]+)))/
CLI_HTTP_HEADER_RE = /(?:^|(?<=[\s;|&('"=`]))(?:(?:-(?>[A-GI-Za-z0-9]*)H|--?(?:proxy-)?header)(?>\s+|=)(?:"((?>[^"\\]*(?:\\.[^"\\]*)*))"|'([^']*)'|((?>[^\s"'`;|&):]+):[^\s"'`;|&)]*))|-(?>[A-GI-Za-z0-9]*)H([A-Za-z](?>[A-Za-z0-9_.-]*):[^\s"'`;|&)]+))|(?<=")-(?>[A-GI-Za-z0-9]*)H([A-Za-z](?>[A-Za-z0-9_.-]*)(?>[ \t]*):[^"\\\r\n]+)|(?<=')-(?>[A-GI-Za-z0-9]*)H([A-Za-z](?>[A-Za-z0-9_.-]*)(?>[ \t]*):[^'\r\n]+)/
SCRIPT_SUBSCRIPT_ASSIGN_RE = /(?:\[\s*(?:(?::|[fFrRbBuU]{0,2})"([A-Za-z_:\\][A-Za-z0-9_. \t\/:\\-]{0,63})"|(?::|[fFrRbBuU]{0,2})'([A-Za-z_:\\][A-Za-z0-9_. \t\/:\\-]{0,63})'|`([A-Za-z_:\\][A-Za-z0-9_. \t\/:\\-]{0,63})`|:\s*([A-Za-z_][A-Za-z0-9_.-]{0,63}))\s*\]|\{\s*(?:[fFrRbBuU]{0,2}"([A-Za-z_:\\][A-Za-z0-9_. \t\/:\\-]{0,63})"|[fFrRbBuU]{0,2}'([A-Za-z_:\\][A-Za-z0-9_. \t\/:\\-]{0,63})'|([A-Za-z_][A-Za-z0-9_.-]{0,63}))\s*\})\s*(?:[:=]|(?:\|\||&&|\?\?|\+)=)(?!=)\s*(?:[fFrRbBuU]{0,2}(?:"((?>[^"\\]*(?:\\.[^"\\]*)*))"|'((?>[^'\\]*(?:\\.[^'\\]*)*))')|`((?>[^`\\]*(?:\\.[^`\\]*)*))`)/
SCRIPT_FAT_COMMA_RE = /(?:(?:^|(?<=[\s{,\(\[;]))(?:"([A-Za-z_:\\][A-Za-z0-9_. \t\/:\\-]{0,63})"|'([A-Za-z_:\\][A-Za-z0-9_. \t\/:\\-]{0,63})')|(?:^|(?<=[\s{,\(\[;])):?([A-Za-z_][A-Za-z0-9_.-]{0,63}))\s*=>\s*(?:"((?>[^"\\]*(?:\\.[^"\\]*)*))"|'((?>[^'\\]*(?:\\.[^'\\]*)*))')/
SCRIPT_QUOTED_KEY_RE = /(?:^|(?<=[\s{,\(\[;]))(?:[fFrRbBuU]{0,2}"([A-Za-z_:\\][A-Za-z0-9_. \t\/:\\-]{0,63})"|[fFrRbBuU]{0,2}'([A-Za-z_:\\][A-Za-z0-9_. \t\/:\\-]{0,63})')\s*[:=](?!=)\s*(?:[fFrRbBuU]{0,2}(?:"((?>[^"\\]*(?:\\.[^"\\]*)*))"|'((?>[^'\\]*(?:\\.[^'\\]*)*))')|`((?>[^`\\]*(?:\\.[^`\\]*)*))`)/
SCRIPT_ARRAY_FLAG_RE = /(?:"(--?)([A-Za-z0-9_][A-Za-z0-9_.-]{0,63})"|'(--?)([A-Za-z0-9_][A-Za-z0-9_.-]{0,63})')\s*,\s*[fFrRbBuU]{0,2}(?:"((?>[^"\\]*(?:\\.[^"\\]*)*))"|'((?>[^'\\]*(?:\\.[^'\\]*)*))')/
MULTILINE_SHELL_HINT_RE = /(?:^|[\s;&|(])(?:(?:\$?['"])?--?(?:[A-Za-z_]|[0-9]+[A-Za-z])|eval\b)|&&|\|\||<<|[;|]/

WRAPPER_POSITIONAL_COUNTS = {
  "timeout" => 1,
  "chroot" => 1,
  "gosu" => 1,
  "su-exec" => 1
}.freeze

def wrapper_opt_takes_arg?(wrapper_kind, flag)
  return false if wrapper_kind.nil? || !flag.is_a?(String) || flag.include?("=")

  case wrapper_kind
  when "env"
    flag.match?(/\A(?:-[i0v]*[uCS]|--(?:unset|chdir|split-string))\z/)
  when "sudo"
    flag.match?(/\A(?:-[AbBEHknPSv]*[ugCDhprtTU]|--(?:user|group|chdir|host|prompt|role|type|command-timeout|other-user))\z/)
  when "timeout"
    flag.match?(/\A(?:-v*[ks]|--(?:kill-after|signal))\z/)
  when "nice"
    flag.match?(/\A(?:-n|--adjustment)\z/)
  when "ionice"
    flag.match?(/\A(?:-[cnp]|--(?:class|classdata|pid))\z/)
  when "stdbuf"
    flag.match?(/\A(?:-[ioe]|--(?:input|output|error))\z/)
  when "exec"
    flag == "-a"
  when "xargs"
    flag.match?(/\A(?:-[ILnPsdE]|--(?:max-args|max-procs|replace|delimiter|eof))\z/)
  when "tini"
    flag == "-e"
  when "dumb-init"
    flag.match?(/\A(?:-r|--rewrite)\z/)
  else
    false
  end
end

def script_interpreter_kind(word)
  return nil unless word.is_a?(String) && !word.empty?

  case word
  when PYTHON_CMD_RE then :python
  when RUBY_CMD_RE then :ruby
  when NODE_CMD_RE then :node
  when PERL_CMD_RE then :perl
  when PHP_CMD_RE then :php
  when LUA_CMD_RE then :lua
  when AWK_CMD_RE then :awk
  when JQ_CMD_RE then :jq
  end
end

def script_code_flag_for?(interp, flag)
  return false unless flag.is_a?(String)

  case interp
  when :python then flag.match?(/\A-[A-Za-z]*c\z/)
  when :ruby then flag.match?(/\A(?:-[A-Za-z0-9]*e|--eval)\z/)
  when :node then flag.match?(/\A(?:-[A-Za-z]*[ep]|--eval|--print)\z/)
  when :perl then flag.match?(/\A-[A-Za-z0-9]*[eE]\z/)
  when :php then flag.match?(/\A-[A-Za-z]*r\z/)
  when :lua then flag.match?(/\A-[A-Za-z0-9]*e\z/)
  when :awk then flag.match?(/\A(?:-e|--source)\z/)
  else false
  end
end

ATTACHED_PYTHON_CODE_RE = /\A-(?>[A-Za-z&&[^c]]*)c(.+)\z/m
ATTACHED_RUBY_LUA_CODE_RE = /\A-(?>[A-Za-z0-9&&[^e]]*)e(.+)\z/m
ATTACHED_NODE_CODE_RE = /\A-(?>[A-Za-z&&[^ep]]*)[ep](.+)\z/m
ATTACHED_PERL_CODE_RE = /\A-(?>[A-Za-z0-9&&[^eE]]*)[eE](.+)\z/m
ATTACHED_PHP_CODE_RE = /\A-(?>[A-Za-z&&[^r]]*)r(.+)\z/m

def extract_attached_script_code(interp, token)
  return nil unless token.is_a?(String) && token.start_with?("-") && !token.start_with?("--")

  re = case interp
       when :python then ATTACHED_PYTHON_CODE_RE
       when :ruby, :lua then ATTACHED_RUBY_LUA_CODE_RE
       when :node then ATTACHED_NODE_CODE_RE
       when :perl then ATTACHED_PERL_CODE_RE
       when :php then ATTACHED_PHP_CODE_RE
       end
  return nil unless re

  m = token.match(re)
  m ? m[1] : nil
end

def attached_script_flag_is_secret_name?(token)
  if (m = token.match(/\A-([A-Za-z0-9][A-Za-z0-9._-]*)=/))
    fk = m[1]
    secret_name?(fk) ||
      %w[header proxy-header user proxy-user].include?(fk) ||
      token.match?(/\A-(?>[A-GI-Za-z0-9]*)H=/) ||
      token.match?(/\A-(?>[A-TV-Za-tv-z0-9]*)[uU]=/)
  elsif token.match?(CLI_FLAG_TOKEN_RE)
    fk = token.sub(/\A--?/, "")
    secret_name?(fk) ||
      %w[header proxy-header user proxy-user].include?(fk) ||
      token.match?(HTTP_HEADER_FLAG_RE) ||
      token.match?(USER_AUTH_FLAG_RE)
  elsif token.match?(/\A-(?>[A-GI-Za-z0-9]*)H[A-Za-z](?>[A-Za-z0-9_.-]*)(?>[ \t]*):/m) ||
        token.match?(/\A-(?>[A-TV-Za-tv-z0-9]*)[uU](?>[A-Za-z0-9._@-]*):/m)
    true
  else
    false
  end
end

def shell_c_cmd?(cmd)
  return false unless cmd.is_a?(Array) && cmd.length >= 2

  last = cmd.last
  return false unless last.is_a?(String) && last.match?(SHELL_C_FLAG_RE)

  mode, = resolve_level0_cmd_mode(cmd, cmd.length - 1)
  mode == :shell
end

def script_code_cmd?(cmd)
  return false unless cmd.is_a?(Array) && cmd.length >= 2

  last = cmd.last
  return false unless last.is_a?(String)

  mode, interp, = resolve_level0_cmd_mode(cmd, cmd.length - 1)
  mode == :script && script_code_flag_for?(interp, last)
end

def pure_json_container?(str)
  trimmed = str.lstrip
  return false unless trimmed.start_with?("{", "[")
  return false if str.bytesize > MAX_LARGE_JSON_BYTES

  parsed = JSON.parse(str, max_nesting: MAX_AST_DEPTH)
  parsed.is_a?(Hash) || parsed.is_a?(Array)
rescue JSON::ParserError, JSON::NestingError, SystemStackError
  false
end

def read_balanced_dollar(str, i, buf, cmd_subs, state, in_outer_dq: false)
  n = str.length
  open_ch = str[i + 1]
  close_ch = open_ch == "(" ? ")" : "}"
  is_cmd_sub = (open_ch == "(")
  start = i
  i += 2
  depth = 1
  in_sq = false
  in_dq = false

  while i < n && depth > 0
    c = str[i]
    if in_sq
      in_sq = false if c == "'"
      i += 1
    elsif in_dq
      if c == "\\" && i + 1 < n
        i += 2
      elsif !is_cmd_sub && c == "$" && i + 1 < n && str[i + 1] == "("
        i = read_balanced_dollar(str, i, String.new, cmd_subs, state)
      elsif !is_cmd_sub && c == "`"
        i = read_backtick(str, i, String.new, cmd_subs, state)
      else
        in_dq = false if c == '"'
        i += 1
      end
    elsif c == "\\" && i + 1 < n
      i += 2
    elsif !is_cmd_sub && c == "$" && i + 1 < n && str[i + 1] == "("
      i = read_balanced_dollar(str, i, String.new, cmd_subs, state)
    elsif !is_cmd_sub && c == "`"
      i = read_backtick(str, i, String.new, cmd_subs, state)
    elsif c == "'" && !in_outer_dq
      in_sq = true
      i += 1
    elsif c == '"'
      in_dq = true
      i += 1
    elsif c == open_ch
      depth += 1
      i += 1
    elsif c == close_ch
      depth -= 1
      i += 1
    else
      i += 1
    end
  end

  state[:unbalanced] = true if depth > 0 || in_sq || in_dq
  buf << str[start...i]
  if is_cmd_sub && depth == 0
    inner = str[(start + 2)...(i - 1)]
    cmd_subs << inner if !inner.empty? && !inner.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\z/)
  end
  i
end

def read_backtick(str, i, buf, cmd_subs, state)
  n = str.length
  start = i
  i += 1
  inner = String.new
  closed = false
  while i < n
    c = str[i]
    if c == "\\" && i + 1 < n && %w[$ ` \\].include?(str[i + 1])
      inner << str[i + 1]
      i += 2
    elsif c == "`"
      closed = true
      i += 1
      break
    else
      inner << c
      i += 1
    end
  end
  state[:unbalanced] = true unless closed
  buf << str[start...i]
  cmd_subs << inner if closed && !inner.empty?
  i
end

def read_heredoc_body(str, i, delim, strip_tabs)
  n = str.length
  body = String.new
  while i < n
    nl = str.index("\n", i)
    line_end = nl ? nl + 1 : n
    raw_line = str[i...line_end]
    i = line_end
    cmp = raw_line.chomp
    cmp = cmp.sub(/\A\t+/, "") if strip_tabs
    break if cmp == delim

    body << raw_line
  end
  [body, i]
end

def tokenize_shell_command(str)
  n = str.length
  i = 0
  tokens = []
  cmd_subs = []
  pending_heredocs = []
  expect_heredoc_delim = nil
  state = { unbalanced: false }

  buf = String.new
  in_word = false
  had_quotes = false

  flush_word = lambda do
    if in_word
      tokens << [:word, buf, had_quotes]
      if expect_heredoc_delim
        pending_heredocs << [buf, expect_heredoc_delim == :strip_tabs]
        expect_heredoc_delim = nil
      end
      buf = String.new
      in_word = false
      had_quotes = false
    end
  end

  while i < n
    ch = str[i]

    if ch == "\n"
      flush_word.call
      tokens << [:op, "\n", false]
      i += 1
      unless pending_heredocs.empty?
        pending_heredocs.each do |delim, strip_tabs|
          body, i = read_heredoc_body(str, i, delim, strip_tabs)
          tokens << [:heredoc, body, false]
        end
        pending_heredocs.clear
      end
    elsif ch == " " || ch == "\t" || ch == "\r"
      flush_word.call
      i += 1
    elsif ch == "#" && !in_word
      nl = str.index("\n", i + 1)
      i = nl || n
    elsif ch == ";" || ch == "|" || ch == "&" || ch == "(" || ch == ")" || ch == "<" || ch == ">"
      flush_word.call
      if ch == "<" && str[i, 3] == "<<<"
        tokens << [:op, "<<<", false]
        i += 3
      elsif ch == "<" && str[i, 3] == "<<-"
        tokens << [:op, "<<-", false]
        expect_heredoc_delim = :strip_tabs
        i += 3
      elsif ch == "<" && str[i, 2] == "<<"
        tokens << [:op, "<<", false]
        expect_heredoc_delim = :normal
        i += 2
      elsif (two = str[i, 2]) && %w[&& || ;; >> <> >& <&].include?(two)
        tokens << [:op, two, false]
        i += 2
      else
        tokens << [:op, ch, false]
        i += 1
      end
    elsif ch == "'"
      in_word = true
      had_quotes = true
      i += 1
      close = str.index("'", i)
      if close
        buf << str[i...close]
        i = close + 1
      else
        state[:unbalanced] = true
        buf << str[i...n]
        i = n
      end
    elsif ch == '"' || (ch == "$" && i + 1 < n && str[i + 1] == '"')
      in_word = true
      had_quotes = true
      i += (ch == "$" ? 2 : 1)
      closed = false
      while i < n
        c = str[i]
        if c == '"'
          closed = true
          i += 1
          break
        elsif c == "\\" && i + 1 < n
          nxt = str[i + 1]
          if nxt == "\n"
            i += 2
          elsif nxt == "\r" && i + 2 < n && str[i + 2] == "\n"
            i += 3
          elsif nxt == '"' || nxt == "\\" || nxt == "$" || nxt == "`"
            buf << nxt
            i += 2
          else
            buf << "\\" << nxt
            i += 2
          end
        elsif c == "$" && i + 1 < n && (str[i + 1] == "(" || str[i + 1] == "{")
          i = read_balanced_dollar(str, i, buf, cmd_subs, state, in_outer_dq: true)
        elsif c == "`"
          i = read_backtick(str, i, buf, cmd_subs, state)
        else
          next_sp = str.index(/["\\$`]/, i + 1)
          if next_sp
            buf << str[i...next_sp]
            i = next_sp
          else
            buf << str[i...n]
            i = n
          end
        end
      end
      state[:unbalanced] = true unless closed
    elsif ch == "$" && i + 1 < n && str[i + 1] == "'"
      in_word = true
      had_quotes = true
      i += 2
      closed = false
      while i < n
        c = str[i]
        if c == "'"
          closed = true
          i += 1
          break
        elsif c == "\\" && i + 1 < n
          nxt = str[i + 1]
          case nxt
          when "n"
            buf << "\n"
            i += 2
          when "t"
            buf << "\t"
            i += 2
          when "r"
            buf << "\r"
            i += 2
          when "'", '"', "\\"
            buf << nxt
            i += 2
          when "x"
            if i + 3 < n && str[i + 2, 2].match?(/\A[0-9a-fA-F]{2}\z/)
              buf << str[i + 2, 2].to_i(16).chr(Encoding::UTF_8)
              i += 4
            elsif i + 2 < n && str[i + 2].match?(/\A[0-9a-fA-F]\z/)
              buf << str[i + 2].to_i(16).chr(Encoding::UTF_8)
              i += 3
            else
              buf << "\\" << nxt
              i += 2
            end
          when "u"
            hex = str[i + 2, 4].to_s[/\A[0-9a-fA-F]{1,4}/]
            if hex && !hex.empty?
              cp = hex.to_i(16)
              buf << cp.chr(Encoding::UTF_8) if cp <= 0xD7FF || cp.between?(0xE000, 0xFFFF)
              i += 2 + hex.length
            else
              buf << "\\" << nxt
              i += 2
            end
          when "U"
            hex = str[i + 2, 8].to_s[/\A[0-9a-fA-F]{1,8}/]
            if hex && !hex.empty?
              cp = hex.to_i(16)
              buf << cp.chr(Encoding::UTF_8) if cp <= 0xD7FF || cp.between?(0xE000, 0x10FFFF)
              i += 2 + hex.length
            else
              buf << "\\" << nxt
              i += 2
            end
          when "0".."7"
            oct = str[i + 1, 3].to_s[/\A[0-7]{1,3}/]
            buf << (oct.to_i(8) & 0xFF).chr(Encoding::UTF_8)
            i += 1 + oct.length
          else
            buf << nxt
            i += 2
          end
        else
          next_sp = str.index(/['\\]/, i + 1)
          if next_sp
            buf << str[i...next_sp]
            i = next_sp
          else
            buf << str[i...n]
            i = n
          end
        end
      end
      state[:unbalanced] = true unless closed
    elsif ch == "\\"
      if i + 1 < n && str[i + 1] == "\n"
        i += 2
      elsif i + 1 < n && str[i + 1] == "\r" && i + 2 < n && str[i + 2] == "\n"
        i += 3
      elsif i + 1 < n
        in_word = true
        buf << str[i + 1]
        i += 2
      else
        i += 1
      end
    elsif ch == "$" && i + 1 < n && (str[i + 1] == "(" || str[i + 1] == "{")
      in_word = true
      i = read_balanced_dollar(str, i, buf, cmd_subs, state)
    elsif ch == "`"
      in_word = true
      i = read_backtick(str, i, buf, cmd_subs, state)
    else
      in_word = true
      next_sp = str.index(/[\s;|&()<>'"\\$`]/, i + 1)
      if next_sp
        buf << str[i...next_sp]
        i = next_sp
      else
        buf << str[i...n]
        i = n
      end
    end
  end

  flush_word.call
  [tokens, cmd_subs, state[:unbalanced]]
end

def secret_value_placeholder?(val, depth = 0)
  s = val.to_s.strip
  return true if s.empty?
  return false if depth > 4

  unwrapped = if s.start_with?('"') && s.end_with?('"') && s.length >= 2
                s[1..-2].strip
              else
                s
              end

  if unwrapped.start_with?("${") && unwrapped.end_with?("}")
    st = { unbalanced: false }
    end_i = read_balanced_dollar(unwrapped, 0, String.new, [], st)
    if end_i == unwrapped.length && !st[:unbalanced]
      inner_param = unwrapped[2...-1]
      if (pm = inner_param.match(/\A[A-Za-z_][A-Za-z0-9_]*:?[-+=?]\s*(.+)\z/m))
        rhs = pm[1].strip
        return true if rhs.empty?
        return secret_value_placeholder?(rhs, depth + 1) if rhs.include?("$(") || rhs.include?("`")
      end
    end
  end

  if unwrapped.start_with?("$(") && unwrapped.end_with?(")")
    st = { unbalanced: false }
    end_i = read_balanced_dollar(unwrapped, 0, String.new, [], st)
    if end_i == unwrapped.length && !st[:unbalanced]
      inner = unwrapped[2...-1].strip
      return true if inner.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\z/)

      inner_tokens, inner_subs, inner_unbalanced = tokenize_shell_command(inner)
      return false if inner_unbalanced || inner_tokens.empty?

      cmd_tok = inner_tokens[0]
      return false unless cmd_tok[0] == :word

      cmd_name = cmd_tok[1]
      rest = inner_tokens[1..]

      if cmd_name.match?(/\A(?:.*\/)?echo\z/)
        return false unless rest.all? { |k, _, _| k == :word }

        idx = 0
        while idx < rest.length
          _, w, q = rest[idx]
          if !q && w.match?(/\A-[neE]+\z/)
            idx += 1
          else
            break
          end
        end
        words = rest[idx..].map { |_, w, _| w }
        return false if words.empty?

        return words.all? { |w| secret_value_placeholder?(w, depth + 1) }
      elsif cmd_name.match?(/\A(?:.*\/)?printf\z/)
        return false unless rest.all? { |k, _, _| k == :word }

        idx = 0
        idx += 1 if idx < rest.length && !rest[idx][2] && rest[idx][1] == "--"
        words = rest[idx..].map { |_, w, _| w }
        return false if words.empty?

        if words.length >= 2 && words[0].match?(/\A(?:%[0-9.*+-]*[a-zA-Z%]|\\[nrt])+\z/)
          words = words[1..]
        end
        return false if words.empty?

        return words.all? { |w| secret_value_placeholder?(w, depth + 1) }
      elsif cmd_name.match?(/\A(?:.*\/)?cat\z/)
        return false unless inner_subs.empty?

        idx = 0
        idx += 1 if idx < rest.length && rest[idx][0] == :word && !rest[idx][2] && rest[idx][1] == "--"
        idx += 1 if idx < rest.length && rest[idx][0] == :op && rest[idx][1] == "<"
        file_toks = rest[idx..]
        return false if file_toks.empty? || !file_toks.all? { |k, _, _| k == :word }

        return file_toks.all? do |_, w, _|
          w.match?(/\A(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(?:\/[A-Za-z0-9._\/-]+)?|\/[A-Za-z0-9._\/-]+)\z/)
        end
      end

      return false
    end
  end

  secret_placeholder?(s)
end

def auth_header_placeholder?(hname, hval)
  v = hval.to_s.strip
  return true if secret_value_placeholder?(v)

  if hname.match?(/\A(?:proxy[-_.])?authorization\z/i)
    if (m = v.match(/\A(?:Bearer|Basic|Token|Digest|ApiKey)(?>\s+)(.+)\z/im))
      return secret_value_placeholder?(m[1])
    end
  elsif hname.match?(/\Acookie\z/i)
    pairs = v.split(";").map(&:strip).reject(&:empty?)
    if !pairs.empty? && pairs.all? { |p| p.include?("=") }
      return pairs.all? { |p| secret_value_placeholder?(p.split("=", 2)[1]) }
    end
  end
  false
end

def scan_http_header_string(hdr, rules, depth, budget)
  s = hdr.to_s
  return if s.empty?

  if (m = s.match(/\A([A-Za-z](?>[A-Za-z0-9_.-]*))(?>[ \t]*):(?>\s*)(.*)\z/m))
    hname = m[1]
    hval = m[2]
    sensitive = secret_name?(hname) || hname.match?(SECRET_HTTP_HEADER_RE)
    if sensitive
      rules << "HTTP ヘッダ #{redact_secret_label(hname)} が機密を表す" unless auth_header_placeholder?(hname, hval)
    else
      scan_token_payload(hval, rules, depth, budget, had_quotes: false)
    end
  else
    scan_token_payload(s, rules, depth, budget, had_quotes: false)
  end
end

def scan_user_auth_string(val, rules)
  s = val.to_s.strip
  return if s.empty? || secret_value_placeholder?(s)
  return if s.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:\/\//)

  idx = s.index(":")
  return unless idx

  pass = s[(idx + 1)..].to_s
  return if pass.empty? || secret_value_placeholder?(pass)

  rules << "認証引数 (-u/--user) に平文パスワードが含まれています"
end

def attached_u_with_eq_value?(dash, fk, fv)
  return false unless dash == "-" && fv.include?(":")
  return true if fk.match?(/\A[0-9][A-TV-Za-tv-z0-9]*[uU].+\z/)
  return false unless fk.match?(/\A[uU][A-Za-z0-9._@-]+\z/)
  return false if fv.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:\/\//)
  return false if fv.match?(/\A[A-Za-z0-9._-]+:\d{1,5}(?:\/[^\s]*)?\z/)

  true
end

def scan_cli_flag_patterns(str, rules)
  return if str.empty?

  str.scan(CLI_FLAG_SPACE_RE) do |fk, dq, sq, bare|
    val = dq || sq || bare
    next if val.nil? || val.empty?

    rules << "引数フラグ #{redact_secret_label(fk)} が機密を表す" if secret_name?(fk) && !secret_value_placeholder?(val)
  end
  str.scan(CLI_FLAG_EQ_RE) do |dash, fk, dq, sq, bare|
    val = dq || sq || bare
    next if val.nil? || val.empty?

    if fk == "header" || fk == "proxy-header" || (dash == "-" && fk.match?(/\A(?>[A-GI-Za-z0-9]*)H\z/))
      scan_http_header_string(val, rules, 0, { bytes: 0 }) if val.include?(":")
    elsif fk == "user" || fk == "proxy-user" || (dash == "-" && fk.match?(/\A(?>[A-TV-Za-tv-z0-9]*)[uU]\z/)) ||
          attached_u_with_eq_value?(dash, fk, val)
      scan_user_auth_string(val, rules)
    elsif secret_name?(fk) && !secret_value_placeholder?(val)
      rules << "引数フラグ #{redact_secret_label(fk)} が機密を表す"
    end
  end
  str.scan(CLI_USER_AUTH_RE) do |dq1, sq1, bare1, dq2, sq2, bare2|
    val = dq1 || sq1 || bare1 || dq2 || sq2 || bare2
    next if val.nil? || val.empty?

    scan_user_auth_string(val, rules)
  end
  str.scan(CLI_HTTP_HEADER_RE) do |dq1, sq1, bare1, bare2, dq2, sq2|
    val = dq1 || sq1 || bare1 || bare2 || dq2 || sq2
    next if val.nil? || val.empty?

    scan_http_header_string(val, rules, 0, { bytes: 0 })
  end
end

REGEX_PREFIX_KEYWORDS = %w[
  return case in of typeof void delete throw new yield await else do
  if unless while until when elsif and or not print puts warn match
].to_set.freeze
PERL_REGEX_KEYWORDS = %w[m qr].to_set.freeze
PERL_SUBST_KEYWORDS = %w[s tr y].to_set.freeze

def regex_start_context?(code, idx, interp)
  k = idx - 1
  while k >= 0 && ((ch = code[k]) == " " || ch == "\t" || ch == "\r")
    k -= 1
  end
  return :regex if k < 0

  ch = code[k]
  return :regex if "\n;([{,=:?!&|~*%<>^".include?(ch)
  return (k == 0 || code[k - 1] != ch) ? :regex : nil if ch == "-" || ch == "+"

  if ch.match?(/[A-Za-z0-9_$]/)
    ws = k
    ws -= 1 while ws > 0 && code[ws - 1].match?(/[A-Za-z0-9_$]/)
    return nil if ws > 0 && code[ws - 1] == "."

    word = code[ws..k]
    return :regex if REGEX_PREFIX_KEYWORDS.include?(word)
    if interp == :perl || (interp.nil? && k == idx - 1)
      return :subst if PERL_SUBST_KEYWORDS.include?(word)
      return :regex if PERL_REGEX_KEYWORDS.include?(word)
    end
  end
  nil
end

def scan_regex_literal_end(code, idx, line_end, is_subst: false)
  j = idx + 1
  in_class = false
  closed_first = false
  while j < line_end
    c = code[j]
    if c == "\\"
      j += 2
      next
    elsif in_class
      in_class = false if c == "]"
      j += 1
    elsif c == "["
      in_class = true
      j += 1
    elsif c == "/"
      closed_first = true
      j += 1
      break
    else
      j += 1
    end
  end
  return nil unless closed_first
  return j unless is_subst

  while j < line_end
    c = code[j]
    if c == "\\"
      j += 2
      next
    elsif c == "/"
      return j + 1
    else
      j += 1
    end
  end
  nil
end

def extract_escaped_script_strings(code, interp: nil, allow_slash_line_comment: true, allow_lua_line_comment: true)
  strings = []
  n = code.length
  i = 0
  total_bytes = 0
  allow_c_block_comment = interp.nil? || interp == :node || interp == :php
  allow_slash_comment = interp == :node || interp == :php || (interp.nil? && allow_slash_line_comment)
  allow_regex_literal = interp.nil? || interp == :node || interp == :ruby || interp == :perl
  allow_lua_comment = interp == :lua || interp.nil?
  allow_triple_quote = interp == :python || interp.nil?
  allow_hash_comment = interp != :node && interp != :lua
  scan_re = case interp
            when nil then /["'`#\/-]/
            when :node then /["'`#\/]/
            when :php, :ruby, :perl then /["'#\/]/
            when :lua then /["'#-]/
            else /["'#]/
            end
  next_nl = :unset
  next_esc_q = :unset
  next_block_close = :unset
  regex_fail_line_end = -1
  lua_unclosed_eqs = nil
  while i < n && total_bytes < MAX_YAML_AST_BYTES
    idx = code.index(scan_re, i)
    break unless idx

    q = code[idx]
    if q == "#"
      if (allow_hash_comment && (idx == 0 || !code[idx - 1].match?(/[.$]/))) ||
         (idx == 0 && n > 1 && code[1] == "!")
        nl = code.index("\n", idx + 1)
        i = nl ? nl + 1 : n
        next
      end
      i = idx + 1
      next
    elsif q == "/"
      nxt_c = idx + 1 < n ? code[idx + 1] : nil
      if allow_c_block_comment && nxt_c == "*"
        if next_block_close == :unset || (next_block_close && next_block_close < idx + 2)
          next_block_close = code.index("*/", idx + 2)
        end
        i = next_block_close ? next_block_close + 2 : idx + 2
        next
      elsif nxt_c == "/"
        if interp == :node || interp == :php
          nl = code.index("\n", idx + 2)
          i = nl ? nl + 1 : n
          next
        elsif allow_slash_comment && interp.nil?
          if next_nl == :unset || (next_nl && next_nl < idx + 2)
            next_nl = code.index("\n", idx + 2)
          end
          line_end = next_nl || n
          if next_esc_q == :unset || (next_esc_q && next_esc_q < idx + 2)
            next_esc_q = code.index(/\\["'`]/, idx + 2)
          end
          if next_esc_q && next_esc_q < line_end
            sub_strs = extract_escaped_script_strings(
              code[(idx + 2)...line_end],
              interp: nil,
              allow_slash_line_comment: false,
              allow_lua_line_comment: false
            )
            sub_strs.each do |s|
              break if total_bytes >= MAX_YAML_AST_BYTES

              total_bytes += s.bytesize
              strings << s
            end
          end
          i = next_nl ? next_nl + 1 : n
          next
        else
          i = idx + 2
          next
        end
      elsif allow_regex_literal && idx >= regex_fail_line_end && !nxt_c.nil? &&
            (ctx = regex_start_context?(code, idx, interp))
        if next_nl == :unset || (next_nl && next_nl < idx + 1)
          next_nl = code.index("\n", idx + 1)
        end
        line_end = next_nl || n
        end_pos = scan_regex_literal_end(code, idx, line_end, is_subst: (ctx == :subst))
        if end_pos
          i = end_pos
        else
          regex_fail_line_end = line_end
          i = idx + 1
        end
        next
      else
        i = idx + 1
        next
      end
    elsif q == "-"
      if allow_lua_comment && idx + 1 < n && code[idx + 1] == "-"
        p_idx = idx + 2
        if p_idx < n && code[p_idx] == "["
          eq_cnt = 0
          q2 = p_idx + 1
          while q2 < n && code[q2] == "="
            eq_cnt += 1
            q2 += 1
          end
          if q2 < n && code[q2] == "["
            lua_unclosed_eqs ||= Set.new
            if lua_unclosed_eqs.include?(eq_cnt)
              i = q2 + 1
            else
              close_marker = "]#{'=' * eq_cnt}]"
              close_idx = code.index(close_marker, q2 + 1)
              if close_idx
                i = close_idx + close_marker.length
              else
                lua_unclosed_eqs.add(eq_cnt)
                i = q2 + 1
              end
            end
            next
          end
        end
        if interp == :lua
          nl = code.index("\n", idx + 2)
          i = nl ? nl + 1 : n
          next
        elsif interp.nil? && allow_lua_line_comment && (idx == 0 || code[idx - 1].match?(/[\s;]/))
          if next_nl == :unset || (next_nl && next_nl < idx + 2)
            next_nl = code.index("\n", idx + 2)
          end
          line_end = next_nl || n
          if next_esc_q == :unset || (next_esc_q && next_esc_q < idx + 2)
            next_esc_q = code.index(/\\["'`]/, idx + 2)
          end
          if next_esc_q && next_esc_q < line_end
            sub_strs = extract_escaped_script_strings(
              code[(idx + 2)...line_end],
              interp: nil,
              allow_slash_line_comment: false,
              allow_lua_line_comment: false
            )
            sub_strs.each do |s|
              break if total_bytes >= MAX_YAML_AST_BYTES

              total_bytes += s.bytesize
              strings << s
            end
          end
          i = next_nl ? next_nl + 1 : n
          next
        else
          i = idx + 2
          next
        end
      end
      i = idx + 1
      next
    elsif idx > 0 && code[idx - 1] == "\\"
      bs = 0
      bp = idx - 1
      while bp >= 0 && code[bp] == "\\"
        bs += 1
        bp -= 1
      end
      if bs.odd?
        i = idx + 1
        next
      end
    elsif q == "'" && idx > 0 && code[idx - 1].match?(/[A-Za-z0-9_]/)
      prefix_start = idx - 1
      prefix_start -= 1 if prefix_start > 0 && code[prefix_start - 1].match?(/[A-Za-z0-9_]/)
      is_py_prefix = (prefix_start == 0 || !code[prefix_start - 1].match?(/[A-Za-z0-9_]/)) &&
                     code[prefix_start...idx].match?(/\A(?:[fFrRbBuU]|fr|rf|br|rb)\z/i)
      unless is_py_prefix
        i = idx + 1
        next
      end
    end

    if allow_triple_quote && (q == '"' || q == "'") && idx + 2 < n && code[idx + 1] == q && code[idx + 2] == q
      j = idx + 3
      has_escaped_q = false
      buf = String.new
      closed = false
      tq_pat = q == '"' ? /["\\]/ : /['\\]/
      while j < n
        c = code[j]
        if c == q && j + 2 < n && code[j + 1] == q && code[j + 2] == q
          while j + 3 < n && code[j + 3] == q
            buf << q
            j += 1
          end
          closed = true
          j += 3
          break
        elsif c == "\\" && j + 1 < n
          nxt = code[j + 1]
          has_escaped_q = true if nxt == '"' || nxt == "'" || nxt == "`"
          case nxt
          when '"', "'", "`", "\\" then buf << nxt
          when "n" then buf << "\n"
          when "t" then buf << "\t"
          when "r" then buf << "\r"
          else buf << "\\" << nxt
          end
          j += 2
        elsif c == q
          buf << q
          j += 1
        else
          next_sp = code.index(tq_pat, j + 1)
          if next_sp
            buf << code[j...next_sp]
            j = next_sp
          else
            buf << code[j...n]
            j = n
          end
        end
      end
      if has_escaped_q && !buf.empty? && (buf.include?("=") || buf.include?(":") || buf.include?("-"))
        total_bytes += buf.bytesize
        strings << buf
      end
      i = closed ? j : n
      next
    end

    j = idx + 1
    has_escaped_q = false
    buf = String.new
    closed = false
    q_pat = q == '"' ? /["\\]/ : (q == "'" ? /['\\]/ : /[`\\]/)
    while j < n
      c = code[j]
      if c == q
        closed = true
        j += 1
        break
      elsif c == "\\" && j + 1 < n
        nxt = code[j + 1]
        has_escaped_q = true if nxt == '"' || nxt == "'" || nxt == "`"
        case nxt
        when '"', "'", "`", "\\" then buf << nxt
        when "n" then buf << "\n"
        when "t" then buf << "\t"
        when "r" then buf << "\r"
        else buf << "\\" << nxt
        end
        j += 2
      else
        next_sp = code.index(q_pat, j + 1)
        if next_sp
          buf << code[j...next_sp]
          j = next_sp
        else
          buf << code[j...n]
          j = n
        end
      end
    end
    if has_escaped_q && !buf.empty? && (buf.include?("=") || buf.include?(":") || buf.include?("-"))
      total_bytes += buf.bytesize
      strings << buf
    end
    i = closed ? j : n
  end
  strings
end

def scan_script_payload(code, rules, depth = 0, interp: nil)
  return if code.empty? || depth > 2

  rules.concat(secret_value_rules(code))
  rules.concat(dotenv_secret_rules(code))
  found = []
  scan_text_lines_and_inline_kv(code, found, whole_line: false)
  found.uniq.each { |k| rules << "設定テキスト内の機密項目 (#{redact_secret_label(k)})" }
  scan_cli_flag_patterns(code, rules)

  if code.include?("=") || code.include?(":")
    code.scan(SCRIPT_SUBSCRIPT_ASSIGN_RE) do |k1, k2, k3, k4, k5, k6, k7, dq, sq, bt|
      raw_k = decode_quoted_kv_key(k1 || k2 || k3 || k4 || k5 || k6 || k7).strip
      val = dq || sq || bt
      next if val.nil? || val.empty?

      rules << "設定テキスト内の機密項目 (#{redact_secret_label(raw_k)})" if secret_name?(raw_k) && !secret_value_placeholder?(val)
    end
  end

  if code.include?("=>")
    code.scan(SCRIPT_FAT_COMMA_RE) do |k1, k2, k3, dq, sq|
      raw_k = decode_quoted_kv_key(k1 || k2 || k3).strip
      val = dq || sq
      next if val.nil? || val.empty?

      rules << "設定テキスト内の機密項目 (#{redact_secret_label(raw_k)})" if secret_name?(raw_k) && !secret_value_placeholder?(val)
    end
  end

  if code.include?(":") || code.include?("=")
    code.scan(SCRIPT_QUOTED_KEY_RE) do |k1, k2, dq, sq, bt|
      raw_k = decode_quoted_kv_key(k1 || k2).strip
      val = dq || sq || bt
      next if val.nil? || val.empty?

      rules << "設定テキスト内の機密項目 (#{redact_secret_label(raw_k)})" if secret_name?(raw_k) && !secret_value_placeholder?(val)
    end
  end

  if code.include?(",") && code.include?("-")
    code.scan(SCRIPT_ARRAY_FLAG_RE) do |d1, fk1, d2, fk2, dq, sq|
      dash = d1 || d2
      fk = fk1 || fk2
      val = dq || sq
      next if val.nil? || val.empty?

      if (dash == "-" && fk.match?(/\A(?>[A-GI-Za-z0-9]*)H\z/)) || fk == "header" || fk == "proxy-header"
        scan_http_header_string(val, rules, 0, { bytes: 0 }) if val.include?(":")
      elsif (dash == "-" && fk.match?(/\A(?>[A-TV-Za-tv-z0-9]*)[uU]\z/)) || fk == "user" || fk == "proxy-user"
        scan_user_auth_string(val, rules) if val.include?(":")
      elsif secret_name?(fk) && !val.match?(BENIGN_NEXT_FLAG_RE) && !secret_value_placeholder?(val)
        rules << "引数フラグ #{redact_secret_label(fk)} が機密を表す"
      end
    end
  end

  if depth == 0 && (code.include?('\"') || code.include?("\\'") || code.include?('\`'))
    extract_escaped_script_strings(code, interp: interp).each do |inner|
      scan_script_payload(inner, rules, depth + 1, interp: interp)
    end
  end
end

def scan_unbalanced_fallback(str, rules)
  found = []
  scan_text_lines_and_inline_kv(str, found, whole_line: false)
  found.uniq.each { |k| rules << "設定テキスト内の機密項目 (#{redact_secret_label(k)})" }
  scan_cli_flag_patterns(str, rules)
end

def scan_token_payload(val, rules, depth, budget, had_quotes: false)
  return if val.empty?

  if val.include?("\n") || val.lstrip.start_with?("{", "[")
    rules.concat(dotenv_secret_rules(val))
    if had_quotes && depth < MAX_SHELL_DEPTH && !pure_json_container?(val) &&
       val.match?(/(?:^|[\s;&|(])--?(?:[A-Za-z_]|[0-9]+[A-Za-z])[A-Za-z0-9_.-]*(?:=|\s)|&&|\|\||[;|]/)
      scan_shell_command_str(val, rules, depth: depth + 1, budget: budget)
    end
    return
  end

  if val.include?('\\n') && (val.include?("=") || val.include?(":"))
    rules.concat(dotenv_secret_rules(val.gsub('\\n', "\n")))
    return
  end

  if (m = val.match(/\A([A-Za-z_][A-Za-z0-9_.-]*)(?>[ \t]*):(?>[ \t]*)(.+)\z/))
    hname = m[1]
    hval = m[2]
    has_space = val.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\s*:\s+/)
    if hname.match?(SECRET_HTTP_HEADER_RE) || (has_space && secret_name?(hname))
      rules << "設定テキスト内の機密項目 (#{redact_secret_label(hname)})" unless auth_header_placeholder?(hname, hval)
      return
    end
  end

  if val.include?("=") || val.include?(":")
    found = []
    scan_text_lines_and_inline_kv(val, found, whole_line: false)
    found.uniq.each { |k| rules << "設定テキスト内の機密項目 (#{redact_secret_label(k)})" }
  end

  return unless had_quotes && depth < MAX_SHELL_DEPTH && val.match?(/\s/) &&
                val.match?(/(?:^|[\s;&|(])(?:(?:\$?['"])?--?(?:[A-Za-z_]|[0-9]+[A-Za-z])[A-Za-z0-9_.-]*|eval\b|[A-Za-z_][A-Za-z0-9_.-]*\+?=)/)

  scan_shell_command_str(val, rules, depth: depth + 1, budget: budget)
end

def scan_form_urlencoded(str, rules, depth, budget)
  rules.concat(secret_value_rules(str))
  str.split("&").each do |pair|
    fk, fv = pair.split("=", 2)
    next if fk.nil? || fv.nil? || fv.empty?

    rules.concat(secret_value_rules(fv))
    if secret_name?(fk)
      rules << "引数内の代入 #{redact_secret_label(fk)} が機密を表す" unless secret_value_placeholder?(fv)
    elsif fv.include?("=") || fv.include?(":")
      scan_token_payload(fv, rules, depth, budget, had_quotes: false)
    end
  end
end

def scan_shell_command_str(str, rules, depth: 0, budget: nil)
  budget ||= { bytes: 0 }
  return if str.empty?

  if depth > MAX_SHELL_DEPTH || budget[:bytes] > MAX_SHELL_WORK_BYTES
    scan_unbalanced_fallback(str, rules)
    return
  end
  budget[:bytes] += str.bytesize

  tokens, cmd_subs, unbalanced = tokenize_shell_command(str)
  scan_unbalanced_fallback(str, rules) if unbalanced

  cmd_mode = nil
  script_interp = nil
  cmd_is_curl = false
  prev_line_cmd_mode = nil
  prev_line_script_interp = nil
  heredoc_modes = []
  pipeline_heredoc_indices = []
  pending_hd_delim = false
  at_cmd_start = true
  wrapper_kind = nil
  wrapper_pos_left = 0
  wrapper_expect_opt_arg = false
  consumed = Set.new

  tokens.each_with_index do |(kind, val, had_quotes), i|
    if kind == :op
      if val == "<<" || val == "<<-"
        pending_hd_delim = true
      elsif CMD_BOUNDARY_OPS.include?(val)
        if val == "\n"
          prev_line_cmd_mode = cmd_mode
          prev_line_script_interp = script_interp
        else
          prev_line_cmd_mode = nil
          prev_line_script_interp = nil
        end
        pipeline_heredoc_indices.clear unless val == "|"
        cmd_mode = nil
        script_interp = nil
        cmd_is_curl = false
        at_cmd_start = true
        wrapper_kind = nil
        wrapper_pos_left = 0
        wrapper_expect_opt_arg = false
        pending_hd_delim = false
      end
      next
    end

    if kind == :heredoc
      if !heredoc_modes.empty?
        hd_entry = heredoc_modes.shift
        hd_mode = hd_entry ? hd_entry[0] : nil
        hd_interp = hd_entry ? hd_entry[1] : nil
      else
        hd_mode = prev_line_cmd_mode
        hd_interp = prev_line_script_interp
      end
      next if val.empty?

      rules.concat(secret_value_rules(val))
      rules.concat(dotenv_secret_rules(val))
      scan_cli_flag_patterns(val, rules)
      if hd_mode == :script
        scan_script_payload(val, rules, interp: hd_interp)
      elsif hd_mode == :shell
        scan_shell_command_str(val, rules, depth: depth + 1, budget: budget)
      else
        if val.include?("=>") || val.include?('\"') || val.include?("\\'") || val.include?('\`') ||
           (val.include?("[") && val.match?(/\](?>\s*)(?:[:=]|(?:\|\||&&|\?\?|\+)=)/)) ||
           (val.include?(",") && val.include?("-") && val.match?(/(?:"--?[A-Za-z0-9_]|'--?[A-Za-z0-9_])/)) ||
           (val.include?("`") && (val.include?(":") || val.include?("="))) ||
           ((val.include?(":") || val.include?("=")) && val.match?(/(?:^|[\s{,\(\[;])[fFrRbBuU]{1,2}["']/)) ||
           val.match?(/\{[A-Za-z0-9_'"` \t-]{1,64}\}\s*=/)
          scan_script_payload(val, rules)
        end
        if !pure_json_container?(val) && val.match?(MULTILINE_SHELL_HINT_RE)
          scan_shell_command_str(val, rules, depth: depth + 1, budget: budget)
        end
      end
      next
    end

    if pending_hd_delim
      pending_hd_delim = false
      pipeline_heredoc_indices << heredoc_modes.length
      heredoc_modes << (cmd_mode ? [cmd_mode, script_interp] : nil)
      next
    end

    if consumed.include?(i)
      wrapper_expect_opt_arg = false
      next
    end

    if at_cmd_start && !had_quotes && SHELL_CMD_START_KEYWORDS.include?(val)
      cmd_mode = nil
      script_interp = nil
      cmd_is_curl = false
      wrapper_kind = nil
      wrapper_pos_left = 0
      wrapper_expect_opt_arg = false
      next
    end

    is_eval_cmd = false
    if at_cmd_start
      if wrapper_expect_opt_arg
        wrapper_expect_opt_arg = false
      elsif val == "--"
        wrapper_kind = nil
      elsif val.start_with?("-")
        wrapper_expect_opt_arg = true if wrapper_opt_takes_arg?(wrapper_kind, val)
      elsif val.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\+?=/)
        # leading env assignment keeps at_cmd_start true
      elsif wrapper_pos_left > 0
        wrapper_pos_left -= 1
      elsif val.match?(TRANSPARENT_CMD_PREFIX_RE)
        wrapper_kind = val.sub(/\A.*\//, "")
        wrapper_pos_left = WRAPPER_POSITIONAL_COUNTS.fetch(wrapper_kind, 0)
        wrapper_expect_opt_arg = false
      else
        is_eval_cmd = (val == "eval")
        cmd_is_curl = val.match?(CURL_CMD_RE)
        if (sk = script_interpreter_kind(val))
          cmd_mode = :script
          script_interp = sk
        elsif val.match?(SHELL_CMD_RE)
          cmd_mode = :shell
          script_interp = nil
        end
        pipeline_heredoc_indices.each { |hi| heredoc_modes[hi] ||= [cmd_mode, script_interp] } if cmd_mode
        at_cmd_start = false
        wrapper_kind = nil
        wrapper_pos_left = 0
        wrapper_expect_opt_arg = false
      end
    elsif cmd_mode.nil? && !val.start_with?("-") && !val.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\+?=/)
      if (sk = script_interpreter_kind(val))
        cmd_mode = :script
        script_interp = sk
      elsif val.match?(SHELL_CMD_RE)
        cmd_mode = :shell
        script_interp = nil
      end
      pipeline_heredoc_indices.each { |hi| heredoc_modes[hi] ||= [cmd_mode, script_interp] } if cmd_mode
    end

    if cmd_mode == :script && (attached_code = extract_attached_script_code(script_interp, val))
      scan_script_payload(attached_code, rules, interp: script_interp)
      next unless attached_script_flag_is_secret_name?(val)
    end

    if cmd_is_curl
      if (m = val.match(/\A-(?>[012346BGIJLMNORSZafgijklnpqsv]*)H([A-Za-z](?>[A-Za-z0-9_.-]*)(?>[ \t]*):.*)\z/m))
        scan_http_header_string(m[1], rules, depth, budget)
        next
      end
      if (m = val.match(/\A-(?>[012346BGIJLMNORSZafgijklnpqsv]*)[uU]((?>[^:\s]*):.+)\z/m))
        scan_user_auth_string(m[1], rules)
        next
      end
    end

    if (m = val.match(/\A(--?)([A-Za-z0-9][A-Za-z0-9._-]*)=(.+)\z/m))
      dash = m[1]
      fk = m[2]
      fv = m[3]
      flag_tok = "#{dash}#{fk}"
      if fk == "header" || fk == "proxy-header" || val.match?(/\A-(?>[A-GI-Za-z0-9]*)H=/)
        scan_http_header_string(fv, rules, depth, budget)
      elsif fk == "user" || fk == "proxy-user" || val.match?(/\A-(?>[A-TV-Za-tv-z0-9]*)[uU]=/) ||
            attached_u_with_eq_value?(dash, fk, fv)
        scan_user_auth_string(fv, rules)
      elsif cmd_mode == :script && script_code_flag_for?(script_interp, flag_tok)
        scan_script_payload(fv, rules, interp: script_interp)
      elsif fk == "command" && cmd_mode == :shell
        rules.concat(dotenv_secret_rules(fv)) if fv.lstrip.start_with?("{", "[")
        scan_shell_command_str(fv, rules, depth: depth + 1, budget: budget)
      elsif secret_name?(fk)
        rules << "引数フラグ #{redact_secret_label(fk)} が機密を表す" unless secret_value_placeholder?(fv)
      else
        scan_token_payload(fv, rules, depth, budget, had_quotes: had_quotes)
      end
      next
    end

    if (m = val.match(/\A-(?>[A-GI-Za-z0-9]*)H([A-Za-z](?>[A-Za-z0-9_.-]*)(?>[ \t]*):.*)\z/m))
      scan_http_header_string(m[1], rules, depth, budget)
      next
    end

    if (m = val.match(/\A-(?>[A-TV-Za-tv-z0-9]*)[uU]((?>[^:\s=]*):.+)\z/m))
      scan_user_auth_string(m[1], rules)
      next
    end

    if (m = val.match(/\A([A-Za-z_][A-Za-z0-9_.-]*)\+?=(.+)\z/m))
      k = m[1]
      v = m[2]
      if val.match?(FORM_URLENCODED_RE)
        scan_form_urlencoded(val, rules, depth, budget)
      elsif secret_name?(k)
        rules << "引数内の代入 #{redact_secret_label(k)} が機密を表す" unless secret_value_placeholder?(v)
      else
        scan_token_payload(v, rules, depth, budget, had_quotes: had_quotes)
      end
      next
    end

    next_tok = tokens[i + 1]
    if next_tok && next_tok[0] == :word
      next_val = next_tok[1]
      next_quoted = next_tok[2]
      next_is_unquoted_flag = !next_quoted && (next_val == "--" || next_val.match?(CLI_FLAG_TOKEN_RE))

      if is_eval_cmd
        j = i + 1
        parts = []
        while j < tokens.length && tokens[j][0] == :word
          parts << tokens[j][1]
          consumed.add(j)
          j += 1
        end
        scan_shell_command_str(parts.join(" "), rules, depth: depth + 1, budget: budget)
        next
      elsif val.match?(HTTP_HEADER_FLAG_RE) && !next_is_unquoted_flag && next_val.include?(":")
        scan_http_header_string(next_val, rules, depth, budget)
        consumed.add(i + 1)
        next
      elsif val.match?(USER_AUTH_FLAG_RE) && !next_is_unquoted_flag && next_val.include?(":")
        scan_user_auth_string(next_val, rules)
        consumed.add(i + 1)
        next
      elsif cmd_mode == :script && script_code_flag_for?(script_interp, val) && !next_is_unquoted_flag
        scan_script_payload(next_val, rules, interp: script_interp)
        consumed.add(i + 1)
        next
      elsif val.match?(SHELL_C_FLAG_RE) && cmd_mode == :shell && !next_is_unquoted_flag
        rules.concat(dotenv_secret_rules(next_val)) if next_val.lstrip.start_with?("{", "[")
        scan_shell_command_str(next_val, rules, depth: depth + 1, budget: budget)
        consumed.add(i + 1)
        next
      elsif val.match?(SHELL_C_FLAG_RE) && cmd_mode.nil? && !next_is_unquoted_flag
        looks_cfg = next_val.include?("\n") ||
                    next_val.lstrip.start_with?("{", "[") ||
                    next_val.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\s*:\s+/)
        rules.concat(dotenv_secret_rules(next_val)) if looks_cfg
        unless looks_cfg && pure_json_container?(next_val)
          scan_shell_command_str(next_val, rules, depth: depth + 1, budget: budget)
        end
        consumed.add(i + 1)
        next
      elsif (m = val.match(/\A--?([A-Za-z_][A-Za-z0-9_.-]*)\z/)) && secret_name?(m[1])
        if !next_val.empty? && (next_quoted || !next_val.match?(BENIGN_NEXT_FLAG_RE)) && !secret_value_placeholder?(next_val)
          rules << "引数フラグ #{redact_secret_label(m[1])} が機密を表す"
        end
        next
      end
    end

    next if val.match?(CLI_FLAG_TOKEN_RE)

    scan_token_payload(val, rules, depth, budget, had_quotes: had_quotes)
  end

  cmd_subs.each do |sub|
    scan_shell_command_str(sub, rules, depth: depth + 1, budget: budget)
  end
end

def resolve_level0_cmd_mode(argv, upto, prev_cmd: nil)
  mode = nil
  interp = nil
  is_eval = false
  is_curl = false
  at_start = true
  wrapper_kind = nil
  wrapper_pos_left = 0
  wrapper_expect_opt_arg = false

  step = lambda do |a|
    next unless a.is_a?(String) && !a.empty?

    if at_start
      if wrapper_expect_opt_arg
        wrapper_expect_opt_arg = false
      elsif a == "--"
        wrapper_kind = nil
      elsif a.start_with?("-")
        wrapper_expect_opt_arg = true if wrapper_opt_takes_arg?(wrapper_kind, a)
      elsif a.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\+?=/)
        # leading env assignment keeps at_start true
      elsif wrapper_pos_left > 0
        wrapper_pos_left -= 1
      elsif a.match?(TRANSPARENT_CMD_PREFIX_RE)
        wrapper_kind = a.sub(/\A.*\//, "")
        wrapper_pos_left = WRAPPER_POSITIONAL_COUNTS.fetch(wrapper_kind, 0)
        wrapper_expect_opt_arg = false
      else
        is_curl = a.match?(CURL_CMD_RE)
        if a == "eval"
          is_eval = true
          mode = :shell
          interp = nil
        elsif (sk = script_interpreter_kind(a))
          mode = :script
          interp = sk
        elsif a.match?(SHELL_CMD_RE)
          mode = :shell
          interp = nil
        end
        at_start = false
        wrapper_kind = nil
        wrapper_pos_left = 0
        wrapper_expect_opt_arg = false
      end
    elsif mode.nil? && !a.start_with?("-") && !a.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\+?=/)
      if (sk = script_interpreter_kind(a))
        mode = :script
        interp = sk
      elsif a.match?(SHELL_CMD_RE)
        mode = :shell
        interp = nil
      end
    end
  end

  prev_cmd.each { |a| step.call(a) } if prev_cmd.is_a?(Array)
  i = 0
  while i < upto
    step.call(argv[i])
    i += 1
  end
  [mode, interp, is_eval, is_curl]
end

def scan_argv_for_secrets(argv, field_label, target, scope_name, hits, scanned_argv_ids: nil, shell_script_first_arg: false, script_code_first_arg: false, prev_cmd: nil)
  return unless argv.is_a?(Array)

  scanned_argv_ids&.add(argv.object_id)

  prev_trailing = prev_cmd.is_a?(Array) && !prev_cmd.empty? && prev_cmd.last.is_a?(String) ? prev_cmd.last : nil
  prev_cmd_mode = if prev_trailing && prev_trailing.match?(SHELL_C_FLAG_RE) && !shell_script_first_arg && !script_code_first_arg
                    resolve_level0_cmd_mode(prev_cmd, prev_cmd.length - 1)[0]
                  end

  eval_joined_scanned = false
  i = 0
  while i < argv.length
    arg = argv[i]
    unless arg.is_a?(String) && !arg.empty?
      i += 1
      next
    end

    text = normalize_utf8(arg)
    rules = secret_value_rules(text)
    budget = { bytes: 0 }

    prev_arg = i > 0 && argv[i - 1].is_a?(String) ? argv[i - 1] : nil
    l0_mode, l0_interp, l0_eval, l0_curl = resolve_level0_cmd_mode(argv, i, prev_cmd: prev_cmd)
    text_is_cli_flag = (text == "--" || text.match?(CLI_FLAG_TOKEN_RE))

    if i == 0 && prev_trailing
      if (tm = prev_trailing.match(/\A--?([A-Za-z_][A-Za-z0-9_.-]*)\z/)) && secret_name?(tm[1])
        if !text.match?(BENIGN_NEXT_FLAG_RE) && !secret_value_placeholder?(text)
          rules << "引数フラグ #{redact_secret_label(tm[1])} が機密を表す"
        end
      end
    end

    if l0_eval && !eval_joined_scanned
      eval_joined_scanned = true
      joined = argv[i..].select { |x| x.is_a?(String) }.map { |x| normalize_utf8(x) }.join(" ")
      scan_shell_command_str(joined, rules, depth: 0, budget: budget) unless joined.empty?
    end

    prev_is_shell_c = prev_arg&.match?(SHELL_C_FLAG_RE) && !text_is_cli_flag
    is_explicit_shell = (shell_script_first_arg && i == 0) ||
                        (prev_is_shell_c && l0_mode == :shell) ||
                        l0_eval
    is_unknown_c_arg = !is_explicit_shell &&
                       ((prev_is_shell_c && l0_mode.nil?) ||
                        (i == 0 && prev_trailing&.match?(SHELL_C_FLAG_RE) && !script_code_first_arg && prev_cmd_mode.nil? && !text_is_cli_flag))
    is_script_code = !is_explicit_shell && !is_unknown_c_arg &&
                     ((script_code_first_arg && i == 0) ||
                      (l0_mode == :script && prev_arg && script_code_flag_for?(l0_interp, prev_arg) && !text_is_cli_flag))
    eff_hdr_flag = (i == 0 && prev_trailing&.match?(HTTP_HEADER_FLAG_RE)) || prev_arg&.match?(HTTP_HEADER_FLAG_RE)
    eff_user_flag = (i == 0 && prev_trailing&.match?(USER_AUTH_FLAG_RE)) || prev_arg&.match?(USER_AUTH_FLAG_RE)
    is_http_header = !is_explicit_shell && !is_unknown_c_arg && !is_script_code && eff_hdr_flag && !text_is_cli_flag && text.include?(":")
    is_user_auth = !is_explicit_shell && !is_unknown_c_arg && !is_script_code && !is_http_header && eff_user_flag && !text_is_cli_flag && text.include?(":")

    attached_handled = false
    if !is_explicit_shell && !is_unknown_c_arg && !is_script_code && !is_http_header && !is_user_auth &&
       l0_mode == :script && (attached_code = extract_attached_script_code(l0_interp, text))
      scan_script_payload(attached_code, rules, interp: l0_interp)
      attached_handled = !attached_script_flag_is_secret_name?(text)
    end

    if attached_handled
      # 連結スクリプトコード引数 (-c<code> / -e<code> / -r<code>) として検査済み
    elsif is_explicit_shell
      rules.concat(dotenv_secret_rules(text)) if text.lstrip.start_with?("{", "[")
      scan_shell_command_str(text, rules, depth: 0, budget: budget)
    elsif is_unknown_c_arg
      looks_cfg = text.include?("\n") ||
                  text.lstrip.start_with?("{", "[") ||
                  text.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\s*:\s+/)
      rules.concat(dotenv_secret_rules(text)) if looks_cfg
      unless looks_cfg && pure_json_container?(text)
        scan_shell_command_str(text, rules, depth: 0, budget: budget)
      end
    elsif is_script_code
      scan_script_payload(text, rules, interp: l0_interp)
    elsif is_http_header
      scan_http_header_string(text, rules, 0, budget)
    elsif is_user_auth
      scan_user_auth_string(text, rules)
    elsif l0_curl && (m = text.match(/\A-(?>[012346BGIJLMNORSZafgijklnpqsv]*)H([A-Za-z](?>[A-Za-z0-9_.-]*)(?>[ \t]*):.*)\z/m))
      scan_http_header_string(m[1], rules, 0, budget)
    elsif l0_curl && (m = text.match(/\A-(?>[012346BGIJLMNORSZafgijklnpqsv]*)[uU]((?>[^:\s]*):.+)\z/m))
      scan_user_auth_string(m[1], rules)
    elsif (m = text.match(/\A(--?)([A-Za-z0-9][A-Za-z0-9._-]*)=(.+)\z/m))
      dash = m[1]
      fk = m[2]
      fv = m[3]
      flag_tok = "#{dash}#{fk}"
      if fk == "header" || fk == "proxy-header" || text.match?(/\A-(?>[A-GI-Za-z0-9]*)H=/)
        scan_http_header_string(fv, rules, 0, budget)
      elsif fk == "user" || fk == "proxy-user" || text.match?(/\A-(?>[A-TV-Za-tv-z0-9]*)[uU]=/) ||
            attached_u_with_eq_value?(dash, fk, fv)
        scan_user_auth_string(fv, rules)
      elsif l0_mode == :script && script_code_flag_for?(l0_interp, flag_tok)
        scan_script_payload(fv, rules, interp: l0_interp)
      elsif l0_mode == :shell && fk == "command"
        rules.concat(dotenv_secret_rules(fv)) if fv.lstrip.start_with?("{", "[")
        scan_shell_command_str(fv, rules, depth: 0, budget: budget)
      elsif secret_name?(fk)
        rules << "引数フラグ #{redact_secret_label(fk)} が機密を表す" unless secret_value_placeholder?(fv)
      else
        scan_token_payload(fv, rules, 0, budget, had_quotes: false)
        scan_shell_command_str(fv, rules, depth: 0, budget: budget) if fv.match?(/(?:\A|[\s;&|(])--?(?:[A-Za-z_]|[0-9]+[A-Za-z])/)
      end
    elsif (m = text.match(/\A-(?>[A-GI-Za-z0-9]*)H([A-Za-z](?>[A-Za-z0-9_.-]*)(?>[ \t]*):.*)\z/m))
      scan_http_header_string(m[1], rules, 0, budget)
    elsif (m = text.match(/\A-(?>[A-TV-Za-tv-z0-9]*)[uU]((?>[^:\s=]*):.+)\z/m))
      scan_user_auth_string(m[1], rules)
    elsif (m = text.match(/\A([A-Za-z_][A-Za-z0-9_.-]*)\+?=(.+)\z/m))
      k = m[1]
      v = m[2]
      if text.include?("\n")
        rules.concat(dotenv_secret_rules(text))
        if text.match?(MULTILINE_SHELL_HINT_RE)
          scan_shell_command_str(text, rules, depth: 0, budget: budget)
        end
      elsif text.match?(FORM_URLENCODED_RE)
        scan_form_urlencoded(text, rules, 0, budget)
      elsif secret_name?(k)
        if v.match?(LEVEL0_SHELL_PLACEHOLDER_CMD_RE)
          scan_shell_command_str(text, rules, depth: 0, budget: budget)
        else
          rules << "引数内の代入 #{redact_secret_label(k)} が機密を表す" unless secret_value_placeholder?(v)
        end
      elsif text.match?(/&&|\|\||[;|]/)
        scan_shell_command_str(text, rules, depth: 0, budget: budget)
      else
        scan_token_payload(v, rules, 0, budget, had_quotes: false)
        scan_shell_command_str(text, rules, depth: 0, budget: budget) if v.match?(/[\s;&|()<>'"]/)
      end
    elsif (m = text.match(/\A--?([A-Za-z_][A-Za-z0-9_.-]*)\z/))
      if secret_name?(m[1])
        next_arg = argv[i + 1]
        if next_arg.is_a?(String) && !next_arg.empty?
          norm_next = normalize_utf8(next_arg)
          if !norm_next.match?(BENIGN_NEXT_FLAG_RE) && !secret_value_placeholder?(norm_next)
            rules << "引数フラグ #{redact_secret_label(m[1])} が機密を表す"
          end
        end
      end
    elsif text.lstrip.start_with?("{", "[")
      rules.concat(dotenv_secret_rules(text))
      if !pure_json_container?(text) &&
         text.match?(/&&|\|\||[;|]|(?:^|[\s{\[(])--?(?:[A-Za-z_]|[0-9]+[A-Za-z])[A-Za-z0-9_.-]*(?:=|\s)/)
        scan_shell_command_str(text, rules, depth: 0, budget: budget)
      end
    elsif text.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\s*:(?:\s|\z)/)
      if text.include?("\n")
        rules.concat(dotenv_secret_rules(text))
        if text.match?(MULTILINE_SHELL_HINT_RE)
          scan_shell_command_str(text, rules, depth: 0, budget: budget)
        end
      else
        scan_http_header_string(text, rules, 0, budget)
        if text.match?(/[;&|]|(?:^|\s)--?(?:[A-Za-z_]|[0-9]+[A-Za-z])/)
          scan_shell_command_str(text, rules, depth: 0, budget: budget)
        end
      end
    elsif text.match?(/[\s;&|()<>'"]/)
      scan_shell_command_str(text, rules, depth: 0, budget: budget)
    else
      scan_token_payload(text, rules, 0, budget, had_quotes: false)
    end

    rules.uniq!
    hits << [target, "#{scope_name} の #{field_label}[#{i}]", rules] unless rules.empty?
    i += 1
  end
end

def scan_env_array_for_secrets(env_arr, target, scope_name, hits)
  return unless env_arr.is_a?(Array)

  env_arr.each do |e|
    next unless e.is_a?(Hash) && e["name"].is_a?(String)

    ename = e["name"]
    nr = (secret_value_rules(ename) + dotenv_secret_rules(ename)).uniq
    safe_ename = nr.empty? ? redact_secret_label(ename, replacement: "<redacted-key>") : "<redacted-key>"
    hits << [target, "#{scope_name} 環境変数名（伏字）", nr] unless nr.empty?

    val = e["value"]
    if val.is_a?(String)
      next if val.empty?

      rules = secret_value_rules(val)
      rules << "変数名が機密を表す" if secret_name?(ename)
      hits << [target, "#{scope_name} 環境変数 #{safe_ename}", rules] unless rules.empty?
    elsif val.is_a?(Numeric)
      hits << [target, "#{scope_name} 環境変数 #{safe_ename}", ["変数名が機密を表す"]] if secret_name?(ename)
    end
  end
end

def scan_env_hash_for_secrets(env_hash, target, scope_name, hits)
  return unless env_hash.is_a?(Hash)

  env_hash.each do |k, v|
    ks = k.is_a?(String) || k.is_a?(Symbol) || k.is_a?(Numeric) ? k.to_s : ""
    kr = ks.empty? ? [] : (secret_value_rules(ks) + dotenv_secret_rules(ks)).uniq
    safe_k = kr.empty? ? redact_secret_label(k, replacement: "<redacted-key>") : "<redacted-key>"
    hits << [target, "#{scope_name} env trait キー（伏字）", kr] unless kr.empty?
    if v.is_a?(String)
      next if v.empty?

      rules = secret_value_rules(v)
      rules << "変数名が機密を表す" if secret_name?(ks)
      hits << [target, "#{scope_name} env trait #{safe_k}", rules] unless rules.empty?
    elsif v.is_a?(Numeric)
      hits << [target, "#{scope_name} env trait #{safe_k}", ["変数名が機密を表す"]] if secret_name?(ks)
    end
  end
end

def scan_probe_for_secrets(probe, target, scope_name, hits, scanned_argv_ids: nil)
  return unless probe.is_a?(Hash)

  scan_argv_for_secrets(safe_dig(probe, "exec", "command"), "probe.exec.command", target, scope_name, hits, scanned_argv_ids: scanned_argv_ids)
  safe_array(safe_dig(probe, "httpGet", "httpHeaders")).each do |h|
    next unless h.is_a?(Hash)

    raw_hname = h["name"]
    if raw_hname.is_a?(String)
      hname = raw_hname
      hr = (secret_value_rules(hname) + dotenv_secret_rules(hname)).uniq
      safe_hname = hr.empty? ? redact_secret_label(hname, replacement: "<redacted-key>") : "<redacted-key>"
      hits << [target, "#{scope_name} HTTP ヘッダ名（伏字）", hr] unless hr.empty?
      sensitive_header = secret_name?(hname) || hname.match?(SECRET_HTTP_HEADER_RE)
    else
      hname = ""
      safe_hname = "<non-string-header>"
      sensitive_header = false
    end
    hval = h["value"]
    if hval.is_a?(String)
      next if hval.empty?

      rules = (secret_value_rules(hval) + dotenv_secret_rules(hval)).uniq
      rules = (rules + secret_value_rules("#{hname}: #{hval}")).uniq unless hname.empty?
      rules << "HTTP ヘッダ名が機密を表す" if sensitive_header && !auth_header_placeholder?(hname, hval)
      hits << [target, "#{scope_name} HTTP ヘッダ #{safe_hname}", rules] unless rules.empty?
    elsif hval.is_a?(Numeric)
      hits << [target, "#{scope_name} HTTP ヘッダ #{safe_hname}", ["HTTP ヘッダ名が機密を表す"]] if sensitive_header
    end
  end
end

def scan_storage_trait_for_secrets(props, target, scope_name, hits)
  return unless props.is_a?(Hash)

  safe_array(props["secret"]).each_with_index do |s, idx|
    next unless s.is_a?(Hash)

    sname = redact_secret_label(non_empty_str(s["name"]) || "secret[#{idx}]")
    has_inline = (s.key?("data") && !s["data"].nil? && (!s["data"].is_a?(Hash) || !s["data"].empty?)) ||
                 (s.key?("stringData") && !s["stringData"].nil? && (!s["stringData"].is_a?(Hash) || !s["stringData"].empty?))
    if has_inline
      hits << [target, "#{scope_name} storage.secret #{sname}", ["storage.secret にインライン機密データ (data / stringData) が含まれています"]]
    end
  end

  safe_array(props["configMap"]).each_with_index do |cm, idx|
    next unless cm.is_a?(Hash) && cm["data"].is_a?(Hash)

    cm_name = redact_secret_label(non_empty_str(cm["name"]) || "configMap[#{idx}]")
    cm["data"].each do |k, v|
      ks = k.is_a?(String) || k.is_a?(Symbol) || k.is_a?(Numeric) ? k.to_s : ""
      kr = ks.empty? ? [] : (secret_value_rules(ks) + dotenv_secret_rules(ks)).uniq
      safe_k = kr.empty? ? redact_secret_label(k, replacement: "<redacted-key>") : "<redacted-key>"
      hits << [target, "#{scope_name} storage.configMap #{cm_name} キー（伏字）", kr] unless kr.empty?
      if v.is_a?(String)
        next if v.empty?

        rules = (secret_value_rules(v) + dotenv_secret_rules(v)).uniq
        rules << "キー名が機密を表す" if secret_name?(ks) && !secret_value_placeholder?(v)
        hits << [target, "#{scope_name} storage.configMap #{cm_name} キー #{safe_k}", rules] unless rules.empty?
      elsif v.is_a?(Numeric)
        hits << [target, "#{scope_name} storage.configMap #{cm_name} キー #{safe_k}", ["キー名が機密を表す"]] if secret_name?(ks)
      end
    end
  end
end

def compute_command_trait_patch_state(cur_st, patch)
  cur_cmd = cur_st[:cmd]
  cur_args = cur_st[:args]
  new_cmd = if patch["command"].is_a?(Array)
              patch["command"].empty? ? nil : patch["command"].dup
            else
              cur_cmd
            end
  has_args_op = patch["args"].is_a?(Array) || patch["addArgs"].is_a?(Array) || patch["delArgs"].is_a?(Array)
  new_args = if has_args_op
               del_set = patch["delArgs"].is_a?(Array) ? patch["delArgs"].to_set : Set.new
               src_args = patch["args"].is_a?(Array) ? patch["args"] : (cur_args || [])
               src_set = src_args.to_set
               add_arr = patch["addArgs"].is_a?(Array) ? patch["addArgs"] : []
               kept = src_args.reject { |a| del_set.include?(a) }
               added = add_arr.reject { |a| del_set.include?(a) || src_set.include?(a) }
               res = kept + added
               res.empty? ? nil : res
             else
               cur_args
             end
  [new_cmd, new_args]
end

def apply_and_scan_command_patch(st, patch, target, scope, hits, scanned_argv_ids:)
  eff_cmd = if patch["command"].is_a?(Array)
              patch["command"].empty? ? nil : patch["command"]
            else
              st[:cmd]
            end
  base_args_for_add = patch["args"].is_a?(Array) ? patch["args"] : st[:args]
  combined_prior = (eff_cmd.is_a?(Array) ? eff_cmd : []) + (base_args_for_add.is_a?(Array) ? base_args_for_add : [])
  combined_prior = nil if combined_prior.empty?

  %w[command args addArgs delArgs].each do |f|
    prev_for_f = if f == "args"
                   eff_cmd
                 elsif f == "addArgs"
                   combined_prior
                 end
    scan_argv_for_secrets(patch[f], "command.#{f}", target, scope, hits,
                          scanned_argv_ids: scanned_argv_ids,
                          shell_script_first_arg: prev_for_f ? shell_c_cmd?(prev_for_f) : false,
                          script_code_first_arg: prev_for_f ? script_code_cmd?(prev_for_f) : false,
                          prev_cmd: prev_for_f)
  end

  new_cmd, new_args = compute_command_trait_patch_state(st, patch)
  if new_args.is_a?(Array) && !new_args.empty? &&
     (new_cmd != st[:cmd] || patch["delArgs"].is_a?(Array) ||
      (patch["addArgs"].is_a?(Array) && new_args != patch["addArgs"]))
    scan_argv_for_secrets(new_args, "command.effective_args", target, scope, hits,
                          scanned_argv_ids: nil,
                          shell_script_first_arg: shell_c_cmd?(new_cmd),
                          script_code_first_arg: script_code_cmd?(new_cmd),
                          prev_cmd: new_cmd)
  end

  st[:cmd] = new_cmd
  st[:args] = new_args
end

def apply_component_cmd_state_only!(comp, comp_state, default_ctr: nil)
  return unless comp.is_a?(Hash) && comp_state.is_a?(Hash)

  eff_ctr = non_empty_str(comp["name"]) || default_ctr || "(default)"
  main_st = (comp_state[eff_ctr] ||= { cmd: nil, args: nil })
  props = comp["properties"]
  if props.is_a?(Hash)
    main_st[:cmd] = props["cmd"].empty? ? nil : props["cmd"].dup if props["cmd"].is_a?(Array)
    main_st[:args] = props["args"].empty? ? nil : props["args"].dup if props["args"].is_a?(Array)
  end

  safe_array(comp["traits"]).each do |t|
    next unless t.is_a?(Hash) && t["disable"] != true

    tprops = t["properties"]
    next unless tprops.is_a?(Hash)

    case t["type"].to_s
    when "command"
      if tprops.key?("command") || tprops.key?("args") || tprops.key?("addArgs") || tprops.key?("delArgs")
        top_ctr = non_empty_str(tprops["containerName"]) || eff_ctr
        st = (comp_state[top_ctr] ||= { cmd: nil, args: nil })
        st[:cmd], st[:args] = compute_command_trait_patch_state(st, tprops)
      end
      safe_array(tprops["containers"]).each do |c|
        next unless c.is_a?(Hash)

        c_ctr = non_empty_str(c["containerName"]) || eff_ctr
        c_st = (comp_state[c_ctr] ||= { cmd: nil, args: nil })
        c_st[:cmd], c_st[:args] = compute_command_trait_patch_state(c_st, c)
      end
    when "sidecar"
      raw_sname = non_empty_str(tprops["name"])
      next unless raw_sname

      sc_st = (comp_state[raw_sname] ||= { cmd: nil, args: nil })
      sc_st[:cmd] = tprops["cmd"].empty? ? nil : tprops["cmd"].dup if tprops["cmd"].is_a?(Array)
      sc_st[:args] = tprops["args"].empty? ? nil : tprops["args"].dup if tprops["args"].is_a?(Array)
    end
  end
end

def clone_comp_cmd_states(states)
  states.each_with_object({}) do |(comp_name, ctrs), copy|
    copy[comp_name] = ctrs.each_with_object({}) do |(ctr_name, st), c_copy|
      c_copy[ctr_name] = {
        cmd: st[:cmd] ? st[:cmd].dup : nil,
        args: st[:args] ? st[:args].dup : nil
      }
    end
  end
end

def collect_deploy_policy_sequences(steps, out, depth = 0)
  return if depth > 4 || !steps.is_a?(Array)

  steps.each do |st|
    next unless st.is_a?(Hash)

    if st["type"] == "deploy" && st["properties"].is_a?(Hash) && st["properties"]["policies"].is_a?(Array)
      pols = st["properties"]["policies"].select { |pn| non_empty_str(pn) }
      out << pols unless pols.empty?
    end
    collect_deploy_policy_sequences(st["subSteps"], out, depth + 1) if st["subSteps"].is_a?(Array)
  end
end

def scan_component_for_secrets(comp, target, scope_prefix, hits, scanned_argv_ids: nil,
                               comp_state: nil, default_ctr: nil)
  return unless comp.is_a?(Hash)

  raw_cname = non_empty_str(comp["name"])
  cname = raw_cname ? redact_secret_label(raw_cname) : "(無名)"
  eff_ctr = raw_cname || default_ctr || "(default)"
  comp_state ||= {}
  main_st = (comp_state[eff_ctr] ||= { cmd: nil, args: nil })
  scope = "#{scope_prefix}コンポーネント #{cname}"
  props = comp["properties"]
  if props.is_a?(Hash)
    scan_env_array_for_secrets(props["env"], target, scope, hits)
    prev_main_cmd = main_st[:cmd]
    if props["cmd"].is_a?(Array)
      scan_argv_for_secrets(props["cmd"], "cmd", target, scope, hits, scanned_argv_ids: scanned_argv_ids)
      main_st[:cmd] = props["cmd"].empty? ? nil : props["cmd"].dup
    end
    if props["args"].is_a?(Array)
      scan_argv_for_secrets(props["args"], "args", target, scope, hits,
                            scanned_argv_ids: scanned_argv_ids,
                            shell_script_first_arg: shell_c_cmd?(main_st[:cmd]),
                            script_code_first_arg: script_code_cmd?(main_st[:cmd]),
                            prev_cmd: main_st[:cmd])
      main_st[:args] = props["args"].empty? ? nil : props["args"].dup
    elsif main_st[:cmd] != prev_main_cmd && main_st[:args].is_a?(Array) && !main_st[:args].empty?
      scan_argv_for_secrets(main_st[:args], "args", target, scope, hits,
                            scanned_argv_ids: nil,
                            shell_script_first_arg: shell_c_cmd?(main_st[:cmd]),
                            script_code_first_arg: script_code_cmd?(main_st[:cmd]),
                            prev_cmd: main_st[:cmd])
    end
    scan_probe_for_secrets(props["livenessProbe"], target, "#{scope} livenessProbe", hits, scanned_argv_ids: scanned_argv_ids)
    scan_probe_for_secrets(props["readinessProbe"], target, "#{scope} readinessProbe", hits, scanned_argv_ids: scanned_argv_ids)
  end

  safe_array(comp["traits"]).each do |t|
    next unless t.is_a?(Hash)

    ttype = t["type"].to_s
    tprops = t["properties"]
    next unless tprops.is_a?(Hash)

    disabled = (t["disable"] == true)

    case ttype
    when "env"
      scan_env_hash_for_secrets(tprops["env"], target, scope, hits)
      safe_array(tprops["containers"]).each do |c|
        next unless c.is_a?(Hash)

        ctr_name = non_empty_str(c["containerName"])
        safe_ctr = redact_secret_label(ctr_name || "(container)")
        scan_env_hash_for_secrets(c["env"], target, "#{scope}/#{safe_ctr}", hits)
      end
    when "command"
      if tprops.key?("command") || tprops.key?("args") || tprops.key?("addArgs") || tprops.key?("delArgs")
        raw_top_ctr = non_empty_str(tprops["containerName"])
        top_ctr = raw_top_ctr || eff_ctr
        top_scope = raw_top_ctr ? "#{scope}/#{redact_secret_label(raw_top_ctr)}" : scope
        st = disabled ? { cmd: nil, args: nil } : (comp_state[top_ctr] ||= { cmd: nil, args: nil })
        apply_and_scan_command_patch(st, tprops, target, top_scope, hits, scanned_argv_ids: scanned_argv_ids)
      end
      safe_array(tprops["containers"]).each do |c|
        next unless c.is_a?(Hash)

        ctr_name = non_empty_str(c["containerName"])
        safe_ctr = redact_secret_label(ctr_name || "(container)")
        target_ctr = ctr_name || eff_ctr
        c_st = disabled ? { cmd: nil, args: nil } : (comp_state[target_ctr] ||= { cmd: nil, args: nil })
        apply_and_scan_command_patch(c_st, c, target, "#{scope}/#{safe_ctr}", hits, scanned_argv_ids: scanned_argv_ids)
      end
    when "init-container", "sidecar"
      raw_sname = non_empty_str(tprops["name"])
      sname = redact_secret_label(raw_sname || ttype)
      sub_scope = "#{scope} #{ttype}(#{sname})"
      scan_env_array_for_secrets(tprops["env"], target, sub_scope, hits)
      sc_st = if ttype == "sidecar" && raw_sname && !disabled
                (comp_state[raw_sname] ||= { cmd: nil, args: nil })
              end
      prev_sc_cmd = sc_st ? sc_st[:cmd] : nil
      eff_sc_cmd = if tprops["cmd"].is_a?(Array)
                     tprops["cmd"].empty? ? nil : tprops["cmd"].dup
                   else
                     prev_sc_cmd
                   end
      scan_argv_for_secrets(tprops["cmd"], "cmd", target, sub_scope, hits, scanned_argv_ids: scanned_argv_ids)
      sc_st[:cmd] = eff_sc_cmd if sc_st && tprops["cmd"].is_a?(Array)
      if tprops["args"].is_a?(Array)
        scan_argv_for_secrets(tprops["args"], "args", target, sub_scope, hits,
                              scanned_argv_ids: scanned_argv_ids,
                              shell_script_first_arg: shell_c_cmd?(eff_sc_cmd),
                              script_code_first_arg: script_code_cmd?(eff_sc_cmd),
                              prev_cmd: eff_sc_cmd)
        sc_st[:args] = tprops["args"].empty? ? nil : tprops["args"].dup if sc_st
      elsif sc_st && sc_st[:cmd] != prev_sc_cmd && sc_st[:args].is_a?(Array) && !sc_st[:args].empty?
        scan_argv_for_secrets(sc_st[:args], "args", target, sub_scope, hits,
                              scanned_argv_ids: nil,
                              shell_script_first_arg: shell_c_cmd?(sc_st[:cmd]),
                              script_code_first_arg: script_code_cmd?(sc_st[:cmd]),
                              prev_cmd: sc_st[:cmd])
      end
      scan_probe_for_secrets(tprops["livenessProbe"], target, "#{sub_scope} livenessProbe", hits, scanned_argv_ids: scanned_argv_ids)
      scan_probe_for_secrets(tprops["readinessProbe"], target, "#{sub_scope} readinessProbe", hits, scanned_argv_ids: scanned_argv_ids)
    when "startup-probe"
      scan_probe_for_secrets(tprops, target, "#{scope} startup-probe", hits, scanned_argv_ids: scanned_argv_ids)
      safe_array(tprops["probes"]).each_with_index do |pr, idx|
        scan_probe_for_secrets(pr, target, "#{scope} startup-probe[#{idx}]", hits, scanned_argv_ids: scanned_argv_ids)
      end
    when "lifecycle"
      scan_probe_for_secrets(tprops["postStart"], target, "#{scope} lifecycle.postStart", hits, scanned_argv_ids: scanned_argv_ids)
      scan_probe_for_secrets(tprops["preStop"], target, "#{scope} lifecycle.preStop", hits, scanned_argv_ids: scanned_argv_ids)
    when "storage"
      scan_storage_trait_for_secrets(tprops, target, scope, hits)
    end
  end
end

def scan_arbitrary_tree(obj, target, path, hits, depth = 0, skip_dotenv_obj_ids: nil)
  abort "機密検査のネストが深すぎます (#{target}: #{path})" if depth > 64

  case obj
  when Hash
    obj.each do |k, v|
      ks = k.is_a?(String) || k.is_a?(Symbol) || k.is_a?(Numeric) ? k.to_s : ""
      kr = ks.empty? ? [] : (secret_value_rules(ks) + dotenv_secret_rules(ks)).uniq
      safe_ks = kr.empty? ? redact_secret_label(k, replacement: "<redacted-key>") : "<redacted-key>"
      child_path = path.empty? ? safe_ks : "#{path}.#{safe_ks}"
      hits << [target, "#{child_path}（キー名）", kr] unless kr.empty?
      if v.is_a?(String) || v.is_a?(Symbol)
        vs = v.to_s
        next if vs.empty?

        rules = (secret_value_rules(vs) + dotenv_secret_rules(vs)).uniq
        if !SAFE_REF_META_KEYS.include?(ks) && secret_name?(ks) && !secret_value_placeholder?(vs)
          rules << "項目名 #{safe_ks} が機密を表す"
        end
        hits << [target, child_path, rules] unless rules.empty?
      elsif v.is_a?(Numeric)
        if !SAFE_REF_META_KEYS.include?(ks) && secret_name?(ks)
          hits << [target, child_path, ["項目名 #{safe_ks} が機密を表す"]]
        end
      elsif v.is_a?(Hash) || v.is_a?(Array)
        scan_arbitrary_tree(v, target, child_path, hits, depth + 1, skip_dotenv_obj_ids: skip_dotenv_obj_ids)
      end
    end
  when Array
    skip_dotenv = skip_dotenv_obj_ids&.include?(obj.object_id)
    obj.each_with_index do |el, idx|
      child_path = "#{path}[#{idx}]"
      if el.is_a?(String) || el.is_a?(Symbol)
        es = el.to_s
        next if es.empty?

        rules = skip_dotenv ? secret_value_rules(es) : (secret_value_rules(es) + dotenv_secret_rules(es)).uniq
        hits << [target, child_path, rules] unless rules.empty?
      elsif el.is_a?(Hash) || el.is_a?(Array)
        scan_arbitrary_tree(el, target, child_path, hits, depth + 1, skip_dotenv_obj_ids: skip_dotenv_obj_ids)
      end
    end
  end
end

# 昇格対象の全リソースから、機密らしい箇所を集める。[対象（Kind/名前）, 場所, 当たったルール]
def secret_like_hits(resources)
  hits = []
  resources.each do |r|
    next unless r.is_a?(Hash)

    raw_meta_name = safe_dig(r, "metadata", "name")
    name_rules = raw_meta_name.is_a?(String) && !raw_meta_name.empty? ? (secret_value_rules(raw_meta_name) + dotenv_secret_rules(raw_meta_name)).uniq : []
    safe_meta_name = name_rules.empty? ? redact_secret_label(raw_meta_name) : "<redacted>"
    target = "#{r['kind']}/#{safe_meta_name}"
    meta = r["metadata"]
    if meta.is_a?(Hash)
      scan_arbitrary_tree(meta["annotations"], target, "metadata.annotations", hits) if meta["annotations"].is_a?(Hash)
      scan_arbitrary_tree(meta["labels"], target, "metadata.labels", hits) if meta["labels"].is_a?(Hash)
      hits << [target, "metadata.name", name_rules] unless name_rules.empty?
      extra_meta = meta.reject { |k, _| %w[name annotations labels].include?(k) }
      scan_arbitrary_tree(extra_meta, target, "metadata", hits) unless extra_meta.empty?
    end
    if r["apiVersion"].is_a?(String) && !r["apiVersion"].empty?
      av_rules = (secret_value_rules(r["apiVersion"]) + dotenv_secret_rules(r["apiVersion"])).uniq
      hits << [target, "apiVersion", av_rules] unless av_rules.empty?
    end

    if r["kind"] == "ConfigMap"
      if r["data"].is_a?(Hash)
        r["data"].each do |key, val|
          ks = key.is_a?(String) || key.is_a?(Symbol) || key.is_a?(Numeric) ? key.to_s : ""
          kr = ks.empty? ? [] : (secret_value_rules(ks) + dotenv_secret_rules(ks)).uniq
          safe_key = kr.empty? ? redact_secret_label(key, replacement: "<redacted-key>") : "<redacted-key>"
          hits << [target, "キー（伏字）", kr] unless kr.empty?
          if val.is_a?(String)
            rules = (secret_value_rules(val) + dotenv_secret_rules(val)).uniq
            rules << "キー名が機密を表す" if secret_name?(ks) && !secret_value_placeholder?(val)
            hits << [target, "キー #{safe_key}", rules] unless rules.empty?
          elsif val.is_a?(Numeric)
            hits << [target, "キー #{safe_key}", ["キー名が機密を表す"]] if secret_name?(ks)
          end
        end
      end
      if r["binaryData"].is_a?(Hash)
        r["binaryData"].each do |key, val|
          ks = key.is_a?(String) || key.is_a?(Symbol) || key.is_a?(Numeric) ? key.to_s : ""
          kr = ks.empty? ? [] : (secret_value_rules(ks) + dotenv_secret_rules(ks)).uniq
          safe_key = kr.empty? ? redact_secret_label(key, replacement: "<redacted-key>") : "<redacted-key>"
          hits << [target, "キー（伏字・binaryData）", kr] unless kr.empty?
          rules = secret_binary_rules(val)
          if secret_name?(ks) && ((val.is_a?(String) && !val.empty?) || val.is_a?(Numeric))
            raw_bytes = val.is_a?(String) ? decode_strict_base64(val) : nil
            utf8 = raw_bytes ? String.new(raw_bytes, encoding: Encoding::UTF_8) : nil
            is_placeholder = utf8 && utf8.valid_encoding? && !utf8.include?("\x00") && secret_value_placeholder?(utf8)
            rules = (rules + ["キー名が機密を表す"]).uniq unless is_placeholder
          end
          hits << [target, "キー #{safe_key}（binaryData）", rules] unless rules.empty?
        end
      end
      extra_cm = r.reject { |k, _| %w[apiVersion kind metadata data binaryData].include?(k) }
      scan_arbitrary_tree(extra_cm, target, "", hits) unless extra_cm.empty?
    elsif r["kind"] == "Application"
      spec = r["spec"]
      if spec.is_a?(Hash)
        scanned_argv_ids = Set.new
        base_comp_states = {}
        base_comp_names = []
        base_comp_type_by_name = {}
        safe_array(spec["components"]).each do |comp|
          next unless comp.is_a?(Hash)

          cname = non_empty_str(comp["name"])
          comp_st = {}
          if cname
            base_comp_names << cname
            base_comp_type_by_name[cname] = non_empty_str(comp["type"])
            base_comp_states[cname] = comp_st
          end
          scan_component_for_secrets(comp, target, "", hits,
                                     scanned_argv_ids: scanned_argv_ids,
                                     comp_state: comp_st,
                                     default_ctr: cname)
        end

        run_override_sequence = lambda do |seq_entries, states|
          seq_entries.each do |pol, idx|
            next unless pol.is_a?(Hash) && pol["type"] == "override" && pol["properties"].is_a?(Hash)

            pname = redact_secret_label(non_empty_str(pol["name"]) || "policies[#{idx}]")
            raw_sel = pol["properties"]["selector"]
            selected_names = if raw_sel.is_a?(Array) && !raw_sel.empty?
                               base_comp_names.select { |n| raw_sel.include?(n) }
                             else
                               base_comp_names
                             end
            safe_array(pol["properties"]["components"]).each do |oc|
              next unless oc.is_a?(Hash)

              oc_name = non_empty_str(oc["name"])
              if oc_name
                st_map = (states[oc_name] ||= {})
                scan_component_for_secrets(oc, target, "override(#{pname}) ", hits,
                                           scanned_argv_ids: scanned_argv_ids,
                                           comp_state: st_map,
                                           default_ctr: oc_name)
              else
                oc_type = non_empty_str(oc["type"])
                cands = oc_type ? selected_names.select { |n| base_comp_type_by_name[n] == oc_type } : selected_names
                if cands.empty?
                  scan_component_for_secrets(oc, target, "override(#{pname}) ", hits,
                                             scanned_argv_ids: scanned_argv_ids,
                                             comp_state: {},
                                             default_ctr: nil)
                else
                  seen_fps = Set.new
                  cands.each do |tb|
                    st_map = (states[tb] ||= {})
                    fp = st_map.map { |k, v| [k == tb ? :__primary__ : k, v[:cmd], v[:args]] }
                               .sort_by { |e| [e[0].is_a?(Symbol) ? 0 : 1, e[0].to_s] }
                    if seen_fps.add?(fp)
                      scan_component_for_secrets(oc, target, "override(#{pname}) ", hits,
                                                 scanned_argv_ids: scanned_argv_ids,
                                                 comp_state: st_map,
                                                 default_ctr: tb)
                    else
                      apply_component_cmd_state_only!(oc, st_map, default_ctr: tb)
                    end
                  end
                end
              end
            end
          end
        end

        all_pol_entries = safe_array(spec["policies"]).each_with_index.to_a
        run_override_sequence.call(all_pol_entries, clone_comp_cmd_states(base_comp_states))

        wf_steps = safe_dig(spec, "workflow", "steps")
        if wf_steps.is_a?(Array) && !all_pol_entries.empty?
          override_by_name = {}
          default_override_names = []
          all_pol_entries.each do |pol, idx|
            next unless pol.is_a?(Hash) && pol["type"] == "override"

            pn = non_empty_str(pol["name"])
            if pn
              override_by_name[pn] ||= [pol, idx]
              default_override_names << pn
            end
          end
          unless override_by_name.empty?
            raw_deploy_seqs = []
            collect_deploy_policy_sequences(wf_steps, raw_deploy_seqs)
            seen_seqs = Set.new([default_override_names])
            extra_runs = 0
            raw_deploy_seqs.each do |pnames|
              break if extra_runs >= 16

              ov_names = pnames.select { |pn| override_by_name.key?(pn) }
              next if ov_names.empty? || !seen_seqs.add?(ov_names)

              extra_runs += 1
              seq = ov_names.map { |pn| override_by_name[pn] }
              run_override_sequence.call(seq, clone_comp_cmd_states(base_comp_states))
            end
          end
        end

        scan_arbitrary_tree(spec, target, "spec", hits, skip_dotenv_obj_ids: scanned_argv_ids)
      end
      extra_app = r.reject { |k, _| %w[apiVersion kind metadata spec].include?(k) }
      scan_arbitrary_tree(extra_app, target, "", hits) unless extra_app.empty?
    else
      rest = r.reject { |k, _| %w[apiVersion kind metadata].include?(k) }
      scan_arbitrary_tree(rest, target, "", hits) unless rest.empty?
    end
  end
  $gateway_secret_refs.each do |sn|
    sr = (secret_value_rules(sn) + dotenv_secret_rules(sn)).uniq
    hits << ["gateway", "secretName（伏字）", sr] unless sr.empty?
  end
  $gateway_existing_services.each do |svc_name, _|
    sr = (secret_value_rules(svc_name) + dotenv_secret_rules(svc_name)).uniq
    hits << ["gateway", "existingServiceName（伏字）", sr] unless sr.empty?
  end
  hits.uniq
end

# ---------------------------------------------------------------------------
# 所有関係・Kyverno 判定・構造検証
# ---------------------------------------------------------------------------

def kyverno_managed?(meta)
  return false unless meta.is_a?(Hash)

  labels = meta["labels"]
  if labels.is_a?(Hash)
    return true if labels["app.kubernetes.io/managed-by"] == "kyverno"
    return true if labels.key?("generate.kyverno.io/policy-name")
    return true if labels.keys.any? { |k| k.to_s.start_with?("generate.kyverno.io/") }
  end

  annos = meta["annotations"]
  annos.is_a?(Hash) && annos.keys.any? { |k| k.to_s.start_with?("generate.kyverno.io/") }
end

# KubeVela v1.11.2 は ownerReferences ではなく OAM ラベルとクラスタスコープの ResourceTracker で
# 生成リソースを管理する。非 Application リソースが OAM ラベルを持つ場合、Application から再生成
# されるため base/resources.yaml に重複出力してはならない（MustBeControlledByApp 衝突防止）。
def vela_managed?(meta)
  return false unless meta.is_a?(Hash)

  labels = meta["labels"]
  if labels.is_a?(Hash)
    return true if non_empty_str(labels["app.oam.dev/name"]) && non_empty_str(labels["app.oam.dev/namespace"])
    return true if labels.key?("app.oam.dev/appRevision")
    return true if labels.key?("app.oam.dev/resourceType")
  end

  annos = meta["annotations"]
  annos.is_a?(Hash) && annos.key?("app.oam.dev/last-applied-configuration")
end

def check_configmap_shape!(name, data, binary_data)
  safe_name = redact_secret_label(name)
  unless data.nil?
    abort "ConfigMap/#{safe_name} の data がマッピングではありません" unless data.is_a?(Hash)
    abort "ConfigMap/#{safe_name} の data に文字列ではない値があります" unless data.values.all? { |v| v.is_a?(String) }
  end
  return if binary_data.nil?

  abort "ConfigMap/#{safe_name} の binaryData がマッピングではありません" unless binary_data.is_a?(Hash)
  abort "ConfigMap/#{safe_name} の binaryData に文字列ではない値があります" unless binary_data.values.all? { |v| v.is_a?(String) }
end

def check_env_array_shape!(label, env)
  return if env.nil?

  abort "#{label} の env が配列ではありません" unless env.is_a?(Array)
  env.each do |e|
    abort "#{label} の env にマッピングではない要素があります" unless e.is_a?(Hash)
    abort "#{label} の env の name が文字列ではありません" unless e["name"].is_a?(String)
    abort "#{label} の env の value が文字列ではありません" unless e["value"].nil? || e["value"].is_a?(String)
  end
end

def check_argv_shape!(label, field, val)
  return if val.nil?

  abort "#{label} の #{field} が配列ではありません" unless val.is_a?(Array)
  abort "#{label} の #{field} に文字列ではない要素があります" unless val.all? { |v| v.is_a?(String) }
end

def check_probe_shape!(label, probe)
  return if probe.nil?

  abort "#{label} がマッピングではありません" unless probe.is_a?(Hash)
  reject_case_variant_keys!(probe, %w[exec httpGet containerName], label)
  unless probe["containerName"].nil? || probe["containerName"].is_a?(String)
    abort "#{label} の containerName が文字列ではありません"
  end
  unless probe["exec"].nil?
    abort "#{label} の exec がマッピングではありません" unless probe["exec"].is_a?(Hash)
    reject_case_variant_keys!(probe["exec"], %w[command], "#{label}.exec")
    check_argv_shape!("#{label}.exec", "command", probe["exec"]["command"])
  end
  return if probe["httpGet"].nil?

  abort "#{label} の httpGet がマッピングではありません" unless probe["httpGet"].is_a?(Hash)
  reject_case_variant_keys!(probe["httpGet"], %w[httpHeaders path port host scheme], "#{label}.httpGet")
  headers = probe["httpGet"]["httpHeaders"]
  return if headers.nil?

  abort "#{label} の httpGet.httpHeaders が配列ではありません" unless headers.is_a?(Array)
  headers.each do |h|
    abort "#{label} の httpGet.httpHeaders 要素がマッピングではありません" unless h.is_a?(Hash)
    reject_case_variant_keys!(h, %w[name value], "#{label}.httpGet.httpHeaders")
    abort "#{label} の httpGet.httpHeaders[].name が文字列ではありません" unless h["name"].is_a?(String)
    abort "#{label} の httpGet.httpHeaders[].value が文字列ではありません" unless h["value"].nil? || h["value"].is_a?(String)
  end
end

DISALLOWED_COMP_INPUT_PREFIXES = [
  ".", '"', "'", "[", "traits", "value", "namespace", "cluster", "type", "externalrevision", "privileges"
].freeze
# M2 vela-application-guard (VAP:601) の `pk.matches('^[a-z0-9_\\[\\].-]+$')` と 1:1 完全一致（\A...\z 必須）
SAFE_COMP_INPUT_PK_RE = /\A[a-z0-9_\[\].-]+\z/

INPUT_FORBIDDEN_WORKFLOW_STEP_TYPES = %w[
  deploy apply-component apply-application clean-jobs step-group
].freeze

# M2 ValidatingAdmissionPolicy (vela-application-guard:645,678,723,734,759,769,833,852,868,918,937,953)
# と 1:1 完全一致する 12 箇所（8 スキーマ）の厳格正規キー許可リスト
SERVICE_ACCOUNT_ALLOWED_KEYS = %w[name create privileges].freeze
TOPOLOGY_ALLOWED_KEYS = %w[clusters clusterLabelSelector allowEmpty clusterSelector namespace].freeze
OVERRIDE_PROPERTIES_ALLOWED_KEYS = %w[components selector].freeze
OVERRIDE_COMPONENT_ALLOWED_KEYS = %w[name type properties traits externalRevision inputs].freeze
OVERRIDE_TRAIT_ALLOWED_KEYS = %w[type properties disable].freeze
APPLY_COMPONENT_ALLOWED_KEYS = %w[component cluster namespace].freeze
CLEAN_JOBS_ALLOWED_KEYS = %w[labelselector namespace].freeze
DEPLOY_STEP_ALLOWED_KEYS = %w[auto policies parallelism ignoreTerraformComponent inlinePolicies].freeze

def enforce_allowed_keys!(hash, allowed_keys, context_label)
  return unless hash.is_a?(Hash)

  hash.each_key do |k|
    unless k.is_a?(String) && allowed_keys.include?(k)
      abort "#{context_label} に許可されていないキー (#{redact_inspect(k)}; 許可キー: #{allowed_keys.join(', ')}) は指定できません"
    end
  end
end

# Go encoding/json.Unmarshal (strings.EqualFold: ASCII + Unicode U+017F ſ / U+212A K 等) による
# 大文字小文字・Unicode ケースフォールディング回避キーを拒否する（Ruby 3.1/3.4 共通の :fold を使用）。
def reject_case_variant_keys!(hash, canonical_keys, context_label)
  return unless hash.is_a?(Hash)

  lower_map = canonical_keys.each_with_object({}) { |ck, m| m[ck.downcase(:fold)] = ck }
  hash.each_key do |k|
    ks = k.is_a?(String) ? k : (k.is_a?(Symbol) ? k.to_s : nil)
    next unless ks

    folded = (ks.encoding == Encoding::UTF_8 && ks.valid_encoding? ? ks : normalize_utf8(ks)).downcase(:fold)
    canonical = lower_map[folded]
    if canonical && k != canonical
      abort "#{context_label} に大文字小文字回避キー (#{redact_inspect(k)}; 正規キー: #{canonical.inspect}) は指定できません"
    end
  end
end

def check_component_inputs!(app_name, comp_label, inputs, allow_safe_inputs:)
  return if inputs.nil?

  abort "Application/#{app_name} #{comp_label} の inputs が配列ではありません" unless inputs.is_a?(Array)
  unless allow_safe_inputs
    abort "Application/#{app_name} #{comp_label} で inputs は使用できません" unless inputs.empty?
    return
  end

  inputs.each do |inp|
    abort "Application/#{app_name} #{comp_label} の inputs 要素がマッピングではありません" unless inp.is_a?(Hash)
    reject_case_variant_keys!(inp, %w[parameterKey from], "Application/#{app_name} #{comp_label} の inputs")
    raw_pk = inp["parameterKey"]
    abort "Application/#{app_name} #{comp_label} の inputs[].parameterKey が文字列ではありません" unless raw_pk.is_a?(String)

    # IMPORTANT: VAP:599 の .trim().lowerAscii() と 1:1 一致させるため .tr("A-Z", "a-z") を維持する
    # （.downcase(:fold) を使うと \u212A が k に畳まれて SAFE_COMP_INPUT_PK_RE をすり抜けるため不可）
    pk = raw_pk.gsub(/\A[[:space:]]+|(?<![[:space:]])[[:space:]]+\z/, "").tr("A-Z", "a-z")
    if pk.empty? ||
       !pk.match?(SAFE_COMP_INPUT_PK_RE) ||
       DISALLOWED_COMP_INPUT_PREFIXES.any? { |pre| pk.start_with?(pre) } ||
       pk.include?("traits") ||
       pk.include?("privileges")
      abort "Application/#{app_name} #{comp_label} の inputs[].parameterKey に許可されないパスが指定されています: #{redact_inspect(raw_pk)}"
    end
  end
end

def check_trait_security_and_shape!(app_name, comp_label, trait, allow_ingress:, is_override: false)
  abort "Application/#{app_name} #{comp_label} の trait がマッピングではありません" unless trait.is_a?(Hash)
  if is_override
    enforce_allowed_keys!(trait, OVERRIDE_TRAIT_ALLOWED_KEYS, "Application/#{app_name} #{comp_label} の trait")
  else
    reject_case_variant_keys!(trait, %w[type properties], "Application/#{app_name} #{comp_label} の trait")
  end
  ttype = non_empty_str(trait["type"])
  abort "Application/#{app_name} #{comp_label} に type の無い trait があります" unless ttype

  allowed = allow_ingress ? (ALLOWED_TRAIT_TYPES + INGRESS_TRAIT_TYPES) : ALLOWED_TRAIT_TYPES
  unless allowed.include?(ttype)
    abort "Application/#{app_name} #{comp_label} に許可されていない trait type が含まれています: #{redact_secret_label(ttype)}"
  end

  tprops = trait["properties"]
  abort "Application/#{app_name} #{comp_label} の trait #{ttype} の properties がマッピングではありません" if !tprops.nil? && !tprops.is_a?(Hash)
  return unless tprops.is_a?(Hash)

  case ttype
  when "service-account"
    enforce_allowed_keys!(tprops, SERVICE_ACCOUNT_ALLOWED_KEYS, "Application/#{app_name} #{comp_label} の service-account trait")
    privs = tprops["privileges"]
    if !privs.nil? && (!privs.is_a?(Array) || !privs.empty?)
      abort "Application/#{app_name} #{comp_label} の service-account trait に privileges は指定できません（RBAC 自動生成禁止）"
    end
  when "storage"
    reject_case_variant_keys!(tprops, %w[hostPath pvc secret configMap emptyDir], "Application/#{app_name} #{comp_label} の storage trait")
    hp = tprops["hostPath"]
    if !hp.nil? && (!hp.is_a?(Array) || !hp.empty?)
      abort "Application/#{app_name} #{comp_label} の storage trait に hostPath は指定できません"
    end
    abort "Application/#{app_name} #{comp_label} の storage.secret が配列ではありません" if !tprops["secret"].nil? && !tprops["secret"].is_a?(Array)
    abort "Application/#{app_name} #{comp_label} の storage.configMap が配列ではありません" if !tprops["configMap"].nil? && !tprops["configMap"].is_a?(Array)
    abort "Application/#{app_name} #{comp_label} の storage.pvc が配列ではありません" if !tprops["pvc"].nil? && !tprops["pvc"].is_a?(Array)
    safe_array(tprops["secret"]).each do |s|
      abort "Application/#{app_name} #{comp_label} の storage.secret 要素がマッピングではありません" unless s.is_a?(Hash)
      reject_case_variant_keys!(s, %w[data stringData mountOnly name], "Application/#{app_name} #{comp_label} の storage.secret")
    end
    safe_array(tprops["pvc"]).each do |pvc|
      abort "Application/#{app_name} #{comp_label} の storage.pvc 要素がマッピングではありません" unless pvc.is_a?(Hash)
      reject_case_variant_keys!(pvc, %w[volumeName dataSource dataSourceRef selector storageClassName accessModes mountOnly],
                                "Application/#{app_name} #{comp_label} の storage.pvc")
      if !pvc["storageClassName"].nil? && !pvc["storageClassName"].is_a?(String)
        abort "Application/#{app_name} #{comp_label} の storage.pvc の storageClassName が文字列ではありません"
      end
    end
    safe_array(tprops["configMap"]).each do |cm|
      abort "Application/#{app_name} #{comp_label} の storage.configMap 要素がマッピングではありません" unless cm.is_a?(Hash)
      reject_case_variant_keys!(cm, %w[data mountOnly name], "Application/#{app_name} #{comp_label} の storage.configMap")
      next if cm["data"].nil?

      abort "Application/#{app_name} #{comp_label} の storage.configMap の data がマッピングではありません" unless cm["data"].is_a?(Hash)
      unless cm["data"].values.all? { |v| v.is_a?(String) }
        abort "Application/#{app_name} #{comp_label} の storage.configMap の data に文字列ではない値があります"
      end
    end
  when "volumes"
    reject_case_variant_keys!(tprops, %w[volumes hostPath], "Application/#{app_name} #{comp_label} の volumes trait")
    hp = tprops["hostPath"]
    if !hp.nil? && (!hp.is_a?(Array) || !hp.empty?)
      abort "Application/#{app_name} #{comp_label} の volumes trait に hostPath は指定できません"
    end
    unless tprops["volumes"].nil?
      abort "Application/#{app_name} #{comp_label} の volumes trait の volumes が配列ではありません" unless tprops["volumes"].is_a?(Array)
      tprops["volumes"].each do |v|
        abort "Application/#{app_name} #{comp_label} の volumes trait の volumes 要素がマッピングではありません" unless v.is_a?(Hash)
        reject_case_variant_keys!(v, %w[type claimName secretName cmName hostPath], "Application/#{app_name} #{comp_label} の volumes trait")
        if (v["type"].is_a?(String) && normalize_utf8(v["type"]).downcase(:fold) == "hostpath") || !v["hostPath"].nil?
          abort "Application/#{app_name} #{comp_label} の volumes trait で hostPath は禁止されています"
        end
      end
    end
  when "pvc"
    reject_case_variant_keys!(tprops, %w[volumeName dataSource dataSourceRef selector storageClassName accessModes claimName],
                              "Application/#{app_name} #{comp_label} の pvc trait")
    if !tprops["storageClassName"].nil? && !tprops["storageClassName"].is_a?(String)
      abort "Application/#{app_name} #{comp_label} の pvc trait の storageClassName が文字列ではありません"
    end
  when "securitycontext"
    reject_case_variant_keys!(tprops,
                              %w[containers privileged allowPrivilegeEscalation addCapabilities dropCapabilities procMount seccompProfile appArmorProfile seLinuxOptions],
                              "Application/#{app_name} #{comp_label} の securitycontext trait")
    if tprops.key?("containers") && !tprops["containers"].nil?
      abort "Application/#{app_name} #{comp_label} の securitycontext trait の containers が配列ではありません" unless tprops["containers"].is_a?(Array)
      tprops["containers"].each do |c|
        abort "Application/#{app_name} #{comp_label} の securitycontext trait の containers 要素がマッピングではありません" unless c.is_a?(Hash)
        reject_case_variant_keys!(c,
                                  %w[privileged allowPrivilegeEscalation addCapabilities dropCapabilities procMount seccompProfile appArmorProfile seLinuxOptions],
                                  "Application/#{app_name} #{comp_label} の securitycontext trait の containers")
      end
    end
    entries = [tprops] + safe_array(tprops["containers"])
    entries.each do |sc|
      next unless sc.is_a?(Hash)

      if !sc["privileged"].nil? && sc["privileged"] != false
        abort "Application/#{app_name} #{comp_label} の securitycontext trait で privileged は false 以外指定できません"
      end
      if !sc["allowPrivilegeEscalation"].nil? && sc["allowPrivilegeEscalation"] != false
        abort "Application/#{app_name} #{comp_label} の securitycontext trait で allowPrivilegeEscalation は false 以外指定できません"
      end
      next unless sc.key?("addCapabilities") && !sc["addCapabilities"].nil?

      caps = sc["addCapabilities"]
      unless caps.is_a?(Array) && caps.all? { |cap| cap.is_a?(String) }
        abort "Application/#{app_name} #{comp_label} の securitycontext trait の addCapabilities は文字列配列である必要があります"
      end
      bad_caps = caps.reject { |cap| ALLOWED_BASELINE_CAPABILITIES.include?(cap.upcase) }
      unless bad_caps.empty?
        abort "Application/#{app_name} #{comp_label} の securitycontext trait に許可されていない Linux capability が含まれています: #{bad_caps.map { |cap| redact_secret_label(cap) }.join(', ')}"
      end
    end
  when "podsecuritycontext"
    reject_case_variant_keys!(tprops, %w[seccompProfile appArmorProfile seLinuxOptions sysctls],
                              "Application/#{app_name} #{comp_label} の podsecuritycontext trait")
    %w[seccompProfile appArmorProfile].each do |prof_key|
      next unless tprops.key?(prof_key) && !tprops[prof_key].nil?

      prof = tprops[prof_key]
      unless prof.is_a?(Hash)
        abort "Application/#{app_name} #{comp_label} の podsecuritycontext trait の #{prof_key} がマッピングではありません"
      end
      reject_case_variant_keys!(prof, %w[type localhostProfile], "Application/#{app_name} #{comp_label} の podsecuritycontext trait の #{prof_key}")
      ptype = prof["type"]
      next if ptype.nil?
      unless ptype.is_a?(String) && %w[RuntimeDefault Localhost].include?(ptype)
        abort "Application/#{app_name} #{comp_label} の podsecuritycontext trait で #{prof_key}.type=#{redact_inspect(ptype)} は禁止されています（RuntimeDefault / Localhost のみ許可）"
      end
    end
  when "sidecar"
    reject_case_variant_keys!(tprops, %w[env cmd args ports livenessProbe readinessProbe securityContext],
                              "Application/#{app_name} #{comp_label} の sidecar trait")
    check_env_array_shape!("Application/#{app_name} #{comp_label} sidecar", tprops["env"])
    check_argv_shape!("Application/#{app_name} #{comp_label} sidecar", "cmd", tprops["cmd"])
    check_argv_shape!("Application/#{app_name} #{comp_label} sidecar", "args", tprops["args"])
    check_probe_shape!("Application/#{app_name} #{comp_label} sidecar livenessProbe", tprops["livenessProbe"])
    check_probe_shape!("Application/#{app_name} #{comp_label} sidecar readinessProbe", tprops["readinessProbe"])
    if tprops.key?("ports") && !tprops["ports"].nil?
      abort "Application/#{app_name} #{comp_label} の sidecar trait の ports が配列ではありません" unless tprops["ports"].is_a?(Array)
      tprops["ports"].each do |p|
        abort "Application/#{app_name} #{comp_label} の sidecar trait の ports 要素がマッピングではありません" unless p.is_a?(Hash)
        reject_case_variant_keys!(p, %w[hostPort containerPort protocol name], "Application/#{app_name} #{comp_label} の sidecar trait の ports")
        if !p["hostPort"].nil?
          abort "Application/#{app_name} #{comp_label} の sidecar trait で hostPort は禁止されています"
        end
      end
    end
  when "init-container"
    reject_case_variant_keys!(tprops, %w[env cmd args livenessProbe readinessProbe securityContext], "Application/#{app_name} #{comp_label} の init-container trait")
    check_env_array_shape!("Application/#{app_name} #{comp_label} init-container", tprops["env"])
    check_argv_shape!("Application/#{app_name} #{comp_label} init-container", "cmd", tprops["cmd"])
    check_argv_shape!("Application/#{app_name} #{comp_label} init-container", "args", tprops["args"])
    check_probe_shape!("Application/#{app_name} #{comp_label} init-container livenessProbe", tprops["livenessProbe"])
    check_probe_shape!("Application/#{app_name} #{comp_label} init-container readinessProbe", tprops["readinessProbe"])
  when "expose"
    reject_case_variant_keys!(tprops, %w[type ports port externalIPs], "Application/#{app_name} #{comp_label} の expose trait")
    ext_ips = tprops["externalIPs"]
    if !ext_ips.nil? && (!ext_ips.is_a?(Array) || !ext_ips.empty?)
      abort "Application/#{app_name} #{comp_label} の expose trait で externalIPs は禁止されています"
    end
    safe_array(tprops["ports"]).each do |p|
      reject_case_variant_keys!(p, %w[port nodePort protocol name], "Application/#{app_name} #{comp_label} の expose trait の ports") if p.is_a?(Hash)
    end
  when "env"
    reject_case_variant_keys!(tprops, %w[env containers containerName], "Application/#{app_name} #{comp_label} の env trait")
    unless tprops["containerName"].nil? || tprops["containerName"].is_a?(String)
      abort "Application/#{app_name} #{comp_label} の env trait の containerName が文字列ではありません"
    end
    unless tprops["env"].nil?
      abort "Application/#{app_name} #{comp_label} の env trait の env がマッピングではありません" unless tprops["env"].is_a?(Hash)
      unless tprops["env"].values.all? { |v| v.is_a?(String) }
        abort "Application/#{app_name} #{comp_label} の env trait の env に文字列ではない値があります"
      end
    end
    abort "Application/#{app_name} #{comp_label} の env trait の containers が配列ではありません" if !tprops["containers"].nil? && !tprops["containers"].is_a?(Array)
    safe_array(tprops["containers"]).each do |c|
      abort "Application/#{app_name} #{comp_label} の env trait の containers 要素が不正です" unless c.is_a?(Hash) && (c["env"].nil? || c["env"].is_a?(Hash))
      reject_case_variant_keys!(c, %w[env containerName], "Application/#{app_name} #{comp_label} の env trait の containers")
      unless c["containerName"].nil? || c["containerName"].is_a?(String)
        abort "Application/#{app_name} #{comp_label} の env trait の containers[].containerName が文字列ではありません"
      end
      if c["env"].is_a?(Hash) && !c["env"].values.all? { |v| v.is_a?(String) }
        abort "Application/#{app_name} #{comp_label} の env trait の containers[].env に文字列ではない値があります"
      end
    end
  when "command"
    reject_case_variant_keys!(tprops, %w[command args addArgs delArgs containers containerName], "Application/#{app_name} #{comp_label} の command trait")
    unless tprops["containerName"].nil? || tprops["containerName"].is_a?(String)
      abort "Application/#{app_name} #{comp_label} の command trait の containerName が文字列ではありません"
    end
    %w[command args addArgs delArgs].each { |f| check_argv_shape!("Application/#{app_name} #{comp_label} command", f, tprops[f]) }
    abort "Application/#{app_name} #{comp_label} の command trait の containers が配列ではありません" if !tprops["containers"].nil? && !tprops["containers"].is_a?(Array)
    safe_array(tprops["containers"]).each do |c|
      abort "Application/#{app_name} #{comp_label} の command trait の containers 要素が不正です" unless c.is_a?(Hash)
      reject_case_variant_keys!(c, %w[command args addArgs delArgs containerName], "Application/#{app_name} #{comp_label} の command trait の containers")
      unless c["containerName"].nil? || c["containerName"].is_a?(String)
        abort "Application/#{app_name} #{comp_label} の command trait の containers[].containerName が文字列ではありません"
      end
      %w[command args addArgs delArgs].each { |f| check_argv_shape!("Application/#{app_name} #{comp_label} command", f, c[f]) }
    end
  when "startup-probe"
    reject_case_variant_keys!(tprops, %w[probes], "Application/#{app_name} #{comp_label} の startup-probe trait")
    check_probe_shape!("Application/#{app_name} #{comp_label} startup-probe", tprops)
    unless tprops["probes"].nil?
      abort "Application/#{app_name} #{comp_label} の startup-probe trait の probes が配列ではありません" unless tprops["probes"].is_a?(Array)
      tprops["probes"].each_with_index do |pr, idx|
        check_probe_shape!("Application/#{app_name} #{comp_label} startup-probe[#{idx}]", pr)
      end
    end
  when "lifecycle"
    reject_case_variant_keys!(tprops, %w[postStart preStop], "Application/#{app_name} #{comp_label} の lifecycle trait")
    check_probe_shape!("Application/#{app_name} #{comp_label} lifecycle.postStart", tprops["postStart"])
    check_probe_shape!("Application/#{app_name} #{comp_label} lifecycle.preStop", tprops["preStop"])
  when *INGRESS_TRAIT_TYPES
    reject_case_variant_keys!(tprops, %w[domain http secretName existingServiceName], "Application/#{app_name} #{comp_label} の #{ttype} trait")
  end
end

def check_component_security_and_shape!(app_name, comp, require_name:, require_type:, allow_ingress:, allow_safe_inputs: require_name, is_override: !require_name)
  abort "Application/#{app_name} の component がマッピングではありません" unless comp.is_a?(Hash)
  cname = non_empty_str(comp["name"])
  comp_label = cname ? "component/#{redact_secret_label(cname)}" : "component"
  if is_override
    enforce_allowed_keys!(comp, OVERRIDE_COMPONENT_ALLOWED_KEYS, "Application/#{app_name} #{comp_label}")
  else
    reject_case_variant_keys!(comp, %w[name type externalRevision properties traits inputs outputs dependsOn scopes], "Application/#{app_name} #{comp_label}")
  end
  ctype = non_empty_str(comp["type"])
  if require_name
    abort "Application/#{app_name} の component.name が DNS-1123 ラベル形式ではありません: #{redact_inspect(comp['name'])}" unless cname && cname.match?(DNS_LABEL_RE)
  elsif !comp["name"].nil? && !comp["name"].is_a?(String)
    abort "Application/#{app_name} の override component.name が文字列ではありません"
  end
  if require_type || (!comp["type"].nil? && comp["type"] != "")
    unless ctype && ALLOWED_COMPONENT_TYPES.include?(ctype)
      abort "Application/#{app_name} に許可されていない component type が含まれています: #{redact_inspect(comp['type'])}"
    end
  end

  check_component_inputs!(app_name, comp_label, comp["inputs"], allow_safe_inputs: allow_safe_inputs)

  props = comp["properties"]
  abort "Application/#{app_name} #{comp_label} の properties がマッピングではありません" if !props.nil? && !props.is_a?(Hash)
  if props.is_a?(Hash)
    reject_case_variant_keys!(props,
                              %w[volumeMounts volumes exposeType ports port env cmd args livenessProbe readinessProbe imagePullSecrets],
                              "Application/#{app_name} #{comp_label} の properties")
    check_env_array_shape!("Application/#{app_name} #{comp_label}", props["env"])
    check_argv_shape!("Application/#{app_name} #{comp_label}", "cmd", props["cmd"])
    check_argv_shape!("Application/#{app_name} #{comp_label}", "args", props["args"])
    check_probe_shape!("Application/#{app_name} #{comp_label} livenessProbe", props["livenessProbe"])
    check_probe_shape!("Application/#{app_name} #{comp_label} readinessProbe", props["readinessProbe"])
    if props["exposeType"].is_a?(String) && normalize_utf8(props["exposeType"]).downcase(:fold) == "externalname"
      abort "Application/#{app_name} #{comp_label} の exposeType に ExternalName は指定できません"
    end
    safe_array(props["ports"]).each do |p|
      reject_case_variant_keys!(p, %w[port containerPort name protocol expose nodePort], "Application/#{app_name} #{comp_label} の properties.ports") if p.is_a?(Hash)
    end
    vm = props["volumeMounts"]
    abort "Application/#{app_name} #{comp_label} の volumeMounts がマッピングではありません" if !vm.nil? && !vm.is_a?(Hash)
    if vm.is_a?(Hash)
      reject_case_variant_keys!(vm, %w[hostPath pvc secret configMap emptyDir], "Application/#{app_name} #{comp_label} の volumeMounts")
      hp = vm["hostPath"]
      if !hp.nil? && (!hp.is_a?(Array) || !hp.empty?)
        abort "Application/#{app_name} #{comp_label} の volumeMounts.hostPath は禁止されています"
      end
    end
    unless props["volumes"].nil?
      abort "Application/#{app_name} #{comp_label} の properties.volumes が配列ではありません" unless props["volumes"].is_a?(Array)
      props["volumes"].each do |v|
        abort "Application/#{app_name} #{comp_label} の properties.volumes 要素がマッピングではありません" unless v.is_a?(Hash)
        reject_case_variant_keys!(v, %w[type claimName secretName cmName hostPath], "Application/#{app_name} #{comp_label} の properties.volumes")
        if (v["type"].is_a?(String) && normalize_utf8(v["type"]).downcase(:fold) == "hostpath") || !v["hostPath"].nil?
          abort "Application/#{app_name} #{comp_label} の properties.volumes で hostPath は禁止されています"
        end
      end
    end
  end

  traits = comp["traits"]
  abort "Application/#{app_name} #{comp_label} の traits が配列ではありません" if !traits.nil? && !traits.is_a?(Array)
  safe_array(traits).each do |t|
    check_trait_security_and_shape!(app_name, comp_label, t, allow_ingress: allow_ingress, is_override: is_override)
  end
end

def expected_source_namespace
  SOURCE_NAMESPACE.empty? ? "dev-#{APP}" : SOURCE_NAMESPACE
end

def check_topology_properties!(app_name, pprops)
  enforce_allowed_keys!(pprops, TOPOLOGY_ALLOWED_KEYS, "Application/#{app_name} の topology policy")

  clusters = pprops["clusters"]
  unless clusters.nil?
    abort "Application/#{app_name} の topology policy の clusters が配列ではありません" unless clusters.is_a?(Array)
    bad_clusters = clusters.reject { |cl| cl == "local" }
    unless bad_clusters.empty?
      abort "Application/#{app_name} の topology policy に local 以外のクラスタが含まれています: #{bad_clusters.map { |cl| redact_inspect(cl) }.join(', ')}"
    end
  end

  %w[clusterLabelSelector clusterSelector].each do |sel_key|
    val = pprops[sel_key]
    next if val.nil?
    unless val.is_a?(Hash) && val.empty?
      abort "Application/#{app_name} の topology policy で #{sel_key} は使用できません"
    end
  end

  return unless pprops.key?("namespace") && !pprops["namespace"].nil?

  unless pprops["namespace"].is_a?(String)
    abort "Application/#{app_name} の topology policy の namespace が文字列ではありません"
  end
  target_ns = pprops["namespace"]
  if !target_ns.empty? && target_ns != expected_source_namespace
    abort "Application/#{app_name} の topology policy が別 Namespace (#{redact_secret_label(target_ns)}) を指定しているため昇格できません"
  end
end

def check_workflow_steps_shape!(app_name, steps, depth = 0)
  abort "Application/#{app_name} の workflow.steps が配列ではありません" unless steps.is_a?(Array)

  steps.each do |st|
    abort "Application/#{app_name} の workflow step がマッピングではありません" unless st.is_a?(Hash)
    reject_case_variant_keys!(st, %w[name type properties inputs outputs subSteps], "Application/#{app_name} の workflow step")
    stype = non_empty_str(st["type"])
    unless stype && ALLOWED_WORKFLOW_STEP_TYPES.include?(stype)
      abort "Application/#{app_name} に許可されていない workflow step type が含まれています: #{redact_inspect(st['type'])}"
    end
    if depth >= 1 && stype == "step-group"
      abort "Application/#{app_name} の workflow subSteps 内で step-group は使用できません"
    end
    unless st["inputs"].nil?
      abort "Application/#{app_name} の workflow step #{stype} の inputs が配列ではありません" unless st["inputs"].is_a?(Array)
      if INPUT_FORBIDDEN_WORKFLOW_STEP_TYPES.include?(stype) && !st["inputs"].empty?
        abort "Application/#{app_name} の workflow step #{stype} で inputs は使用できません"
      end
    end

    sprops = st["properties"]
    abort "Application/#{app_name} の workflow step #{stype} の properties がマッピングではありません" if !sprops.nil? && !sprops.is_a?(Hash)
    if sprops.is_a?(Hash)
      case stype
      when "apply-component"
        enforce_allowed_keys!(sprops, APPLY_COMPONENT_ALLOWED_KEYS, "Application/#{app_name} の workflow step apply-component")
        if sprops.key?("namespace") && !sprops["namespace"].nil?
          unless sprops["namespace"].is_a?(String)
            abort "Application/#{app_name} の workflow step apply-component の namespace が文字列ではありません"
          end
          target_ns = sprops["namespace"]
          if !target_ns.empty? && target_ns != expected_source_namespace
            abort "Application/#{app_name} の workflow step apply-component が別 Namespace (#{redact_secret_label(target_ns)}) を指定しているため昇格できません"
          end
        end
        if sprops.key?("cluster") && !sprops["cluster"].nil?
          unless sprops["cluster"].is_a?(String)
            abort "Application/#{app_name} の workflow step apply-component の cluster が文字列ではありません"
          end
          unless sprops["cluster"].empty? || sprops["cluster"] == "local"
            abort "Application/#{app_name} の workflow step apply-component に local 以外の cluster (#{redact_secret_label(sprops['cluster'])}) は指定できません"
          end
        end
      when "clean-jobs"
        enforce_allowed_keys!(sprops, CLEAN_JOBS_ALLOWED_KEYS, "Application/#{app_name} の workflow step clean-jobs")
        if sprops.key?("namespace") && !sprops["namespace"].nil?
          unless sprops["namespace"].is_a?(String)
            abort "Application/#{app_name} の workflow step clean-jobs の namespace が文字列ではありません"
          end
          target_ns = sprops["namespace"]
          if !target_ns.empty? && target_ns != expected_source_namespace
            abort "Application/#{app_name} の workflow step clean-jobs が別 Namespace (#{redact_secret_label(target_ns)}) を指定しているため昇格できません"
          end
        end
      when "deploy"
        enforce_allowed_keys!(sprops, DEPLOY_STEP_ALLOWED_KEYS, "Application/#{app_name} の workflow step deploy")
        if sprops.key?("inlinePolicies") && !sprops["inlinePolicies"].nil?
          ip = sprops["inlinePolicies"]
          unless ip.is_a?(Array) && ip.empty?
            abort "Application/#{app_name} の workflow step deploy で inlinePolicies は使用できません"
          end
        end
        if sprops.key?("policies") && !sprops["policies"].nil?
          pols = sprops["policies"]
          unless pols.is_a?(Array) && pols.all? { |pn| pn.is_a?(String) }
            abort "Application/#{app_name} の workflow step deploy の policies は文字列配列である必要があります"
          end
        end
      end
    end

    next if st["subSteps"].nil?

    abort "Application/#{app_name} の workflow step #{stype} の subSteps が配列ではありません" unless st["subSteps"].is_a?(Array)
    if depth >= 1
      unless st["subSteps"].empty?
        abort "Application/#{app_name} の workflow subSteps をさらにネストすることはできません"
      end
    else
      check_workflow_steps_shape!(app_name, st["subSteps"], depth + 1)
    end
  end
end

def check_application_shape!(name, app)
  safe_app = redact_secret_label(name)
  unless app["apiVersion"] == "core.oam.dev/v1beta1"
    abort "Application/#{safe_app} の apiVersion が非対応です: #{redact_inspect(app['apiVersion'])}"
  end

  spec = app["spec"]
  abort "Application/#{safe_app} の spec がマッピングではありません" unless spec.is_a?(Hash)
  reject_case_variant_keys!(spec, %w[components policies workflow], "Application/#{safe_app} の spec")
  comps = spec["components"]
  abort "Application/#{safe_app} の spec.components が配列ではありません" unless comps.is_a?(Array)

  seen_comp_names = Set.new
  comps.each do |c|
    check_component_security_and_shape!(safe_app, c, require_name: true, require_type: true, allow_ingress: true, allow_safe_inputs: true)
    cname = c["name"]
    abort "Application/#{safe_app} 内でコンポーネント名が重複しています: #{redact_secret_label(cname)}" if seen_comp_names.include?(cname)
    seen_comp_names << cname
  end

  unless spec["policies"].nil?
    abort "Application/#{safe_app} の spec.policies が配列ではありません" unless spec["policies"].is_a?(Array)
    spec["policies"].each do |pol|
      abort "Application/#{safe_app} の policy がマッピングではありません" unless pol.is_a?(Hash)
      reject_case_variant_keys!(pol, %w[name type properties], "Application/#{safe_app} の policy")
      ptype = non_empty_str(pol["type"])
      unless ptype && ALLOWED_POLICY_TYPES.include?(ptype)
        abort "Application/#{safe_app} に許可されていない policy type が含まれています: #{redact_inspect(pol['type'])}"
      end
      pprops = pol["properties"]
      abort "Application/#{safe_app} の policy #{ptype} の properties がマッピングではありません" if !pprops.nil? && !pprops.is_a?(Hash)

      if ptype == "topology" && pprops.is_a?(Hash)
        check_topology_properties!(safe_app, pprops)
      elsif ptype == "override" && pprops.is_a?(Hash)
        enforce_allowed_keys!(pprops, OVERRIDE_PROPERTIES_ALLOWED_KEYS, "Application/#{safe_app} の override policy")
        if !pprops["selector"].nil? && !(pprops["selector"].is_a?(Array) && pprops["selector"].all? { |s| s.is_a?(String) })
          abort "Application/#{safe_app} の override policy の selector は文字列配列である必要があります"
        end
        abort "Application/#{safe_app} の override policy の components が配列ではありません" if !pprops["components"].nil? && !pprops["components"].is_a?(Array)
        safe_array(pprops["components"]).each do |oc|
          check_component_security_and_shape!(safe_app, oc, require_name: false, require_type: false, allow_ingress: false, allow_safe_inputs: false, is_override: true)
        end
      end
    end
  end

  return if spec["workflow"].nil?

  wf = spec["workflow"]
  abort "Application/#{safe_app} の spec.workflow がマッピングではありません" unless wf.is_a?(Hash)
  reject_case_variant_keys!(wf, %w[ref steps mode], "Application/#{safe_app} の spec.workflow")
  unless wf["ref"].nil? || (wf["ref"].is_a?(String) && wf["ref"].empty?)
    abort "Application/#{safe_app} の spec.workflow.ref は昇格できません: #{redact_inspect(wf['ref'])}"
  end
  check_workflow_steps_shape!(safe_app, wf["steps"]) unless wf["steps"].nil?
end

# ---------------------------------------------------------------------------
# サニタイズ処理（Application + 補助リソース）
# ---------------------------------------------------------------------------

def clean_annotations_hash!(container)
  return unless container.is_a?(Hash)

  if (anno = container["annotations"]).is_a?(Hash)
    anno.delete_if { |k, _| VELA_VOLATILE_ANNO.include?(k.to_s) || k.to_s.match?(VOLATILE_ANNO_PREFIX) }
    container.delete("annotations") if anno.empty?
  end
end

def clean_labels_hash!(container)
  return unless container.is_a?(Hash)

  if (labels = container["labels"]).is_a?(Hash)
    labels.delete_if { |k, _| VELA_VOLATILE_LABELS.include?(k.to_s) || k.to_s.match?(VELA_VOLATILE_LABEL_PREFIX) }
    container.delete("labels") if labels.empty?
  end
end

def sanitize_pvc_spec_hash!(pvc_hash, label_name)
  return unless pvc_hash.is_a?(Hash)

  if !pvc_hash["storageClassName"].nil? && !pvc_hash["storageClassName"].is_a?(String)
    abort "PVC #{redact_secret_label(label_name)} の storageClassName が文字列ではありません"
  end
  VOLATILE_PVC_FIELDS.each { |k| pvc_hash.delete(k) }
  return unless pvc_hash["storageClassName"] == "manual"

  pvc_hash.delete("storageClassName")
  $manual_pvcs << label_name
end

def sanitize_component_expose_and_traits!(comp, app_name, is_override: false)
  cname = non_empty_str(comp["name"]) || "(override)"
  props = comp["properties"]

  if props.is_a?(Hash)
    if %w[LoadBalancer NodePort].include?(props["exposeType"])
      $downgraded_services << [cname, props["exposeType"]]
      props["exposeType"] = "ClusterIP"
    end
    safe_array(props["ports"]).each { |p| p.delete("nodePort") if p.is_a?(Hash) }
  end

  return unless comp["traits"].is_a?(Array)

  gateway_ports = []
  needs_expose_synthesis = false
  kept_traits = []

  comp["traits"].each do |t|
    ttype = t["type"]
    tprops = t["properties"].is_a?(Hash) ? t["properties"] : {}

    if INGRESS_TRAIT_TYPES.include?(ttype)
      $dev_has_ingress = true
      domain = non_empty_str(tprops["domain"])
      $dev_ingress_hosts << domain if domain
      sec_name = non_empty_str(tprops["secretName"])
      $gateway_secret_refs << sec_name if sec_name

      http_ports = tprops["http"].is_a?(Hash) ? tprops["http"].values.filter_map { |v| valid_port_int(v) }.uniq.sort : []
      if ttype != "pure-ingress"
        existing_svc = non_empty_str(tprops["existingServiceName"])
        if existing_svc
          $gateway_existing_services << [existing_svc, http_ports]
          $gateway_preferred_ports[existing_svc].merge(http_ports)
        else
          needs_expose_synthesis = true
          gateway_ports.concat(http_ports)
          $gateway_preferred_ports[cname].merge(http_ports) unless is_override
        end
      elsif !is_override
        $gateway_preferred_ports[cname].merge(http_ports)
      end
      next
    end

    case ttype
    when "expose"
      if tprops["type"] == "ExternalName"
        $dropped_externalname_services << cname
        next
      elsif %w[LoadBalancer NodePort].include?(tprops["type"])
        $downgraded_services << [cname, tprops["type"]]
        tprops["type"] = "ClusterIP"
      end
      safe_array(tprops["ports"]).each { |p| p.delete("nodePort") if p.is_a?(Hash) }
    when "storage"
      safe_array(tprops["pvc"]).each_with_index do |pvc, idx|
        next unless pvc.is_a?(Hash)

        pname = non_empty_str(pvc["name"]) || "pvc[#{idx}]"
        sanitize_pvc_spec_hash!(pvc, "#{cname}/#{pname}")
      end
    when "pvc"
      pname = non_empty_str(tprops["claimName"]) || cname
      sanitize_pvc_spec_hash!(tprops, "#{cname}/#{pname}")
    when "labels"
      tprops.delete_if { |k, _| VELA_VOLATILE_LABELS.include?(k.to_s) || k.to_s.match?(VELA_VOLATILE_LABEL_PREFIX) }
      next if tprops.empty? && !(is_override && t["disable"] == true)
    when "annotations"
      tprops.delete_if { |k, _| VELA_VOLATILE_ANNO.include?(k.to_s) || k.to_s.match?(VOLATILE_ANNO_PREFIX) }
      next if tprops.empty? && !(is_override && t["disable"] == true)
    end

    kept_traits << t
  end

  if !is_override && needs_expose_synthesis
    target_ports = gateway_ports.uniq.sort
    if target_ports.empty? && props.is_a?(Hash)
      target_ports = safe_array(props["ports"]).filter_map do |p|
        next nil unless p.is_a?(Hash)

        proto = p["protocol"].to_s.upcase
        valid_port_int(p["port"]) if proto.empty? || proto == "TCP"
      end.uniq.sort
      if target_ports.empty? && (single_p = valid_port_int(props["port"]))
        target_ports = [single_p]
      end
    end

    exposed_tcp_ports = Set.new
    uses_webservice_expose = %w[webservice statefulset].include?(comp["type"]) &&
                             props.is_a?(Hash) &&
                             safe_array(props["ports"]).any? { |p| p.is_a?(Hash) && p["expose"] == true }
    if uses_webservice_expose
      safe_array(props["ports"]).each do |p|
        next unless p.is_a?(Hash) && p["expose"] == true

        proto = p["protocol"].to_s.upcase
        pnum = valid_port_int(p["port"])
        exposed_tcp_ports << pnum if pnum && (proto.empty? || proto == "TCP")
      end
    end

    expose_trait = kept_traits.find { |t| t["type"] == "expose" }
    if expose_trait && expose_trait["properties"].is_a?(Hash)
      etp = expose_trait["properties"]
      if etp["ports"].is_a?(Array) && !etp["ports"].empty?
        etp["ports"].each do |p|
          next unless p.is_a?(Hash)

          proto = p["protocol"].to_s.upcase
          pnum = valid_port_int(p["port"])
          exposed_tcp_ports << pnum if pnum && (proto.empty? || proto == "TCP")
        end
      elsif etp["port"].is_a?(Array)
        etp["port"].each do |p|
          pnum = valid_port_int(p)
          exposed_tcp_ports << pnum if pnum
        end
      end
    end

    missing_ports = target_ports.reject { |p| exposed_tcp_ports.include?(p) }
    unless missing_ports.empty?
      if uses_webservice_expose
        # webservice / statefulset が既に expose: true で Service/<comp> を描画しているため、
        # expose trait との Service 衝突を避け props["ports"] 側で gateway ポートを公開する。
        missing_ports.each do |pnum|
          existing_entry = props["ports"].find do |pe|
            next false unless pe.is_a?(Hash) && valid_port_int(pe["port"]) == pnum

            proto = pe["protocol"].to_s.upcase
            proto.empty? || proto == "TCP"
          end
          if existing_entry
            existing_entry["expose"] = true
          else
            props["ports"] << { "port" => pnum, "expose" => true, "protocol" => "TCP" }
          end
        end
        $updated_component_expose_ports << "#{app_name}/#{cname}"
      elsif expose_trait
        expose_trait["properties"] ||= {}
        etp = expose_trait["properties"]
        etp["type"] ||= "ClusterIP"
        if etp["ports"].is_a?(Array) && !etp["ports"].empty?
          missing_ports.each { |pnum| etp["ports"] << { "port" => pnum, "protocol" => "TCP" } }
        elsif etp["port"].is_a?(Array)
          etp["port"] = (etp["port"] + missing_ports).uniq
        else
          etp["ports"] = missing_ports.map { |pnum| { "port" => pnum, "protocol" => "TCP" } }
        end
        $synthesized_expose_services << "#{app_name}/#{cname}"
      else
        kept_traits << {
          "type" => "expose",
          "properties" => {
            "type" => "ClusterIP",
            "ports" => missing_ports.map { |pnum| { "port" => pnum, "protocol" => "TCP" } }
          }
        }
        $synthesized_expose_services << "#{app_name}/#{cname}"
      end
    end
  end

  if kept_traits.empty?
    comp.delete("traits")
  else
    comp["traits"] = kept_traits
  end
end

def clean_workflow_steps!(app_name, steps, stripped_topology_names, retained_policy_names)
  return unless steps.is_a?(Array)

  steps.each do |st|
    next unless st.is_a?(Hash)

    sprops = st["properties"]
    if sprops.is_a?(Hash)
      if %w[apply-component clean-jobs].include?(st["type"])
        sprops.delete("namespace")
      elsif st["type"] == "deploy"
        if sprops["inlinePolicies"].is_a?(Array) && sprops["inlinePolicies"].empty?
          sprops.delete("inlinePolicies")
        end
        if sprops["policies"].is_a?(Array)
          sprops["policies"] -= stripped_topology_names.to_a
          undeclared = sprops["policies"].reject { |pn| retained_policy_names.include?(pn) }
          unless undeclared.empty?
            abort "Application/#{redact_secret_label(app_name)} の workflow step deploy が spec.policies に存在しない外部ポリシーを参照しています: #{undeclared.map { |pn| redact_secret_label(pn) }.join(', ')}"
          end
          sprops.delete("policies") if sprops["policies"].empty?
        end
      end
      st.delete("properties") if sprops.empty?
    end
    clean_workflow_steps!(app_name, st["subSteps"], stripped_topology_names, retained_policy_names) if st["subSteps"].is_a?(Array)
  end
end

def trivial_default_deploy_workflow?(wf)
  return true unless wf.is_a?(Hash)
  return false if wf["mode"].is_a?(Hash) && !wf["mode"].empty?

  steps = safe_array(wf["steps"])
  return true if steps.empty?

  steps.all? do |st|
    next false unless st.is_a?(Hash) && st["type"] == "deploy"
    next false unless (st.keys - %w[name type properties]).empty?

    props = st["properties"]
    props.nil? || props.empty? || props == { "auto" => true }
  end
end

def assert_workflow_step_names!(app_name, steps)
  safe_app = redact_secret_label(app_name)
  safe_array(steps).each do |st|
    abort "Application/#{safe_app} のカスタム workflow step に name がありません" unless non_empty_str(st["name"])
    assert_workflow_step_names!(app_name, st["subSteps"]) if st["subSteps"].is_a?(Array)
  end
end

def clean_application!(app)
  meta = app["metadata"]
  app_name = meta["name"]
  spec = app["spec"]
  return nil if safe_array(spec["components"]).empty?

  app.delete("status")
  VOLATILE_META.each { |k| meta.delete(k) }
  clean_annotations_hash!(meta)
  clean_labels_hash!(meta)

  spec["components"].each do |comp|
    if comp.key?("externalRevision")
      $stripped_external_revisions << "#{app_name}/#{comp['name']}"
      comp.delete("externalRevision")
    end
    sanitize_component_expose_and_traits!(comp, app_name, is_override: false)
  end

  stripped_topology_names = Set.new
  retained_policy_names = Set.new
  if spec["policies"].is_a?(Array)
    kept_policies = []
    spec["policies"].each do |pol|
      if pol["type"] == "topology"
        pname = non_empty_str(pol["name"])
        stripped_topology_names << pname if pname
        next
      elsif pol["type"] == "override" && pol["properties"].is_a?(Hash)
        safe_array(pol["properties"]["components"]).each do |oc|
          if oc.is_a?(Hash) && oc.key?("externalRevision")
            oc_name = non_empty_str(oc["name"]) || "(override)"
            $stripped_external_revisions << "#{app_name}/override/#{oc_name}"
            oc.delete("externalRevision")
          end
          sanitize_component_expose_and_traits!(oc, app_name, is_override: true)
        end
        pol.delete("properties") if pol["properties"].empty?
      end
      pname = non_empty_str(pol["name"])
      retained_policy_names << pname if pname
      kept_policies << pol
    end
    if kept_policies.empty?
      spec.delete("policies")
    else
      spec["policies"] = kept_policies
    end
  end

  if (wf = spec["workflow"]).is_a?(Hash)
    clean_workflow_steps!(app_name, wf["steps"], stripped_topology_names, retained_policy_names)
    if trivial_default_deploy_workflow?(wf)
      spec.delete("workflow")
    else
      assert_workflow_step_names!(app_name, wf["steps"])
    end
  end

  meta["annotations"] ||= {}
  meta["annotations"]["config.kubernetes.io/depends-on"] = APP_DEPENDS_ON
  app
end

def clean(obj)
  return nil unless obj.is_a?(Hash)

  kind = non_empty_str(obj["kind"])
  meta = obj["metadata"].is_a?(Hash) ? obj["metadata"] : nil
  name = meta ? non_empty_str(meta["name"]) : nil

  if kind != "Application"
    return nil if meta && (safe_array(meta["ownerReferences"]).any? || vela_managed?(meta))
  end

  unless kind && ALLOWED_KINDS.include?(kind)
    kyverno_policy = kind == "NetworkPolicy" && (kyverno_managed?(meta) || KYVERNO_NETWORK_POLICIES.include?(name))
    $dropped[kind.to_s] << name unless kyverno_policy
    return nil
  end

  abort "リソース #{kind} の metadata.name が不正です" unless meta && name
  safe_name = redact_secret_label(name)
  abort "リソース #{kind}/#{safe_name} の metadata.annotations がマッピングではありません" if !meta["annotations"].nil? && !meta["annotations"].is_a?(Hash)
  abort "リソース #{kind}/#{safe_name} の metadata.labels がマッピングではありません" if !meta["labels"].nil? && !meta["labels"].is_a?(Hash)
  abort "リソース #{kind}/#{safe_name} の spec がマッピングではありません" if !obj["spec"].nil? && !obj["spec"].is_a?(Hash)

  if kind == "Application"
    check_application_shape!(name, obj)
    return clean_application!(obj)
  end

  check_configmap_shape!(name, obj["data"], obj["binaryData"]) if kind == "ConfigMap"
  return nil if kind == "ServiceAccount" && name == "default"
  return nil if kind == "ConfigMap" && name == "kube-root-ca.crt"
  return nil if kyverno_managed?(meta)

  obj.delete("status")
  VOLATILE_META.each { |k| meta.delete(k) }
  clean_annotations_hash!(meta)
  clean_labels_hash!(meta)

  if kind == "PersistentVolumeClaim" && obj["spec"].is_a?(Hash)
    reject_case_variant_keys!(obj["spec"], %w[volumeName dataSource dataSourceRef selector storageClassName accessModes], "PersistentVolumeClaim/#{safe_name} の spec")
    sanitize_pvc_spec_hash!(obj["spec"], name)
  end

  obj
end

# 機密検査通過後: storage.secret[].mountOnly = true を強制し、空の data/stringData キーを除去する
def enforce_storage_secret_mount_only!(apps)
  enforce_traits = lambda do |traits, scope|
    safe_array(traits).each do |t|
      next unless t.is_a?(Hash) && t["type"] == "storage" && t["properties"].is_a?(Hash)

      safe_array(t["properties"]["secret"]).each do |s|
        next unless s.is_a?(Hash)

        s.delete("data") if s["data"].is_a?(Hash) && s["data"].empty?
        s.delete("stringData") if s["stringData"].is_a?(Hash) && s["stringData"].empty?
        unless s["mountOnly"] == true
          s["mountOnly"] = true
          sname = non_empty_str(s["name"]) || "(無名)"
          $forced_secret_mount_only << "#{scope}/#{sname}"
        end
      end
    end
  end

  apps.each do |app|
    app_name = app["metadata"]["name"]
    safe_array(safe_dig(app, "spec", "components")).each do |comp|
      enforce_traits.call(comp["traits"], "#{app_name}/#{comp['name']}")
    end
    safe_array(safe_dig(app, "spec", "policies")).each do |pol|
      next unless pol.is_a?(Hash) && pol["type"] == "override" && pol["properties"].is_a?(Hash)

      safe_array(pol["properties"]["components"]).each do |oc|
        enforce_traits.call(oc["traits"], "#{app_name}/override")
      end
    end
  end
end

# ---------------------------------------------------------------------------
# 参照している Secret を集める（KubeVela Application + 補助 ServiceAccount）
# ---------------------------------------------------------------------------

def collect_component_secret_refs(comp, refs, optional_seen)
  return unless comp.is_a?(Hash)

  props = comp["properties"]
  if props.is_a?(Hash)
    safe_array(props["imagePullSecrets"]).each do |s|
      sname = s.is_a?(String) ? non_empty_str(s) : (s.is_a?(Hash) ? non_empty_str(s["name"]) : nil)
      refs[sname][:pull] = true if sname && !sname.start_with?("default-token-")
    end

    safe_array(props["env"]).each do |e|
      next unless e.is_a?(Hash)

      ref = safe_dig(e, "valueFrom", "secretKeyRef")
      next unless ref.is_a?(Hash)

      sname = non_empty_str(ref["name"])
      skey = non_empty_str(ref["key"])
      next unless sname && skey && !sname.start_with?("default-token-")

      if ref["optional"] == true
        optional_seen << sname
      else
        refs[sname][:keys] << skey
      end
    end

    safe_array(safe_dig(props, "volumeMounts", "secret")).each do |s|
      next unless s.is_a?(Hash)

      sname = non_empty_str(s["secretName"])
      next unless sname && !sname.start_with?("default-token-")

      if s["items"].is_a?(Array) && !s["items"].empty?
        valid_keys = s["items"].filter_map { |i| non_empty_str(i["key"]) if i.is_a?(Hash) }
        refs[sname][:keys].concat(valid_keys) unless valid_keys.empty?
      else
        refs[sname][:whole] = true
      end
    end

    safe_array(props["volumes"]).each do |v|
      next unless v.is_a?(Hash) && v["type"] == "secret"

      sname = non_empty_str(v["secretName"])
      next unless sname && !sname.start_with?("default-token-")

      if v["items"].is_a?(Array) && !v["items"].empty?
        valid_keys = v["items"].filter_map { |i| non_empty_str(i["key"]) if i.is_a?(Hash) }
        refs[sname][:keys].concat(valid_keys) unless valid_keys.empty?
      else
        refs[sname][:whole] = true
      end
    end
  end

  safe_array(comp["traits"]).each do |t|
    next unless t.is_a?(Hash) && t["properties"].is_a?(Hash)

    tprops = t["properties"]
    case t["type"]
    when "storage"
      safe_array(tprops["secret"]).each do |s|
        next unless s.is_a?(Hash)

        sname = non_empty_str(s["name"])
        next unless sname && !sname.start_with?("default-token-")

        keys = []
        if (mte = s["mountToEnv"]).is_a?(Hash)
          k = non_empty_str(mte["secretKey"])
          keys << k if k
        end
        safe_array(s["mountToEnvs"]).each do |m|
          next unless m.is_a?(Hash)

          k = non_empty_str(m["secretKey"])
          keys << k if k
        end
        if s["items"].is_a?(Array) && !s["items"].empty?
          keys.concat(s["items"].filter_map { |i| non_empty_str(i["key"]) if i.is_a?(Hash) })
          refs[sname][:keys].concat(keys) unless keys.empty?
        elsif non_empty_str(s["mountPath"])
          refs[sname][:whole] = true
        elsif !keys.empty?
          refs[sname][:keys].concat(keys)
        else
          refs[sname][:whole] = true
        end
      end
    when "volumes"
      safe_array(tprops["volumes"]).each do |v|
        next unless v.is_a?(Hash) && v["type"] == "secret"

        sname = non_empty_str(v["secretName"])
        next unless sname && !sname.start_with?("default-token-")

        if v["items"].is_a?(Array) && !v["items"].empty?
          valid_keys = v["items"].filter_map { |i| non_empty_str(i["key"]) if i.is_a?(Hash) }
          refs[sname][:keys].concat(valid_keys) unless valid_keys.empty?
        else
          refs[sname][:whole] = true
        end
      end
    when "init-container", "sidecar"
      safe_array(tprops["env"]).each do |e|
        next unless e.is_a?(Hash)

        ref = safe_dig(e, "valueFrom", "secretKeyRef")
        next unless ref.is_a?(Hash)

        sname = non_empty_str(ref["name"])
        skey = non_empty_str(ref["key"])
        next unless sname && skey && !sname.start_with?("default-token-")

        if ref["optional"] == true
          optional_seen << sname
        else
          refs[sname][:keys] << skey
        end
      end
    end
  end
end

def collect_secret_refs(apps, companions)
  refs = Hash.new { |h, k| h[k] = { keys: [], whole: false, pull: false } }
  optional_seen = Set.new

  apps.each do |app|
    safe_array(safe_dig(app, "spec", "components")).each do |comp|
      collect_component_secret_refs(comp, refs, optional_seen)
    end
    safe_array(safe_dig(app, "spec", "policies")).each do |pol|
      next unless pol.is_a?(Hash) && pol["type"] == "override" && pol["properties"].is_a?(Hash)

      safe_array(pol["properties"]["components"]).each do |oc|
        collect_component_secret_refs(oc, refs, optional_seen)
      end
    end
  end

  $gateway_secret_refs.each do |sname|
    refs[sname][:whole] = true unless sname.start_with?("default-token-")
  end

  companions.select { |r| r["kind"] == "ServiceAccount" }.each do |sa|
    safe_array(sa["imagePullSecrets"]).each do |s|
      next unless s.is_a?(Hash)

      sname = non_empty_str(s["name"])
      refs[sname][:pull] = true if sname && !sname.start_with?("default-token-")
    end
  end

  refs.each_value { |v| v[:keys].uniq! }
  [refs, (optional_seen - refs.keys).sort]
end

SECRET_ID_MAX = 255

def secret_tuple_digest(parts, attempt = 0)
  payload = attempt.zero? ? ["prod", APP, parts] : ["prod", APP, parts, attempt]
  serialized =
    begin
      JSON.dump(payload)
    rescue EncodingError, JSON::GeneratorError
      items = Array(parts)
      [
        "\x00BIN\x00".b,
        APP.bytesize,
        APP.b,
        items.size,
        *items.flat_map { |s| b = s.to_s.b; [b.bytesize, b] },
        attempt
      ].map { |x| x.is_a?(Integer) ? [x].pack("Q>") : x }.join
    end
  Digest::SHA256.hexdigest(serialized)
end

def secret_id_for(parts, taken)
  clean_parts = Array(parts).map do |p|
    s = p.to_s
    ascii_src = if s.encoding.ascii_compatible?
                  s.valid_encoding? ? s : s.b
                else
                  s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
                end
    ascii_src.gsub(/[^A-Za-z0-9_-]/, "-").encode(Encoding::UTF_8)
  end
  body = clean_parts.join("-")
  prefix = "prod-#{APP}_"
  base_id = "#{prefix}#{body}"

  id = base_id
  if body.empty? || taken.include?(id) || id.length > SECRET_ID_MAX
    stem = body.empty? ? "#{prefix}secret" : base_id
    attempt = 0
    loop do
      suffix = "-#{secret_tuple_digest(parts, attempt)[0, 8]}"
      id = "#{stem[0, SECRET_ID_MAX - suffix.length]}#{suffix}"
      break unless taken.include?(id)

      attempt += 1
    end
  end

  taken << id
  id
end

# ---------------------------------------------------------------------------
# Ingress を当てる Service を選ぶ
# ---------------------------------------------------------------------------

def collect_web_candidates(apps, dev_service_ports)
  candidates = []

  apps.each do |app|
    safe_array(safe_dig(app, "spec", "components")).each do |comp|
      next unless comp.is_a?(Hash)

      cname = non_empty_str(comp["name"])
      next unless cname

      props = comp["properties"].is_a?(Hash) ? comp["properties"] : {}
      ports = []

      if %w[webservice statefulset].include?(comp["type"])
        safe_array(props["ports"]).each do |p|
          next unless p.is_a?(Hash) && p["expose"] == true

          pnum = valid_port_int(p["port"])
          proto = p["protocol"].to_s.upcase
          if pnum && (proto.empty? || proto == "TCP")
            ports << { "port" => pnum, "name" => non_empty_str(p["name"]), "protocol" => "TCP" }
          end
        end
      end

      safe_array(comp["traits"]).each do |t|
        next unless t.is_a?(Hash) && t["type"] == "expose" && t["properties"].is_a?(Hash)

        tprops = t["properties"]
        next if tprops["type"] == "ExternalName"

        if tprops["ports"].is_a?(Array) && !tprops["ports"].empty?
          tprops["ports"].each do |p|
            next unless p.is_a?(Hash)

            pnum = valid_port_int(p["port"])
            proto = p["protocol"].to_s.upcase
            if pnum && (proto.empty? || proto == "TCP")
              ports << { "port" => pnum, "name" => non_empty_str(p["name"]), "protocol" => "TCP" }
            end
          end
        elsif tprops["port"].is_a?(Array)
          tprops["port"].each do |p|
            pnum = valid_port_int(p)
            ports << { "port" => pnum, "name" => nil, "protocol" => "TCP" } if pnum
          end
        end
      end

      candidates << { "name" => cname, "ports" => ports } unless ports.empty?
    end
  end

  $gateway_existing_services.each do |svc_name, gw_ports|
    if dev_service_ports.key?(svc_name)
      candidates << { "name" => svc_name, "ports" => dev_service_ports[svc_name] }
    elsif !gw_ports.empty?
      candidates << { "name" => svc_name, "ports" => gw_ports.map { |p| { "port" => p, "name" => nil, "protocol" => "TCP" } } }
    end
  end

  candidates
end

def pick_web_service(candidates)
  scored = candidates.filter_map do |cand|
    svc_name = non_empty_str(cand["name"])
    next nil unless svc_name

    ports = safe_array(cand["ports"]).select do |p|
      p.is_a?(Hash) && valid_port_int(p["port"]) && (p["protocol"].nil? || p["protocol"].to_s.empty? || p["protocol"].to_s.upcase == "TCP")
    end
    gw_pref = $gateway_preferred_ports[svc_name]
    port = ports.find { |p| gw_pref.include?(valid_port_int(p["port"])) } ||
           ports.find { |p| p["name"] == "http" } ||
           ports.find { |p| valid_port_int(p["port"]) == 80 } ||
           ports.find { |p| valid_port_int(p["port"]) == 3000 } ||
           ports.first
    next nil unless port

    port_num = valid_port_int(port["port"])
    score = if gw_pref.include?(port_num) then -1
            elsif port["name"] == "http" then 0
            elsif port_num == 80 then 1
            elsif port_num == 3000 then 2
            else 3
            end
    [score, svc_name, port_num]
  end

  scored.min_by { |s| [s[0], s[1]] }
end

# ---------------------------------------------------------------------------
# YAML の出力（Prettier 3.10.1 の 2 スペース配列インデント・クォート規則に揃える）
# ---------------------------------------------------------------------------

YAML_BLOCK_FORBIDDEN_RE = /[\x00-\x09\x0B-\x1F\x7F\u0080-\u009F\u2028\u2029\uFEFF\uFFFE\uFFFF]/
YAML_INLINE_FORBIDDEN_RE = /[\x00-\x1F\x7F\u0080-\u009F\u2028\u2029\uFEFF\uFFFE\uFFFF]/
YAML_ESCAPE_RE = /[\x7F\u0080-\u009F\u2028\u2029\uFEFF\uFFFE\uFFFF]/

YAML_AMBIGUOUS_RE = /\A(?:y|n|yes|no|on|off|true|false|null|~|\.nan|[-+]?\.inf|
  [-+]?(?:0|[1-9][0-9_]*|0x[0-9a-fA-F_]+|0o?[0-7_]+|0b[01_]+|
  [0-9][0-9_]*\.[0-9_]*(?:[eE][-+]?[0-9]+)?|\.[0-9_]+(?:[eE][-+]?[0-9]+)?|[0-9_]+[eE][-+]?[0-9]+))\z/ix

YAML_PLAIN_FORBIDDEN_RE = /[:#\[\]{},&*!|>'"%@`]|\A(?:[-?=]|---|\.\.\.)|\A[[:space:]]|[[:space:]]\z/
YAML_ZERO_RANGES_B36 =
  "0:v,2n:w,gw:33,7n:6,7b:18,1,1:1,1:1,1,20:a,1c:k,g,2t:6,2:5,2:1,1:3,z,u:q,2j:a," \
  "1m:8,9,o:3,1:8,1:2,1:4,17:2,1n:8,16:n,1:v,1j,1,4:7,4,3:6,a:1,t,1m,4:3,8,k:1,q," \
  "2:1,1l,4:1,4:1,2:2,3,u:1,3,b:1,1l,4:4,1:1,4,k:1,m:5,1,1m,2,1:3,8,7:1,b:1,u,1p," \
  "c,1e,3,1j,1:2,5:2,1:3,7:1,b:1,t,1m,2,6,5:1,k:1,s:1,1l:1,4:3,8,k:1,t,20,7:2,1," \
  "2i,2:6,c:7,2q,2:8,b:6,21:1,r,1,1,1j:d,1:4,1:1,5:a,1:z,9,2u:3,1:5,1:1,2:1,p:1," \
  "4:2,g:3,d,2:1,6,f,jj:2,qa:2,t:1,u:1,u:1,1s:1,1:6,8,2:a,9,19:2,1,39:1,y,3a:2," \
  "4:1,9,6:2,63:1,2,1m,1:6,1,1,2:7,6:9,2,1c:19,2:b,k:3,1c,1:4,1,5,14:8,c:1,w:3," \
  "2:1,1:2,1k,1:1,3,1:2,1m:7,2:1,48:2,1:c,1:6,4,6,3:1,5i:1r,k0:w,2da:2,3x,2o:v," \
  "fe:3,2z:1,n9w:3,1:9,w:1,28:1,7k,3,4,p:1,5,47:1,q:h,d,12:7,p:a,1a:2,1c,2:3,2:1," \
  "13,1v:5,2:1,2:1,c,8,1b,1f,1:2,2:1,5:1,1,16:1,8,6m,2,4,fn4,kh:f,g:f,r1,6a,45:4," \
  "1ae:2,1:1,5:3,14:2,4,4l:1,fx:3,1t:4,8t:1,25:5,1y:a,1d:3,3f,1i:e,15,2:1,a:2," \
  "1d:3,2:1,7,1p:2,10:4,1:7,1q,c:1,1g:8,a:3,2,2n:2,2,1:1,6,2,4d,3:7,l:1,1l:1,3," \
  "11:6,3:4,1y:5,d,1,1,e:1,2d:7,2:2,1,n,2c:5,1,4:1,1:1,6m:3,6:1,1:1,r:1,2d:7,2," \
  "1:1,2y,1,2:5,1,2t,1,2:3,1:4,77:8,1:1,74:1,1,4,40:3,2:1,4,w:9,14:5,2:3,8,9:5," \
  "2:2,1a:c,1:1,5i,1:2,1,5l:6,1:5,1,2a:l,2:6,1:1,1:1,3e:5,3,1:1,1:6,1,20:1,3,1," \
  "9n:1,b:1,1g:4,5,1,n,44l,6:e,8ug:b,3:2,1xc:4,1n:6,t4,1r:3,29,f5k:1,3mp:19,2:m," \
  "f4:2,h:7,2:6,u:3,44:2,1iz:1i,4:1d,8,e,m:4,1:e,11s:6,1:g,2:6,1:1,1:4,2s,4g:6," \
  "af,1p:3,e4:3,72:1,6r,2,7:1,5,d6:6,31:6,gzhx:6n"

YAML_WIDE_RANGES_B36 =
  "3cw:2n,3i2:1,d:1,5a:3,3,2,eh:1,l:1,7,i:7,g:b,17,a:5,3,d,8:1,h:1,5:1,8,5,l,7:1," \
  "1,3:1,2,7,4:3,q,z,1,4:2,1,1p:2,o,e,nv:1,1f,4,mi:p,1:2g,c:5x,q:1l,4:g,2:2d,4:2s," \
  "5:16,1:2l,1:2d,9:1b,1:13,8:mkc,3:1i,wp:s,hv:8mb,6l8:e7,ls:9,m:y,1:i,1:3,45:2n," \
  "3j:6,m49:3,c:6,9:5p6,10:x,2n:36,d:pd,e:1e,5y5:3,1:6,1:1,1:88,9,t:2,2,e:4,7:az," \
  "6bo:2e,9:m,5n1,5m,5a,2:9,j,29:2,d:17,4:8,7:1,e:5,4a:w,c:8,1:1x,1:l,c:18,2:4," \
  "c:g,3,3:1y,1,1:56,2:1q,d:3,1:n,c:1,4,l,4:1,d,2e:2c,1c:1x,6,3:2,2:4,2:3,b:1," \
  "7:8,65,5:b,4,7v:1a,1:9,1:54,34:c,3:1y,1,3:h,1:c,3:b,zp:1ekd,2:1ekd"

YAML_CP_WIDTH_TABLE = begin
  tbl = "\x01".b * 0x110000
  [[YAML_ZERO_RANGES_B36, "\x00".b], [YAML_WIDE_RANGES_B36, "\x02".b]].each do |spec, byte|
    pos = 0
    spec.split(",").each do |tok|
      g_s, l_s = tok.split(":")
      s = pos + g_s.to_i(36)
      len = l_s ? l_s.to_i(36) + 1 : 1
      tbl[s, len] = byte * len
      pos = s + len
    end
  end
  tbl.freeze
end

YAML_EMOJI_SEQ_RE = begin
  st = "[\\u{1F3FB}-\\u{1F3FF}]"
  gen = "\\u200D[\\u2640\\u2642]\\uFE0F?"
  prof = "[\\u2695\\u2696\\u2708]\\uFE0F?|" \
         "[\\u{1F33E}\\u{1F373}\\u{1F37C}\\u{1F393}\\u{1F3A4}\\u{1F3A8}\\u{1F3EB}\\u{1F3ED}" \
         "\\u{1F4BB}\\u{1F4BC}\\u{1F527}\\u{1F52C}\\u{1F680}\\u{1F692}\\u{1F9B0}-\\u{1F9B3}]|" \
         "[\\u{1F9AF}\\u{1F9BC}\\u{1F9BD}](?:\\u200D\\u27A1\\uFE0F?)?"
  kids = "\\u{1F466}(?:\\u200D\\u{1F466})?|\\u{1F467}(?:\\u200D[\\u{1F466}\\u{1F467}])?"
  c1 = "[\\u00A9\\u00AE\\u203C\\u2049\\u2122\\u2139\\u2194-\\u2199\\u21A9\\u21AA\\u2328\\u23CF" \
       "\\u23ED-\\u23EF\\u23F1\\u23F2\\u23F8-\\u23FA\\u24C2\\u25AA\\u25AB\\u25B6\\u25C0\\u25FB" \
       "\\u25FC\\u2600-\\u2604\\u260E\\u2611\\u2618\\u2620\\u2622\\u2623\\u2626\\u262A\\u262E" \
       "\\u262F\\u2638-\\u263A\\u2640\\u2642\\u265F\\u2660\\u2663\\u2665\\u2666\\u2668\\u267B" \
       "\\u267E\\u2692\\u2694-\\u2697\\u2699\\u269B\\u269C\\u26A0\\u26A7\\u26B0\\u26B1\\u26C8" \
       "\\u26CF\\u26D1\\u26E9\\u26F0\\u26F1\\u26F4\\u26F7\\u26F8\\u2702\\u2708\\u2709\\u270F" \
       "\\u2712\\u2714\\u2716\\u271D\\u2721\\u2733\\u2734\\u2744\\u2747\\u2763\\u27A1\\u2934" \
       "\\u2935\\u2B05-\\u2B07\\u{1F170}\\u{1F171}\\u{1F17E}\\u{1F17F}\\u{1F321}\\u{1F324}-\\u{1F32C}" \
       "\\u{1F336}\\u{1F37D}\\u{1F396}\\u{1F397}\\u{1F399}-\\u{1F39B}\\u{1F39E}\\u{1F39F}\\u{1F3CD}" \
       "\\u{1F3CE}\\u{1F3D4}-\\u{1F3DF}\\u{1F3F5}\\u{1F3F7}\\u{1F43F}\\u{1F4FD}\\u{1F549}\\u{1F54A}" \
       "\\u{1F56F}\\u{1F570}\\u{1F573}\\u{1F576}-\\u{1F579}\\u{1F587}\\u{1F58A}-\\u{1F58D}\\u{1F5A5}" \
       "\\u{1F5A8}\\u{1F5B1}\\u{1F5B2}\\u{1F5BC}\\u{1F5C2}-\\u{1F5C4}\\u{1F5D1}-\\u{1F5D3}" \
       "\\u{1F5DC}-\\u{1F5DE}\\u{1F5E1}\\u{1F5E3}\\u{1F5E8}\\u{1F5EF}\\u{1F5F3}\\u{1F5FA}\\u{1F6CB}" \
       "\\u{1F6CD}-\\u{1F6CF}\\u{1F6E0}-\\u{1F6E5}\\u{1F6E9}\\u{1F6F0}\\u{1F6F3}]"
  c2 = "[\\u261D\\u270A-\\u270D\\u{1F385}\\u{1F3C2}\\u{1F3C7}\\u{1F442}\\u{1F443}\\u{1F446}-\\u{1F450}" \
       "\\u{1F466}\\u{1F467}\\u{1F46B}-\\u{1F46D}\\u{1F472}\\u{1F474}-\\u{1F476}\\u{1F478}\\u{1F47C}" \
       "\\u{1F483}\\u{1F485}\\u{1F48F}\\u{1F491}\\u{1F4AA}\\u{1F574}\\u{1F57A}\\u{1F590}\\u{1F595}" \
       "\\u{1F596}\\u{1F64C}\\u{1F64F}\\u{1F6C0}\\u{1F6CC}\\u{1F90C}\\u{1F90F}\\u{1F918}-\\u{1F91F}" \
       "\\u{1F930}-\\u{1F934}\\u{1F936}\\u{1F977}\\u{1F9B5}\\u{1F9B6}\\u{1F9BB}\\u{1F9D2}\\u{1F9D3}" \
       "\\u{1F9D5}\\u{1FAC3}-\\u{1FAC5}\\u{1FAF0}\\u{1FAF2}-\\u{1FAFA}]"
  c6 = "[\\u{1F3C4}\\u{1F3CA}\\u{1F46E}-\\u{1F471}\\u{1F473}\\u{1F477}\\u{1F481}\\u{1F482}\\u{1F486}" \
       "\\u{1F487}\\u{1F645}-\\u{1F647}\\u{1F64B}\\u{1F64D}\\u{1F64E}\\u{1F6A3}\\u{1F6B4}\\u{1F6B5}" \
       "\\u{1F926}\\u{1F935}\\u{1F937}-\\u{1F939}\\u{1F93C}-\\u{1F93E}\\u{1F9B8}\\u{1F9B9}\\u{1F9CD}" \
       "\\u{1F9CF}\\u{1F9D4}\\u{1F9D6}-\\u{1F9DD}]"
  dir = "\\u200D(?:[\\u2640\\u2642]\\uFE0F?(?:\\u200D\\u27A1\\uFE0F?)?|\\u27A1\\uFE0F?)"
  Regexp.new(
    "[\\x23*0-9]\\uFE0F?\\u20E3|#{c1}\\uFE0F|#{c2}#{st}|" \
    "\\u26D3(?:\\uFE0F(?:\\u200D\\u{1F4A5})?|\\u200D\\u{1F4A5})|" \
    "[\\u26F9\\u{1F3CB}\\u{1F3CC}\\u{1F575}](?:#{st}(?:#{gen})?|\\uFE0F?#{gen})|" \
    "\\u2764(?:\\uFE0F(?:\\u200D[\\u{1F525}\\u{1FA79}])?|\\u200D[\\u{1F525}\\u{1FA79}])|" \
    "#{c6}(?:#{st}(?:#{gen})?|#{gen})|\\u{1F344}\\u200D\\u{1F7EB}|\\u{1F34B}\\u200D\\u{1F7E9}|" \
    "[\\u{1F3C3}\\u{1F6B6}\\u{1F9CE}](?:#{st}(?:#{dir})?|#{dir})|" \
    "\\u{1F3F3}(?:\\uFE0F(?:\\u200D(?:\\u26A7\\uFE0F?|\\u{1F308}))?|\\u200D(?:\\u26A7\\uFE0F?|\\u{1F308}))|" \
    "\\u{1F3F4}(?:\\u200D\\u2620\\uFE0F?|\\u{E0067}\\u{E0062}(?:\\u{E0065}\\u{E006E}\\u{E0067}|" \
    "\\u{E0073}\\u{E0063}\\u{E0074}|\\u{E0077}\\u{E006C}\\u{E0073})\\u{E007F})|" \
    "\\u{1F408}\\u200D\\u2B1B|\\u{1F415}\\u200D\\u{1F9BA}|\\u{1F426}\\u200D[\\u2B1B\\u{1F525}]|" \
    "\\u{1F43B}\\u200D\\u2744\\uFE0F?|\\u{1F441}(?:\\uFE0F(?:\\u200D\\u{1F5E8}\\uFE0F?)?|\\u200D\\u{1F5E8}\\uFE0F?)|" \
    "\\u{1F468}(?:\\u200D(?:#{prof}|\\u2764\\uFE0F?\\u200D(?:\\u{1F48B}\\u200D)?\\u{1F468}|" \
    "[\\u{1F468}\\u{1F469}]\\u200D(?:#{kids})|#{kids})|(#{st})(?:\\u200D(?:#{prof}|" \
    "\\u2764\\uFE0F?\\u200D(?:\\u{1F48B}\\u200D)?\\u{1F468}#{st}|" \
    "[\\u{1F430}\\u{1F91D}\\u{1FAEF}]\\u200D\\u{1F468}(?!\\1)#{st}))?)|" \
    "\\u{1F469}(?:\\u200D(?:#{prof}|\\u2764\\uFE0F?\\u200D(?:\\u{1F48B}\\u200D)?[\\u{1F468}\\u{1F469}]|" \
    "\\u{1F469}\\u200D(?:#{kids})|#{kids})|(#{st})(?:\\u200D(?:#{prof}|" \
    "\\u2764\\uFE0F?\\u200D(?:\\u{1F48B}\\u200D)?[\\u{1F468}\\u{1F469}]#{st}|" \
    "\\u{1F91D}\\u200D[\\u{1F468}\\u{1F469}](?!\\2)#{st}|" \
    "[\\u{1F430}\\u{1FAEF}]\\u200D\\u{1F469}(?!\\2)#{st}))?)|" \
    "\\u{1F62E}\\u200D\\u{1F4A8}|\\u{1F635}\\u200D\\u{1F4AB}|\\u{1F636}\\u200D\\u{1F32B}\\uFE0F?|" \
    "\\u{1F642}\\u200D[\\u2194\\u2195]\\uFE0F?|[\\u{1F9DE}\\u{1F9DF}]#{gen}|" \
    "\\u{1F9D1}(?:\\u200D(?:#{prof}|[\\u{1F384}\\u{1FA70}]|\\u{1F91D}\\u200D\\u{1F9D1}|" \
    "\\u{1F9D1}\\u200D\\u{1F9D2}(?:\\u200D\\u{1F9D2})?|\\u{1F9D2}(?:\\u200D\\u{1F9D2})?)|" \
    "(#{st})(?:\\u200D(?:#{prof}|[\\u{1F384}\\u{1FA70}]|\\u{1F91D}\\u200D\\u{1F9D1}#{st}|" \
    "(?:\\u2764\\uFE0F?\\u200D(?:\\u{1F48B}\\u200D)?|[\\u{1F430}\\u{1FAEF}]\\u200D)\\u{1F9D1}(?!\\3)#{st}))?)|" \
    "\\u{1FAF1}(#{st})(?:\\u200D\\u{1FAF2}(?!\\4)#{st})?"
  )
end

def yaml_display_width(str)
  str = normalize_utf8(str) unless str.encoding == Encoding::UTF_8 && str.valid_encoding?
  return str.length if str.match?(/\A[\x20-\x7F]*\z/)

  w = 0
  rem = str.gsub(YAML_EMOJI_SEQ_RE) do
    w += 2
    ""
  end
  rem.each_codepoint { |cp| w += YAML_CP_WIDTH_TABLE.getbyte(cp) }
  w
end

def yaml_double_quote(str)
  JSON.dump(str).gsub(YAML_ESCAPE_RE) { |ch| format("\\u%04x", ch.ord) }
end

def yaml_quoted_str(str)
  if str.include?("\"") && !str.match?(YAML_INLINE_FORBIDDEN_RE) && !str.include?("\\")
    "'#{str.gsub("'", "''")}'"
  else
    yaml_double_quote(str)
  end
end

def yaml_scalar_key_id(val)
  case val
  when Integer, TrueClass, FalseClass, NilClass
    [val.class, val]
  when Date
    abort "YAML に非対応のスカラ型が含まれています: #{val.class}" if defined?(DateTime) && val.is_a?(DateTime)
    abort "YAML の日付年が範囲外です: #{val.year}" unless (0..9999).cover?(val.year)
    [Date, format("%04d-%02d-%02d", val.year, val.month, val.day)]
  when Float
    val.nan? ? [:float_nan] : [Float, val == 0.0 ? 0.0 : val]
  when Time
    u = val.getutc
    unless (-9999..9999).cover?(u.year) || ((-9999..9999).cover?(val.year) && (val.utc_offset % 60).zero?)
      abort "YAML のタイムスタンプ年が範囲外です: #{val.year}"
    end
    [Time, u.tv_sec, u.subsec.to_r]
  when String
    [String, normalize_utf8(val)]
  when Symbol
    [Symbol, normalize_utf8(val.to_s)]
  else
    abort "YAML に非対応のスカラ型が含まれています: #{val.class}"
  end
end

def format_yaml_time(val)
  u = val.getutc
  if (-9999..9999).cover?(u.year)
    t = u
    tz = "Z"
  elsif (-9999..9999).cover?(val.year) && (val.utc_offset % 60).zero?
    t = val
    tz = val.utc_offset.zero? ? "Z" : val.strftime("%:z")
  else
    abort "YAML のタイムスタンプ年が範囲外です: #{val.year}"
  end
  yr = t.year < 0 ? format("-%04d", -t.year) : format("%04d", t.year)
  base_ts = "#{yr}#{t.strftime('-%m-%dT%H:%M:%S')}"
  sub = t.subsec
  return "#{base_ts}#{tz}" if sub.zero?

  r = sub.to_r
  den = r.denominator
  abort "YAML のタイムスタンプ精度が上限を超えています" if den.bit_length > 4096
  a = 0
  while den.even?
    den >>= 1
    a += 1
  end
  b = 0
  while (den % 5).zero?
    den /= 5
    b += 1
  end
  frac = if den == 1
           k = a > b ? a : b
           abort "YAML のタイムスタンプ精度が上限を超えています" if k > 1000
           digits = (r.numerator * (5**[a - b, 0].max) * (2**[b - a, 0].max)).to_s.rjust(k, "0").sub(/(?<!0)0+\z/, "")
           ".#{digits}"
         else
           format(".%09d", t.nsec).sub(/(?<!0)\.?0+\z/, "")
         end
  "#{base_ts}#{frac}#{tz}"
end

def yaml_scalar(val, indent = 0, allow_block: true)
  case val
  when Integer, TrueClass, FalseClass then val.to_s
  when Float
    if val.nan?
      ".nan"
    elsif val.infinite? == 1
      ".inf"
    elsif val.infinite? == -1
      "-.inf"
    else
      val.to_s
    end
  when NilClass then "null"
  when Date
    abort "YAML に非対応のスカラ型が含まれています: #{val.class}" if defined?(DateTime) && val.is_a?(DateTime)
    abort "YAML の日付年が範囲外です: #{val.year}" unless (0..9999).cover?(val.year)
    format("%04d-%02d-%02d", val.year, val.month, val.day)
  when Time
    format_yaml_time(val)
  when Symbol
    s = normalize_utf8(val.to_s)
    !s.empty? && s.match?(/\A[A-Za-z0-9._\/-]+\z/) ? ":#{s}" : "!ruby/symbol #{yaml_quoted_str(s)}"
  when String
    val = normalize_utf8(val)
    if allow_block &&
       val.include?("\n") &&
       val.end_with?("\n") &&
       !val.end_with?("\n\n") &&
       !val.start_with?(" ", "\n") &&
       !val.match?(YAML_BLOCK_FORBIDDEN_RE) &&
       val.lines.none? { |l| l.chomp("\n").end_with?(" ") }
      pad = " " * (indent + 2)
      "|\n#{val.lines.map { |l| l == "\n" ? "\n" : "#{pad}#{l}" }.join.chomp}"
    elsif !val.empty? &&
          !val.match?(YAML_INLINE_FORBIDDEN_RE) &&
          !val.match?(YAML_AMBIGUOUS_RE) &&
          !val.match?(YAML_PLAIN_FORBIDDEN_RE) &&
          Psych.parse_stream({ "k" => val }.to_yaml(line_width: -1)).children[0].children[0].children[1].style == Psych::Nodes::Scalar::PLAIN
      val
    else
      yaml_quoted_str(val)
    end
  else
    abort "YAML に非対応のスカラ型が含まれています: #{val.class}"
  end
end

def render_yaml(obj, indent = 0)
  abort "YAML のネストが深すぎます" if indent >= 78
  pad = " " * indent
  case obj
  when Hash
    return "{}" if obj.empty?

    seen_out_id = {}
    seen_out_ks = {}
    obj.map do |k, v|
      abort "YAML に複合マッピングキーが含まれています: #{k.class}" if k.is_a?(Hash) || k.is_a?(Array)
      out_kid = yaml_scalar_key_id(k)
      abort "YAML の出力マッピングキーが衝突しています: #{redact_inspect(k)}" if seen_out_id[out_kid]
      seen_out_id[out_kid] = true
      key_s = if k.is_a?(String)
                k_str = out_kid[1]
                k_str == "<<" && (v.is_a?(Hash) || v.is_a?(Array)) ? '!!str "<<"' : yaml_scalar(k_str, indent, allow_block: false)
              else
                yaml_scalar(k, indent, allow_block: false)
              end
      abort "YAML の出力マッピングキーが衝突しています: #{redact_secret_label(key_s)}" if seen_out_ks[key_s]
      seen_out_ks[key_s] = true
      abort "YAML のマッピングキーが 1024 文字（UTF-16 コード単位）を超えています" if key_s.encode(Encoding::UTF_16LE).bytesize > 2048
      key_w = indent + yaml_display_width(key_s)
      case v
      when Hash
        if v.empty?
          key_w + 4 <= 80 ? "#{pad}#{key_s}: {}" : "#{pad}#{key_s}:\n#{pad}  {}"
        else
          "#{pad}#{key_s}:\n#{render_yaml(v, indent + 2)}"
        end
      when Array
        if v.empty?
          key_w + 4 <= 80 ? "#{pad}#{key_s}: []" : "#{pad}#{key_s}:\n#{pad}  []"
        else
          "#{pad}#{key_s}:\n#{render_yaml(v, indent + 2)}"
        end
      else
        "#{pad}#{key_s}: #{yaml_scalar(v, indent, allow_block: key_w + 3 <= 80)}"
      end
    end.join("\n")
  when Array
    return "[]" if obj.empty?

    obj.map do |item|
      case item
      when Hash, Array
        if item.empty?
          "#{pad}- #{item.is_a?(Hash) ? '{}' : '[]'}"
        else
          lines = render_yaml(item, indent + 2).split("\n", -1)
          first = lines.shift.sub(/\A {#{indent + 2}}/, "#{pad}- ")
          ([first] + lines).join("\n")
        end
      else
        "#{pad}- #{yaml_scalar(item, indent, allow_block: indent + 3 <= 80)}"
      end
    end.join("\n")
  else
    "#{pad}#{yaml_scalar(obj, indent, allow_block: indent + 1 <= 80)}"
  end
end

def yaml_doc(hash)
  "#{render_yaml(hash)}\n"
end

def external_secret_for(name, info, taken, notes)
  base = {
    "apiVersion" => "external-secrets.io/v1",
    "kind" => "ExternalSecret",
    "metadata" => {
      "name" => name,
      "annotations" => {
        "config.kubernetes.io/depends-on" => ESO_DEPENDS_ON
      }
    },
    "spec" => {
      "refreshInterval" => "1h",
      "secretStoreRef" => { "name" => "gcp-secret-store", "kind" => "ClusterSecretStore" },
      "target" => { "name" => name, "creationPolicy" => "Owner" }
    }
  }
  spec = base["spec"]

  if info[:pull]
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
# 同一 Namespace の dev FQDN を本番向け短縮名に書き換える
# ---------------------------------------------------------------------------

DNS_LABEL_PART = "[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?"
SVC_PREFIX_RE = "(#{DNS_LABEL_PART}(?:\\.#{DNS_LABEL_PART})?)"
SVC_SUFFIX_RE = "\\.svc(?:\\.cluster\\.local)?\\.?"

def build_host_rewrite_regex(source_ns)
  clean_source = source_ns.to_s
  return nil if clean_source.empty?

  /(?:\A|(?<=:\/\/)|(?<![A-Za-z0-9._\/\\-]))#{SVC_PREFIX_RE}\.#{Regexp.escape(clean_source)}#{SVC_SUFFIX_RE}(?![A-Za-z0-9._-])/
end

def rewrite_host_string(str, pattern, rewritten)
  return str unless pattern && str.is_a?(String)

  str.gsub(pattern) do
    full = Regexp.last_match(0)
    svc = Regexp.last_match(1)
    rewritten << [full, svc]
    svc
  end
end

def rewrite_argv!(arr, pattern, rewritten)
  return unless arr.is_a?(Array)

  arr.map! { |item| item.is_a?(String) ? rewrite_host_string(item, pattern, rewritten) : item }
end

def rewrite_env_array!(arr, pattern, rewritten)
  return unless arr.is_a?(Array)

  arr.each do |e|
    next unless e.is_a?(Hash) && e["value"].is_a?(String)

    e["value"] = rewrite_host_string(e["value"], pattern, rewritten)
  end
end

def rewrite_component_hosts!(comp, pattern, rewritten)
  return unless comp.is_a?(Hash)

  if (props = comp["properties"]).is_a?(Hash)
    rewrite_env_array!(props["env"], pattern, rewritten)
    rewrite_argv!(props["cmd"], pattern, rewritten)
    rewrite_argv!(props["args"], pattern, rewritten)
  end

  safe_array(comp["traits"]).each do |t|
    next unless t.is_a?(Hash) && t["properties"].is_a?(Hash)

    tp = t["properties"]
    case t["type"]
    when "env"
      tp["env"] = tp["env"].transform_values { |v| v.is_a?(String) ? rewrite_host_string(v, pattern, rewritten) : v } if tp["env"].is_a?(Hash)
      safe_array(tp["containers"]).each do |c|
        c["env"] = c["env"].transform_values { |v| v.is_a?(String) ? rewrite_host_string(v, pattern, rewritten) : v } if c.is_a?(Hash) && c["env"].is_a?(Hash)
      end
    when "command"
      %w[command args addArgs delArgs].each { |f| rewrite_argv!(tp[f], pattern, rewritten) }
      safe_array(tp["containers"]).each do |c|
        next unless c.is_a?(Hash)

        %w[command args addArgs delArgs].each { |f| rewrite_argv!(c[f], pattern, rewritten) }
      end
    when "init-container", "sidecar"
      rewrite_env_array!(tp["env"], pattern, rewritten)
      rewrite_argv!(tp["cmd"], pattern, rewritten)
      rewrite_argv!(tp["args"], pattern, rewritten)
    when "storage"
      safe_array(tp["configMap"]).each do |cm|
        next unless cm.is_a?(Hash) && cm["data"].is_a?(Hash)

        cm["data"] = cm["data"].transform_values { |v| v.is_a?(String) ? rewrite_host_string(v, pattern, rewritten) : v }
      end
    end
  end
end

def rewrite_hosts(resources, source_ns, rewritten)
  pattern = build_host_rewrite_regex(source_ns)
  return resources unless pattern

  resources.each do |r|
    next unless r.is_a?(Hash)

    if r["kind"] == "ConfigMap" && r["data"].is_a?(Hash)
      r["data"] = r["data"].transform_values { |v| v.is_a?(String) ? rewrite_host_string(v, pattern, rewritten) : v }
    elsif r["kind"] == "Application"
      safe_array(safe_dig(r, "spec", "components")).each { |c| rewrite_component_hosts!(c, pattern, rewritten) }
      safe_array(safe_dig(r, "spec", "policies")).each do |pol|
        next unless pol.is_a?(Hash) && pol["type"] == "override" && pol["properties"].is_a?(Hash)

        safe_array(pol["properties"]["components"]).each { |oc| rewrite_component_hosts!(oc, pattern, rewritten) }
      end
    end
  end
  resources
end

def statefulset_pvc_names(items)
  items.select { |i| i.is_a?(Hash) && i["kind"] == "StatefulSet" }.flat_map do |sts|
    sts_name = non_empty_str(safe_dig(sts, "metadata", "name"))
    next [] unless sts_name

    safe_array(safe_dig(sts, "spec", "volumeClaimTemplates")).filter_map do |t|
      tpl_name = non_empty_str(safe_dig(t, "metadata", "name"))
      /\A#{Regexp.escape("#{tpl_name}-#{sts_name}")}-\d+\z/ if tpl_name
    end
  end
end

# ---------------------------------------------------------------------------
# 安全な YAML ローダ（エイリアス爆弾・重複キー・不正タグ防御）
# ---------------------------------------------------------------------------

def resolve_yaml_scalar_node(s_node)
  return s_node.value if (s_node.quoted && s_node.tag.nil?) || s_node.tag == "tag:yaml.org,2002:str"

  if s_node.tag.nil? &&
     !s_node.value.empty? &&
     s_node.value.match?(/\A[A-Za-z_][A-Za-z0-9_\/.-]*\z/) &&
     !s_node.value.match?(/\A(?:y|n|yes|no|on|off|true|false|null)\z/i)
    return s_node.value
  end

  sc = s_node.dup
  sc.anchor = nil
  d = Psych::Nodes::Document.new
  d.children << sc
  st = Psych::Nodes::Stream.new
  st.children << d
  YAML.safe_load(st.to_yaml, permitted_classes: [Time, Date, Symbol])
end

YAML_SCALAR_INVALID = Object.new.freeze

def resolve_yaml_scalar_node_safe(s_node)
  resolve_yaml_scalar_node(s_node)
rescue ArgumentError, TypeError, RangeError, Psych::Exception
  YAML_SCALAR_INVALID
end

def validate_yaml_scalar_node(s_node)
  case s_node.tag
  when nil, "!", "tag:yaml.org,2002:str", "!ruby/symbol", "!ruby/sym"
    true
  when "tag:yaml.org,2002:binary"
    begin
      s_node.value.gsub(/\s+/, "").unpack1("m0")
    rescue ArgumentError
      abort "YAML に不正な !!binary 値が含まれています"
    end
    true
  when "tag:yaml.org,2002:int"
    v = resolve_yaml_scalar_node_safe(s_node)
    abort "YAML に不正な !!int 値が含まれています: #{redact_inspect(s_node.value)}" unless v.is_a?(Integer)
  when "tag:yaml.org,2002:float"
    v = resolve_yaml_scalar_node_safe(s_node)
    abort "YAML に不正な !!float 値が含まれています: #{redact_inspect(s_node.value)}" unless v.is_a?(Float)
  when "tag:yaml.org,2002:bool"
    v = resolve_yaml_scalar_node_safe(s_node)
    abort "YAML に不正な !!bool 値が含まれています: #{redact_inspect(s_node.value)}" unless v == true || v == false
  when "tag:yaml.org,2002:null"
    v = resolve_yaml_scalar_node_safe(s_node)
    abort "YAML に不正な !!null 値が含まれています: #{redact_inspect(s_node.value)}" unless v.nil?
  when "tag:yaml.org,2002:timestamp"
    v = resolve_yaml_scalar_node_safe(s_node)
    abort "YAML に不正な !!timestamp 値が含まれています: #{redact_inspect(s_node.value)}" unless v.is_a?(Time) || v.is_a?(Date)
  when "tag:yaml.org,2002:merge"
    abort "YAML に不正な !!merge 値が含まれています: #{redact_inspect(s_node.value)}" unless s_node.value == "<<"
  when "tag:yaml.org,2002:value"
    abort "YAML に不正な !!value 値が含まれています: #{redact_inspect(s_node.value)}" unless s_node.value == "="
  else
    abort "YAML に非対応のスカラタグが含まれています: #{redact_secret_label(s_node.tag)}"
  end
end

def safe_load_yaml_docs(yaml_text)
  yaml_text = String.new(yaml_text, encoding: Encoding::UTF_8) if yaml_text.encoding == Encoding::ASCII_8BIT
  abort "YAML に不正な UTF-8 バイト列が含まれています" unless yaml_text.valid_encoding?
  stream_total_expanded = 0
  parsed_stream = begin
    parse_yaml_stream_bounded(
      yaml_text,
      max_depth: 65,
      max_flow_depth: 65,
      max_nodes: 200_000,
      max_docs: 10_000,
      max_flow_work: 1_000_000,
      max_tag_directives: MAX_YAML_TAG_DIRECTIVES
    )
  rescue YamlNestingDepthError
    abort "YAML のネストが深すぎます"
  rescue YamlNodeLimitError
    abort "YAML のノード展開数が上限を超えています"
  rescue YamlDirectiveLimitError
    abort "YAML のディレクティブ数が上限を超えています"
  end
  parsed_stream.children.map do |doc|
    if (doc_root = doc.root)
      anchors = {}
      active_nodes = {}
      subtree_weight = {}
      mapping_keys = {}
      seq_targets = {}
      total_expanded = 0

      unwrap_node = lambda do |n|
        cur = n
        seen_al = {}
        while cur.is_a?(Psych::Nodes::Alias)
          al = cur.anchor
          abort "YAML に循環参照エイリアスが含まれています: *#{redact_secret_label(al)}" if seen_al[al]
          seen_al[al] = true
          cur = anchors[al]
          abort "YAML に未定義のエイリアスが含まれています: *#{redact_secret_label(al)}" unless cur
          abort "YAML に循環参照エイリアスが含まれています: *#{redact_secret_label(al)}" if active_nodes[cur.object_id]
        end
        cur
      end

      visit_ast = lambda do |node, depth = 0|
        abort "YAML のネストが深すぎます" if depth > 64
        if node.is_a?(Psych::Nodes::Alias)
          target = unwrap_node.call(node)
          w = subtree_weight.fetch(target.object_id, 1)
          total_expanded += w
          stream_total_expanded += w
          abort "YAML のエイリアス展開数が上限を超えています" if total_expanded > 100_000 || stream_total_expanded > 200_000
          next w
        end

        anc = node.respond_to?(:anchor) ? node.anchor : nil
        anchors[anc] = node if anc && !anc.empty?
        active_nodes[node.object_id] = true

        w = 1
        if node.is_a?(Psych::Nodes::Mapping)
          abort "YAML に非対応のマッピングタグが含まれています: #{redact_secret_label(node.tag)}" if node.tag && node.tag != "tag:yaml.org,2002:map"
          explicit_keys = {}
          merged_keys = {}
          seen_merge_dir = false
          node.children.each_slice(2) do |k_node, v_node|
            w += visit_ast.call(k_node, depth + 1)
            abort "YAML のノード展開数が上限を超えています" if w > 100_000
            k_target = unwrap_node.call(k_node)
            abort "YAML に複合マッピングキーが含まれています" if k_target.is_a?(Psych::Nodes::Mapping) || k_target.is_a?(Psych::Nodes::Sequence)
            k_val = resolve_yaml_scalar_node(k_target)
            kid = yaml_scalar_key_id(k_val)
            k_tag = k_node.is_a?(Psych::Nodes::Scalar) ? k_node.tag : nil

            w += visit_ast.call(v_node, depth + 1)
            abort "YAML のノード展開数が上限を超えています" if w > 100_000
            v_target = unwrap_node.call(v_node)

            merge_maps = if kid == [String, "<<"] && k_tag != "tag:yaml.org,2002:str"
                           if v_target.is_a?(Psych::Nodes::Mapping)
                             [v_target]
                           elsif v_node.is_a?(Psych::Nodes::Sequence)
                             elems = seq_targets[v_node.object_id]
                             elems if elems && elems.all? { |el| el.is_a?(Psych::Nodes::Mapping) }
                           end
                         end

            if merge_maps
              abort "YAML に重複したマージキー << が含まれています" if seen_merge_dir
              seen_merge_dir = true
              merge_maps.each do |mm|
                (mapping_keys[mm.object_id] || {}).each_key do |mk|
                  if explicit_keys.key?(mk) || merged_keys.key?(mk)
                    mk_display = case mk[0]
                                 when :float_nan then ".nan"
                                 when Symbol then mk[1].to_sym
                                 when Time then "Time(#{mk[1]})"
                                 else mk[1]
                                 end
                    abort "YAML のマージキー << によりキーが衝突しています: #{redact_inspect(mk_display)}"
                  end
                  merged_keys[mk] = true
                end
              end
            else
              abort "YAML に重複したマッピングキーが含まれています: #{redact_inspect(k_val)}" if explicit_keys.key?(kid)
              abort "YAML のマージキー << によりキーが衝突しています: #{redact_inspect(k_val)}" if merged_keys.key?(kid)
              explicit_keys[kid] = true
            end
          end
          mapping_keys[node.object_id] = explicit_keys.merge(merged_keys)
        elsif node.is_a?(Psych::Nodes::Sequence)
          abort "YAML に非対応のシーケンスタグが含まれています: #{redact_secret_label(node.tag)}" if node.tag && node.tag != "tag:yaml.org,2002:seq"
          elems = []
          node.children.each do |ch|
            w += visit_ast.call(ch, depth + 1)
            abort "YAML のノード展開数が上限を超えています" if w > 100_000
            elems << unwrap_node.call(ch)
          end
          seq_targets[node.object_id] = elems
        elsif node.is_a?(Psych::Nodes::Scalar)
          validate_yaml_scalar_node(node)
        elsif node.respond_to?(:children) && node.children
          node.children.each do |ch|
            w += visit_ast.call(ch, depth + 1)
            abort "YAML のノード展開数が上限を超えています" if w > 100_000
          end
        end

        active_nodes.delete(node.object_id)
        subtree_weight[node.object_id] = w
        total_expanded += 1
        stream_total_expanded += 1
        abort "YAML のノード展開数が上限を超えています" if total_expanded > 100_000 || stream_total_expanded > 200_000
        w
      end

      visit_ast.call(doc_root)
    else
      stream_total_expanded += 1
      abort "YAML のノード展開数が上限を超えています" if stream_total_expanded > 200_000
    end
    stream = Psych::Nodes::Stream.new
    stream.children << doc
    deep_copy(YAML.safe_load(stream.to_yaml, permitted_classes: [Time, Date, Symbol], aliases: true))
  end
rescue Psych::SyntaxError => e
  abort "YAML の解析に失敗しました: #{redact_secret_label(e.message)}"
rescue Psych::Exception, StandardError, SystemStackError => e
  abort "YAML の解析に失敗しました (#{e.class})"
end

def deep_copy(obj, depth = 0)
  abort "YAML のネストが深すぎます" if depth > 64
  case obj
  when Hash
    obj.each_with_object({}) { |(k, v), copy| copy[deep_copy(k, depth + 1)] = deep_copy(v, depth + 1) }
  when Array
    obj.map { |v| deep_copy(v, depth + 1) }
  when Time, String
    obj.dup
  else
    obj
  end
end

# ---------------------------------------------------------------------------
# Trait / Policy 操作ヘルパー（RWO 判定・scaler・Recreate・Spread・apply-once）
# ---------------------------------------------------------------------------

def component_has_rwo_pvc?(comp, dev_pvc_rwo, companion_rwo_pvcs)
  props = comp["properties"].is_a?(Hash) ? comp["properties"] : {}
  safe_array(safe_dig(props, "volumeMounts", "pvc")).each do |p|
    cname = p.is_a?(Hash) ? non_empty_str(p["claimName"]) : nil
    return true if cname && (dev_pvc_rwo[cname] || companion_rwo_pvcs.include?(cname))
  end
  safe_array(props["volumes"]).each do |v|
    next unless v.is_a?(Hash) && v["type"] == "pvc"

    cname = non_empty_str(v["claimName"])
    return true if cname && (dev_pvc_rwo[cname] || companion_rwo_pvcs.include?(cname))
  end

  safe_array(comp["traits"]).each do |t|
    next unless t.is_a?(Hash) && t["properties"].is_a?(Hash)

    tp = t["properties"]
    case t["type"]
    when "storage"
      safe_array(tp["pvc"]).each do |pvc|
        next unless pvc.is_a?(Hash)

        pname = non_empty_str(pvc["name"])
        if pvc["mountOnly"] == true
          return true if pname && (dev_pvc_rwo[pname] || companion_rwo_pvcs.include?(pname))
          return true if pvc["accessModes"].is_a?(Array) && (pvc["accessModes"] & RWO_ACCESS_MODES).any?
        else
          # addons/kubevela/base/definitions/storage.yaml:275 の既定 accessModes は ["ReadWriteOnce"]
          modes = pvc["accessModes"].is_a?(Array) && !pvc["accessModes"].empty? ? pvc["accessModes"] : ["ReadWriteOnce"]
          return true if (modes & RWO_ACCESS_MODES).any?
        end
      end
    when "pvc"
      modes = tp["accessModes"].is_a?(Array) && !tp["accessModes"].empty? ? tp["accessModes"] : ["ReadWriteOnce"]
      return true if (modes & RWO_ACCESS_MODES).any?
    when "volumes"
      safe_array(tp["volumes"]).each do |v|
        next unless v.is_a?(Hash) && v["type"] == "pvc"

        cname = non_empty_str(v["claimName"])
        return true if cname && (dev_pvc_rwo[cname] || companion_rwo_pvcs.include?(cname))
      end
    end
  end

  false
end

def upsert_trait!(comp, type, properties)
  comp["traits"] ||= []
  existing = comp["traits"].find { |t| t.is_a?(Hash) && t["type"] == type }
  if existing
    existing["properties"] = properties
  else
    comp["traits"] << { "type" => type, "properties" => properties }
  end
end

def remove_traits!(comp, types)
  return [] unless comp["traits"].is_a?(Array)

  removed = []
  comp["traits"].reject! do |t|
    if t.is_a?(Hash) && types.include?(t["type"])
      removed << t
      true
    else
      false
    end
  end
  comp.delete("traits") if comp["traits"].empty?
  removed
end

def ensure_hostname_spread_trait!(comp, app_name, comp_name)
  comp["traits"] ||= []
  existing = comp["traits"].find { |t| t.is_a?(Hash) && t["type"] == "topologyspreadconstraints" }
  new_constraint = {
    "maxSkew" => 1,
    "topologyKey" => "kubernetes.io/hostname",
    "whenUnsatisfiable" => "ScheduleAnyway",
    "labelSelector" => {
      "matchLabels" => {
        "app.oam.dev/name" => app_name,
        "app.oam.dev/component" => comp_name
      }
    }
  }
  if existing
    existing["properties"] ||= {}
    constraints = existing["properties"]["constraints"].is_a?(Array) ? existing["properties"]["constraints"] : []
    return if constraints.any? { |c| c.is_a?(Hash) && c["topologyKey"] == "kubernetes.io/hostname" }

    existing["properties"]["constraints"] = constraints + [new_constraint]
  else
    comp["traits"] << {
      "type" => "topologyspreadconstraints",
      "properties" => {
        "constraints" => [new_constraint]
      }
    }
  end
end

def apply_once_covers_replicas?(app, comp_names)
  safe_array(safe_dig(app, "spec", "policies")).any? do |pol|
    next false unless pol.is_a?(Hash) && pol["type"] == "apply-once" && pol["name"] != "hpa-replicas-apply-once"
    next false unless safe_dig(pol, "properties", "enable") == true

    rules = safe_array(safe_dig(pol, "properties", "rules"))
    comp_names.all? do |cn|
      rules.any? do |r|
        next false unless r.is_a?(Hash)

        strat = r["strategy"].is_a?(Hash) ? r["strategy"] : {}
        affect = strat["affect"]
        next false unless affect.nil? || affect == "" || affect == "always"

        paths = safe_array(strat["path"])
        next false unless paths.include?("spec.replicas") || paths.include?("*")

        sel = r["selector"].is_a?(Hash) ? r["selector"] : {}
        next false unless %w[oamTypes traitTypes resourceNames componentTypes].all? do |k|
          sel[k].nil? || (sel[k].is_a?(Array) && sel[k].empty?)
        end
        next false unless sel["componentNames"].nil? || sel["componentNames"].is_a?(Array)
        next false unless sel["resourceTypes"].nil? || sel["resourceTypes"].is_a?(Array)

        cnames = safe_array(sel["componentNames"])
        rtypes = safe_array(sel["resourceTypes"])
        (cnames.empty? || cnames.include?(cn)) && (rtypes.empty? || rtypes.include?("Deployment"))
      end
    end
  end
end

def upsert_hpa_apply_once_policy!(app, scaled_comp_names)
  return if scaled_comp_names.empty?
  return if apply_once_covers_replicas?(app, scaled_comp_names)

  spec = app["spec"]
  spec["policies"] ||= []
  policy_obj = {
    "name" => "hpa-replicas-apply-once",
    "type" => "apply-once",
    "properties" => {
      "enable" => true,
      "rules" => [
        {
          "selector" => {
            "componentNames" => scaled_comp_names.sort,
            "resourceTypes" => ["Deployment"]
          },
          "strategy" => {
            "affect" => "always",
            "path" => ["spec.replicas"]
          }
        }
      ]
    }
  }
  idx = spec["policies"].index { |p| p.is_a?(Hash) && p["name"] == "hpa-replicas-apply-once" }
  if idx
    spec["policies"][idx] = policy_obj
  else
    spec["policies"] << policy_obj
  end
end

def component_scaler_replicas(comp)
  t = safe_array(comp["traits"]).find { |x| x.is_a?(Hash) && x["type"] == "scaler" }
  rep = safe_dig(t, "properties", "replicas") if t
  rep.is_a?(Integer) ? rep : 1
end

def component_missing_cpu_request?(comp)
  props = comp["properties"].is_a?(Hash) ? comp["properties"] : {}
  res_trait = safe_array(comp["traits"]).find { |t| t.is_a?(Hash) && t["type"] == "resource" }
  res_props = res_trait.is_a?(Hash) && res_trait["properties"].is_a?(Hash) ? res_trait["properties"] : {}

  has_mem = !props["memory"].nil? ||
            !safe_dig(props, "limit", "memory").nil? ||
            !res_props["memory"].nil? ||
            !safe_dig(res_props, "requests", "memory").nil? ||
            !safe_dig(res_props, "limits", "memory").nil?
  has_cpu = !props["cpu"].nil? ||
            !safe_dig(props, "limit", "cpu").nil? ||
            !res_props["cpu"].nil? ||
            !safe_dig(res_props, "requests", "cpu").nil? ||
            !safe_dig(res_props, "limits", "cpu").nil?
  has_mem && !has_cpu
end

def velaux_sync_yaml
  target_payload = JSON.generate({
    "createTime" => VELAUX_SYNC_TIMESTAMP,
    "updateTime" => VELAUX_SYNC_TIMESTAMP,
    "name" => "local-prod-#{APP}",
    "alias" => "prod-#{APP}",
    "project" => "production",
    "description" => "GitOps prod target (Config Sync managed)",
    "cluster" => {
      "clusterName" => "local",
      "namespace" => "prod-#{APP}"
    }
  })
  env_payload = JSON.generate({
    "createTime" => VELAUX_SYNC_TIMESTAMP,
    "updateTime" => VELAUX_SYNC_TIMESTAMP,
    "name" => "prod-#{APP}",
    "alias" => "prod-#{APP}",
    "description" => "GitOps prod environment (Config Sync managed)",
    "project" => "production",
    "namespace" => "prod-#{APP}",
    "targets" => ["local-prod-#{APP}"]
  })

  target_cm = {
    "apiVersion" => "v1",
    "kind" => "ConfigMap",
    "metadata" => {
      "name" => "tg-local-prod-#{APP}",
      "namespace" => "velaux-store",
      "annotations" => {
        "config.kubernetes.io/depends-on" => "/Namespace/velaux-store"
      },
      "labels" => {
        "name" => "local-prod-#{APP}",
        "primaryKey" => "local-prod-#{APP}",
        "project" => "production",
        "table" => "vela_target"
      }
    },
    "binaryData" => {
      "data" => [target_payload].pack("m0")
    }
  }

  env_cm = {
    "apiVersion" => "v1",
    "kind" => "ConfigMap",
    "metadata" => {
      "name" => "ev-prod-#{APP}",
      "namespace" => "velaux-store",
      "annotations" => {
        "config.kubernetes.io/depends-on" => "/Namespace/velaux-store"
      },
      "labels" => {
        "name" => "prod-#{APP}",
        "namespace" => "prod-#{APP}",
        "primaryKey" => "prod-#{APP}",
        "project" => "production",
        "table" => "vela_env"
      }
    },
    "binaryData" => {
      "data" => [env_payload].pack("m0")
    }
  }

  header = <<~YAML
    # VelaUX の Production (GitOps Read-Only) プロジェクトへ prod-#{APP} を事前登録する ConfigMap。
    # CR2UX が Config Sync 管理下の Application を検出した際、prod-#{APP} への書込みを一切行わず
    # 状態・トポロジ・Pod・ログ・イベントを VelaUX UI 上で読取専用可視化する。
    # 再昇格のたびに上書きされる（固定タイムスタンプのため差分は出ない）。
  YAML
  header + [yaml_doc(target_cm), yaml_doc(env_cm)].join("---\n")
end

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

# tg-local-prod-<APP> (ConfigMap 名・接頭辞 14 文字) が DNS-1123 ラベル上限 (63 文字) に収まるよう
# APP は 1〜49 文字に制限し、予約名・dev-*・プラットフォーム予約ホスト名も拒否する。
unless APP.match?(/\A[a-z0-9]([-a-z0-9]{0,47}[a-z0-9])?\z/) &&
       !APP.match?(RESERVED_NS_RE) &&
       !APP.start_with?("dev-") &&
       !RESERVED_APP_NAMES.include?(APP)
  abort "APP が昇格先の命名規則に適合しません（1〜49文字・DNSラベル・予約名/dev-*/プラットフォームホスト名不可）: #{redact_inspect(APP)}"
end

if !SOURCE_NAMESPACE.empty? && (!SOURCE_NAMESPACE.match?(DNS_LABEL_RE) || SOURCE_NAMESPACE.match?(RESERVED_NS_RE))
  abort "システム・プラットフォーム・本番または不正な Namespace は昇格の元にできません: #{redact_secret_label(SOURCE_NAMESPACE)}"
end

$stdin.set_encoding(Encoding::UTF_8)
docs = safe_load_yaml_docs($stdin.read)
items = docs.flat_map do |d|
  next [] unless d.is_a?(Hash)

  if d["kind"].to_s.end_with?("List")
    abort "List の items が配列ではありません" unless d["items"].nil? || d["items"].is_a?(Array)
    d["items"] || []
  elsif d["items"].is_a?(Array) && d["kind"].nil?
    d["items"]
  else
    [d]
  end
end.select { |i| i.is_a?(Hash) }

source_of = lambda do |i|
  ns = safe_dig(i, "metadata", "namespace")
  abort "metadata.namespace が文字列ではありません" if !ns.nil? && !ns.is_a?(String)
  ns.to_s
end
unknown = items.map(&source_of).uniq - [SOURCE_NAMESPACE, ""]
if !SOURCE_NAMESPACE.empty? && unknown.any?
  abort "想定していない Namespace のリソースが入力にあります: #{unknown.map { |ns| redact_secret_label(ns) }.join(', ')}"
end

# フィルタ前に dev Namespace 内の Ingress / PVC / Service を事前走査する
# （vela-core が描画した子リソースから公開有無・RWO PVC・existingServiceName ポート情報を得るため）
dev_pvc_rwo = {}
dev_service_ports = {}
items.each do |i|
  kind = non_empty_str(i["kind"])
  name = non_empty_str(safe_dig(i, "metadata", "name"))
  next unless kind && name

  case kind
  when "Ingress"
    $dev_has_ingress = true
    safe_array(safe_dig(i, "spec", "rules")).each do |r|
      host = r.is_a?(Hash) ? non_empty_str(r["host"]) : nil
      $dev_ingress_hosts << host if host
    end
  when "PersistentVolumeClaim"
    modes = safe_array(safe_dig(i, "spec", "accessModes"))
    dev_pvc_rwo[name] = (modes & RWO_ACCESS_MODES).any?
  when "Service"
    if safe_dig(i, "spec", "clusterIP") != "None" && safe_dig(i, "spec", "type") != "ExternalName"
      dev_service_ports[name] = safe_array(safe_dig(i, "spec", "ports"))
    end
  end
end

sts_pvcs = statefulset_pvc_names(items)
items = items.reject do |i|
  i["kind"] == "PersistentVolumeClaim" && sts_pvcs.any? { |re| re.match?(safe_dig(i, "metadata", "name").to_s) }
end

resources = items.filter_map { |i| clean(i) }

duplicates = resources.group_by { |r| [r["kind"], safe_dig(r, "metadata", "name")] }.select { |_, v| v.size > 1 }.keys
unless duplicates.empty?
  abort "同じ Kind・名前のリソースが重複しています（#{duplicates.map { |k, n| "#{k}/#{redact_secret_label(n)}" }.join(', ')}）"
end

rewritten = []
rewrite_hosts(resources, SOURCE_NAMESPACE, rewritten)

if resources.empty?
  safe_app = redact_secret_label(APP)
  if Dir.exist?(OUT)
    warn "昇格対象のリソースがありません (#{safe_app})。本番の定義は変更しません。" \
         "本番から外す場合は components/apps/#{safe_app} を削除する PR を手で出してください。"
  else
    warn "昇格対象のリソースがありません (#{safe_app})。何もしません。"
  end
  exit EXIT_NOTHING_TO_DO
end

# 機密らしい値が 1 つでもあれば、何も書き出さずに止める（公開リポジトリへ push される前に止めるため）。
secret_hits = secret_like_hits(resources)
unless secret_hits.empty?
  lines = secret_hits.map { |target, where, rules| "  - #{target}: #{where}（#{rules.join('、')}）" }
  abort <<~MSG.chomp
    機密らしい値が見つかったため、#{redact_secret_label(APP)} の昇格を中止しました。何も書き出していません。
    このリポジトリは公開されており、昇格 PR はレビューより前に push されるため、ここで止めます。
    見つかった箇所（値は表示しません）:
    #{lines.join("\n")}
    対処: 値を Secret に移し、dev では env の valueFrom.secretKeyRef または storage.secret (mountOnly: true) で参照してください
    （昇格時に ExternalSecret の雛形が作られます）。そのうえで昇格をやり直してください。
    値が機密ではない場合は、変数名や内容を変えてください。
  MSG
end

apps = resources.select { |r| r["kind"] == "Application" }
companions = resources.reject { |r| r["kind"] == "Application" }

enforce_storage_secret_mount_only!(apps)

# 複数 Application 間でコンポーネント名（Deployment / StatefulSet / CronJob / Service / PDB 名）が衝突していないか確認する
all_comp_entries = []
deployment_entries = []
statefulset_entries = []
apps.each do |app|
  app_name = app["metadata"]["name"]
  safe_array(safe_dig(app, "spec", "components")).each do |comp|
    entry = { app: app, app_name: app_name, comp: comp, comp_name: comp["name"] }
    all_comp_entries << entry
    if DEPLOYMENT_COMPONENT_TYPES.include?(comp["type"])
      deployment_entries << entry
    elsif comp["type"] == "statefulset"
      statefulset_entries << entry
    end
  end
end

dup_comps = all_comp_entries.group_by { |e| e[:comp_name] }.select { |_, v| v.size > 1 }.keys
unless dup_comps.empty?
  abort "複数の Application で同じコンポーネント名が重複しています: #{dup_comps.map { |n| redact_secret_label(n) }.join(', ')}"
end

companion_rwo_pvcs = companions.select do |r|
  r["kind"] == "PersistentVolumeClaim" && (safe_array(safe_dig(r, "spec", "accessModes")) & RWO_ACCESS_MODES).any?
end.map { |r| r["metadata"]["name"] }.to_set

rwo_entries = deployment_entries.select { |e| component_has_rwo_pvc?(e[:comp], dev_pvc_rwo, companion_rwo_pvcs) }
labeled_entries = SINGLE_REPLICA ? (deployment_entries - rwo_entries) : []
single_entries = rwo_entries + labeled_entries
single_names = single_entries.map { |e| e[:comp_name] }
multi_entries = deployment_entries - single_entries
multi_names = multi_entries.map { |e| e[:comp_name] }

dropped_single_hpas = []
single_entries.each do |e|
  comp = e[:comp]
  comp["properties"].delete("replicas") if comp["properties"].is_a?(Hash)
  upsert_trait!(comp, "scaler", { "replicas" => 1 })
  upsert_trait!(comp, "k8s-update-strategy", { "targetKind" => "Deployment", "strategy" => { "type" => "Recreate" } })
  removed = remove_traits!(comp, %w[hpa cpuscaler])
  removed.each { |t| dropped_single_hpas << "#{e[:comp_name]} (#{t['type']} trait)" }
end

replaced_dev_hpa_traits = []
multi_entries.each do |e|
  comp = e[:comp]
  removed = remove_traits!(comp, %w[hpa cpuscaler])
  removed.each { |t| replaced_dev_hpa_traits << "#{e[:comp_name]} (#{t['type']} trait)" }
  ensure_hostname_spread_trait!(comp, e[:app_name], e[:comp_name])
end

base = File.join(OUT, "base")
prod = File.join(OUT, "overlays", "production")
overlay = File.join(prod, "kustomization.yaml")
hpa_path = File.join(prod, "hpa.yaml")
pdb_path = File.join(prod, "pdb.yaml")
ingress_path = File.join(prod, "ingress.yaml")
es_path = File.join(prod, "external-secret.yaml")

# 既存または初回生成される overlays/production/hpa.yaml の対象 Deployment を確定し、
# 該当コンポーネントの scaler trait 除去 + Application の hpa-replicas-apply-once policy を適用する。
HPA_MIN = 2
HPA_MAX = 5
HPA_CPU = 70

will_create_hpa = !File.exist?(overlay) && multi_names.any? && !File.exist?(hpa_path)
file_hpa_targets =
  if File.exist?(hpa_path)
    safe_load_yaml_docs(File.read(hpa_path, encoding: "UTF-8")).filter_map do |doc|
      next nil unless doc.is_a?(Hash) && (safe_dig(doc, "spec", "scaleTargetRef", "kind") || "Deployment") == "Deployment"

      non_empty_str(safe_dig(doc, "spec", "scaleTargetRef", "name"))
    end
  elsif will_create_hpa
    multi_names.dup
  else
    []
  end

scaled = file_hpa_targets.uniq & multi_names
scaled_set = scaled.to_set

multi_entries.each do |e|
  next unless scaled_set.include?(e[:comp_name])

  e[:comp]["properties"].delete("replicas") if e[:comp]["properties"].is_a?(Hash)
  remove_traits!(e[:comp], %w[scaler])
end

apps.each do |app|
  scaled_in_app = multi_entries.select { |e| e[:app].equal?(app) && scaled_set.include?(e[:comp_name]) }
                               .map { |e| e[:comp_name] }
  upsert_hpa_apply_once_policy!(app, scaled_in_app) unless scaled_in_app.empty?
end

# ---------------------------------------------------------------------------
# ファイル出力（すべての検査・変換が完了してから書き出す）
# ---------------------------------------------------------------------------

FileUtils.mkdir_p(base)
FileUtils.mkdir_p(prod)

app_file = File.join(base, "application.yaml")
res_file = File.join(base, "resources.yaml")
base_resources = []

if apps.any?
  File.write(app_file, apps.map { |a| yaml_doc(deep_copy(a)) }.join("---\n"))
  base_resources << "application.yaml"
else
  FileUtils.rm_f(app_file)
end

if companions.any?
  File.write(res_file, companions.map { |r| yaml_doc(deep_copy(r)) }.join("---\n"))
  base_resources << "resources.yaml"
else
  FileUtils.rm_f(res_file)
end

base_kust_header = <<~YAML
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization

  # NOTE: このディレクトリは KubeVela / VelaUX の dev 環境から昇格されたものです。
  #       base/application.yaml（および補助 base/resources.yaml）は再昇格のたびに上書きされます。
  #       環境固有の調整は overlays/production/ 側で行ってください。
YAML
File.write(File.join(base, "kustomization.yaml"), base_kust_header + yaml_doc({ "resources" => base_resources }))

# Pod Security Admission (enforce: baseline, warn/audit: restricted)
File.write(File.join(prod, "namespace.yaml"),
           yaml_doc({
                      "apiVersion" => "v1",
                      "kind" => "Namespace",
                      "metadata" => {
                        "name" => "prod-#{APP}",
                        "labels" => {
                          "wax100.io/environment" => "production",
                          "pod-security.kubernetes.io/enforce" => "baseline",
                          "pod-security.kubernetes.io/warn" => "restricted",
                          "pod-security.kubernetes.io/audit" => "restricted"
                        }
                      }
                    }))

# VelaUX Production (GitOps Read-Only) 同期用 ConfigMap（毎回冪等に書き出す）
File.write(File.join(prod, "velaux-sync.yaml"), velaux_sync_yaml)

notes = []
overlay_extra = []

notes << "- VelaUX の **Production (GitOps Read-Only)** プロジェクトへ自動登録されます" \
         "（`overlays/production/velaux-sync.yaml`: `tg-local-prod-#{APP}` / `ev-prod-#{APP}`）。"

unless rewritten.empty?
  notes << ("- **接続先のホスト名を書き換えました**（dev Namespace 宛ての FQDN を同一 Namespace 内の短縮名へ統一）: " +
            rewritten.uniq.map { |from, to| "`#{from}` → `#{to}`" }.join(", "))
end

unless $synthesized_expose_services.empty?
  notes << "- **dev の Ingress 系 trait (`gateway` / `ingress-1-20`) を除去し、代わりに ClusterIP の `expose` trait で公開ポートを補完しました**" \
           "（#{$synthesized_expose_services.uniq.map { |s| "`#{s}`" }.join(', ')}）。本番 Ingress の転送先 Service を維持するためです。"
end
unless $updated_component_expose_ports.empty?
  notes << "- **dev の Ingress 系 trait (`gateway` / `ingress-1-20`) を除去し、コンポーネントの `ports[].expose: true` に公開ポートを補完しました**" \
           "（#{$updated_component_expose_ports.uniq.map { |s| "`#{s}`" }.join(', ')}）。既存の Component Service と衝突させずに本番 Ingress の転送先を維持するためです。"
end

unless $stripped_external_revisions.empty?
  notes << "- dev の `externalRevision` 指定を外しました（#{$stripped_external_revisions.uniq.map { |s| "`#{s}`" }.join(', ')}）。"
end

unless $forced_secret_mount_only.empty?
  notes << "- **`storage.secret` に `mountOnly: true` を設定しました**（#{$forced_secret_mount_only.uniq.map { |s| "`#{s}`" }.join(', ')}）。" \
           "本番 Secret の作成は ExternalSecret に一元化します。"
end

# --- 公開用 Ingress（初回のみ生成） ---
web_candidates = collect_web_candidates(apps, dev_service_ports)
web = pick_web_service(web_candidates)
should_generate_ingress = $dev_has_ingress || PUBLIC_INGRESS

if web
  _score, svc_name, svc_port = web
  if !File.exist?(ingress_path) && should_generate_ingress
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
  if File.exist?(ingress_path)
    notes << "- 公開 URL: `https://#{APP}.#{APPS_DOMAIN}`（`#{svc_name}:#{svc_port}` へ転送）"
  else
    src_ns_hint = SOURCE_NAMESPACE.empty? ? "<dev の Namespace>" : SOURCE_NAMESPACE
    notes << "- dev に Ingress / gateway trait が無く `wax100.io/public=true` ラベルも付いていないため、本番 Ingress は自動生成していません。" \
             "外部公開する場合は `kubectl label ns #{src_ns_hint} wax100.io/public=true` を付けて再昇格するか、" \
             "`overlays/production/ingress.yaml` を手で追加してください。"
  end
elsif !File.exist?(ingress_path)
  if should_generate_ingress
    notes << "- Ingress の転送先になる TCP Service が見つからなかったため、Ingress は生成していません。公開が必要なら手で追加してください。"
  else
    notes << "- dev に Ingress / gateway trait が無く `wax100.io/public=true` ラベルも付いていないため、本番 Ingress は自動生成していません。公開が必要なら手で追加してください。"
  end
end
overlay_extra << "ingress.yaml" if File.exist?(ingress_path)

unless $dev_ingress_hosts.empty?
  notes << "- dev の Ingress / gateway ホスト（#{$dev_ingress_hosts.uniq.map { |h| "`#{redact_secret_label(h)}`" }.join(', ')}）は持ち込んでいません。" \
           "本番は `overlays/production/ingress.yaml` のホストで公開されます。"
end

# --- ExternalSecret の雛形（初回のみ生成） ---
secret_refs, optional_only_secrets = collect_secret_refs(apps, companions)

if secret_refs.any?
  secret_notes = []
  taken = Set.new
  blocks = secret_refs.keys.sort.map { |name| external_secret_for(name, secret_refs[name], taken, secret_notes) }

  unless File.exist?(es_path)
    header = <<~YAML
      # 昇格時に自動生成された雛形です（Secret の値は読んでいません。
      # Application / ServiceAccount が参照している Secret 名とキーだけから組み立てています）。
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
             "dev で参照する Secret が増えていないか確認してください（dev の参照: #{secret_refs.keys.sort.map { |n| "`#{n}`" }.join(', ')}）。"
  end
end
unless optional_only_secrets.empty?
  notes << "- 任意の Secret 参照（`optional: true` のみ）は ExternalSecret の生成から除外しました（" \
           "#{optional_only_secrets.map { |n| "`#{n}`" }.join(', ')}）。本番でも使う場合は `overlays/production/external-secret.yaml` に追加してください。"
end
overlay_extra << "external-secret.yaml" if File.exist?(es_path)

# --- HPA・PDB（初回のみ生成） ---
unless rwo_entries.empty?
  notes << "- **1 台で動かします**（#{rwo_entries.map { |e| "`#{e[:comp_name]}`" }.join(', ')}）。ReadWriteOnce の PVC を付けているため、" \
           "HPA を付けず、`scaler (replicas: 1)`・更新方法 `Recreate` にしました（更新時は数十秒止まります）。"
end
unless labeled_entries.empty?
  notes << "- **1 台で動かします**（#{labeled_entries.map { |e| "`#{e[:comp_name]}`" }.join(', ')}）。dev の Namespace に " \
           "`wax100.io/single-replica=true` が付いているため、HPA を付けず、`scaler (replicas: 1)`・更新方法 `Recreate` にしました" \
           "（更新時と Spot の回収時は数十秒〜数分止まります）。"
end
unless dropped_single_hpas.empty?
  notes << "- **1 台固定のコンポーネントに付いていた dev の HPA trait を除外しました**（#{dropped_single_hpas.map { |s| "`#{s}`" }.join(', ')}）。"
end
unless replaced_dev_hpa_traits.empty?
  notes << "- **dev の `hpa` / `cpuscaler` trait を外し、本番は `overlays/production/hpa.yaml` に統一しました**" \
           "（#{replaced_dev_hpa_traits.map { |s| "`#{s}`" }.join(', ')}）。"
end

if will_create_hpa
  hpas = multi_names.map do |name|
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
    # 最小・最大・目標値は自由に変えてよい。Application 側には hpa-replicas-apply-once
    # ポリシーが付与されているため、vela-core の定期 StateKeep が台数を巻き戻さない。
  HEAD
end
overlay_extra << "hpa.yaml" if File.exist?(hpa_path)

multi_sts_entries = statefulset_entries.select { |e| component_scaler_replicas(e[:comp]) >= 2 }
pdb_entries = multi_entries + multi_sts_entries

if !File.exist?(overlay) && pdb_entries.any? && !File.exist?(pdb_path)
  pdbs = pdb_entries.map do |e|
    yaml_doc({
      "apiVersion" => "policy/v1",
      "kind" => "PodDisruptionBudget",
      "metadata" => { "name" => e[:comp_name] },
      "spec" => {
        "minAvailable" => 1,
        "selector" => {
          "matchLabels" => {
            "app.oam.dev/name" => e[:app_name],
            "app.oam.dev/component" => e[:comp_name]
          }
        }
      }
    })
  end
  File.write(pdb_path, <<~HEAD + pdbs.join("---\n"))
    # 昇格時に自動生成（初回のみ）。Spot ノードの入れ替えやメンテナンスでも最低 1 台を残す。
    # replicas: 1 に戻すときは、ドレインが詰まらないようこの定義も外すこと。
  HEAD
end
overlay_extra << "pdb.yaml" if File.exist?(pdb_path)

conflicting_hpa = file_hpa_targets.uniq & single_names
unless conflicting_hpa.empty?
  notes << "- **HPA が 1 台でしか動かせない Deployment を指しています**（#{conflicting_hpa.map { |n| "`#{n}`" }.join(', ')}）。" \
           "`overlays/production/hpa.yaml` から外してください。"
end
missing_hpa = multi_names - scaled
if File.exist?(overlay) && missing_hpa.any?
  notes << "- HPA が無い Deployment コンポーネントがあります（#{missing_hpa.map { |n| "`#{n}`" }.join(', ')}）。" \
           "負荷で台数を変えるなら `overlays/production/hpa.yaml` に追加してください。"
end

file_pdb_names =
  if File.exist?(pdb_path)
    safe_load_yaml_docs(File.read(pdb_path, encoding: "UTF-8")).filter_map do |doc|
      non_empty_str(safe_dig(doc, "metadata", "name")) if doc.is_a?(Hash) && doc["kind"] == "PodDisruptionBudget"
    end
  else
    []
  end
pdb_eligible_names = pdb_entries.map { |e| e[:comp_name] }
active_pdbs = file_pdb_names.uniq & pdb_eligible_names
conflicting_pdb = file_pdb_names.uniq & single_names
unless conflicting_pdb.empty?
  notes << "- **PodDisruptionBudget が 1 台でしか動かせない Deployment に残っています**（#{conflicting_pdb.map { |n| "`#{n}`" }.join(', ')}）。" \
           "ノードのドレインが止まるため、`overlays/production/pdb.yaml` から外してください。"
end
missing_pdb = pdb_eligible_names - active_pdbs
if File.exist?(overlay) && missing_pdb.any?
  notes << "- PodDisruptionBudget が無い複数台コンポーネントがあります（#{missing_pdb.map { |n| "`#{n}`" }.join(', ')}）。" \
           "ノード入れ替え時の瞬断を防ぐため `overlays/production/pdb.yaml` への追加を検討してください。"
end

if scaled.any?
  notes << "- **本番は HPA（`overlays/production/hpa.yaml`）で台数が変わります**（#{scaled.map { |n| "`#{n}`" }.join(', ')}。" \
           "初回生成の既定は最小 #{HPA_MIN} / 最大 #{HPA_MAX} / 目標 CPU #{HPA_CPU}%）。Application に `hpa-replicas-apply-once` を付与済みです。"
end
if active_pdbs.any?
  notes << "- **PodDisruptionBudget で最低 1 台を維持します**（#{active_pdbs.map { |n| "`#{n}`" }.join(', ')}: `minAvailable: 1`）。" \
           "調整は `overlays/production/pdb.yaml` で。"
end

unscaled_targets = multi_entries.select { |e| scaled_set.include?(e[:comp_name]) && component_missing_cpu_request?(e[:comp]) }
                                .map { |e| "#{e[:app_name]}/#{e[:comp_name]}" }
unless unscaled_targets.empty?
  notes << "- **CPU の requests が無いコンポーネントがあります**（#{unscaled_targets.join(', ')}）。" \
           "このままでは HPA が CPU 使用率を計算できず、台数が変わりません。dev の Application または overlay で CPU を指定してください。"
end

# --- 持ち込まなかったもの / 変えたもの ---
unless $dropped_externalname_services.empty?
  notes << "- **ExternalName 型の expose trait を除外しました**（#{$dropped_externalname_services.uniq.map { |n| "`#{n}`" }.join(', ')}）。" \
           "本番ではクラスタ外・他 Namespace への暗黙の転送（ExternalName）を禁止しています。"
end

unless $downgraded_services.empty?
  notes << "- **Service 公開種別を ClusterIP に変えました**（" \
           "#{$downgraded_services.uniq.map { |n, t| "`#{n}`: #{t}" }.join(', ')}）。" \
           "本番の入口は Cloudflare Tunnel → ingress-nginx だけです。LoadBalancer は外部 LB を作ります。"
end

other_dropped = $dropped.reject { |k, _| k == "Ingress" }
unless other_dropped.empty?
  dropped_line = "- 昇格の対象外として除外（KubeVela Application 管理外のリソース）: " +
                 other_dropped.map { |k, names| "#{k.empty? ? '(kind 無し)' : redact_secret_label(k)} (#{names.select { |n| non_empty_str(n) }.map { |n| redact_secret_label(n) }.join(', ')})" }.join(" / ")
  if $dropped.key?("NetworkPolicy")
    dropped_line += "。NetworkPolicy は持ち込んでいません。本番で許可が必要な通信は、レビューのうえで overlays/production に NetworkPolicy を手で追加してください"
  end
  notes << dropped_line
end

# --- ConfigMap の警告 ---
cms = companions.select { |r| r["kind"] == "ConfigMap" }
storage_cms = apps.flat_map do |app|
  safe_array(safe_dig(app, "spec", "components")).flat_map do |comp|
    safe_array(comp["traits"]).select { |t| t.is_a?(Hash) && t["type"] == "storage" }.flat_map do |t|
      safe_array(safe_dig(t, "properties", "configMap")).filter_map do |cm|
        "#{comp['name']}/#{non_empty_str(cm['name']) || '(configMap)'}" if cm.is_a?(Hash) && cm["data"].is_a?(Hash) && !cm["data"].empty?
      end
    end
  end
end
all_cm_names = cms.map { |c| c["metadata"]["name"] } + storage_cms
if all_cm_names.any?
  notes << "- **ConfigMap が中身ごとコミットされます**（#{all_cm_names.join(', ')}）。" \
           "機密が混ざっていないかレビューで確認してください。混ざっている場合は Secret に移し、" \
           "`overlays/production/external-secret.yaml` 経由で渡してください。"
end

# --- env の平文の警告 ---
env_plain = apps.flat_map do |app|
  app_name = app["metadata"]["name"]
  safe_array(safe_dig(app, "spec", "components")).filter_map do |comp|
    names = []
    safe_array(safe_dig(comp, "properties", "env")).each do |e|
      names << e["name"] if e.is_a?(Hash) && e["name"].is_a?(String) && non_empty_str(e["value"])
    end
    safe_array(comp["traits"]).each do |t|
      next unless t.is_a?(Hash) && t["properties"].is_a?(Hash)

      tp = t["properties"]
      case t["type"]
      when "env"
        tp["env"].each { |k, v| names << k.to_s if non_empty_str(v) } if tp["env"].is_a?(Hash)
        safe_array(tp["containers"]).each do |c|
          c["env"].each { |k, v| names << k.to_s if non_empty_str(v) } if c.is_a?(Hash) && c["env"].is_a?(Hash)
        end
      when "init-container", "sidecar"
        safe_array(tp["env"]).each do |e|
          names << e["name"] if e.is_a?(Hash) && e["name"].is_a?(String) && non_empty_str(e["value"])
        end
      end
    end
    names.uniq!
    next nil if names.empty?

    "`Application/#{app_name}/#{comp['name']}`（#{names.map { |n| "`#{n}`" }.join(', ')}）"
  end
end
if env_plain.any?
  notes << "- **env の値が平文のままコミットされます**（変数名のみ記載: #{env_plain.join('、')}）。" \
           "値はそのまま Git に入ります。機密が混ざっていないかレビューで確認してください。" \
           "混ざっている場合は Secret に移し、`overlays/production/external-secret.yaml` 経由で渡してください。"
end

# --- PVC / ストレージの警告 ---
pvcs = companions.select { |r| r["kind"] == "PersistentVolumeClaim" }.map { |p| p["metadata"]["name"] }
trait_pvcs = apps.flat_map do |app|
  safe_array(safe_dig(app, "spec", "components")).flat_map do |comp|
    safe_array(comp["traits"]).flat_map do |t|
      next [] unless t.is_a?(Hash) && t["properties"].is_a?(Hash)

      if t["type"] == "storage"
        safe_array(t["properties"]["pvc"]).filter_map { |p| "#{comp['name']}/#{p['name']}" if p.is_a?(Hash) && non_empty_str(p["name"]) }
      elsif t["type"] == "pvc"
        cn = non_empty_str(t["properties"]["claimName"])
        cn ? ["#{comp['name']}/#{cn}"] : []
      else
        []
      end
    end
  end
end
unless $manual_pvcs.empty?
  notes << "- **PVC の StorageClass を既定に変えました**（#{$manual_pvcs.uniq.map { |n| "`#{n}`" }.join(', ')}）。" \
           "本番ではクラスタ既定の Persistent Disk が割り当てられます。"
end
storage_items = (pvcs + trait_pvcs).uniq
if storage_items.any?
  notes << "- **永続ボリューム（PVC）があります**（#{storage_items.join(', ')}）。" \
           "定義だけが昇格され、中身は空で作られます。データ移行が要る場合は別途。" \
           "容量や StorageClass を本番だけ変えるときは `overlays/production` でパッチを当ててください" \
           "（作成後の PVC は容量の拡張しかできません）。"
end

# --- overlay の kustomization（初回のみ生成） ---
# NOTE: top-level の `namespace: prod-<app>` は書かない。書くと velaux-sync.yaml
#       (`namespace: velaux-store`) の namespace まで prod-<app> に上書きされるため、
#       `unsetOnly: true` の組み込み NamespaceTransformer を使用する。
unless File.exist?(overlay)
  overlay_res = ["namespace.yaml", "../../base", "velaux-sync.yaml", *overlay_extra]
  res_yaml = overlay_res.map { |r| "  - #{r}" }.join("\n")
  File.write(overlay, <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization

    resources:
    #{res_yaml}

    # NOTE: top-level の namespace: は設定しない。設定すると velaux-sync.yaml
    #       (namespace: velaux-store) まで prod-#{APP} に書き換わってしまうため、
    #       unsetOnly: true の NamespaceTransformer で namespace 未設定リソースのみ prod-#{APP} に設定する。
    #       本番固有の差分（リソース、HPA、PVC 容量など）はこのファイルに追記する（再昇格で上書きしない）。
    transformers:
      - |-
        apiVersion: builtin
        kind: NamespaceTransformer
        metadata:
          name: set-prod-namespace
          namespace: prod-#{APP}
        unsetOnly: true
        setRoleBindingSubjects: none
  YAML
end

File.write(NOTES, "#{notes.join("\n")}\n") if NOTES && !notes.empty?

puts "generated #{OUT} (#{apps.size} applications, #{companions.size} companion resources, #{secret_refs.size} secret refs)"
