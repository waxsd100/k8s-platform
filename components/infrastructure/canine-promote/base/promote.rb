#!/usr/bin/env ruby
# frozen_string_literal: true

# Canine が dev Namespace にデプロイした実体を、
# components/apps/<app>/{base,overlays/production} の形に整形する。
#
# 入力 : STDIN に kubectl get ... -o yaml (List)
# 引数 : APP=アプリ名（dev の Namespace dev-<app> から dev- を外したもの）
#        SOURCE_NAMESPACE=アプリの dev の Namespace
#        ADDON_NAMESPACES=一緒に持ち込むアドオンの Namespace（空白区切り。addons.rb が決める）
#        OUT=出力先ディレクトリ  NOTES=PR 本文に差し込むメモの出力先
#        APPS_DOMAIN=公開ドメイン (既定 wax100.io)
#        SINGLE_REPLICA=true なら Deployment をすべて 1 台で動かす（dev の Namespace に
#                       ラベル wax100.io/single-replica=true。Discord の BOT のように 2 台同時に
#                       動くと壊れるアプリ用）
#
# 生成物:
#   base/resources.yaml                      dev の実体（再昇格で上書きする）
#   base/kustomization.yaml
#   overlays/production/kustomization.yaml   初回のみ。以降は人が書いた内容を尊重する
#   overlays/production/namespace.yaml
#   overlays/production/ingress.yaml         初回のみ。<app>.<APPS_DOMAIN> で公開する
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
ADDON_NAMESPACES = ENV["ADDON_NAMESPACES"].to_s.split.freeze
SINGLE_REPLICA = ENV["SINGLE_REPLICA"].to_s == "true"

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

# APP は dev Namespace 名の一部で、Kubernetes が DNS ラベルとして検証済みのはず。
# それでも生成物の Namespace 名 (prod-<APP>) やホスト名に埋め込むので、ここでも確かめる。
# prod- を付けて 63 文字に収まる長さまでに限る。
unless APP.match?(/\A[a-z0-9]([-a-z0-9]{0,56}[a-z0-9])?\z/)
  abort "APP が Namespace 名として不正です: #{APP.inspect}"
end

if !SOURCE_NAMESPACE.empty? && (!SOURCE_NAMESPACE.match?(DNS_LABEL_RE) || SOURCE_NAMESPACE.match?(RESERVED_NS_RE))
  abort "システム・プラットフォーム・本番または不正な Namespace は昇格の元にできません: #{SOURCE_NAMESPACE}"
end

bad_addons = ADDON_NAMESPACES.select { |ns| !ns.match?(DNS_LABEL_RE) || ns.match?(RESERVED_NS_RE) }
unless bad_addons.empty?
  abort "システム・プラットフォーム・本番または不正な Namespace はアドオンとして昇格できません: #{bad_addons.join(', ')}"
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

