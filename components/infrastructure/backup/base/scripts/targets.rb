#!/usr/bin/env ruby
# frozen_string_literal: true

# バックアップの対象を決める。db-backup と pvc-backup で「何を DB と見なすか」を共有する。
#
#   ruby targets.rb db  PODS_JSON                    → "<OK|UNREADY> <ns> <pod> <container> <engine>"
#   ruby targets.rb pvc PVCS_JSON PODS_JSON PVS_JSON → "<OK|NOCSI|UNBOUND> <ns> <pvc> <storageClass か ->"
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

def items(path)
  JSON.parse(File.read(path))["items"] || []
end

def db_engine(container)
  ports = Array(container["ports"]).map { |p| p.is_a?(Hash) ? p["containerPort"].to_i : 0 }
  DB_PORTS.find { |port, _| ports.include?(port) }&.last
end

# 実行中で Ready な DB コンテナ（サーバーの台数・Namespace は問わない）。
# 本番（prod-*）で Ready ではない DB Pod（Succeeded と対象外を除く）は UNREADY として返し、
# pvc-backup が DB 用として除外したまま両方とも黙って飛ばす取りこぼしを防ぐ。
# また dev の遅延・ハングで本番が巻き込まれないよう、本番を先に出す。
def db_targets(pods)
  ordered_pods = pods.partition { |p| p.is_a?(Hash) && p.dig("metadata", "namespace").to_s.match?(PROD_NAMESPACE) }.flatten(1)
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
    (pod.dig("spec", "containers") || []).each do |c|
      engine = db_engine(c)
      next unless engine

      if phase == "Running" && ready[c["name"]]
        puts ["OK", ns, name, c["name"], engine].join(" ")
      elsif ns.match?(PROD_NAMESPACE)
        puts ["UNREADY", ns, name, c["name"], engine].join(" ")
      end
    end
  end
end

# 本番の Bound な PVC。DB の Pod がマウントしている PVC は論理ダンプで取っているので除く
# （ファイルとしても取りたいときは PVC に wax100.io/backup: "true"）。
def pvc_targets(pvcs, pods, pvs)
  pvs = pvs.to_h { |pv| [pv.dig("metadata", "name"), pv] }
  db_claims = Set.new
  pods.each do |pod|
    next unless pod.is_a?(Hash)
    next unless (pod.dig("spec", "containers") || []).any? { |c| db_engine(c) }

    pod_ns = pod.dig("metadata", "namespace")
    (pod.dig("spec", "volumes") || []).each do |v|
      claim = v.dig("persistentVolumeClaim", "claimName")
      db_claims << "#{pod_ns}/#{claim}" if pod_ns && claim
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
    state =
      if pvc.dig("status", "phase") != "Bound" then "UNBOUND"
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
