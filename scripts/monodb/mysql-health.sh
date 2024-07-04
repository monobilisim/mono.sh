#!/usr/bin/env bash
###~ description: Checks the status of MySQL and MySQL cluster

#shellcheck disable=SC2034
script_version=v2.6.0
SCRIPT_NAME="mysql-health"
SCRIPT_NAME_PRETTY="MySQL Health"

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

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

    SEND_ALARM=$(yaml .mysql.alarm.enabled $CONFIG_PATH_MONODB "$SEND_ALARM")
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

function check_process_count() {
    echo_status "Number of Processes:"
    processlist_count=$(/usr/bin/mysqladmin processlist | grep -vc 'show processlist')

    if [[ "$processlist_count" -lt "$PROCESS_LIMIT" ]]; then
        alarm_check_up "no_processes" "Number of processes is below limit: $processlist_count/$PROCESS_LIMIT" "process"
        print_colour "Number of Processes" "$processlist_count/$PROCESS_LIMIT"
    else
        alarm_check_down "no_processes" "Number of processes is above limit: $processlist_count/$PROCESS_LIMIT" "process"
        print_colour "Number of Processes" "$processlist_count/$PROCESS_LIMIT" "error"
    fi

}

function write_active_connections() {
    mkdir -p /var/log/monodb
    mysql -e "SELECT * FROM INFORMATION_SCHEMA.PROCESSLIST WHERE STATE = 'executing' AND USER != 'root' ORDER BY TIME DESC;" >/var/log/monodb/mysql-processlist-"$(date +"%a")".log
}

function check_active_connections() {
    echo_status "Active Connections"
    max_and_used=$(mysql -sNe "SELECT @@max_connections AS max_conn, (SELECT COUNT(*) FROM information_schema.processlist WHERE state = 'executing') AS used;")
    
    file="/tmp/monodb-mysql-health/last-connection-above-limit.txt"
    max_conn="$(echo "$max_and_used" | awk '{print $1}')"
    used_conn="$(echo "$max_and_used" | awk '{print $2}')"
  
    used_percentage=$(echo "$max_conn $used_conn" | awk '{print ($2*100/$1)}')
    if [ -f "$file" ]; then
        increase=$(cat $file)
    else
        increase=1
    fi
  
    if eval "$(echo "$used_percentage $CONN_LIMIT_PERCENT" | awk '{if ($1 >= $2) print "true"; else print "false"}')"; then
        alarm_check_down "active_conn" "Number of Active Connections is $used_conn ($used_percentage%) and Above $CONN_LIMIT_PERCENT%"
        print_colour "Number of Active Connections" "$used_conn ($used_percentage)% and Above $CONN_LIMIT_PERCENT%" "error"
        difference=$(((${used_percentage%.*} - ${CONN_LIMIT_PERCENT%.*}) / 10))
        if [[ $difference -ge $increase ]]; then
            write_active_connections
            if [ -f "$file" ]; then
                alarm "[MySQL - $IDENTIFIER] [:red_circle:] Number of Active Connections has passed $((CONN_LIMIT_PERCENT + (increase * 10)))% - It is now $used_conn ($used_percentage%)"
            fi
            increase=$((difference + 1))
        fi
        echo "$increase" >$file
    else
        alarm_check_up "active_conn" "Number of Active Connections is $used_conn ($used_percentage)% and Below $CONN_LIMIT_PERCENT%"
        print_colour "Number of Active Connections" "$used_conn ($used_percentage)% and Below $CONN_LIMIT_PERCENT%"
        rm -f $file
    fi
}

function check_cluster_status() {
    echo_status "Cluster Status:"
    cluster_status=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_cluster_size';")
    no_cluster=$(echo "$cluster_status" | awk '{print $2}')
    if [ "$no_cluster" -eq "$CLUSTER_SIZE" ]; then
        alarm_check_up "cluster_size" "Cluster size is accurate: $no_cluster/$CLUSTER_SIZE"
        print_colour "Cluster size" "$no_cluster/$CLUSTER_SIZE"
    elif [ -z "$no_cluster" ]; then
        alarm_check_down "cluster_size" "Couldn't get cluster size: $no_cluster/$CLUSTER_SIZE"
        print_colour "Cluster size" "Couln't get" "error"
    else
        alarm_check_down "cluster_size" "Cluster size is not accurate: $no_cluster/$CLUSTER_SIZE"
        print_colour "Cluster size" "$no_cluster/$CLUSTER_SIZE" "error"
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
    pid_file=$(create_pid)

    printf '\n'
    echo  MySQL Health "$VERSION" - "$(date)"  
    printf '\n'
    select_now
    printf '\n'
    check_process_count
    printf '\n'
    check_active_connections
    printf '\n'
    if [ "$IS_CLUSTER" -eq 1 ]; then
        check_cluster_status
        check_node_status
        check_cluster_synced
        #check_flow_control
    fi

    if [ "$(date "+%H:%M")" == "05:00" ]; then
        check_db
    fi
}

main

rm "${pid_file}"