# Kyverno の generate ルール（clusterpolicy-environment-isolation.yaml）が配る NetworkPolicy。
# ラベルでも弾くが、ラベルが欠けた入力でも本番に dev-to-dev 等を持ち込まないよう名前でも防ぐ。
KYVERNO_NETWORK_POLICIES = %w[
  environment-isolation
  dev-access-relay
  dev-to-dev
  deny-cloudsql-egress
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

# Bound 済みの PVC にコントローラやスケジューラが付ける動的な注釈。残したまま volumeName だけ消すと
# 本番で Lost になったり、dev の Spot ノードへの割り当て（selected-node）を引きずったりする。
VOLATILE_ANNO_PREFIX = /\A(pv|volume\.beta|volume)\.kubernetes\.io\//

# 新しい Namespace では再採番・空作成されるため持ち込まない
VOLATILE_SPEC = {
  "Service" => %w[clusterIP clusterIPs ipFamilies ipFamilyPolicy healthCheckNodePort].freeze,
  "PersistentVolumeClaim" => %w[volumeName dataSource dataSourceRef].freeze
}.freeze

# 本番の入口は Cloudflare Tunnel → ingress-nginx だけ。Service を外に出す設定は
# 持ち込まない（LoadBalancer は GCP に外部 LB を作り、Access を通らない入口と
# 固定費ができる）。type は ClusterIP に落とす。
EXTERNAL_SERVICE_FIELDS = %w[
  loadBalancerIP loadBalancerSourceRanges loadBalancerClass
  allocateLoadBalancerNodePorts externalTrafficPolicy externalIPs
].freeze

WORKLOAD_KINDS = %w[Deployment StatefulSet DaemonSet Job CronJob Pod].freeze

$dropped = Hash.new { |h, k| h[k] = [] } # kind => [name]
$downgraded_services = []                 # [name, 元の type]
$dev_ingress_hosts = []
$manual_pvcs = []

def non_empty_str(val)
  val.is_a?(String) && !val.empty? ? val : nil
end

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

def clean(obj)
  return nil unless obj.is_a?(Hash)

  kind = obj["kind"]
  meta = obj["metadata"].is_a?(Hash) ? obj["metadata"] : {}
  name = meta["name"]

  unless ALLOWED_KINDS.include?(kind)
    $dropped[kind.to_s] << name
    Array(obj.dig("spec", "rules")).each { |r| $dev_ingress_hosts << r["host"] if r.is_a?(Hash) && r["host"] } if kind == "Ingress"
    return nil
  end
  # 他リソースが所有しているもの（Deployment が作った ReplicaSet、CronJob が作った Job など）は
  # 親から再生成されるので持ち込まない。許可リストの kind はどれも通常は所有者を持たない。
  return nil if meta.key?("ownerReferences") && !Array(meta["ownerReferences"]).empty?
  # Kubernetes や Kyverno が各 Namespace に自動生成するものは持ち込まない
  # （アドオンと名前が衝突して落ちるほか、dev 用の NetworkPolicy が本番に混入するのを防ぐ）
  return nil if kind == "ServiceAccount" && name == "default"
  return nil if kind == "ConfigMap" && name == "kube-root-ca.crt"
  return nil if kyverno_managed?(meta)
  return nil if kind == "NetworkPolicy" && KYVERNO_NETWORK_POLICIES.include?(name)

  obj.delete("status")
  VOLATILE_META.each { |k| meta.delete(k) }
  if (anno = meta["annotations"]).is_a?(Hash)
    VOLATILE_ANNO.each { |k| anno.delete(k) }
    anno.delete_if { |k, _| k.to_s.match?(VOLATILE_ANNO_PREFIX) }
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

def pod_spec_for(resource)
  return nil unless resource.is_a?(Hash)

  case resource["kind"]
  when "Pod"
    resource["spec"]
  when "CronJob"
    resource.dig("spec", "jobTemplate", "spec", "template", "spec")
  when "Deployment", "StatefulSet", "DaemonSet", "Job"
    resource.dig("spec", "template", "spec")
  end
end

# ---------------------------------------------------------------------------
# 参照している Secret を集める
# ---------------------------------------------------------------------------

# Pod テンプレートを持つリソースと ServiceAccount から、必須で参照している Secret の
# 名前とキーを集める。Secret 本体は読まない（RBAC 上も読めない）。参照だけを見て雛形を作る。
# optional: true だけの参照は除外する（上流の Helm チャートが持つ任意の Secret まで必須の
# ExternalSecret にすると、Secret Manager にダミーを入れない限り同期エラーになるため）。
# 同じ Secret・キーが必須と任意の両方で参照されていれば必須として扱う。
#   keys  : 特定のキーだけ使っている
#   whole : Secret を丸ごと使っている（envFrom / volume）
#   pull  : イメージ取得用（imagePullSecrets）。型が kubernetes.io/dockerconfigjson である必要がある
def collect_secret_refs(resources)
  refs = Hash.new { |h, k| h[k] = { keys: [], whole: false, pull: false } }
  optional_seen = Set.new

  pod_specs = resources.filter_map { |r| pod_spec_for(r) }

  pod_specs.each do |spec|
    next unless spec.is_a?(Hash)

    Array(spec["imagePullSecrets"]).each do |s|
      next unless s.is_a?(Hash)

      sname = non_empty_str(s["name"])
      refs[sname][:pull] = true if sname
    end

    containers = Array(spec["containers"]) + Array(spec["initContainers"])
    containers.each do |c|
      next unless c.is_a?(Hash)

      Array(c["env"]).each do |e|
        next unless e.is_a?(Hash)

        ref = e.dig("valueFrom", "secretKeyRef")
        next unless ref.is_a?(Hash)

        sname = non_empty_str(ref["name"])
        skey = non_empty_str(ref["key"])
        next unless sname && skey

        if ref["optional"] == true
          optional_seen << sname
        else
          refs[sname][:keys] << skey
        end
      end

      Array(c["envFrom"]).each do |e|
        next unless e.is_a?(Hash)

        sref = e["secretRef"]
        next unless sref.is_a?(Hash)

        sname = non_empty_str(sref["name"])
        next unless sname

        if sref["optional"] == true
          optional_seen << sname
        else
          refs[sname][:whole] = true
        end
      end
    end

    Array(spec["volumes"]).each do |v|
      next unless v.is_a?(Hash)

      secret_sources = []
      if (vs = v["secret"]).is_a?(Hash)
        secret_sources << {
          "name" => vs["secretName"],
          "items" => vs["items"],
          "optional" => vs["optional"]
        }
      end
      Array(v.dig("projected", "sources")).each do |src|
        secret_sources << src["secret"] if src.is_a?(Hash) && src["secret"].is_a?(Hash)
      end

      secret_sources.each do |s|
        sname = non_empty_str(s["name"])
        next unless sname

        if s["optional"] == true
          optional_seen << sname
          next
        end

        if s["items"].is_a?(Array) && !s["items"].empty?
          valid_keys = s["items"].filter_map { |i| non_empty_str(i["key"]) if i.is_a?(Hash) }
          refs[sname][:keys].concat(valid_keys) unless valid_keys.empty?
        else
          refs[sname][:whole] = true
        end
      end
    end
  end

  # ServiceAccount に付いた imagePullSecrets は、その SA を使う Pod すべてに効く。
  # NOTE: SA の `secrets` (mountable secrets) は見ない。古いクラスタが自動生成した
  #       トークン Secret で、外部から与えるものではない。
  resources.select { |r| r["kind"] == "ServiceAccount" }.each do |sa|
    Array(sa["imagePullSecrets"]).each do |s|
      next unless s.is_a?(Hash)

      sname = non_empty_str(s["name"])
      refs[sname][:pull] = true if sname
    end
  end

  refs.each_value { |v| v[:keys].uniq! }
  [refs, (optional_seen - refs.keys).sort]
end

# Secret Manager のシークレット ID。使える文字は [A-Za-z0-9_-]、長さは 255 まで。
# 大文字・小文字・アンダースコアはそのまま残す（DB_PASSWORD と db_password を区別する）。
# それ以外の文字（Secret 名やキーに入りうるのは '.'）だけを '-' にする。
# 置き換えやハイフン境界の移動で衝突したとき、長すぎるときは、タプル全体のハッシュを付けて一意にする。
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
  prefix = "prod-#{APP}-"
  base_id = "#{prefix}#{body}"

  id = base_id
  if body.empty? || taken.include?(id) || id.length > SECRET_ID_MAX
    stem = body.empty? ? "prod-#{APP}" : base_id
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
# YAML の出力（Prettier の 2 スペース配列インデント・クォート規則に揃える）
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
           digits = (r.numerator * (5**[a - b, 0].max) * (2**[b - a, 0].max)).to_s.rjust(k, "0").sub(/0+\z/, "")
           ".#{digits}"
         else
           format(".%09d", t.nsec).sub(/\.?0+\z/, "")
         end
  "#{base_ts}#{frac}#{tz}"
end

# 値を文字列展開で YAML に埋め込まない。真偽値や数値に解釈されうる文字列（`yes` / `true` /
# `y` / `123` など）や制御文字・Unicode 改行は確実にクォート・エスケープし、
# Psych (`safe_load`) の往復と Prettier (`--check`) の両方に完全一致させる。
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
      abort "YAML の出力マッピングキーが衝突しています: #{k.inspect}" if seen_out_id[out_kid]
      seen_out_id[out_kid] = true
      key_s = if k.is_a?(String)
                k_str = out_kid[1]
                k_str == "<<" && (v.is_a?(Hash) || v.is_a?(Array)) ? '!!str "<<"' : yaml_scalar(k_str, indent, allow_block: false)
              else
                yaml_scalar(k, indent, allow_block: false)
              end
      abort "YAML の出力マッピングキーが衝突しています: #{key_s}" if seen_out_ks[key_s]
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
# アドオン（別の Namespace の DB など）を同じ Namespace にまとめる
# ---------------------------------------------------------------------------

DNS_LABEL_PART = "[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?"
# 通常の Service (<svc>) と Headless StatefulSet の Pod DNS (<pod>.<svc>) の両方を捉える
SVC_PREFIX_RE = "(#{DNS_LABEL_PART}(?:\\.#{DNS_LABEL_PART})?)"
SVC_SUFFIX_RE = "\\.svc(?:\\.cluster\\.local)?\\.?"

# dev ではアプリとアドオンが別の Namespace に居るので、アプリは DB を
# <Service>.<アドオンの Namespace>(.svc(.cluster.local)) で指している。本番は全部 prod-<app> に入るので、
# Namespace の部分を外して <Service>（Headless の Pod DNS なら <Pod>.<Service>）にする。
#   - 対象は ConfigMap の data と、ワークロードの env[].value の文字列だけ（image / command / args 等は触らない）
#   - アプリ自身の Namespace（SOURCE_NAMESPACE）は、server.db や foo.app のような拡張子を壊さないよう
#     .svc(.cluster.local) が付いているときだけ書き換える
#   - アドオンの Namespace（<SOURCE_NAMESPACE>-*）は省略形も書き換えるが、ファイルパス（/backups/dump.myapp-pg）や
#     外部ドメイン（pg.myapp-pg.example.com）、前方一致する別アドオン名を壊さないようホスト名の境界で厳密に判定する
def build_host_rewrite_regex(source_ns, addon_namespaces, app_name = APP)
  clean_addons = Array(addon_namespaces).map(&:to_s).reject(&:empty?).uniq
  clean_source = source_ns.to_s

  prefix_owners = [clean_source, app_name, "dev-#{app_name}"].reject(&:empty?).uniq
  bare_addons = clean_addons.select do |ns|
    prefix_owners.any? { |p| ns.start_with?("#{p}-") && ns.length > p.length + 1 }
  end.to_set

  all_namespaces = (clean_addons + [clean_source]).reject(&:empty?).uniq
  return nil if all_namespaces.empty?

  # 長い Namespace 名を先に並べて前方一致の取り違えを防ぎ、1 回の gsub で二重書き換えも防ぐ
  ns_branches = all_namespaces.sort_by { |ns| -ns.length }.map do |ns|
    if bare_addons.include?(ns)
      "#{Regexp.escape(ns)}(?:#{SVC_SUFFIX_RE})?"
    else
      "#{Regexp.escape(ns)}#{SVC_SUFFIX_RE}"
    end
  end

  /(?:\A|(?<=:\/\/)|(?<![A-Za-z0-9._\/\\-]))#{SVC_PREFIX_RE}\.(?:#{ns_branches.join('|')})(?![A-Za-z0-9._-])/
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

def rewrite_hosts(resources, source_ns, addon_namespaces, rewritten)
  pattern = build_host_rewrite_regex(source_ns, addon_namespaces)
  return resources unless pattern

  resources.each do |r|
    next unless r.is_a?(Hash)

    if r["kind"] == "ConfigMap" && r["data"].is_a?(Hash)
      r["data"] = r["data"].transform_values do |v|
        v.is_a?(String) ? rewrite_host_string(v, pattern, rewritten) : v
      end
    elsif WORKLOAD_KINDS.include?(r["kind"])
      spec = pod_spec_for(r)
      next unless spec.is_a?(Hash)

      (Array(spec["containers"]) + Array(spec["initContainers"])).each do |c|
        next unless c.is_a?(Hash) && c["env"].is_a?(Array)

        c["env"].each do |e|
          next unless e.is_a?(Hash) && e["value"].is_a?(String)

          e["value"] = rewrite_host_string(e["value"], pattern, rewritten)
        end
      end
    end
  end

  resources
end

# StatefulSet の volumeClaimTemplates から作られた PVC（<テンプレート名>-<StatefulSet 名>-<番号>）。
# 本番でも StatefulSet が作るので、単独の PVC としては持ち込まない
def statefulset_pvc_names(items)
  items.select { |i| i.is_a?(Hash) && i["kind"] == "StatefulSet" }.flat_map do |sts|
    sts_name = sts.dig("metadata", "name")
    next [] unless sts_name

    Array(sts.dig("spec", "volumeClaimTemplates")).filter_map do |t|
      tpl_name = t.is_a?(Hash) ? t.dig("metadata", "name") : nil
      /\A#{Regexp.escape("#{tpl_name}-#{sts_name}")}-\d+\z/ if tpl_name
    end
  end
end

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

def validate_yaml_scalar_node(s_node)
  case s_node.tag
  when nil, "!", "tag:yaml.org,2002:str", "!ruby/symbol", "!ruby/sym"
    true
  when "tag:yaml.org,2002:binary"
    s_node.value.gsub(/\s+/, "").unpack1("m0")
    true
  when "tag:yaml.org,2002:int"
    v = resolve_yaml_scalar_node(s_node)
    abort "YAML に不正な !!int 値が含まれています: #{s_node.value.inspect}" unless v.is_a?(Integer)
  when "tag:yaml.org,2002:float"
    v = resolve_yaml_scalar_node(s_node)
    abort "YAML に不正な !!float 値が含まれています: #{s_node.value.inspect}" unless v.is_a?(Float)
  when "tag:yaml.org,2002:bool"
    v = resolve_yaml_scalar_node(s_node)
    abort "YAML に不正な !!bool 値が含まれています: #{s_node.value.inspect}" unless v == true || v == false
  when "tag:yaml.org,2002:null"
    v = resolve_yaml_scalar_node(s_node)
    abort "YAML に不正な !!null 値が含まれています: #{s_node.value.inspect}" unless v.nil?
  when "tag:yaml.org,2002:timestamp"
    v = resolve_yaml_scalar_node(s_node)
    abort "YAML に不正な !!timestamp 値が含まれています: #{s_node.value.inspect}" unless v.is_a?(Time) || v.is_a?(Date)
  when "tag:yaml.org,2002:merge"
    abort "YAML に不正な !!merge 値が含まれています: #{s_node.value.inspect}" unless s_node.value == "<<"
  when "tag:yaml.org,2002:value"
    abort "YAML に不正な !!value 値が含まれています: #{s_node.value.inspect}" unless s_node.value == "="
  else
    abort "YAML に非対応のスカラタグが含まれています: #{s_node.tag}"
  end
end

def safe_load_yaml_docs(yaml_text)
  yaml_text = String.new(yaml_text, encoding: Encoding::UTF_8) if yaml_text.encoding == Encoding::ASCII_8BIT
  abort "YAML に不正な UTF-8 バイト列が含まれています" unless yaml_text.valid_encoding?
  Psych.parse_stream(yaml_text).children.map do |doc|
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
          abort "YAML に循環参照エイリアスが含まれています: *#{al}" if seen_al[al]
          seen_al[al] = true
          cur = anchors[al]
          abort "YAML に未定義のエイリアスが含まれています: *#{al}" unless cur
          abort "YAML に循環参照エイリアスが含まれています: *#{al}" if active_nodes[cur.object_id]
        end
        cur
      end

      visit_ast = lambda do |node, depth = 0|
        abort "YAML のネストが深すぎます" if depth > 64
        if node.is_a?(Psych::Nodes::Alias)
          target = unwrap_node.call(node)
          w = subtree_weight.fetch(target.object_id, 1)
          total_expanded += w
          abort "YAML のエイリアス展開数が上限を超えています" if total_expanded > 100_000
          next w
        end

        anc = node.respond_to?(:anchor) ? node.anchor : nil
        anchors[anc] = node if anc && !anc.empty?
        active_nodes[node.object_id] = true

        w = 1
        if node.is_a?(Psych::Nodes::Mapping)
          abort "YAML に非対応のマッピングタグが含まれています: #{node.tag}" if node.tag && node.tag != "tag:yaml.org,2002:map"
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
                  abort "YAML のマージキー << によりキーが衝突しています: #{mk.inspect}" if explicit_keys.key?(mk) || merged_keys.key?(mk)
                  merged_keys[mk] = true
                end
              end
            else
              abort "YAML に重複したマッピングキーが含まれています: #{k_val.inspect}" if explicit_keys.key?(kid)
              abort "YAML のマージキー << によりキーが衝突しています: #{k_val.inspect}" if merged_keys.key?(kid)
              explicit_keys[kid] = true
            end
          end
          mapping_keys[node.object_id] = explicit_keys.merge(merged_keys)
        elsif node.is_a?(Psych::Nodes::Sequence)
          abort "YAML に非対応のシーケンスタグが含まれています: #{node.tag}" if node.tag && node.tag != "tag:yaml.org,2002:seq"
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
        abort "YAML のノード展開数が上限を超えています" if total_expanded > 100_000
        w
      end

      visit_ast.call(doc_root)
    end
    stream = Psych::Nodes::Stream.new
    stream.children << doc
    deep_copy(YAML.safe_load(stream.to_yaml, permitted_classes: [Time, Date, Symbol], aliases: true))
  end
rescue Psych::Exception, StandardError, SystemStackError => e
  abort "YAML の解析に失敗しました: #{e.message}"
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

def deployment_pod_selector(deployment)
  sel = deployment.dig("spec", "selector")
  if sel.is_a?(Hash)
    ml = sel["matchLabels"]
    me = sel["matchExpressions"]
    result = {}
    result["matchLabels"] = deep_copy(ml) if ml.is_a?(Hash) && !ml.empty?
    if me.is_a?(Array) && !me.empty?
      copied_me = me.filter_map { |e| deep_copy(e) if e.is_a?(Hash) }
      result["matchExpressions"] = copied_me unless copied_me.empty?
    end
    return result unless result.empty?
  end

  tpl = deployment.dig("spec", "template", "metadata", "labels")
  tpl.is_a?(Hash) && !tpl.empty? ? { "matchLabels" => deep_copy(tpl) } : nil
end

# Spot ノード（apps-pool）は OPTIMIZE_UTILIZATION で 1 台に詰め込みやすいため、
# 複数レプリカの Deployment は可能な限り別ノードへ分散させる（1 ノードしかないときは同居を許す）。
# 既に kubernetes.io/hostname の制約があれば尊重し、重複して足さない。
def ensure_hostname_spread!(deployment)
  selector = deployment_pod_selector(deployment)
  return unless selector

  pod_spec = deployment.dig("spec", "template", "spec")
  return unless pod_spec.is_a?(Hash)

  raw_constraints = pod_spec["topologySpreadConstraints"]
  constraints = raw_constraints.is_a?(Array) ? raw_constraints : []
  return if constraints.any? { |c| c.is_a?(Hash) && c["topologyKey"] == "kubernetes.io/hostname" }

  pod_spec["topologySpreadConstraints"] = constraints + [{
    "maxSkew" => 1,
    "topologyKey" => "kubernetes.io/hostname",
    "whenUnsatisfiable" => "ScheduleAnyway",
    "labelSelector" => selector
  }]
end

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

# 入力はクラスタから取った YAML。任意のクラスを復元させないよう safe_load で読む。
# NOTE: YAML.safe_load_stream は Canine のイメージ (Ruby 3.3 / Psych 5.1) に無いので、
#       ドキュメントごとに 1 本のストリームへ入れ直して safe_load する
#       （Document 単体は to_yaml できない）。Date を許可するには require "date" が要る。
$stdin.set_encoding(Encoding::UTF_8)
docs = safe_load_yaml_docs($stdin.read)
items = docs.flat_map { |d| d.is_a?(Hash) && d["items"] ? d["items"] : [d] }.select { |i| i.is_a?(Hash) }

# 入力はアプリの Namespace と、アドオンの Namespace の分をつなげたもの。どこから来たかは clean の前に見る
source_of = ->(i) { i.dig("metadata", "namespace").to_s }
unknown = items.map(&source_of).uniq - [SOURCE_NAMESPACE, *ADDON_NAMESPACES, ""]
if !SOURCE_NAMESPACE.empty? && unknown.any?
  abort "想定していない Namespace のリソースが入力にあります: #{unknown.join(', ')}"
end

sts_pvcs = statefulset_pvc_names(items)
items = items.reject do |i|
  i["kind"] == "PersistentVolumeClaim" && sts_pvcs.any? { |re| re.match?(i.dig("metadata", "name").to_s) }
end

# Ingress の転送先は、clean で clusterIP を消す前の値で選ぶ。アドオン（DB など）の Service は選ばない
web_candidates = items.select do |i|
  meta = i["metadata"].is_a?(Hash) ? i["metadata"] : {}
  (SOURCE_NAMESPACE.empty? || source_of.call(i) == SOURCE_NAMESPACE) && i["kind"] == "Service" &&
    i.dig("spec", "clusterIP") != "None" && i.dig("spec", "type") != "ExternalName" &&
    !Array(meta["ownerReferences"]).any? && !kyverno_managed?(meta)
end

resources = items.filter_map { |i| clean(i) }

# アプリとアドオンで同じ kind・名前のものがあると、本番の 1 つの Namespace に入らない
duplicates = resources.group_by { |r| [r["kind"], r.dig("metadata", "name")] }.select { |_, v| v.size > 1 }.keys
unless duplicates.empty?
  abort "アプリとアドオンで名前が重なっています（#{duplicates.map { |k, n| "#{k}/#{n}" }.join(', ')}）。" \
        "本番では同じ Namespace に入るため、Canine でどちらかの名前を変えてください。"
end

rewritten = []
rewrite_hosts(resources, SOURCE_NAMESPACE, ADDON_NAMESPACES, rewritten)

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
rwo_deployments = resources.select { |r| r["kind"] == "Deployment" }.select do |d|
  Array(d.dig("spec", "template", "spec", "volumes")).any? do |v|
    rwo_pvcs.include?(v.dig("persistentVolumeClaim", "claimName"))
  end
end
# 2 台同時に動くと壊れるアプリ（Discord の BOT は 2 台とも同じトークンで接続し、同じ出来事を
# 2 回処理する）は、dev の Namespace のラベル wax100.io/single-replica=true で全部 1 台にする。
# Recreate なので、更新中も古い Pod が消えてから新しい Pod が起動し、2 台が重ならない。
labeled_deployments = SINGLE_REPLICA ? resources.select { |r| r["kind"] == "Deployment" } - rwo_deployments : []
single_deployments = rwo_deployments + labeled_deployments
single_deployments.each do |d|
  spec = (d["spec"] ||= {})
  spec["strategy"] = { "type" => "Recreate" }
  spec["replicas"] = 1
end
single_names = single_deployments.map { |d| d["metadata"]["name"] }

multi_deployments = resources.select { |r| r["kind"] == "Deployment" } - single_deployments
multi_deployments.each { |d| ensure_hostname_spread!(d) }

base = File.join(OUT, "base")
prod = File.join(OUT, "overlays", "production")
FileUtils.mkdir_p(base)
FileUtils.mkdir_p(prod)

File.write(File.join(base, "resources.yaml"), resources.map { |r| "---\n#{yaml_doc(deep_copy(r))}" }.join)

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

unless ADDON_NAMESPACES.empty?
  notes << "- **アドオンも一緒に昇格します**（#{ADDON_NAMESPACES.map { |n| "`#{n}`" }.join(', ')}）。" \
           "本番では `prod-#{APP}` の中にまとめて立ちます。DB の中身は空で作られます。"
end
unless rewritten.empty?
  notes << ("- **接続先のホスト名を書き換えました**（本番はアプリとアドオンが同じ Namespace のため）: " +
           rewritten.uniq.map { |from, to| "`#{from}` → `#{to}`" }.join(", "))
end
unless ADDON_NAMESPACES.empty?
  notes << "- Secret の値（`DATABASE_URL` など）は読めないので書き換えていません。Secret Manager に本番の値を入れるとき、" \
           "ホスト名は `<Service>.<Namespace>.svc.cluster.local` ではなく `<Service>` だけにしてください。"
end

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
secret_refs, optional_only_secrets = collect_secret_refs(resources)
es_path = File.join(prod, "external-secret.yaml")

if secret_refs.any?
  secret_notes = []
  taken = Set.new
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
unless optional_only_secrets.empty?
  notes << "- 任意の Secret 参照（`optional: true` のみ）は ExternalSecret の生成から除外しました（" \
           "#{optional_only_secrets.map { |n| "`#{n}`" }.join(', ')}）。本番でも使う場合は `overlays/production/external-secret.yaml` に追加してください。"
end
overlay_extra << "  - external-secret.yaml" if File.exist?(es_path)

# --- HPA・PDB（初回のみ生成） ---
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
pdb_path = File.join(prod, "pdb.yaml")
overlay = File.join(prod, "kustomization.yaml")

unless rwo_deployments.empty?
  notes << "- **1 台で動かします**（#{rwo_deployments.map { |d| "`#{d['metadata']['name']}`" }.join(', ')}）。ReadWriteOnce の PVC を付けているため、" \
           "HPA を付けず、replicas: 1・更新方法 Recreate にしました（更新時は数十秒止まります）。"
end
unless labeled_deployments.empty?
  notes << "- **1 台で動かします**（#{labeled_deployments.map { |d| "`#{d['metadata']['name']}`" }.join(', ')}）。dev の Namespace に " \
           "`wax100.io/single-replica=true` が付いているため、HPA を付けず、replicas: 1・更新方法 Recreate にしました" \
           "（更新時と Spot の回収時は数十秒〜数分止まります）。"
end

deployments = multi_deployments.map { |d| d["metadata"]["name"] }
dev_hpas = resources.select do |r|
  r["kind"] == "HorizontalPodAutoscaler" &&
    (r.dig("spec", "scaleTargetRef", "kind") || "Deployment") == "Deployment"
end
dev_hpa_targets = dev_hpas.filter_map { |h| h.dig("spec", "scaleTargetRef", "name") }
hpa_targets = deployments - dev_hpa_targets
unscaled_targets = []

if !File.exist?(overlay) && hpa_targets.any? && !File.exist?(hpa_path)
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

dev_multi_hpa_names = dev_hpas.select { |h| (h.dig("spec", "minReplicas") || 1).to_i >= 2 }
                              .filter_map { |h| h.dig("spec", "scaleTargetRef", "name") }
pdb_eligible_names = (hpa_targets + dev_multi_hpa_names).uniq & deployments
pdb_deployments = multi_deployments.select do |d|
  pdb_eligible_names.include?(d["metadata"]["name"]) && !deployment_pod_selector(d).nil?
end

if !File.exist?(overlay) && pdb_deployments.any? && !File.exist?(pdb_path)
  pdbs = pdb_deployments.map do |d|
    yaml_doc({
      "apiVersion" => "policy/v1",
      "kind" => "PodDisruptionBudget",
      "metadata" => { "name" => d["metadata"]["name"] },
      "spec" => {
        "minAvailable" => 1,
        "selector" => deployment_pod_selector(d)
      }
    })
  end
  File.write(pdb_path, <<~HEAD + pdbs.join("---\n"))
    # 昇格時に自動生成（初回のみ）。Spot ノードの入れ替えやメンテナンスでも最低 1 台を残す。
    # replicas: 1 に戻すときは、ドレインが詰まらないようこの定義も外すこと。
  HEAD
end
overlay_extra << "  - pdb.yaml" if File.exist?(pdb_path)

file_hpa_targets =
  if File.exist?(hpa_path)
    safe_load_yaml_docs(File.read(hpa_path, encoding: "UTF-8")).filter_map do |doc|
      next nil unless doc.is_a?(Hash) && (doc.dig("spec", "scaleTargetRef", "kind") || "Deployment") == "Deployment"

      doc.dig("spec", "scaleTargetRef", "name")
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
if File.exist?(overlay) && missing_hpa.any?
  notes << "- HPA が無い Deployment があります（#{missing_hpa.map { |n| "`#{n}`" }.join(', ')}）。" \
           "負荷で台数を変えるなら `overlays/production/hpa.yaml` に追加し、replicas を消すパッチも足してください。"
end

file_pdb_names =
  if File.exist?(pdb_path)
    safe_load_yaml_docs(File.read(pdb_path, encoding: "UTF-8")).filter_map do |doc|
      doc.dig("metadata", "name") if doc.is_a?(Hash) && doc["kind"] == "PodDisruptionBudget"
    end
  else
    []
  end
active_pdbs = file_pdb_names.uniq & deployments
conflicting_pdb = file_pdb_names.uniq & single_names
unless conflicting_pdb.empty?
  notes << "- **PodDisruptionBudget が 1 台でしか動かせない Deployment に残っています**（#{conflicting_pdb.map { |n| "`#{n}`" }.join(', ')}）。" \
           "ノードのドレインが止まるため、`overlays/production/pdb.yaml` から外してください。"
end
missing_pdb = pdb_eligible_names - active_pdbs
if File.exist?(overlay) && missing_pdb.any?
  notes << "- PodDisruptionBudget が無い Deployment があります（#{missing_pdb.map { |n| "`#{n}`" }.join(', ')}）。" \
           "複数台で動かすならノード入れ替え時の瞬断を防ぐため `overlays/production/pdb.yaml` への追加を検討してください。"
end

if scaled.any?
  notes << "- **本番は CPU 使用率で台数が変わります**（#{scaled.map { |n| "`#{n}`" }.join(', ')}: " \
           "最小 #{HPA_MIN} / 最大 #{HPA_MAX} / 目標 #{HPA_CPU}%）。調整は `overlays/production/hpa.yaml` で。"
end
if active_pdbs.any?
  notes << "- **PodDisruptionBudget で最低 1 台を維持します**（#{active_pdbs.map { |n| "`#{n}`" }.join(', ')}: `minAvailable: 1`）。" \
           "調整は `overlays/production/pdb.yaml` で。"
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
  notes << ("- 昇格の対象外として除外: " +
           other_dropped.map { |k, names| "#{k.empty? ? '(kind 無し)' : k} (#{names.compact.join(', ')})" }.join(" / "))
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
unless File.exist?(overlay)
  res_lines = ["  - namespace.yaml", "  - ../../base", *overlay_extra].join("\n")
  kust_parts = [
    "apiVersion: kustomize.config.k8s.io/v1beta1\n" \
    "kind: Kustomization\n" \
    "namespace: prod-#{APP}\n\n" \
    "resources:\n#{res_lines}\n\n" \
    "# 本番固有の差分はここに書く（リソース、HPA、PVC の容量など）。\n" \
    "# 再昇格してもこのファイルは上書きされません。\n"
  ]
  # HPA を付けた Deployment の replicas を消す（Config Sync と HPA の取り合いを防ぐ）
  unless scaled.empty?
    patches = scaled.map do |name|
      {
        "target" => { "kind" => "Deployment", "name" => name },
        "patch" => "- op: remove\n  path: /spec/replicas\n"
      }
    end
    kust_parts << "\n# HPA が台数を持つので、base の replicas を消す。HPA を外すならこれも外す。\n"
    kust_parts << yaml_doc({ "patches" => patches }).chomp
  end
  File.write(overlay, "#{kust_parts.join.chomp}\n")
end

File.write(NOTES, "#{notes.join("\n")}\n") if NOTES && !notes.empty?

puts "generated #{OUT} (#{resources.size} resources, #{secret_refs.size} secret refs)"
