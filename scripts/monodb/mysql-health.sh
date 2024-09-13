#!/usr/bin/env bash
###~ description: Checks the status of MySQL and MySQL cluster

#shellcheck disable=SC2034
VERSION=v2.8.1
SCRIPT_NAME="mysql-health"
SCRIPT_NAME_PRETTY="MySQL Health"

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$(
    cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit
    pwd -P
)"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

create_tmp_dir

cron_mode "$ENABLE_CRON"

function parse_config_mysql() {
    CONFIG_PATH_MONODB="db"
    export REQUIRED=true

    PROCESS_LIMIT=$(yaml .mysql.process_limit $CONFIG_PATH_MONODB)
    CLUSTER_SIZE=$(yaml .mysql.cluster.size $CONFIG_PATH_MONODB)
    IS_CLUSTER=$(yaml .mysql.cluster.enabled $CONFIG_PATH_MONODB)
    CHECK_TABLE_DAY=$(yaml .mysql.cluster.check_table_day $CONFIG_PATH_MONODB)
    CHECK_TABLE_HOUR=$(yaml .mysql.cluster.check_table_hour $CONFIG_PATH_MONODB)

    SEND_ALARM=$(yaml .mysql.alarm.enabled $CONFIG_PATH_MONODB "$SEND_ALARM")
}

