#!/bin/bash
###############################################################################
# kubeadm Cluster Upgrade Script
#
# A generic, interactive script to upgrade kubeadm-based Kubernetes clusters.
# Auto-discovers nodes via kubectl, checks SSH connectivity, and performs
# sequential minor version hops with etcd backups and health checks.
#
# Usage:
#   ./kubeadm-upgrade.sh <TARGET_MINOR>   [OPTIONS]
#   ./kubeadm-upgrade.sh <TARGET_VERSION> [OPTIONS]
#
# Examples:
#   ./kubeadm-upgrade.sh 1.34             # Upgrade to latest patch of 1.34
#   ./kubeadm-upgrade.sh 1.34.4           # Upgrade to specific patch version
#   ./kubeadm-upgrade.sh 1.34 --yes       # Skip confirmations
#
# Requirements:
#   - Must be run on a control-plane (master) node as root
#   - Passwordless root SSH access to all other nodes via their InternalIP
#   - kubectl, kubeadm, curl, gpg must be available
#
###############################################################################

# NOTE: We intentionally do NOT use 'set -e'. Many apt/gpg/ssh commands can
# return non-zero for harmless reasons and would kill the script silently.
# Instead we check return codes explicitly where it matters.
set -uo pipefail

# ======================== COLORS & LOGGING ========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="/tmp/kubeadm-upgrade-$(date +%Y%m%d-%H%M%S).log"

log()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $*${NC}" | tee -a "$LOG_FILE"; }
info()   { echo -e "${BLUE}[$(date '+%H:%M:%S')] ℹ $*${NC}" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $*${NC}" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $*${NC}" | tee -a "$LOG_FILE"; }
header() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
}

confirm() {
    local msg="$1"
    echo ""
    read -rp "$(echo -e "${YELLOW}  ▶ ${msg} [y/N]: ${NC}")" answer
    [[ "$answer" =~ ^[yY]$ ]]
}

die() { error "$@"; exit 1; }

# ======================== USAGE ========================
usage() {
    cat <<'EOF'
kubeadm Cluster Upgrade Script

Usage:
  ./kubeadm-upgrade.sh <TARGET_MINOR>   [OPTIONS]
  ./kubeadm-upgrade.sh <TARGET_VERSION> [OPTIONS]

Examples:
  ./kubeadm-upgrade.sh 1.34             Upgrade to latest patch of 1.34
  ./kubeadm-upgrade.sh 1.34.4           Upgrade to a specific patch version
  ./kubeadm-upgrade.sh 1.34 --yes       Skip confirmations

Options:
  --yes       Skip confirmations
  -h, --help  Show this help

Requirements:
  - Must be run on a control-plane (master) node as root
  - Passwordless root SSH access to all other nodes via their InternalIP
  - kubectl, kubeadm, curl, gpg available on this node
EOF
    exit 0
}

# ======================== GLOBAL VARIABLES ========================
AUTO_YES="false"
TARGET_ARG=""
TARGET_MINOR=""
EXPLICIT_PATCH=""
LOCAL_HOSTNAME=""
LOCAL_IP=""
CURRENT_VERSION=""
CURRENT_MINOR=""
CURRENT_MINOR_NUM=""
TARGET_MINOR_NUM=""
SELECTED_PATCH=""

declare -a MASTER_NAMES=()
declare -a MASTER_IPS=()
declare -a WORKER_NAMES=()
declare -a WORKER_IPS=()
declare -a ALL_REMOTE_IPS=()

# ======================== PREREQUISITE CHECKS ========================

