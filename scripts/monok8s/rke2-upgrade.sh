#!/bin/bash
###############################################################################
# RKE2 Cluster Upgrade Script
#
# A generic, interactive script to upgrade RKE2 clusters.
# Auto-discovers nodes via kubectl, checks SSH connectivity, and performs
# sequential minor version hops with etcd snapshots and health checks.
#
# Usage:
#   ./rke2-upgrade.sh <TARGET_MINOR>   [OPTIONS]
#   ./rke2-upgrade.sh <TARGET_VERSION> [OPTIONS]
#
# Examples:
#   ./rke2-upgrade.sh 1.34             # Upgrade to latest patch of 1.34
#   ./rke2-upgrade.sh v1.34.5+rke2r1   # Upgrade to specific RKE2 version
#   ./rke2-upgrade.sh 1.34 --yes       # Skip confirmations
#
# Requirements:
#   - Must be run on a server (control-plane) node as root
#   - Passwordless root SSH access to all other nodes via their InternalIP
#   - kubectl, curl must be available
#   - Internet access to https://get.rke2.io and https://update.rke2.io
#
###############################################################################

set -uo pipefail

# ======================== COLORS & LOGGING ========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="/tmp/rke2-upgrade-$(date +%Y%m%d-%H%M%S).log"

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
RKE2 Cluster Upgrade Script

Usage:
  ./rke2-upgrade.sh <TARGET_MINOR>   [OPTIONS]
  ./rke2-upgrade.sh <TARGET_VERSION> [OPTIONS]

Examples:
  ./rke2-upgrade.sh 1.34                 Upgrade to latest stable of 1.34
  ./rke2-upgrade.sh v1.34.5+rke2r1       Upgrade to specific RKE2 release
  ./rke2-upgrade.sh 1.34 --yes           Skip confirmations

Options:
  --yes       Skip confirmations
  -h, --help  Show this help

Requirements:
  - Must be run on a server (control-plane) node as root
  - Passwordless root SSH access to all other nodes via their InternalIP
  - kubectl, curl available on this node
  - Internet access to https://get.rke2.io and https://update.rke2.io
EOF
    exit 0
}

# ======================== GLOBAL VARIABLES ========================
AUTO_YES="false"
TARGET_ARG=""
TARGET_MINOR=""
EXPLICIT_VERSION=""
LOCAL_HOSTNAME=""
LOCAL_IP=""
CURRENT_VERSION=""
CURRENT_K8S_VERSION=""
CURRENT_MINOR=""
CURRENT_MINOR_NUM=""
TARGET_MINOR_NUM=""
SELECTED_VERSION=""

declare -a SERVER_NAMES=()
declare -a SERVER_IPS=()
declare -a AGENT_NAMES=()
declare -a AGENT_IPS=()
declare -a ALL_REMOTE_IPS=()

# ======================== KUBECTL WRAPPER ========================
# RKE2 installs kubectl at a non-standard path
KUBECTL=""

find_kubectl() {
    if command -v kubectl &>/dev/null; then
        KUBECTL="kubectl"
    elif [[ -x /var/lib/rancher/rke2/bin/kubectl ]]; then
        KUBECTL="/var/lib/rancher/rke2/bin/kubectl"
        export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
    else
        die "kubectl not found. Ensure RKE2 is installed and running."
    fi
}

# ======================== PREREQUISITE CHECKS ========================