function containsElement() {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

function select_now() {
    echo_status "MySQL Access:"
    if mysql -sNe "SELECT NOW();" >/dev/null; then
        alarm_check_up "now" "Can run 'SELECT' statements again"
        print_colour "MySQL" "accessible"
    else
        alarm_check_down "now" "Couldn't run a 'SELECT' statement on MySQL"
        print_colour "MySQL" "not accessible" "error"
        exit 1
    fi
}

function write_processlist() {
    mkdir -p /var/log/monodb
    mysql -e "SELECT * FROM INFORMATION_SCHEMA.PROCESSLIST WHERE USER != 'root' ORDER BY TIME DESC;" >/var/log/monodb/mysql-processlist-"$(date +"%a")".log
}

function check_process_count() {
    echo_status "Number of Processes:"
    processlist_count=$(/usr/bin/mysqladmin processlist | grep -vc 'show processlist')
    file="$TMP_PATH_SCRIPT/processlist.txt"
    if [ -f "$file" ]; then
        increase=$(cat "$file")
    else
        increase=1
    fi

    if [[ "$processlist_count" -lt "$PROCESS_LIMIT" ]]; then
        alarm_check_up "no_processes" "Number of processes is below limit: $processlist_count/$PROCESS_LIMIT" "process"
        print_colour "Number of Processes" "$processlist_count/$PROCESS_LIMIT"
        rm -f "$file"
    else
        alarm_check_down "no_processes" "Number of processes is above limit: $processlist_count/$PROCESS_LIMIT" "process"
        print_colour "Number of Processes" "$processlist_count/$PROCESS_LIMIT" "error"
        difference=$(((processlist_count - PROCESS_LIMIT) / 10))
        if [[ $difference -ge $increase ]]; then
            write_processlist
            if [ -f "$file" ]; then
                alarm "[MySQL - $IDENTIFIER] [:red_circle:] Number of processes surpassed $((PROCESS_LIMIT + (increase * 10))): $processlist_count/$PROCESS_LIMIT"
            fi
            increase=$((difference + 1))
        fi
        echo "$increase" >"$file"
    fi

}

function inaccessible_clusters() {
    listening_clusters=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_incoming_addresses';" | awk '{print $2}' | sed 's/,/\ /g')
    # shellcheck disable=SC2206
    listening_clusters_array=($listening_clusters)

    file="$TMP_PATH_SCRIPT/cluster_nodes.txt"
    if [ -f "$file" ]; then
        # shellcheck disable=SC2207
        old_clusters=($(cat "$file"))
        for cluster in "${old_clusters[@]}"; do
            if containsElement "$cluster" "${listening_clusters_array[@]}"; then
                continue
            else
                alarm_check_down "$cluster" "Node $cluster is no longer in the cluster."
            fi
        done
    fi
    echo "$listening_clusters" >"$file"
}

function check_cluster_status() {
    echo_status "Cluster Status:"
    cluster_status=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_cluster_size';")
    no_cluster=$(echo "$cluster_status" | awk '{print $2}')

    IDENTIFIER_REDMINE=$(echo "$IDENTIFIER" | cut -d'-' -f1-2)

    if [[ ! -f /tmp/mono/mysql-cluster-size-redmine.log ]]; then
        if monokit redmine issue exists --subject "Cluster size is $no_cluster at $IDENTIFIER_REDMINE" --date "$(date +"%Y-%m-%d")" >"$TMP_PATH_SCRIPT"/pgsql-cluster-size-redmine.log; then
            ISSUE_ID=$(cat "$TMP_PATH_SCRIPT"/mysql-cluster-size-redmine.log)
        fi

        if [[ -z "$ISSUE_ID" ]]; then
            mkdir -p /tmp/mono
            # Put issue ID in a file so monokit can know it is already created
            echo "$ISSUE_ID" >/tmp/mono/mysql-cluster-size-redmine.log
        fi
    fi

    if [ "$no_cluster" -eq "$CLUSTER_SIZE" ]; then
        alarm_check_up "cluster_size" "Cluster size is accurate: $no_cluster/$CLUSTER_SIZE"
        monokit redmine issue close --service "mysql-cluster-size" --message "MySQL cluster size is $no_cluster at $IDENTIFIER_REDMINE"
        print_colour "Cluster size" "$no_cluster/$CLUSTER_SIZE"
    elif [ -z "$no_cluster" ]; then
        alarm_check_down "cluster_size" "Couldn't get cluster size: $no_cluster/$CLUSTER_SIZE"
        monokit redmine issue update --service "mysql-cluster-size" --message "Couldn't get cluster size with command: \"mysql -sNe \"SHOW STATUS WHERE Variable_name = 'wsrep_cluster_size';\"\""
        print_colour "Cluster size" "Couln't get" "error"
    else
        alarm_check_down "cluster_size" "Cluster size is not accurate: $no_cluster/$CLUSTER_SIZE"
        monokit redmine issue update --service "mysql-cluster-size" --message "MySQL cluster size is $no_cluster at $IDENTIFIER_REDMINE"
        print_colour "Cluster size" "$no_cluster/$CLUSTER_SIZE" "error"
    fi

    if [[ "$no_cluster" -eq 1 ]] || [[ "$no_cluster" -gt $CLUSTER_SIZE ]]; then
        monokit redmine issue create --service "mysql-cluster-size" --subject "Cluster size is $no_cluster at $IDENTIFIER_REDMINE" --message "MySQL cluster size is $no_cluster at $IDENTIFIER"
    fi
}

function check_node_status() {
    output=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_ready';")
    name=$(echo "$output" | awk '{print $1}')
    is_available=$(echo "$output" | awk '{print $2}')
    if [ -n "$is_available" ]; then
        alarm_check_up "is_available" "Node status $name is $is_available"
        print_colour "Node status" "$is_available"
    elif [ -z "$name" ] || [ -z "$is_available" ]; then
        alarm_check_down "is_available" "Node status couldn't get a response from MySQL"
        print_colour "Node status" "Couldn't get info" "error"
    else
        alarm_check_down "is_available" "Node status $name is $is_available"
        print_colour "Node status" "$is_available" "error"
    fi
}

function check_cluster_synced() {
    output=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_local_state_comment';")
    name=$(echo "$output" | awk '{print $1}')
    is_synced=$(echo "$output" | awk '{print $2}')
    if [ -n "$is_synced" ]; then
        alarm_check_up "is_synced" "Node local state $name is $is_synced"
        print_colour "Node local state" "$is_synced"
    elif [ -z "$name" ] || [ -z "$is_synced" ]; then
        alarm_check_down "is_synced" "Node local state couldn't get a response from MySQL"
        print_colour "Node local state" "Couldn't get info" "error"
    else
        alarm_check_down "is_synced" "Node local state $name is $is_synced"
        print_colour "Node local state" "$is_synced" "error"
    fi
}

function check_flow_control() {
    output=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_flow_control_paused';")
    name=$(echo "$output" | awk '{print $1}')
    stop_time=$(echo "$output" | awk '{print $2}' | cut -c 1)
    if [ "$stop_time" -gt 0 ]; then
        alarm_check_down "flow" "Replication paused by Flow Control more than 1 second - $stop_time"
        print_colour "Replication pause time" "$stop_time" "error"
    else
        alarm_check_up "flow" "Replication paused by Flow Control less than 1 second again - $stop_time"
        print_colour "Replication pause time" "$stop_time"
    fi
}

function check_db() {
    check_out=$(mysqlcheck --auto-repair --all-databases)
    tables=$(echo "$check_out" | sed -n '/Repairing tables/,$p' | tail -n +2)
    message=""
    if [ -n "$tables" ]; then
        message="[MySQL - $IDENTIFIER] [:info:] MySQL - \`mysqlcheck --auto-repair --all-databases\` result"
    fi
    oldIFS=$IFS
    IFS=$'\n'
    for table in $tables; do
        message="$message\n$table"
    done
    if [ -n "$message" ]; then
        alarm "$message"
    fi
    IFS=$oldIFS
}

function main() {
    parse_config_mysql
    create_pid

    printf '\n'
    echo MySQL Health "$VERSION" - "$(date)"
    printf '\n'
    select_now
    printf '\n'
    check_process_count
    printf '\n'
    if [ "$IS_CLUSTER" -eq 1 ]; then
        inaccessible_clusters
        check_cluster_status
        check_node_status
        check_cluster_synced
        #check_flow_control
    fi

    if [ -z "$CHECK_TABLE_DAY" ]; then
        CHECK_TABLE_DAY="Sun"
    fi

    if [ -z "$CHECK_TABLE_HOUR" ]; then
        CHECK_TABLE_HOUR="05:00"
    fi

    if [ "$(date "+%a %H:%M")" == "$CHECK_TABLE_DAY $CHECK_TABLE_HOUR" ]; then
        check_db
    fi
}

main

remove_pid
