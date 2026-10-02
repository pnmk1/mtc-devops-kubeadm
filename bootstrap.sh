#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/scripts/common.sh"
[[ $EUID -eq 0 ]] || die 'Run: sudo bash bootstrap.sh'
trap diagnostics ERR
# shellcheck source=/dev/null
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || die 'This bootstrap supports Ubuntu 24.04 only.'
[[ $(uname -m) == x86_64 ]] || die 'The locked tool binaries support x86_64 only.'
[[ $(nproc) -ge 4 ]] || die 'At least 4 vCPU are required.'
awk '/MemTotal/ {exit ($2 < 7500000)}' /proc/meminfo || die 'Allocate at least 8 GB RAM.'
df -Pk /var | awk 'NR==2 {exit ($4 < 15000000)}' || die 'At least 15 GB free disk is required.'
check_files

REAL_USER=${SUDO_USER:-root}
USER_DIR=$(getent passwd "$REAL_USER" | cut -d: -f6)
if [[ -z ${NODE_IP:-} && -f "$DATA_ROOT/cluster-ip" ]]; then
  NODE_IP=$(cat "$DATA_ROOT/cluster-ip")
fi
NODE_IP=${NODE_IP:-$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')}
[[ -n "$NODE_IP" ]] || die 'No IPv4 source address found.'
ip -j -4 address show | python3 -c 'import json,sys; addresses={a["local"] for interface in json.load(sys.stdin) for a in interface.get("addr_info",[])}; sys.exit(0 if sys.argv[1] in addresses else 1)' "$NODE_IP" || die "Node IP $NODE_IP is not assigned to a local interface."
export NODE_IP

if [[ -f /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
  need kubectl
  kubectl --request-timeout=15s get --raw=/readyz >/dev/null || die 'Existing API is unhealthy; investigate it. Bootstrap will not reset it.'
  CURRENT_VERSION=$(kubectl version -o json | python3 -c 'import sys,json; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')
  [[ "$CURRENT_VERSION" == "v$KUBERNETES_VERSION" ]] || die "Existing cluster is $CURRENT_VERSION; required v$KUBERNETES_VERSION. No automatic upgrade/reset."
  [[ -f "$DATA_ROOT/cluster-ip" ]] || die 'Existing cluster is not marked as managed by this repository.'
  [[ $(cat "$DATA_ROOT/cluster-ip") == "$NODE_IP" ]] || die 'Node IP changed. Restore its original static IP before continuing.'
  [[ $(kubectl get nodes -o json | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["items"]))') == 1 ]] || die 'Only a dedicated single-node cluster is supported.'
  log 'Existing managed cluster is healthy; preserving it.'
else
  [[ ! -d /etc/kubernetes/manifests && ! -d /var/lib/etcd/member ]] || die 'Partial/existing Kubernetes state found. No automatic reset.'
  python3 - "$NODE_IP" <<'PY'
import ipaddress, json, subprocess, sys
reserved = [ipaddress.ip_network('10.244.0.0/16'), ipaddress.ip_network('10.96.0.0/12')]
routes = json.loads(subprocess.check_output(['ip','-j','-4','route','show']))
for route in routes:
    dst = route.get('dst', 'default')
    if dst == 'default':
        continue
    network = ipaddress.ip_network(dst, strict=False)
    if any(network.overlaps(r) for r in reserved):
        raise SystemExit(f'Existing route {dst} overlaps Kubernetes pod/service networks')
if any(ipaddress.ip_address(sys.argv[1]) in r for r in reserved):
    raise SystemExit('Node IP overlaps Kubernetes networks')
PY
  log 'Installing pinned runtime and Kubernetes packages.'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gpg gettext-base python3
  install -d -m 0755 /etc/apt/keyrings
  download 'https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key' "$STATE_DIR/kubernetes.key"
  gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "$STATE_DIR/kubernetes.key"
  printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
  apt-get update
  for package in containerd kubelet kubeadm kubectl; do
    expected=$KUBERNETES_DEB_VERSION
    [[ $package != containerd ]] || expected=$CONTAINERD_DEB_VERSION
    apt-cache madison "$package" | awk '{print $3}' | grep -Fxq "$expected" || die "Pinned package not available: $package=$expected"
  done
  DEBIAN_FRONTEND=noninteractive apt-get install -y "containerd=$CONTAINERD_DEB_VERSION" "kubelet=$KUBERNETES_DEB_VERSION" "kubeadm=$KUBERNETES_DEB_VERSION" "kubectl=$KUBERNETES_DEB_VERSION"
  apt-mark hold containerd kubelet kubeadm kubectl
  log 'Configuring containerd, kernel networking and swap.'
  swapoff -a
  cp -n /etc/fstab /etc/fstab.mtc-backup || true
  sed -i -E '/^[[:space:]]*#/! { /[[:space:]]swap[[:space:]]/ s/^/# mtc-disabled /; }' /etc/fstab
  while read -r unit _; do
    [[ $unit == *.swap ]] && systemctl mask "$unit"
  done < <(systemctl list-units --type=swap --all --no-legend)
  printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/mtc-kubernetes.conf
  modprobe overlay
  modprobe br_netfilter
  printf 'net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-mtc-kubernetes.conf
  sysctl --system >/dev/null
  install -d /etc/containerd
  containerd config default > "$STATE_DIR/containerd.toml"
  sed -i -E 's/SystemdCgroup = false/SystemdCgroup = true/' "$STATE_DIR/containerd.toml"
  grep -q 'SystemdCgroup = true' "$STATE_DIR/containerd.toml" || die 'Unable to configure systemd cgroups.'
  install -m 0644 "$STATE_DIR/containerd.toml" /etc/containerd/config.toml
  systemctl enable --now containerd kubelet
  systemctl restart containerd
  install -d -m 0755 "$DATA_ROOT"
  cat > "$STATE_DIR/kubeadm.yaml" <<YAML
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$NODE_IP"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: "$NODE_IP"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v$KUBERNETES_VERSION"
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
apiServer:
  certSANs:
    - "$NODE_IP"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
YAML
  kubeadm init --config "$STATE_DIR/kubeadm.yaml"
  printf '%s\n' "$NODE_IP" > "$DATA_ROOT/cluster-ip"
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

log 'Setting up kubeconfig, network and local data directories.'
install -d -m 0700 -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$USER_DIR/.kube"
install -m 0600 -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" /etc/kubernetes/admin.conf "$USER_DIR/.kube/config"
kubectl apply -f "$ROOT/vendor/flannel.yaml"
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint node "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule- || true
kubectl label node "$NODE_NAME" mtc-devops.storage=local --overwrite
install -d -m 0750 -o 1000 -g 1000 "$DATA_ROOT/logs" "$DATA_ROOT/metrics"
kubectl wait node "$NODE_NAME" --for=condition=Ready --timeout=300s
kubectl -n kube-system rollout status deployment/coredns --timeout=300s

if ! command -v helm >/dev/null || ! [[ $(helm version --short) == "v$HELM_VERSION"* ]]; then
  log 'Installing checksum-verified Helm.'
  download "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" "$STATE_DIR/helm.tar.gz"
  printf '%s  %s\n' "$HELM_LINUX_AMD64_SHA256" "$STATE_DIR/helm.tar.gz" | sha256sum --check -
  tar -xzf "$STATE_DIR/helm.tar.gz" -C "$STATE_DIR"
  install -m 0755 "$STATE_DIR/linux-amd64/helm" /usr/local/bin/helm
fi
dpkg-query -W containerd runc kubeadm kubelet kubectl > "$STATE_DIR/installed-packages.txt"
chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$STATE_DIR"
log "Cluster ready. Next (as $REAL_USER): bash deploy.sh"

