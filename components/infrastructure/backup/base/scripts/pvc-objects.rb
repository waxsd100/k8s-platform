#!/usr/bin/env ruby
# frozen_string_literal: true

# pvc-backup.sh が kubectl create に渡すリソースを YAML で出す。
#
#   ruby pvc-objects.rb source-snapshot NAME NS PVC   アプリの Namespace で取るスナップショット
#   ruby pvc-objects.rb import NAME HANDLE            同じスナップショットを infra に取り込む
#   ruby pvc-objects.rb disk NAME SIZE STORAGE_CLASS  取り込んだスナップショットから作る一時ディスク
#   ruby pvc-objects.rb mover NAME NS PVC             一時ディスクを読んで restic で送る Job
#
# mover の形は Kyverno の pvc-backup-job-scope が許す形そのもの。変えるときは両方を直す。

require "yaml"

LABEL = { "wax100.io/pvc-backup" => "true" }.freeze
SNAPSHOT_CLASS = "pvc-backup"
SNAPSHOT_API = "snapshot.storage.k8s.io/v1"

def meta(name, namespace = "infra")
  { "name" => name, "namespace" => namespace, "labels" => LABEL.dup }.compact
end

def source_snapshot(name, ns, pvc)
  [{
    "apiVersion" => SNAPSHOT_API, "kind" => "VolumeSnapshot", "metadata" => meta(name, ns),
    "spec" => { "volumeSnapshotClassName" => SNAPSHOT_CLASS, "source" => { "persistentVolumeClaimName" => pvc } }
  }]
end

# 別の Namespace のスナップショットからディスクは作れないので、同じ GCE スナップショットを
# 指す VolumeSnapshotContent を作って infra に取り込む。Retain なので消しても元は残る。
def import(name, handle)
  [
    {
      "apiVersion" => SNAPSHOT_API, "kind" => "VolumeSnapshotContent", "metadata" => meta(name, nil),
      "spec" => {
        "deletionPolicy" => "Retain", "driver" => "pd.csi.storage.gke.io",
        "volumeSnapshotClassName" => SNAPSHOT_CLASS, "source" => { "snapshotHandle" => handle },
        "volumeSnapshotRef" => { "name" => name, "namespace" => "infra" }
      }
    },
    {
      "apiVersion" => SNAPSHOT_API, "kind" => "VolumeSnapshot", "metadata" => meta(name),
      "spec" => { "volumeSnapshotClassName" => SNAPSHOT_CLASS, "source" => { "volumeSnapshotContentName" => name } }
    }
  ]
end

def disk(name, size, storage_class)
  spec = {
    "accessModes" => ["ReadWriteOnce"],
    "resources" => { "requests" => { "storage" => size } },
    "dataSource" => { "apiGroup" => "snapshot.storage.k8s.io", "kind" => "VolumeSnapshot", "name" => name }
  }
  spec["storageClassName"] = storage_class unless storage_class == "-"
  [{ "apiVersion" => "v1", "kind" => "PersistentVolumeClaim", "metadata" => meta(name), "spec" => spec }]
end

def secret_env(name, key)
  { "name" => name, "valueFrom" => { "secretKeyRef" => { "name" => "restic-client", "key" => key } } }
end

def config_env(name)
  { "name" => name, "valueFrom" => { "configMapKeyRef" => { "name" => "restic-config", "key" => name } } }
end

def mover(name, ns, pvc)
  path = "/pvc/#{ns}/#{pvc}"
  container = {
    "name" => "restic",
    "image" => ENV.fetch("MOVER_IMAGE"),
    "command" => ["restic"],
    "args" => ["backup", "--host", "pvc-backup", "--tag", "pvc", "--tag", ns, "--exclude", "lost+found", path],
    "env" => [
      config_env("RESTIC_REPOSITORY"), config_env("RESTIC_REST_USERNAME"),
      secret_env("RESTIC_REST_PASSWORD", "RESTIC_REST_PASSWORD"), secret_env("RESTIC_PASSWORD", "RESTIC_PASSWORD"),
      { "name" => "RESTIC_CACHE_DIR", "value" => "/cache" }
    ],
    # 持ち主やパーミッションに関わらず読むため、root で DAC_READ_SEARCH だけを持つ
    "securityContext" => {
      "runAsUser" => 0, "allowPrivilegeEscalation" => false, "readOnlyRootFilesystem" => true,
      "capabilities" => { "drop" => ["ALL"], "add" => ["DAC_READ_SEARCH"] }
    },
    "resources" => { "requests" => { "cpu" => "100m", "memory" => "256Mi" }, "limits" => { "memory" => "2Gi" } },
    "volumeMounts" => [
      { "name" => "data", "mountPath" => path, "readOnly" => true },
      { "name" => "cache", "mountPath" => "/cache" },
      { "name" => "tmp", "mountPath" => "/tmp" }
    ]
  }
  [{
    "apiVersion" => "batch/v1", "kind" => "Job", "metadata" => meta(name),
    "spec" => {
      "backoffLimit" => 0,
      "activeDeadlineSeconds" => 10_800,
      "template" => {
        "metadata" => { "labels" => LABEL.merge("app" => "pvc-backup-mover") },
        "spec" => {
          "restartPolicy" => "Never",
          "serviceAccountName" => "pvc-backup-mover",
          "automountServiceAccountToken" => false,
          "nodeSelector" => { "workload-type" => "platform" },
          "tolerations" => [{ "key" => "cloud.google.com/gke-spot", "operator" => "Equal", "value" => "true",
                              "effect" => "NoSchedule" }],
          "containers" => [container],
          "volumes" => [
            { "name" => "data", "persistentVolumeClaim" => { "claimName" => name, "readOnly" => true } },
            { "name" => "cache", "emptyDir" => { "sizeLimit" => "5Gi" } },
            { "name" => "tmp", "emptyDir" => { "sizeLimit" => "1Gi" } }
          ]
        }
      }
    }
  }]
end

kind, *args = ARGV
objects =
  case kind
  when "source-snapshot" then source_snapshot(*args)
  when "import" then import(*args)
  when "disk" then disk(*args)
  when "mover" then mover(*args)
  else abort "usage: pvc-objects.rb source-snapshot|import|disk|mover ..."
  end
puts objects.map(&:to_yaml).join
