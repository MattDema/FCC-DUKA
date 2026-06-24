#!/bin/bash
WORKER_IP=$1
WORKER_NAME=$2

echo "=== Setting up $WORKER_NAME ($WORKER_IP) ==="
ssh -o StrictHostKeyChecking=no root@$WORKER_IP << 'REMOTE'
hostnamectl set-hostname $WORKER_NAME

modprobe overlay && modprobe br_netfilter
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system
swapoff -a
sed -i '/swap/d' /etc/fstab

apt-get update
apt-get install -y containerd apt-transport-https ca-certificates curl gnupg
mkdir -p /etc/containerd
cat <<EOF > /etc/containerd/config.toml
version = 2
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.9"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = true
EOF
systemctl restart containerd
systemctl enable containerd

mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet=1.29.* kubeadm=1.29.* kubectl=1.29.*
apt-mark hold kubelet kubeadm kubectl
echo "=== $WORKER_NAME ready for kubeadm join ==="
REMOTE