check_prerequisites() {
    header "PREREQUISITE CHECKS"

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root."
    fi
    log "Running as root"

    # Required commands
    local missing=()
    for cmd in kubectl kubeadm curl gpg apt-get ssh; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
    log "All required commands available"

    # Must be on a control-plane node
    LOCAL_HOSTNAME=$(hostname)
    local roles
    roles=$(kubectl get node "$LOCAL_HOSTNAME" --no-headers -o custom-columns='ROLES:.metadata.labels' 2>/dev/null || echo "")

    # Also try the ROLES column directly
    local role_col
    role_col=$(kubectl get node "$LOCAL_HOSTNAME" --no-headers 2>/dev/null | awk '{print $3}')

    if ! echo "$roles $role_col" | grep -qi "control-plane"; then
        echo ""
        echo -e "${RED}  ┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}  │  This script must be run on a control-plane (master) node.   │${NC}"
        echo -e "${RED}  │                                                              │${NC}"
        echo -e "${RED}  │  Current hostname '${LOCAL_HOSTNAME}' does not appear to have     │${NC}"
        echo -e "${RED}  │  the control-plane role.                                     │${NC}"
        echo -e "${RED}  │                                                              │${NC}"
        echo -e "${RED}  │  Please SSH into a master node and run this script there.    │${NC}"
        echo -e "${RED}  └──────────────────────────────────────────────────────────────┘${NC}"
        exit 1
    fi
    log "Running on control-plane node: ${LOCAL_HOSTNAME}"

    LOCAL_IP=$(kubectl get node "$LOCAL_HOSTNAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [[ -z "$LOCAL_IP" ]]; then
        die "Could not determine InternalIP of ${LOCAL_HOSTNAME}"
    fi
    log "Local node IP: ${LOCAL_IP}"
}

# ======================== NODE DISCOVERY ========================

discover_nodes() {
    header "NODE DISCOVERY"
    info "Querying cluster nodes via kubectl..."

    # Use 'kubectl get nodes --no-headers' and parse the standard columns:
    #   NAME   STATUS   ROLES            AGE   VERSION
    # This is much more reliable than jsonpath for role detection.
    while read -r name status roles age version; do
        [[ -z "$name" ]] && continue
        [[ "$name" == "$LOCAL_HOSTNAME" ]] && continue

        # Get InternalIP for this node
        local ip
        ip=$(kubectl get node "$name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        [[ -z "$ip" ]] && continue

        if echo "$roles" | grep -qi "control-plane"; then
            MASTER_NAMES+=("$name")
            MASTER_IPS+=("$ip")
        else
            WORKER_NAMES+=("$name")
            WORKER_IPS+=("$ip")
        fi
        ALL_REMOTE_IPS+=("$ip")
    done < <(kubectl get nodes --no-headers 2>/dev/null)

    echo "" | tee -a "$LOG_FILE"
    info "Cluster topology:"
    echo -e "  ${BOLD}Control-plane (this node):${NC}" | tee -a "$LOG_FILE"
    echo -e "    ${LOCAL_HOSTNAME} (${LOCAL_IP}) ← you are here" | tee -a "$LOG_FILE"

    if [[ ${#MASTER_NAMES[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Other control-plane nodes:${NC}" | tee -a "$LOG_FILE"
        for i in "${!MASTER_NAMES[@]}"; do
            echo -e "    ${MASTER_NAMES[$i]} (${MASTER_IPS[$i]})" | tee -a "$LOG_FILE"
        done
    fi

    if [[ ${#WORKER_NAMES[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Worker nodes:${NC}" | tee -a "$LOG_FILE"
        for i in "${!WORKER_NAMES[@]}"; do
            echo -e "    ${WORKER_NAMES[$i]} (${WORKER_IPS[$i]})" | tee -a "$LOG_FILE"
        done
    fi

    local total=$(( 1 + ${#MASTER_NAMES[@]} + ${#WORKER_NAMES[@]} ))
    log "Discovered ${total} node(s): 1 local master + ${#MASTER_NAMES[@]} other master(s) + ${#WORKER_NAMES[@]} worker(s)"
}

# ======================== SSH ACCESS CHECK ========================

check_ssh_access() {
    header "SSH CONNECTIVITY CHECK"

    if [[ ${#ALL_REMOTE_IPS[@]} -eq 0 ]]; then
        info "Single-node cluster, no remote SSH checks needed."
        return
    fi

    echo "" | tee -a "$LOG_FILE"
    echo -e "  ${BOLD}This script needs passwordless root SSH access to all remote${NC}" | tee -a "$LOG_FILE"
    echo -e "  ${BOLD}nodes via their InternalIP. Testing now...${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    local failed=()
    for ip in "${ALL_REMOTE_IPS[@]}"; do
        local rhost
        rhost=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "$ip" hostname 2>/dev/null | tail -1) || true

        if [[ -n "$rhost" ]]; then
            log "SSH OK : ${ip} → ${rhost}"
        else
            error "SSH FAIL: ${ip}"
            failed+=("$ip")
        fi
    done

    echo "" | tee -a "$LOG_FILE"

    if [[ ${#failed[@]} -gt 0 ]]; then
        error "SSH access failed for ${#failed[@]} node(s): ${failed[*]}"
        echo ""
        echo -e "${RED}  ┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}  │  Cannot proceed without SSH access to ALL nodes.             │${NC}"
        echo -e "${RED}  │                                                              │${NC}"
        echo -e "${RED}  │  Please ensure:                                              │${NC}"
        echo -e "${RED}  │    1. Root SSH keys are distributed to all nodes              │${NC}"
        echo -e "${RED}  │    2. Nodes are reachable on their InternalIP                 │${NC}"
        echo -e "${RED}  │    3. sshd is running and permits root login                  │${NC}"
        echo -e "${RED}  │                                                              │${NC}"
        echo -e "${RED}  │  Fix the above issues and re-run this script.                │${NC}"
        echo -e "${RED}  └──────────────────────────────────────────────────────────────┘${NC}"
        exit 1
    fi

    log "SSH access verified for all ${#ALL_REMOTE_IPS[@]} remote node(s)"
}

# ======================== VERSION CHECK ========================

check_versions() {
    header "VERSION CHECK"

    CURRENT_VERSION=$(kubectl get node "$LOCAL_HOSTNAME" -o jsonpath='{.status.nodeInfo.kubeletVersion}' | sed 's/^v//')
    CURRENT_MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f1,2)
    CURRENT_MINOR_NUM=$(echo "$CURRENT_MINOR" | cut -d. -f2)
    TARGET_MINOR_NUM=$(echo "$TARGET_MINOR" | cut -d. -f2)

    info "Current versions:"
    echo -e "    Kubelet    : v${CURRENT_VERSION}" | tee -a "$LOG_FILE"
    echo -e "    Target     : v${TARGET_MINOR}.x" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    info "Per-node versions:"
    kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,IP:.status.addresses[?(@.type=="InternalIP")].address' | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    # Warn about mixed versions
    local unique_versions
    unique_versions=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort -u | wc -l)
    if [[ "$unique_versions" -gt 1 ]]; then
        warn "Nodes are running different Kubernetes versions!"
        if [[ "$AUTO_YES" != "true" ]]; then
            if ! confirm "Continue anyway?"; then exit 1; fi
        fi
    fi

    if [[ "$CURRENT_MINOR_NUM" -ge "$TARGET_MINOR_NUM" ]]; then
        die "Current version (${CURRENT_MINOR}) is already at or above target (${TARGET_MINOR})."
    fi

    local hop_count=$(( TARGET_MINOR_NUM - CURRENT_MINOR_NUM ))
    local hop_list=""
    for ((m = CURRENT_MINOR_NUM + 1; m <= TARGET_MINOR_NUM; m++)); do
        hop_list+="1.${m} "
    done

    echo -e "  ${BOLD}Upgrade summary:${NC}" | tee -a "$LOG_FILE"
    echo -e "    From  : v${CURRENT_VERSION}" | tee -a "$LOG_FILE"
    echo -e "    To    : v${TARGET_MINOR}.x" | tee -a "$LOG_FILE"
    echo -e "    Hops  : ${hop_list}(${hop_count} total)" | tee -a "$LOG_FILE"
    echo -e "    Nodes : $(( 1 + ${#MASTER_NAMES[@]} + ${#WORKER_NAMES[@]} ))" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    if [[ "$AUTO_YES" != "true" ]]; then
        if ! confirm "Do you approve this upgrade? Kubelet will be restarted on all nodes."; then
            info "Upgrade cancelled by user."
            exit 0
        fi
    else
        info "Auto-approved (--yes)"
    fi
}

# ======================== HELPERS ========================

remote_exec() {
    local ip="$1"; shift
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$ip" "$@" 2>&1 | tee -a "$LOG_FILE"
}

node_name_by_ip() {
    local ip="$1"
    for i in "${!MASTER_IPS[@]}"; do
        [[ "${MASTER_IPS[$i]}" == "$ip" ]] && echo "${MASTER_NAMES[$i]}" && return
    done
    for i in "${!WORKER_IPS[@]}"; do
        [[ "${WORKER_IPS[$i]}" == "$ip" ]] && echo "${WORKER_NAMES[$i]}" && return
    done
    echo "unknown-${ip}"
}

wait_for_node_ready() {
    local name="$1" timeout=180 elapsed=0
    info "Waiting for node to become Ready: ${name}"
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(kubectl get node "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$status" == "True" ]]; then
            log "Node Ready: ${name}"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    error "TIMEOUT: ${name} did not become Ready within ${timeout}s"
    return 1
}

wait_for_system_pods() {
    info "Waiting 30s for kube-system pods to stabilize..."
    sleep 30
    local bad
    bad=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -v Running | grep -v Completed | wc -l)
    if [[ "$bad" -gt 0 ]]; then
        warn "${bad} kube-system pod(s) not Running:"
        kubectl get pods -n kube-system | grep -v Running | grep -v Completed | tee -a "$LOG_FILE"
    else
        log "All kube-system pods are Running"
    fi
}

# ======================== ETCD BACKUP ========================

take_etcd_backup() {
    local label="$1"
    local backup_file="/tmp/etcd-backup-${label}-$(date +%Y%m%d-%H%M%S).db"

    header "ETCD BACKUP: ${label}"

    if command -v etcdctl &>/dev/null; then
        info "Using local etcdctl..."
        ETCDCTL_API=3 etcdctl snapshot save "$backup_file" \
            --endpoints=https://127.0.0.1:2379 \
            --cacert=/etc/kubernetes/pki/etcd/ca.crt \
            --cert=/etc/kubernetes/pki/etcd/server.crt \
            --key=/etc/kubernetes/pki/etcd/server.key 2>&1 | tee -a "$LOG_FILE"
    else
        info "etcdctl not found locally, using etcd pod..."
        local etcd_pod="etcd-${LOCAL_HOSTNAME}"
        kubectl exec -n kube-system "$etcd_pod" -- etcdctl snapshot save /var/lib/etcd/snapshot.db \
            --endpoints=https://127.0.0.1:2379 \
            --cacert=/etc/kubernetes/pki/etcd/ca.crt \
            --cert=/etc/kubernetes/pki/etcd/server.crt \
            --key=/etc/kubernetes/pki/etcd/server.key 2>&1 | tee -a "$LOG_FILE"
        cp /var/lib/etcd/snapshot.db "$backup_file" 2>/dev/null || true
        rm -f /var/lib/etcd/snapshot.db 2>/dev/null || true
    fi

    if [[ -f "$backup_file" ]]; then
        local size; size=$(du -sh "$backup_file" | cut -f1)
        log "etcd backup saved: ${backup_file} (${size})"
    else
        error "etcd backup FAILED!"
        if [[ "$AUTO_YES" != "true" ]]; then
            if ! confirm "Continue without etcd backup? (NOT recommended)"; then
                exit 1
            fi
        else
            warn "Continuing without backup (--yes mode)"
        fi
    fi
}

# ======================== REPO MANAGEMENT ========================

change_repo_on_node() {
    local ip="$1" minor="$2"

    if [[ "$ip" == "$LOCAL_IP" ]]; then
        mkdir -p /etc/apt/keyrings
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release.key" | \
            gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes 2>/dev/null || true
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${minor}/deb/ /" | \
            tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
        apt-get update -qq 2>/dev/null || true
    else
        remote_exec "$ip" bash <<REPO_EOF
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes 2>/dev/null || true
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${minor}/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
apt-get update -qq 2>/dev/null || true
REPO_EOF
    fi
}

change_repo_all() {
    local minor="$1"
    header "UPDATING APT REPOS → v${minor} (all nodes)"

    info "Local: ${LOCAL_HOSTNAME} (${LOCAL_IP})"
    change_repo_on_node "$LOCAL_IP" "$minor"
    log "Repo OK: ${LOCAL_HOSTNAME}"

    for ip in "${ALL_REMOTE_IPS[@]}"; do
        local name; name=$(node_name_by_ip "$ip")
        info "Remote: ${name} (${ip})"
        change_repo_on_node "$ip" "$minor"
        log "Repo OK: ${name}"
    done

    log "All repos updated to v${minor}"
}

# ======================== PATCH VERSION SELECTION ========================

select_patch_version() {
    local minor="$1"

    # Point local repo to discover available versions
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release.key" | \
        gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes 2>/dev/null || true
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${minor}/deb/ /" | \
        tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
    apt-get update -qq 2>/dev/null || true

    local latest
    latest=$(apt-cache madison kubeadm 2>/dev/null | head -1 | awk '{print $3}' | cut -d'-' -f1)

    if [[ -z "$latest" ]]; then
        die "Could not find any patch version for v${minor} in the repository!"
    fi

    echo "" | tee -a "$LOG_FILE"
    info "Available patch versions for v${minor}:"
    apt-cache madison kubeadm 2>/dev/null | head -10 | while read -r line; do
        local ver; ver=$(echo "$line" | awk '{print $3}' | cut -d'-' -f1)
        echo -e "    ${ver}" | tee -a "$LOG_FILE"
    done
    echo "" | tee -a "$LOG_FILE"
    echo -e "  ${BOLD}Latest available: v${latest}${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    if [[ "$AUTO_YES" != "true" ]]; then
        read -rp "$(echo -e "${YELLOW}  ▶ Use v${latest}? Press Enter to accept, or type a different version (e.g. ${minor}.3): ${NC}")" custom
        if [[ -n "$custom" ]]; then
            # Validate
            if ! apt-cache madison kubeadm 2>/dev/null | awk '{print $3}' | cut -d'-' -f1 | grep -qx "$custom"; then
                die "Version ${custom} not found in repository!"
            fi
            latest="$custom"
        fi
    else
        info "Auto-selected latest: v${latest}"
    fi

    SELECTED_PATCH="$latest"
    log "Selected: v${SELECTED_PATCH}"
}

# ======================== PACKAGE INSTALL ========================

install_kubeadm() {
    local ip="$1" version="$2"
    local pkg="${version}-1.1"

    if [[ "$ip" == "$LOCAL_IP" ]]; then
        apt-mark unhold kubeadm 2>/dev/null || true
        apt-get install -y "kubeadm=${pkg}" 2>&1 | tee -a "$LOG_FILE"
        apt-mark hold kubeadm 2>&1 | tee -a "$LOG_FILE"
    else
        remote_exec "$ip" bash <<EOF
apt-mark unhold kubeadm 2>/dev/null || true
apt-get install -y "kubeadm=${pkg}"
apt-mark hold kubeadm
EOF
    fi
}

install_kubelet_kubectl() {
    local ip="$1" version="$2"
    local pkg="${version}-1.1"

    if [[ "$ip" == "$LOCAL_IP" ]]; then
        apt-mark unhold kubelet kubectl 2>/dev/null || true
        apt-get install -y "kubelet=${pkg}" "kubectl=${pkg}" 2>&1 | tee -a "$LOG_FILE"
        apt-mark hold kubelet kubectl 2>&1 | tee -a "$LOG_FILE"
        systemctl daemon-reload
        systemctl restart kubelet
    else
        remote_exec "$ip" bash <<EOF
apt-mark unhold kubelet kubectl 2>/dev/null || true
apt-get install -y "kubelet=${pkg}" "kubectl=${pkg}"
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet
EOF
    fi
}

# ======================== NODE UPGRADE ========================

upgrade_first_master() {
    local version="$1"
    header "UPGRADE FIRST MASTER: ${LOCAL_HOSTNAME} (${LOCAL_IP}) → v${version}"

    info "Installing kubeadm v${version}..."
    install_kubeadm "$LOCAL_IP" "$version"

    info "Running: kubeadm upgrade plan"
    kubeadm upgrade plan 2>&1 | tail -15 | tee -a "$LOG_FILE"

    info "Running: kubeadm upgrade apply v${version}"
    if ! kubeadm upgrade apply "v${version}" --ignore-preflight-errors=CreateJob -y 2>&1 | tee -a "$LOG_FILE"; then
        error "kubeadm upgrade apply FAILED!"
        die "Cannot continue. Check the log: ${LOG_FILE}"
    fi
    log "Control plane upgraded to v${version}"

    info "Installing kubelet & kubectl v${version}..."
    install_kubelet_kubectl "$LOCAL_IP" "$version"

    wait_for_node_ready "$LOCAL_HOSTNAME"
    log "First master done: ${LOCAL_HOSTNAME} → v${version}"
}

upgrade_other_master() {
    local ip="$1" version="$2"
    local name; name=$(node_name_by_ip "$ip")
    header "UPGRADE MASTER: ${name} (${ip}) → v${version}"

    info "Installing kubeadm v${version} on ${name}..."
    install_kubeadm "$ip" "$version"

    info "Running: kubeadm upgrade node on ${name}"
    remote_exec "$ip" "kubeadm upgrade node"

    info "Draining ${name}..."
    kubectl drain "$name" --ignore-daemonsets --delete-emptydir-data --timeout=120s 2>&1 | tee -a "$LOG_FILE"

    info "Installing kubelet & kubectl v${version} on ${name}..."
    install_kubelet_kubectl "$ip" "$version"

    info "Uncordoning ${name}..."
    kubectl uncordon "$name" 2>&1 | tee -a "$LOG_FILE"

    wait_for_node_ready "$name"
    log "Master done: ${name} → v${version}"
}

upgrade_worker() {
    local ip="$1" version="$2"
    local name; name=$(node_name_by_ip "$ip")
    header "UPGRADE WORKER: ${name} (${ip}) → v${version}"

    info "Draining ${name}..."
    kubectl drain "$name" --ignore-daemonsets --delete-emptydir-data --timeout=300s 2>&1 | tee -a "$LOG_FILE"

    info "Installing kubeadm v${version} on ${name}..."
    install_kubeadm "$ip" "$version"

    info "Running: kubeadm upgrade node on ${name}"
    remote_exec "$ip" "kubeadm upgrade node"

    info "Installing kubelet & kubectl v${version} on ${name}..."
    install_kubelet_kubectl "$ip" "$version"

    info "Uncordoning ${name}..."
    kubectl uncordon "$name" 2>&1 | tee -a "$LOG_FILE"

    wait_for_node_ready "$name"
    log "Worker done: ${name} → v${version}"
}

# ======================== HEALTH CHECK ========================

cluster_health_check() {
    header "CLUSTER HEALTH CHECK"
    info "Node status:"
    kubectl get nodes -o wide | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    local not_ready
    not_ready=$(kubectl get nodes --no-headers | grep -cv " Ready " || true)
    if [[ "$not_ready" -gt 0 ]]; then
        error "${not_ready} node(s) NOT Ready!"
    else
        log "All nodes are Ready"
    fi
}

# ======================== SINGLE HOP ========================

perform_hop() {
    local patch_version="$1"
    local minor; minor=$(echo "$patch_version" | cut -d. -f1,2)

    # 1. etcd backup
    take_etcd_backup "pre-${minor}"

    # 2. Repos
    change_repo_all "$minor"

    # 3. First master
    upgrade_first_master "$patch_version"

    # 4. Other masters
    for ip in "${MASTER_IPS[@]}"; do
        upgrade_other_master "$ip" "$patch_version"
    done

    # 5. Workers
    for ip in "${WORKER_IPS[@]}"; do
        upgrade_worker "$ip" "$patch_version"
    done

    # 6. Settle
    wait_for_system_pods
    cluster_health_check

    log "══════ HOP COMPLETE: v${patch_version} ══════"
}

# ======================== MAIN ========================

main() {
    for arg in "$@"; do
        case "$arg" in
            --yes) AUTO_YES="true" ;;
            -h|--help) usage ;;
            -*) die "Unknown option: $arg" ;;
            *)  [[ -z "$TARGET_ARG" ]] && TARGET_ARG="$arg" ;;
        esac
    done

    [[ -z "$TARGET_ARG" ]] && usage

    # Parse target
    if [[ "$TARGET_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        EXPLICIT_PATCH="$TARGET_ARG"
        TARGET_MINOR=$(echo "$TARGET_ARG" | cut -d. -f1,2)
    elif [[ "$TARGET_ARG" =~ ^[0-9]+\.[0-9]+$ ]]; then
        TARGET_MINOR="$TARGET_ARG"
    else
        die "Invalid version format: ${TARGET_ARG} (expected: 1.34 or 1.34.4)"
    fi

    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║         kubeadm Cluster Upgrade Script                ║"
    echo "  ╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    info "Log file: ${LOG_FILE}"

    check_prerequisites
    discover_nodes
    check_ssh_access
    check_versions

    # Build hop list
    local hops=()
    for ((m = CURRENT_MINOR_NUM + 1; m <= TARGET_MINOR_NUM; m++)); do
        hops+=("1.${m}")
    done

    local total_hops=${#hops[@]}
    local hop_num=0

    for minor in "${hops[@]}"; do
        hop_num=$((hop_num + 1))
        header "PREPARING HOP ${hop_num}/${total_hops}: → v${minor}"

        local patch_version
        if [[ "$minor" == "$TARGET_MINOR" && -n "$EXPLICIT_PATCH" ]]; then
            patch_version="$EXPLICIT_PATCH"
            info "Using specified version: v${patch_version}"
        else
            select_patch_version "$minor"
            patch_version="$SELECTED_PATCH"
        fi

        perform_hop "$patch_version"

        # Inter-hop pause
        if [[ $hop_num -lt $total_hops ]]; then
            echo "" | tee -a "$LOG_FILE"
            log "Hop ${hop_num}/${total_hops} complete. Next: v${hops[$hop_num]}"
            if [[ "$AUTO_YES" != "true" ]]; then
                if ! confirm "Proceed to next hop?"; then
                    warn "Stopped by user after hop ${hop_num}."
                    exit 0
                fi
            fi
        fi
    done

    # Final
    header "UPGRADE COMPLETE!"
    echo "" | tee -a "$LOG_FILE"
    kubectl get nodes -o wide | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    kubectl version 2>&1 | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    take_etcd_backup "post-upgrade-final"

    log "All upgrades completed successfully!"
    log "Log file: ${LOG_FILE}"
}

main "$@"
