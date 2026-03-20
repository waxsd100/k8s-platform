# 現在のGKE状態と復旧・構築手順

## 1. 現在のGCPインフラ状態
直近のコマンド実行（`gcloud`）により、以下の状態であることが確認されました。

- **VPCとサブネット**: 存在します（`wax100-vpc`, `wax100-subnet`, `wax100-subnet-lb`）。
- **GKEクラスタ**: 現在、存在しません。
- **Spotノードプール**: クラスタがないため存在しません。
- **Compute Instances (Edge Gateway)**: 存在しません。

したがって、ゼロからGKEクラスタおよびネットワークのエッジVMを構築する必要があります。

## 2. 差分構築コマンド一覧（SETUP手順）
現在の状態から元の稼働状態に復旧させるために必要なコマンド群です。

### 2.1 GKEクラスタの新規構築
```powershell
gcloud container clusters create wax100-platform `
  --project=wax100 `
  --zone=asia-northeast1-a `
  --network=wax100-vpc `
  --subnetwork=wax100-subnet `
  --enable-private-nodes `
  --master-ipv4-cidr=172.16.0.0/28 `
  --enable-ip-alias `
  --cluster-ipv4-cidr=10.4.0.0/14 `
  --services-ipv4-cidr=10.8.0.0/20 `
  --enable-master-authorized-networks `
  --master-authorized-networks=0.0.0.0/0 `
  --num-nodes=1 `
  --release-channel=stable `
  --workload-pool=wax100.svc.id.goog `
  --disk-size=30 `
  --metadata disable-legacy-endpoints=true `
  --logging=NONE `
  --monitoring=NONE
```

### 2.2 Spotノードプールの追加
```powershell
gcloud container node-pools create spot-pool `
  --project=wax100 `
  --cluster=wax100-platform `
  --zone=asia-northeast1-a `
  --machine-type=e2-small `
  --spot `
  --num-nodes=2 `
  --disk-size=20 `
  --enable-autoscaling `
  --min-nodes=1 `
  --max-nodes=4 `
  --node-taints=cloud.google.com/gke-spot=true:NoSchedule

### 2.2.1 デフォルトプールの削除（gcloud制約対応）
```powershell
gcloud container node-pools delete default-pool `
  --cluster=wax100-platform `
  --zone=asia-northeast1-a `
  --quiet
```
```

### 2.3 エッジVMの構築とネットワークルート設定
```powershell
gcloud compute instances create edge-gateway `
  --project=wax100 `
  --zone=asia-northeast1-a `
  --machine-type=e2-micro `
  --network=wax100-vpc `
  --subnet=wax100-subnet `
  --can-ip-forward `
  --tags=http-server,https-server `
  --image-family=debian-12 `
  --image-project=debian-cloud `
  --boot-disk-size=10GB

# カスタムルートの作成（NAT用）
gcloud compute routes create nat-route `
  --project=wax100 `
  --network=wax100-vpc `
  --destination-range=0.0.0.0/0 `
  --next-hop-instance=edge-gateway `
  --next-hop-instance-zone=asia-northeast1-a `
  --tags=gke-wax100-platform-spot-pool `
  --priority=800
```

### 2.4 クラスタへの接続設定
```powershell
gcloud container clusters get-credentials wax100-platform `
  --project=wax100 `
  --zone=asia-northeast1-a
```

> **注意点**:
> ArgoCDのインストールとApp of Appsの適用、およびVM内部のCaddyやiptablesのセットアップはこれらのインフラ構築が完了した後に実行します。
