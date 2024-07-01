#!/usr/bin/env bash
###~ description: Checks the status of pmg and related services

VERSION=v1.5.0

#shellcheck disable=SC2034
SCRIPT_NAME="pmg-health"

#shellcheck disable=SC2034
SCRIPT_NAME_PRETTY="PMG Health"

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/common.sh

create_tmp_dir

parse_config_pmg() {
    CONFIG_PATH_PMG="mail"
    export REQUIRED=true
    
    QUEUE_LIMIT=$(yaml .pmg.queue_limit $CONFIG_PATH_PMG)

    SEND_ALARM=$(yaml .alarm.enabled "$CONFIG_PATH_POSTAL" "$SEND_ALARM")
}

parse_config_pmg

pmg_services=("pmgproxy.service" "pmg-smtp-filter.service" "postfix@-.service")

function check_pmg_services() {
    echo_status "PMG Services"
    for i in "${pmg_services[@]}"; do
        if systemctl status "$i" >/dev/null; then
            print_colour "$i" "running"
            alarm_check_up "$i" "Service $i is working again" "service"
        else
            print_colour "$i" "not running" "error"
            alarm_check_down "$i" "Service $i is not working" "service"
        fi
    done
}

function postgresql_status() {
    echo_status "PostgreSQL Status"
    if pg_isready -q; then
        alarm_check_up "postgresql" "PostgreSQL is working again"
        print_colour "PostgreSQL" "running"
    else
        alarm_check_down "postgresql" "PostgreSQL is not working"
        print_colour "PostgreSQL" "not running" "error"
    fi
}

function queued_messages() {
    echo_status "Queued Messages"
    queue=$(mailq | grep -c "^[A-F0-9]")
    if [ "$queue" -lt "$QUEUE_LIMIT" ]; then
        print_colour "Number of queued messages" "$queue"
        alarm_check_up "queued" "Number of queued messages is acceptable - $queue/$QUEUE_LIMIT" "queue"
    else
        print_colour "Number of queued messages" "$queue" "error"
        alarm_check_down "queued" "Number of queued messages is above limit - $queue/$QUEUE_LIMIT" "queue"
    fi
}

function main() {
    pid_file="$(create_pid)"
    printf '\n'
    echo "Monomail PMG Health $VERSION - $(date)"
    printf '\n'
    check_pmg_services
    printf '\n'
    postgresql_status
    printf '\n'
    queued_messages
}

main

rm "${pid_file}"
