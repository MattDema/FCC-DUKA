#!/bin/bash
WORKER_IP=$1
WORKER_NAME=$2

echo "=== Installing gVisor on $WORKER_NAME ($WORKER_IP) ==="
ssh -o StrictHostKeyChecking=no ubuntu@$WORKER_IP 'sudo bash -s' << 'REMOTE'

# 1. Add gVisor repository
curl -fsSL https://gvisor.dev/archive.key | gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" > /etc/apt/sources.list.d/gvisor.list

# 2. Install runsc
apt-get update && apt-get install -y runsc

# 3. Verify installation
runsc --version

# 4. Configure containerd to use runsc
# Add gVisor runtime to the existing config
cat <<EOF >> /etc/containerd/config.toml

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
EOF

# 5. Restart containerd
systemctl restart containerd

# 6. Verify containerd is running
systemctl status containerd | grep Active

echo "=== gVisor installed on $WORKER_NAME ==="
REMOTE