check_prerequisites() {
    header "PREREQUISITE CHECKS"

    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root."
    fi
    log "Running as root"

    # Required commands
    local missing=()
    for cmd in curl ssh; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi

    # Find kubectl
    find_kubectl
    log "Using kubectl: ${KUBECTL}"

    # Check if RKE2 is running
    if ! systemctl is-active --quiet rke2-server 2>/dev/null; then
        die "rke2-server is not running on this node. This script must be run on an active RKE2 server node."
    fi
    log "rke2-server is active"

    # Ensure KUBECONFIG is set
    if [[ -z "${KUBECONFIG:-}" ]]; then
        if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
            export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        fi
    fi

    LOCAL_HOSTNAME=$(hostname)
    local role_col
    role_col=$($KUBECTL get node "$LOCAL_HOSTNAME" --no-headers 2>/dev/null | awk '{print $3}') || true

    if ! echo "$role_col" | grep -qi "control-plane"; then
        echo ""
        echo -e "${RED}  ┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}  │  This script must be run on a server (control-plane) node.   │${NC}"
        echo -e "${RED}  │                                                              │${NC}"
        echo -e "${RED}  │  Current hostname '${LOCAL_HOSTNAME}' does not appear to be       │${NC}"
        echo -e "${RED}  │  a control-plane node.                                       │${NC}"
        echo -e "${RED}  │                                                              │${NC}"
        echo -e "${RED}  │  Please SSH into a server node and run this script there.    │${NC}"
        echo -e "${RED}  └──────────────────────────────────────────────────────────────┘${NC}"
        exit 1
    fi
    log "Running on control-plane node: ${LOCAL_HOSTNAME}"

    LOCAL_IP=$($KUBECTL get node "$LOCAL_HOSTNAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [[ -z "$LOCAL_IP" ]]; then
        die "Could not determine InternalIP of ${LOCAL_HOSTNAME}"
    fi
    log "Local node IP: ${LOCAL_IP}"

    # Check internet access
    if ! curl -sfL --max-time 10 https://update.rke2.io/v1-release/channels >/dev/null 2>&1; then
        warn "Cannot reach https://update.rke2.io — version discovery may fail"
    else
        log "Internet access to RKE2 channels: OK"
    fi
}

# ======================== NODE DISCOVERY ========================

discover_nodes() {
    header "NODE DISCOVERY"
    info "Querying cluster nodes via kubectl..."

    while read -r name status roles age version; do
        [[ -z "$name" ]] && continue
        [[ "$name" == "$LOCAL_HOSTNAME" ]] && continue

        local ip
        ip=$($KUBECTL get node "$name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        [[ -z "$ip" ]] && continue

        if echo "$roles" | grep -qi "control-plane\|master"; then
            SERVER_NAMES+=("$name")
            SERVER_IPS+=("$ip")
        else
            AGENT_NAMES+=("$name")
            AGENT_IPS+=("$ip")
        fi
        ALL_REMOTE_IPS+=("$ip")
    done < <($KUBECTL get nodes --no-headers 2>/dev/null)

    echo "" | tee -a "$LOG_FILE"
    info "Cluster topology:"
    echo -e "  ${BOLD}Server (this node):${NC}" | tee -a "$LOG_FILE"
    echo -e "    ${LOCAL_HOSTNAME} (${LOCAL_IP}) ← you are here" | tee -a "$LOG_FILE"

    if [[ ${#SERVER_NAMES[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Other server nodes:${NC}" | tee -a "$LOG_FILE"
        for i in "${!SERVER_NAMES[@]}"; do
            echo -e "    ${SERVER_NAMES[$i]} (${SERVER_IPS[$i]})" | tee -a "$LOG_FILE"
        done
    fi

    if [[ ${#AGENT_NAMES[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Agent nodes:${NC}" | tee -a "$LOG_FILE"
        for i in "${!AGENT_NAMES[@]}"; do
            echo -e "    ${AGENT_NAMES[$i]} (${AGENT_IPS[$i]})" | tee -a "$LOG_FILE"
        done
    fi

    local total=$(( 1 + ${#SERVER_NAMES[@]} + ${#AGENT_NAMES[@]} ))
    log "Discovered ${total} node(s): 1 local server + ${#SERVER_NAMES[@]} other server(s) + ${#AGENT_NAMES[@]} agent(s)"
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

    # Get current RKE2 version from the binary
    CURRENT_VERSION=$(rke2 --version 2>/dev/null | head -1 | awk '{print $3}' || echo "unknown")
    # Extract Kubernetes version (e.g. v1.31.14 from v1.31.14+rke2r1)
    CURRENT_K8S_VERSION=$(echo "$CURRENT_VERSION" | sed 's/+.*//' | sed 's/^v//')
    CURRENT_MINOR=$(echo "$CURRENT_K8S_VERSION" | cut -d. -f1,2)
    CURRENT_MINOR_NUM=$(echo "$CURRENT_MINOR" | cut -d. -f2)
    TARGET_MINOR_NUM=$(echo "$TARGET_MINOR" | cut -d. -f2)

    info "Current versions:"
    echo -e "    RKE2       : ${CURRENT_VERSION}" | tee -a "$LOG_FILE"
    echo -e "    Kubernetes : v${CURRENT_K8S_VERSION}" | tee -a "$LOG_FILE"
    echo -e "    Target     : v${TARGET_MINOR}.x" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    info "Per-node versions:"
    $KUBECTL get nodes --no-headers -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,IP:.status.addresses[?(@.type=="InternalIP")].address' | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    # Mixed versions warning
    local unique_versions
    unique_versions=$($KUBECTL get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort -u | wc -l)
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
    echo -e "    From  : ${CURRENT_VERSION}" | tee -a "$LOG_FILE"
    echo -e "    To    : v${TARGET_MINOR}.x" | tee -a "$LOG_FILE"
    echo -e "    Hops  : ${hop_list}(${hop_count} total)" | tee -a "$LOG_FILE"
    echo -e "    Nodes : $(( 1 + ${#SERVER_NAMES[@]} + ${#AGENT_NAMES[@]} ))" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    if [[ "$AUTO_YES" != "true" ]]; then
        if ! confirm "Do you approve this upgrade? RKE2 will be restarted on all nodes."; then
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
    for i in "${!SERVER_IPS[@]}"; do
        [[ "${SERVER_IPS[$i]}" == "$ip" ]] && echo "${SERVER_NAMES[$i]}" && return
    done
    for i in "${!AGENT_IPS[@]}"; do
        [[ "${AGENT_IPS[$i]}" == "$ip" ]] && echo "${AGENT_NAMES[$i]}" && return
    done
    echo "unknown-${ip}"
}

wait_for_node_ready() {
    local name="$1" timeout=300 elapsed=0
    info "Waiting for node to become Ready: ${name}"
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$($KUBECTL get node "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$status" == "True" ]]; then
            log "Node Ready: ${name}"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    error "TIMEOUT: ${name} did not become Ready within ${timeout}s"
    return 1
}

wait_for_system_pods() {
    info "Waiting 30s for system pods to stabilize..."
    sleep 30
    local bad
    bad=$($KUBECTL get pods -n kube-system --no-headers 2>/dev/null | grep -v Running | grep -v Completed | wc -l)
    if [[ "$bad" -gt 0 ]]; then
        warn "${bad} kube-system pod(s) not Running:"
        $KUBECTL get pods -n kube-system | grep -v Running | grep -v Completed | tee -a "$LOG_FILE"
    else
        log "All kube-system pods are Running"
    fi
}

# ======================== ETCD SNAPSHOT ========================

take_etcd_snapshot() {
    local label="$1"
    header "ETCD SNAPSHOT: ${label}"

    info "Taking on-demand etcd snapshot..."
    if rke2 etcd-snapshot save --name "upgrade-${label}-$(date +%Y%m%d-%H%M%S)" 2>&1 | tee -a "$LOG_FILE"; then
        log "etcd snapshot saved"
        info "Snapshots:"
        rke2 etcd-snapshot list 2>&1 | tail -5 | tee -a "$LOG_FILE"
    else
        error "etcd snapshot FAILED!"
        if [[ "$AUTO_YES" != "true" ]]; then
            if ! confirm "Continue without etcd snapshot? (NOT recommended)"; then
                exit 1
            fi
        else
            warn "Continuing without snapshot (--yes mode)"
        fi
    fi
}

# ======================== VERSION DISCOVERY ========================

discover_rke2_version() {
    local minor="$1"

    info "Querying RKE2 channel API for v${minor} releases..."

    # Try the version-specific channel first
    local channel_url="https://update.rke2.io/v1-release/channels/v${minor}"
    local channel_version
    channel_version=$(curl -sfL "$channel_url" 2>/dev/null | grep -oP '"latest"\s*:\s*"\K[^"]+' || true)

    # Also check via GitHub releases API
    local releases=""
    releases=$(curl -sfL "https://api.github.com/repos/rancher/rke2/releases?per_page=30" 2>/dev/null | \
        grep -oP '"tag_name"\s*:\s*"\K[^"]+' | \
        grep "^v${minor}\." | \
        grep -v "\-rc" | \
        head -10 || true)

    if [[ -z "$releases" && -z "$channel_version" ]]; then
        die "Could not find any RKE2 releases for v${minor}!"
    fi

    echo "" | tee -a "$LOG_FILE"
    info "Available RKE2 releases for v${minor}:"

    if [[ -n "$channel_version" ]]; then
        echo -e "    ${BOLD}Channel (stable): ${channel_version}${NC}" | tee -a "$LOG_FILE"
    fi

    if [[ -n "$releases" ]]; then
        echo "$releases" | while read -r ver; do
            echo -e "    ${ver}" | tee -a "$LOG_FILE"
        done
    fi

    # Determine the best version
    local best=""
    if [[ -n "$channel_version" ]]; then
        best="$channel_version"
    elif [[ -n "$releases" ]]; then
        best=$(echo "$releases" | head -1)
    fi

    echo "" | tee -a "$LOG_FILE"
    echo -e "  ${BOLD}Recommended: ${best}${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    if [[ "$AUTO_YES" != "true" ]]; then
        read -rp "$(echo -e "${YELLOW}  ▶ Use ${best}? Press Enter to accept, or type a different version (e.g. v${minor}.5+rke2r1): ${NC}")" custom
        if [[ -n "$custom" ]]; then
            best="$custom"
        fi
    else
        info "Auto-selected: ${best}"
    fi

    SELECTED_VERSION="$best"
    log "Selected RKE2 version: ${SELECTED_VERSION}"
}

# ======================== NODE UPGRADE ========================

install_rke2_on_node() {
    local ip="$1" version="$2" node_type="$3"

    if [[ "$ip" == "$LOCAL_IP" ]]; then
        info "Installing RKE2 ${version} locally..."
        curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="$version" sh - 2>&1 | tee -a "$LOG_FILE"
    else
        info "Installing RKE2 ${version} on remote node..."
        if [[ "$node_type" == "agent" ]]; then
            remote_exec "$ip" "curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION='${version}' INSTALL_RKE2_TYPE=agent sh -"
        else
            remote_exec "$ip" "curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION='${version}' sh -"
        fi
    fi
}

restart_rke2_on_node() {
    local ip="$1" node_type="$2"
    local service="rke2-server"
    [[ "$node_type" == "agent" ]] && service="rke2-agent"

    if [[ "$ip" == "$LOCAL_IP" ]]; then
        info "Restarting ${service} locally..."
        systemctl restart "$service" 2>&1 | tee -a "$LOG_FILE"
    else
        info "Restarting ${service} on remote node..."
        remote_exec "$ip" "systemctl restart ${service}"
    fi
}

upgrade_first_server() {
    local version="$1"
    header "UPGRADE FIRST SERVER: ${LOCAL_HOSTNAME} (${LOCAL_IP}) → ${version}"

    install_rke2_on_node "$LOCAL_IP" "$version" "server"
    log "RKE2 binary installed: ${version}"

    info "Restarting rke2-server (this may take a few minutes)..."
    systemctl restart rke2-server 2>&1 | tee -a "$LOG_FILE"

    # Wait for the service to be active
    info "Waiting for rke2-server to become active..."
    local timeout=300 elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if systemctl is-active --quiet rke2-server 2>/dev/null; then
            log "rke2-server is active"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    if [[ $elapsed -ge $timeout ]]; then
        error "rke2-server did not become active within ${timeout}s"
        journalctl -u rke2-server --no-pager -n 20 | tee -a "$LOG_FILE"
        die "First server upgrade failed. Check logs."
    fi

    # Wait for node Ready
    sleep 15
    wait_for_node_ready "$LOCAL_HOSTNAME"
    log "First server done: ${LOCAL_HOSTNAME} → ${version}"
}

upgrade_other_server() {
    local ip="$1" version="$2"
    local name; name=$(node_name_by_ip "$ip")
    header "UPGRADE SERVER: ${name} (${ip}) → ${version}"

    # Drain
    info "Draining ${name}..."
    $KUBECTL drain "$name" --ignore-daemonsets --delete-emptydir-data --timeout=120s 2>&1 | tee -a "$LOG_FILE"

    # Install + restart
    install_rke2_on_node "$ip" "$version" "server"
    restart_rke2_on_node "$ip" "server"

    # Wait and uncordon
    sleep 30
    info "Uncordoning ${name}..."
    $KUBECTL uncordon "$name" 2>&1 | tee -a "$LOG_FILE"

    wait_for_node_ready "$name"
    log "Server done: ${name} → ${version}"
}

upgrade_agent() {
    local ip="$1" version="$2"
    local name; name=$(node_name_by_ip "$ip")
    header "UPGRADE AGENT: ${name} (${ip}) → ${version}"

    # Drain
    info "Draining ${name}..."
    $KUBECTL drain "$name" --ignore-daemonsets --delete-emptydir-data --timeout=300s 2>&1 | tee -a "$LOG_FILE"

    # Install + restart
    install_rke2_on_node "$ip" "$version" "agent"
    restart_rke2_on_node "$ip" "agent"

    # Wait and uncordon
    sleep 20
    info "Uncordoning ${name}..."
    $KUBECTL uncordon "$name" 2>&1 | tee -a "$LOG_FILE"

    wait_for_node_ready "$name"
    log "Agent done: ${name} → ${version}"
}

# ======================== HEALTH CHECK ========================

cluster_health_check() {
    header "CLUSTER HEALTH CHECK"
    info "Node status:"
    $KUBECTL get nodes -o wide | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    local not_ready
    not_ready=$($KUBECTL get nodes --no-headers | grep -cv " Ready " || true)
    if [[ "$not_ready" -gt 0 ]]; then
        error "${not_ready} node(s) NOT Ready!"
    else
        log "All nodes are Ready"
    fi
}

# ======================== SINGLE HOP ========================

perform_hop() {
    local version="$1"

    # 1. etcd snapshot
    take_etcd_snapshot "pre-$(echo "$version" | sed 's/+/-/g')"

    # 2. First server
    upgrade_first_server "$version"

    # 3. Other servers
    for ip in "${SERVER_IPS[@]}"; do
        upgrade_other_server "$ip" "$version"
    done

    # 4. Agents
    for ip in "${AGENT_IPS[@]}"; do
        upgrade_agent "$ip" "$version"
    done

    # 5. Settle
    wait_for_system_pods
    cluster_health_check

    log "══════ HOP COMPLETE: ${version} ══════"
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

    # Parse target: "1.34", "v1.34.5+rke2r1", etc.
    if [[ "$TARGET_ARG" =~ \+rke2r ]]; then
        # Full RKE2 version given (v1.34.5+rke2r1)
        EXPLICIT_VERSION="$TARGET_ARG"
        TARGET_MINOR=$(echo "$TARGET_ARG" | sed 's/^v//' | cut -d. -f1,2)
    elif [[ "$TARGET_ARG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Kubernetes version without rke2 suffix (1.34.5 or v1.34.5)
        EXPLICIT_VERSION=""
        TARGET_MINOR=$(echo "$TARGET_ARG" | sed 's/^v//' | cut -d. -f1,2)
    elif [[ "$TARGET_ARG" =~ ^v?[0-9]+\.[0-9]+$ ]]; then
        # Minor version only (1.34)
        TARGET_MINOR=$(echo "$TARGET_ARG" | sed 's/^v//')
    else
        die "Invalid version format: ${TARGET_ARG} (expected: 1.34, v1.34.5+rke2r1, etc.)"
    fi

    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║            RKE2 Cluster Upgrade Script                ║"
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

        local rke2_version
        if [[ "$minor" == "$TARGET_MINOR" && -n "$EXPLICIT_VERSION" ]]; then
            rke2_version="$EXPLICIT_VERSION"
            info "Using specified version: ${rke2_version}"
        else
            discover_rke2_version "$minor"
            rke2_version="$SELECTED_VERSION"
        fi

        perform_hop "$rke2_version"

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
    $KUBECTL get nodes -o wide | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    rke2 --version 2>&1 | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    take_etcd_snapshot "post-upgrade-final"

    log "All upgrades completed successfully!"
    log "Log file: ${LOG_FILE}"
}

main "$@"
