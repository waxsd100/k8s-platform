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
STALE_FAILED_REASONS = %w[Evicted Shutdown NodeAffinity].freeze

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

def items(path)
  data = JSON.parse(File.read(path))
  abort "JSON のルートがオブジェクトではありません: #{path}" unless data.is_a?(Hash)

  raw_items = data["items"]
  return [] if raw_items.nil?
  abort "JSON の items が配列ではありません: #{path}" unless raw_items.is_a?(Array)

  raw_items
rescue JSON::ParserError, SystemCallError => e
  abort "#{path} を読めません: #{e.message}"
end

def db_engine(container)
  return nil unless container.is_a?(Hash)

  ports = safe_array(container["ports"]).map { |p| p.is_a?(Hash) ? p["containerPort"].to_i : 0 }
  DB_PORTS.find { |port, _| ports.include?(port) }&.last
end

def db_containers_of(pod)
  safe_array(safe_dig(pod, "spec", "containers")).filter_map do |c|
    next unless c.is_a?(Hash)

    engine = db_engine(c)
    cname = c["name"].to_s
    next unless engine && !cname.empty?

    [cname, engine]
  end
end

def controller_key(pod)
  meta = safe_hash(pod["metadata"])
  ns = meta["namespace"].to_s
  owners = safe_array(meta["ownerReferences"]).select { |o| o.is_a?(Hash) }
  owner = owners.find { |o| o["controller"] == true } || owners.first
  return nil unless owner && %w[ReplicaSet ReplicationController].include?(owner["kind"])

  owner_name = owner["name"].to_s
  owner_name.empty? ? nil : [ns, owner["kind"], owner_name]
end

def job_owned?(pod)
  safe_array(safe_dig(pod, "metadata", "ownerReferences")).any? do |o|
    o.is_a?(Hash) && o["kind"] == "Job"
  end
end

# ダンプのファイル名に使う、Pod が替わっても変わらない名前。Deployment の Pod は rollout や
# 再配置のたびに Pod 名が変わるので、Deployment 名を使う。
#   所有者が ReplicaSet → ReplicaSet 名から pod-template-hash を外したもの（Deployment 名）
#   StatefulSet・所有者なし・それ以外 → Pod 名（StatefulSet の Pod 名はもともと安定している）
def stable_name(pod)
  meta = safe_hash(pod["metadata"])
  name = meta["name"].to_s
  owners = safe_array(meta["ownerReferences"]).select { |o| o.is_a?(Hash) }
  owner = owners.find { |o| o["controller"] == true } || owners.first
  return name unless owner && owner["kind"] == "ReplicaSet"

  rs = owner["name"].to_s
  hash = safe_dig(meta, "labels", "pod-template-hash").to_s
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

# 同じ Namespace で同じダンプ名になる DB コンテナが 2 つ以上あるとき（複数レプリカや、
# ローリング更新の途中など）、あとから出したダンプが先のものを上書きしないよう、
# 衝突した行のダンプ名を Pod 名ベースへ戻す（保持も Pod ごと）。
# 単一 DB は [stable, pod, pod-container]、複数 DB コンテナ Pod は [stable-container, pod-container]
# の単調増加ステージで退避し、ぶつからなくなるまで繰り返す。
def dump_names(entries)
  loop do
    counts = entries.map { |e| [e[:row][1], e[:row][5]] }.tally
    clashed = entries.select { |e| counts[[e[:row][1], e[:row][5]]] > 1 }
    break if clashed.empty?

    # まずは Pod 名ベース（stage 0 → 1）へ戻せるものだけ退避する
    step = clashed.select { |e| e[:stage] == 0 && e[:stages][1] != e[:row][5] }
    target_stage = 1
    if step.empty?
      # Pod 名ベース同士でもぶつかる稀なケースは stage 2（<pod>-<container>）へ退避する
      step = clashed.select { |e| e[:stage] < 2 && e[:stages][2] != e[:row][5] }
      target_stage = 2
    end
    break if step.empty?

    step.each do |e|
      old_dump = e[:row][5]
      new_dump = e[:stages][target_stage]
      e[:stage] = target_stage
      e[:row][5] = new_dump
      warn "WARN: #{e[:row][1]}/#{e[:row][2]} (#{e[:row][3]}) のダンプ名 #{old_dump} が同じ Namespace の別の DB と重なるため、#{new_dump} を使います（この DB の保持は Pod ごと）"
    end
  end
  entries.map { |e| e[:row] }
end

