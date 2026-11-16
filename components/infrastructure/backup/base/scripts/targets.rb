#!/usr/bin/env ruby
# frozen_string_literal: true

# バックアップの対象を決める。db-backup と pvc-backup で「何を DB と見なすか」を共有する。
#
#   ruby targets.rb db  PODS_JSON                    → "<OK|UNREADY> <ns> <pod> <container> <engine> <ダンプ名>"
#   ruby targets.rb pvc PVCS_JSON PODS_JSON PVS_JSON → "<OK|NOCSI|UNBOUND|STUCK|LOST> <ns> <pvc> <storageClass か ->"
#
# どちらも Pod / PVC に wax100.io/backup: "false" があれば外す。

require "json"
require "set"

# DB と見なすコンテナ: そのポートを containerPort に宣言しているもの。イメージ名では決めない
# （pgvector/pgvector・postgis/postgis・timescale/timescaledb のような派生イメージも、
# 名前を足さずにそのまま取れる）。公式か Bitnami か、mysql か mariadb かは、ダンプするときに
# コンテナの中で見分ける（db-backup.sh の dump_command）。
# Kyverno の db-backup-exec-scope（exec 先の制限）のポートと揃えておく必要がある。
# ずれると CI（hack/check-backup-consistency.sh）が落ちる。
DB_PORTS = {
  5432 => "postgres",
  3306 => "mysql" # mariadb も
}.freeze

OPT_OUT = "wax100.io/backup"
PROD_NAMESPACE = /\Aprod-/
SNAPSHOT_DRIVER = "pd.csi.storage.gke.io"
DNS_LABEL = /\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/

def items(path)
  JSON.parse(File.read(path))["items"] || []
end

def db_engine(container)
  ports = Array(container["ports"]).map { |p| p.is_a?(Hash) ? p["containerPort"].to_i : 0 }
  DB_PORTS.find { |port, _| ports.include?(port) }&.last
end

# ダンプのファイル名に使う、Pod が替わっても変わらない名前。Deployment の Pod は rollout や
# 再配置のたびに Pod 名が変わるので、Deployment 名を使う。
#   所有者が ReplicaSet → ReplicaSet 名から pod-template-hash を外したもの（Deployment 名）
#   StatefulSet・所有者なし・それ以外 → Pod 名（StatefulSet の Pod 名はもともと安定している）
def stable_name(pod)
  meta = pod["metadata"] || {}
  name = meta["name"].to_s
  owners = Array(meta["ownerReferences"]).select { |o| o.is_a?(Hash) }
  owner = owners.find { |o| o["controller"] == true } || owners.first
  return name unless owner && owner["kind"] == "ReplicaSet"

  rs = owner["name"].to_s
  hash = meta.dig("labels", "pod-template-hash").to_s
  base =
    if !hash.empty? && rs.end_with?("-#{hash}")
      rs.delete_suffix("-#{hash}")
    elsif rs.include?("-")
      rs.sub(/-[^-]+\z/, "")
    else
      ""
    end
  base.match?(DNS_LABEL) ? base : name
end

# 同じ Namespace で同じダンプ名になる Pod が 2 つ以上あるとき（複数レプリカや、ローリング更新の途中など）、
# あとから出したダンプが先のものを上書きしないよう、その Pod だけダンプ名を Pod 名に戻す（保持も Pod ごと）。
# 戻した名前が別の名前とぶつかることもあるので、ぶつからなくなるまで繰り返す。
def dump_names(rows)
  loop do
    counts = rows.map { |r| [r[1], r[2], r[5]] }.uniq.map { |ns, _pod, dump| [ns, dump] }.tally
    clashed = rows.select { |r| r[5] != r[2] && counts[[r[1], r[5]]] > 1 }
    break if clashed.empty?

    clashed.uniq { |r| [r[1], r[2]] }.each do |r|
      warn "WARN: #{r[1]}/#{r[2]} のダンプ名 #{r[5]} が同じ Namespace の別の DB と重なるため、Pod 名 #{r[2]} を使います（この DB の保持は Pod ごと）"
    end
    clashed.each { |r| r[5] = r[2] }
  end
  rows
end

