#!/bin/bash

set -e
#set -x

# Variables
CONTROL_PLANE_IP="50.18.35.181"
TOKEN="vpcvep.7752a5z5y0uq5op1"
CERT_HASH="9b41732f545620d79624bc853764a3c96441f2b45a6099be2dd0cc30a682eba3"

echo "Starting Kubernetes worker node setup..."

# Disable swap
echo "Disabling swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab  # Make it persistent

# Enable IPv4 forwarding
echo "Enabling IPv4 forwarding..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system
sysctl net.ipv4.ip_forward | grep "net.ipv4.ip_forward = 1"

# Add Docker's official GPG key:
echo "Installing Docker..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the docker repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# verify docker is ok
sudo docker run hello-world

# Configure containerd
echo "Configuring containerd..."
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

# Install CNI plugins
echo "Installing CNI plugins..."
ARCH=$(uname -m)
  case $ARCH in
    armv7*) ARCH="arm";;
    aarch64) ARCH="arm64";;
    x86_64) ARCH="amd64";;
  esac
sudo mkdir -p /opt/cni/bin
curl -O -L https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-$ARCH-v1.5.1.tgz
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-$ARCH-v1.5.1.tgz

# Install kubeadm, kubelet, and kubectl
echo "Installing kubeadm, kubelet, and kubectl..."
sudo mkdir -p -m 755 /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

# Set up GPU runtime (if necessary)
echo "Configuring GPU runtime..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
&& curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit nvidia-driver-550-server
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd

# Verify containerd is running
echo "Verifying containerd status..."
if systemctl is-active --quiet containerd; then
    echo "containerd is running."
else
    echo "containerd failed to start. Exiting..."
    exit 1
fi

# Enable the br_netfilter Kernel Module for flannel network plugin
sudo modprobe br_netfilter

# Make it persist after reboots by including it in your system's modules-load list:
echo br_netfilter | sudo tee /etc/modules-load.d/kubernetes.conf

echo "Configuring firewall rules..."
echo "y" | sudo ufw enable
# https://kubernetes.io/docs/reference/networking/ports-and-protocols/
sudo ufw allow 10250/tcp
sudo ufw allow 10256/tcp
sudo ufw allow 30000:32767/tcp
# Flannel, VXLAN UDP port to use for sending encapsulated packets
sudo ufw allow 8472/udp
# ssh
sudo ufw allow 22/tcp
sudo ufw reload
sudo ufw status verbose

# Join the Kubernetes cluster
echo "Joining the Kubernetes cluster..."
sudo kubeadm join $CONTROL_PLANE_IP:6443 --token $TOKEN --discovery-token-ca-cert-hash sha256:$CERT_HASH

# Verify the join
if [ $? -eq 0 ]; then
    echo "Node successfully joined the Kubernetes cluster."
else
    echo "Failed to join the Kubernetes cluster."
    exit 1
fi

echo "sleep 30 seconds to wait pods to be launched"
sleep 30
NODE_NAME=$(hostname)


attempt=0
max_attempts=60

# Monitor the status of Pods on the node
while true; do
  # Get the status of all Pods on the node
  POD_STATUS=$(sudo kubectl get pods --kubeconfig /etc/kubernetes/kubelet.conf --field-selector spec.nodeName=$NODE_NAME --all-namespaces -o jsonpath='{.items[*].status.phase}')

#  echo "Current POD_STATUS: $POD_STATUS"

  IFS=' ' read -r -a STATUS_ARRAY <<< "$POD_STATUS"

  # Flag to check if all statuses are 'Running' or 'Succeeded'
  ALL_RUNNING_SUCCEEDED=true

  # Iterate through each status
  for status in "${STATUS_ARRAY[@]}"; do
    if [[ "$status" != "Running" && "$status" != "Succeeded" ]]; then
      echo "Found non-Running/Succeeded status: $status"
      ALL_RUNNING_SUCCEEDED=false
      break
    fi
  done

  # Check if all are 'Running' or 'Succeeded'
  if [ "$ALL_RUNNING_SUCCEEDED" = true ]; then
    echo "All pods are in Running or Succeeded state. Node join successful."
    break
  else
    echo "Waiting for all pods to be in Running or Succeeded state..."
  fi

  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Pods did not reach Running or Succeeded state within the 10 minutes. Join failed."
    exit 1
  fi

  # Wait for 10 seconds before checking again
  sleep 10
done

echo "Worker node setup complete."