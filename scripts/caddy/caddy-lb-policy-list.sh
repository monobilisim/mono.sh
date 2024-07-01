#!/usr/bin/env bash
###~ description: List all load balancer policies for all Caddy servers
VERSION="1.5.0"

#shellcheck disable=SC1091
. "caddy-common.sh" || exit 1

if [[ "$1" == "--version" ]] || [[ "$1" == "-v" ]]; then
    echo "v$VERSION"
    exit 0
fi

function warn() {
    echo "warning: $1"
}

function init_list() {
    printf "%-10s" "|"
    printf "%15s" "SERVERS"
    printf "%17s" " | "
    for i in "$@"; do
        line=$(echo "$i" | cut -d';' -f2)
        printf "%s" " $line | "
    done
    echo
}

function show_list() {
    if [[ ! -d "/tmp/glb/$1" ]]; then
        warn "glb directory for $1 doesn't exist, please run caddy-lb-policy-switcher first"
        return
    fi
    
    printf "%-40s" "| $1"
    printf "|"

    for lb in /tmp/glb/"$1"/*; do
        if [[ -f "$lb/lb_policy" ]]; then
            printf "%s" " $(cat "$lb"/lb_policy) |"
        fi
    done
    echo
}

parse_caddy

init_list "${CADDY_API_URLS[@]}"

for server in "${CADDY_SERVERS[@]}"; do
    show_list "$server"
done