# 実行中で Ready な DB コンテナ（サーバーの台数・Namespace は問わない）。
# 本番（prod-*）で Ready ではない DB Pod（Succeeded と対象外を除く）は UNREADY として返し、
# pvc-backup が DB 用として除外したまま両方とも黙って飛ばす取りこぼしを防ぐ。
# また dev の遅延・ハングで本番が巻き込まれないよう、本番を先に出す。
def db_targets(pods)
  ordered_pods = pods.partition { |p| p.is_a?(Hash) && p.dig("metadata", "namespace").to_s.match?(PROD_NAMESPACE) }.flatten(1)
  rows = []
  ordered_pods.each do |pod|
    next unless pod.is_a?(Hash)

    meta = pod["metadata"] || {}
    next if meta.dig("annotations", OPT_OUT) == "false"

    ns = meta["namespace"].to_s
    name = meta["name"].to_s
    next if ns.empty? || name.empty?

    phase = pod.dig("status", "phase")
    next if phase == "Succeeded"

    ready = (pod.dig("status", "containerStatuses") || []).to_h { |s| [s["name"], s["ready"] == true] }
    dump = stable_name(pod)
    (pod.dig("spec", "containers") || []).each do |c|
      engine = db_engine(c)
      next unless engine

      if phase == "Running" && ready[c["name"]]
        rows << ["OK", ns, name, c["name"], engine, dump]
      elsif ns.match?(PROD_NAMESPACE)
        rows << ["UNREADY", ns, name, c["name"], engine, dump]
      end
    end
  end
  dump_names(rows).each { |row| puts row.join(" ") }
end

# 本番の PVC。DB の Pod がマウントしている PVC は論理ダンプで取っているので除く
# （ファイルとしても取りたいときは PVC に wax100.io/backup: "true"）。
# 終わった Pod（Succeeded / Failed）が参照しているだけの PVC は「使われている」とは見なさない。
def pvc_targets(pvcs, pods, pvs)
  pvs = pvs.to_h { |pv| [pv.dig("metadata", "name"), pv] }
  db_claims = Set.new
  mounted = Set.new
  pods.each do |pod|
    next unless pod.is_a?(Hash)

    is_db = (pod.dig("spec", "containers") || []).any? { |c| db_engine(c) }
    running = !%w[Succeeded Failed].include?(pod.dig("status", "phase"))
    pod_ns = pod.dig("metadata", "namespace")
    (pod.dig("spec", "volumes") || []).each do |v|
      claim = v.dig("persistentVolumeClaim", "claimName")
      next unless pod_ns && claim

      db_claims << "#{pod_ns}/#{claim}" if is_db
      mounted << "#{pod_ns}/#{claim}" if running
    end
  end

  pvcs.each do |pvc|
    next unless pvc.is_a?(Hash)

    meta = pvc["metadata"] || {}
    ns = meta["namespace"].to_s
    next unless ns.match?(PROD_NAMESPACE)

    flag = meta.dig("annotations", OPT_OUT)
    next if flag == "false"
    next if db_claims.include?("#{ns}/#{meta['name']}") && flag != "true"

    vol_name = pvc.dig("spec", "volumeName")
    phase = pvc.dig("status", "phase")
    state =
      if phase == "Lost" then "LOST"
      # Pending でも Pod が使っているなら準備が止まっている。黙って飛ばさず失敗にする
      elsif phase != "Bound" && mounted.include?("#{ns}/#{meta['name']}") then "STUCK"
      elsif phase != "Bound" then "UNBOUND"
      elsif !vol_name || pvs.dig(vol_name, "spec", "csi", "driver") != SNAPSHOT_DRIVER then "NOCSI"
      else "OK"
      end
    storage_class = pvc.dig("spec", "storageClassName").to_s
    puts [state, ns, meta["name"], storage_class.empty? ? "-" : storage_class].join(" ")
  end
end

usage = "usage: targets.rb db PODS_JSON | pvc PVCS_JSON PODS_JSON PVS_JSON"
case ARGV.shift
when "db"
  abort usage unless ARGV.size == 1 && !ARGV[0].to_s.empty?
  db_targets(items(ARGV[0]))
when "pvc"
  abort usage unless ARGV.size == 3 && ARGV.none? { |a| a.to_s.empty? }
  pvc_targets(items(ARGV[0]), items(ARGV[1]), items(ARGV[2]))
else
  abort usage
end