# 実行中で Ready な DB コンテナ（サーバーの台数・Namespace は問わない）。
# 本番（prod-*）で Ready ではない DB Pod（Succeeded・対象外・退避済み等の古い Failed を除く）は
# UNREADY として返し、pvc-backup が DB 用として除外したまま両方とも黙って飛ばす取りこぼしを防ぐ。
# また dev の遅延・ハングで本番が巻き込まれないよう、本番を先に出す。
def db_targets(pods)
  ordered_pods = pods.partition { |p| p.is_a?(Hash) && safe_dig(p, "metadata", "namespace").to_s.match?(PROD_NAMESPACE) }.flatten(1)

  # 同一コントローラ・同一 stable_name に稼働中（非 Succeeded / 非 Failed）の DB Pod があるか先に集める
  active_stable = Set.new
  active_controllers = Set.new
  ordered_pods.each do |pod|
    next unless pod.is_a?(Hash)

    meta = safe_hash(pod["metadata"])
    next if safe_dig(meta, "annotations", OPT_OUT) == "false"

    ns = meta["namespace"].to_s
    name = meta["name"].to_s
    next if ns.empty? || name.empty?

    phase = safe_dig(pod, "status", "phase")
    next if %w[Succeeded Failed].include?(phase)
    next if db_containers_of(pod).empty?

    active_stable << [ns, stable_name(pod)]
    ckey = controller_key(pod)
    active_controllers << ckey if ckey
  end

  entries = []
  ordered_pods.each do |pod|
    next unless pod.is_a?(Hash)

    meta = safe_hash(pod["metadata"])
    next if safe_dig(meta, "annotations", OPT_OUT) == "false"

    ns = meta["namespace"].to_s
    name = meta["name"].to_s
    next if ns.empty? || name.empty?

    phase = safe_dig(pod, "status", "phase")
    next if phase == "Succeeded"

    db_containers = db_containers_of(pod)
    next if db_containers.empty?

    dump_base = stable_name(pod)
    if phase == "Failed"
      reason = safe_dig(pod, "status", "reason").to_s
      ckey = controller_key(pod)
      # Spot 退避（Evicted / Shutdown / NodeAffinity）、Job 由来の失敗 Pod、または
      # 同コントローラ / 同 stable_name の代替 Pod がある古い Failed Pod は除外する
      next if STALE_FAILED_REASONS.include?(reason) ||
              job_owned?(pod) ||
              active_stable.include?([ns, dump_base]) ||
              (ckey && active_controllers.include?(ckey))
    end

    ready = {}
    safe_array(safe_dig(pod, "status", "containerStatuses")).each do |s|
      next unless s.is_a?(Hash)

      sname = s["name"].to_s
      ready[sname] = (s["ready"] == true) unless sname.empty?
    end

    multi_db = db_containers.size > 1
    db_containers.each do |cname, engine|
      state =
        if phase == "Running" && ready[cname]
          "OK"
        elsif ns.match?(PROD_NAMESPACE)
          "UNREADY"
        end
      next unless state

      initial = multi_db ? "#{dump_base}-#{cname}" : dump_base
      pod_level = multi_db ? "#{name}-#{cname}" : name
      final_fallback = "#{name}-#{cname}"
      stages = [initial, pod_level, final_fallback]
      start_stage = initial == pod_level ? 1 : 0
      entries << {
        row: [state, ns, name, cname, engine, initial],
        stages: stages,
        stage: start_stage
      }
    end
  end
  dump_names(entries).each { |row| puts row.join(" ") }
end

# 本番の PVC。稼働中の DB コンテナ（対象外でないもの）が実際にマウントしている PVC は
# 論理ダンプで取っているので除く（ファイルとしても取りたいときは PVC に wax100.io/backup: "true"）。
# 終わった Pod（Succeeded / Failed）が参照しているだけの PVC は「使われている」とは見なさない。
def pvc_targets(pvcs, pods, pvs)
  pvs_by_name = {}
  pvs.each do |pv|
    next unless pv.is_a?(Hash)

    pv_name = safe_dig(pv, "metadata", "name")
    pvs_by_name[pv_name] = pv if pv_name.is_a?(String) && !pv_name.empty?
  end

  db_claims = Set.new
  mounted = Set.new
  pods.each do |pod|
    next unless pod.is_a?(Hash)

    meta = safe_hash(pod["metadata"])
    pod_ns = meta["namespace"].to_s
    next if pod_ns.empty?

    phase = safe_dig(pod, "status", "phase")
    running = !%w[Succeeded Failed].include?(phase)
    opted_out = safe_dig(meta, "annotations", OPT_OUT) == "false"

    db_vol_names = Set.new
    if running && !opted_out
      safe_array(safe_dig(pod, "spec", "containers")).each do |c|
        next unless db_engine(c)

        safe_array(c["volumeMounts"]).each do |vm|
          next unless vm.is_a?(Hash)

          vname = vm["name"].to_s
          db_vol_names << vname unless vname.empty?
        end
      end
    end

    safe_array(safe_dig(pod, "spec", "volumes")).each do |v|
      next unless v.is_a?(Hash)

      claim = safe_dig(v, "persistentVolumeClaim", "claimName").to_s
      next if claim.empty?

      vname = v["name"].to_s
      db_claims << "#{pod_ns}/#{claim}" if !vname.empty? && db_vol_names.include?(vname)
      mounted << "#{pod_ns}/#{claim}" if running
    end
  end

  pvcs.each do |pvc|
    next unless pvc.is_a?(Hash)

    meta = safe_hash(pvc["metadata"])
    ns = meta["namespace"].to_s
    name = meta["name"].to_s
    next unless ns.match?(PROD_NAMESPACE)
    next if name.empty?

    flag = safe_dig(meta, "annotations", OPT_OUT)
    next if flag == "false"
    next if db_claims.include?("#{ns}/#{name}") && flag != "true"

    vol_name = safe_dig(pvc, "spec", "volumeName").to_s
    phase = safe_dig(pvc, "status", "phase")
    state =
      if phase == "Lost" then "LOST"
      # Pending でも Pod が使っているなら準備が止まっている。黙って飛ばさず失敗にする
      elsif phase != "Bound" && mounted.include?("#{ns}/#{name}") then "STUCK"
      elsif phase != "Bound" then "UNBOUND"
      elsif vol_name.empty? || safe_dig(pvs_by_name[vol_name], "spec", "csi", "driver") != SNAPSHOT_DRIVER then "NOCSI"
      else "OK"
      end
    storage_class = safe_dig(pvc, "spec", "storageClassName").to_s
    puts [state, ns, name, storage_class.empty? ? "-" : storage_class].join(" ")
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
