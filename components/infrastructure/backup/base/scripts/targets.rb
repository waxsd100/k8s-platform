#!/usr/bin/env ruby
# frozen_string_literal: true

# バックアップの対象を決める。db-backup と pvc-backup で「何を DB と見なすか」を共有する。
#
#   ruby targets.rb db  PODS_JSON                  → "<ns> <pod> <container> <engine>"
#   ruby targets.rb pvc PVCS_JSON PODS_JSON PVS_JSON → "<OK|NOCSI|UNBOUND> <ns> <pvc> <storageClass か ->"
#
# どちらも Pod / PVC に wax100.io/backup: "false" があれば外す。

require "json"
require "set"

# DB と見なすイメージ。Kyverno の db-backup-exec-scope（exec 先の制限）の正規表現と
# 揃えておく必要がある。ずれると CI（hack/check-backup-consistency.sh）が落ちる。
#   公式       postgres / mysql / mariadb（library/ 付きも）     → 方式 postgres など
#   Bitnami    bitnami/postgresql など（bitnamilegacy/ も）      → 方式 bitnami-postgresql など
# 方式ごとのダンプのしかたは db-backup.sh の dump_command。
DB_ENGINES = %w[postgres mysql mariadb].freeze
BITNAMI_DB_ENGINES = %w[postgresql mysql mariadb].freeze
DB_IMAGE = %r{
  (?:\A|/)
  (?:(?:library/)?(?<official>#{DB_ENGINES.join('|')})
    |bitnami(?:legacy)?/(?<bitnami>#{BITNAMI_DB_ENGINES.join('|')}))
  [:@]
}x

OPT_OUT = "wax100.io/backup"
PROD_NAMESPACE = /\Aprod-/
SNAPSHOT_DRIVER = "pd.csi.storage.gke.io"

def items(path)
  JSON.parse(File.read(path))["items"]
end

def db_engine(container)
  m = DB_IMAGE.match(container["image"].to_s) or return
  m[:official] || "bitnami-#{m[:bitnami]}"
end

# 実行中で Ready な DB コンテナ（サーバーの台数・Namespace は問わない）
def db_targets(pods)
  pods.each do |pod|
    meta = pod["metadata"]
    next if meta.dig("annotations", OPT_OUT) == "false"
    next unless pod.dig("status", "phase") == "Running"

    ready = (pod.dig("status", "containerStatuses") || []).to_h { |s| [s["name"], s["ready"]] }
    (pod.dig("spec", "containers") || []).each do |c|
      engine = db_engine(c)
      next unless engine && ready[c["name"]]

      puts [meta["namespace"], meta["name"], c["name"], engine].join(" ")
    end
  end
end

# 本番の Bound な PVC。DB の Pod がマウントしている PVC は論理ダンプで取っているので除く
# （ファイルとしても取りたいときは PVC に wax100.io/backup: "true"）。
def pvc_targets(pvcs, pods, pvs)
  pvs = pvs.to_h { |pv| [pv["metadata"]["name"], pv] }
  db_claims = Set.new
  pods.each do |pod|
    next unless (pod.dig("spec", "containers") || []).any? { |c| db_engine(c) }

    (pod.dig("spec", "volumes") || []).each do |v|
      claim = v.dig("persistentVolumeClaim", "claimName")
      db_claims << "#{pod['metadata']['namespace']}/#{claim}" if claim
    end
  end

  pvcs.each do |pvc|
    meta = pvc["metadata"]
    ns = meta["namespace"]
    next unless ns.match?(PROD_NAMESPACE)

    flag = meta.dig("annotations", OPT_OUT)
    next if flag == "false"
    next if db_claims.include?("#{ns}/#{meta['name']}") && flag != "true"

    state =
      if pvc.dig("status", "phase") != "Bound" then "UNBOUND"
      elsif pvs.dig(pvc.dig("spec", "volumeName"), "spec", "csi", "driver") != SNAPSHOT_DRIVER then "NOCSI"
      else "OK"
      end
    storage_class = pvc.dig("spec", "storageClassName").to_s
    puts [state, ns, meta["name"], storage_class.empty? ? "-" : storage_class].join(" ")
  end
end

case ARGV.shift
when "db" then db_targets(items(ARGV[0]))
when "pvc" then pvc_targets(items(ARGV[0]), items(ARGV[1]), items(ARGV[2]))
else abort "usage: targets.rb db PODS_JSON | pvc PVCS_JSON PODS_JSON PVS_JSON"
end
