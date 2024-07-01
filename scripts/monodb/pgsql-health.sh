#!/usr/bin/env bash
###~ description: Checks the status of PostgreSQL and Patroni cluster
#shellcheck disable=SC2034

#~ variables
script_version="v2.5.0"
SCRIPT_NAME=pgsql-health
SCRIPT_NAME_PRETTY="PGSQL Health"

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$(
    cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit
    pwd -P
)"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

create_tmp_dir

cron_mode "$ENABLE_CRON"

function parse_config_pgsql() {
    CONFIG_PATH_MONODB="db"
    export REQUIRED=true

    PROCESS_LIMIT=$(yaml .postgres.limits.process $CONFIG_PATH_MONODB)
    QUERY_LIMIT=$(yaml .postgres.limits.query $CONFIG_PATH_MONODB)
    CONN_LIMIT_PERCENT=$(yaml .postgres.limits.conn_percent $CONFIG_PATH_MONODB)

    SEND_ALARM=$(yaml .postgres.alarm.enabled $CONFIG_PATH_MONODB "$SEND_ALARM")

    if [ -z "$PATRONI_API" ] && [ -f /etc/patroni/patroni.yml ]; then
        PATRONI_API="$(yq -r .restapi.listen /etc/patroni/patroni.yml)"
    fi
}

function postgresql_status() {
    echo_status "PostgreSQL Status"
    if systemctl status postgresql.service &>/dev/null || systemctl status postgresql*.service >/dev/null; then
        print_colour "PostgreSQL" "Active"
        alarm_check_up "postgresql" "PostgreSQL is active again!"
    else
        print_colour "PostgreSQL" "Active" "error"
        alarm_check_down "postgresql" "PostgreSQL is not active!"
    fi
}

function pgsql_uptime() {
    # SELECT current_timestamp - pg_postmaster_start_time();
    #su - postgres -c "psql -c 'SELECT current_timestamp - pg_postmaster_start_time();'" | awk 'NR==3'
    echo_status "PostgreSQL Uptime:"
    # shellcheck disable=SC2037
    if grep iasdb /etc/passwd &>/dev/null; then
        # shellcheck disable=SC2037
        command="su - iasdb -c \"psql -c 'SELECT current_timestamp - pg_postmaster_start_time();'\""
    elif grep gitlab-psql /etc/passwd &>/dev/null; then
        # shellcheck disable=SC2037
        command="gitlab-psql -c 'SELECT current_timestamp - pg_postmaster_start_time();'"
    else
        # shellcheck disable=SC2037
        command="su - postgres -c \"psql -c 'SELECT current_timestamp - pg_postmaster_start_time();'\""
    fi

    if eval "$command" &>/dev/null; then
        uptime="$(eval "$command" | awk 'NR==3' | xargs)"
        alarm_check_up "now" "Can run 'SELECT' statements again"
        print_colour "Uptime" "$uptime"
    else
        alarm_check_down "now" "Couldn't run a 'SELECT' statement on PostgreSQL"
        print_colour "Uptime" "not accessible" "error"
        exit 1
    fi
}

function write_active_connections() {
    mkdir -p /var/log/monodb
    if grep iasdb /etc/passwd &>/dev/null; then
        su - iasdb -c "psql -c \"SELECT pid,usename, client_addr, now() - pg_stat_activity.query_start AS duration, query, state FROM pg_stat_activity  WHERE state='active' ORDER BY duration DESC;\"" >/var/log/monodb/pgsql-stat_activity-"$(date +"%a")".log
    elif grep gitlab-psql /etc/passwd &>/dev/null; then
        gitlab-psql -c "SELECT pid,usename, client_addr, now() - pg_stat_activity.query_start AS duration, query, state FROM pg_stat_activity  WHERE state='active' ORDER BY duration DESC;" >/var/log/monodb/pgsql-stat_activity-"$(date +"%a")".log
    else
        su - postgres -c "psql -c \"SELECT pid,usename, client_addr, now() - pg_stat_activity.query_start AS duration, query, state FROM pg_stat_activity  WHERE state='active' ORDER BY duration DESC;\"" >/var/log/monodb/pgsql-stat_activity-"$(date +"%a")".log
    fi
}

function check_active_connections() {
    echo_status "Active Connections"
    if grep iasdb /etc/passwd &>/dev/null; then
        max_and_used=$(su - iasdb -c "psql -c \"SELECT max_conn, used FROM (SELECT COUNT(*) used FROM pg_stat_activity) t1, (SELECT setting::int max_conn FROM pg_settings WHERE name='max_connections') t2;\"" | awk 'NR==3')
    elif grep gitlab-psql /etc/passwd &>/dev/null; then
        max_and_used=$(gitlab-psql -c "SELECT max_conn, used FROM (SELECT COUNT(*) used FROM pg_stat_activity) t1, (SELECT setting::int max_conn FROM pg_settings WHERE name='max_connections') t2;" | awk 'NR==3')
    else
        max_and_used=$(su - postgres -c "psql -c \"SELECT max_conn, used FROM (SELECT COUNT(*) used FROM pg_stat_activity) t1, (SELECT setting::int max_conn FROM pg_settings WHERE name='max_connections') t2;\"" | awk 'NR==3')
    fi

    file="$TMP_PATH_SCRIPT/last-connection-above-limit.txt"
    max_conn="$(echo "$max_and_used" | awk '{print $1}')"
    used_conn="$(echo "$max_and_used" | awk '{print $3}')"

    used_percentage=$(echo "$max_conn $used_conn" | awk '{print ($2*100/$1)}')
    if [ -f "$file" ]; then
        increase="$(cat "$file")"
    else
        increase=1
    fi

    if eval "$(echo "$used_percentage $CONN_LIMIT_PERCENT" | awk '{if ($1 >= $2) print "true"; else print "false"}')"; then
        if [[ ! -f "$TMP_PATH_SCRIPT" ]]; then
            write_active_connections
        fi
        alarm_check_down "active_conn" "Number of active connections is $used_conn/$max_conn ($used_percentage%) and above $CONN_LIMIT_PERCENT%"
        print_colour "Number of Active Connections" "$used_conn/$max_conn ($used_percentage%) and Above $CONN_LIMIT_PERCENT%" "error"
        difference=$(((${used_percentage%.*} - ${CONN_LIMIT_PERCENT%.*}) / 10))
        if [[ $difference -ge $increase ]]; then
            write_active_connections
            if [ -f "$file" ]; then
                alarm "[PostgreSQL - $IDENTIFIER] [:red_circle:] Number of Active Connections has passed $((CONN_LIMIT_PERCENT + (increase * 10)))% - It is now $used_conn ($used_percentage%)"
            fi
            increase=$((difference + 1))
        fi
        echo "$increase" >"$file"
    else
        alarm_check_up "active_conn" "Number of active connections is $used_conn/$max_conn ($used_percentage%) and below $CONN_LIMIT_PERCENT%"
        print_colour "Number of Active Connections" "$used_conn/$max_conn ($used_percentage%) and below $CONN_LIMIT_PERCENT%"
        rm -f "$file"
    fi
}

function check_running_queries() {
    echo_status "Active Queries"
    if grep iasdb /etc/passwd &>/dev/null; then
        queries=$(su - iasdb -c "psql -c \"SELECT COUNT(*) AS active_queries_count FROM pg_stat_activity WHERE state = 'active';\"" | awk 'NR==3 {print $1}')
    elif grep gitlab-psql /etc/passwd &>/dev/null; then
        queries=$(gitlab-psql -c "SELECT COUNT(*) AS active_queries_count FROM pg_stat_activity WHERE state = 'active';" | awk 'NR==3 {print $1}')
    else
        queries=$(su - postgres -c "psql -c \"SELECT COUNT(*) AS active_queries_count FROM pg_stat_activity WHERE state = 'active';\"" | awk 'NR==3 {print $1}')
    fi

    # SELECT COUNT(*) AS active_queries_count FROM pg_stat_activity WHERE state = 'active';
    if [[ "$queries" -gt "$QUERY_LIMIT" ]]; then
        alarm_check_down "query_limit" "Number of active queries is $queries/$QUERY_LIMIT" "active_queries"
        print_colour "Number of Active Queries" "$queries/$QUERY_LIMIT" "error"
    else
        alarm_check_up "query_limit" "Number of active queries is $queries/$QUERY_LIMIT" "active_queries"
        print_colour "Number of Active Queries" "$queries/$QUERY_LIMIT"
    fi
}

function cluster_status() {
    echo_status "Patroni Status"
    if systemctl status patroni.service >/dev/null; then
        print_colour "Patroni" "Active"
        alarm_check_up "patroni" "Patroni is active again!"
    else
        print_colour "Patroni" "Active" "error"
        alarm_check_down "patroni" "Patroni is not active!"
    fi

    CLUSTER_URL="$PATRONI_API/cluster"
    if ! curl -s "$CLUSTER_URL" >/dev/null; then
        print_colour "Patroni API" "not accessible" "error"
        alarm_check_down "patroni_api" "Can't access Patroni API through: $CLUSTER_URL"
        return
    fi
    alarm_check_up "patroni_api" "Patroni API is accessible again through: $CLUSTER_URL"

    output=$(curl -s "$CLUSTER_URL")
    mapfile -t cluster_names < <(echo "$output" | jq -r '.members[] | .name ')
    mapfile -t cluster_roles < <(echo "$output" | jq -r '.members[] | .role')
    mapfile -t cluster_states < <(curl -s "$CLUSTER_URL" | jq -r '.members[] | .state')
    name=$(yq -r .name /etc/patroni/patroni.yml)
    this_node=$(curl -s "$CLUSTER_URL" | jq -r --arg name "$name" '.members[] | select(.name==$name) | .role')
    print_colour "This Node" "$this_node"

    printf '\n'
    echo_status "Cluster Roles"
    i=0
    for cluster in "${cluster_names[@]}"; do
        print_colour "$cluster" "${cluster_roles[$i]}"
        if [ -f "$TMP_PATH_SCRIPT"/raw_output.json ]; then
            old_role="$(jq -r '.members['"$i"'] | .role' <"$TMP_PATH_SCRIPT"/raw_output.json)"
            if [ "${cluster_roles[$i]}" != "$old_role" ] &&
                [ "$cluster" == "$(jq -r '.members['"$i"'] | .name' <"$TMP_PATH_SCRIPT"/raw_output.json)" ]; then
                echo "  Role of $cluster has changed!"
                print_colour "  Old Role of $cluster" "$old_role" "error"
                printf '\n'
                alarm "[Patroni - $IDENTIFIER] [:info:] Role of $cluster has changed! Old: **$old_role**, Now: **${cluster_roles[$i]}**"
                if [ "${cluster_roles[$i]}" == "leader" ]; then
                    alarm "[Patroni - $IDENTIFIER] [:check:] New leader is $cluster!"
                    if [[ -n "$LEADER_SWITCH_HOOK" ]] && [[ -f "/etc/patroni/patroni.yml" ]]; then
                        if [[ "$(curl -s "$PATRONI_API" | jq -r .role)" == "master" ]]; then
                            eval "$LEADER_SWITCH_HOOK"
                            EXIT_CODE=$?
                            if [ $EXIT_CODE -eq 0 ]; then
                                alarm "[Patroni - $IDENTIFIER] [:check:] Leader switch hook executed successfully"
                            else
                                alarm "[Patroni - $IDENTIFIER] [:red_circle:] Leader switch hook failed with exit code $EXIT_CODE"
                            fi
                        fi
                    fi
                fi

            fi
        fi
        i=$((i + 1))
    done
    echo "$output" | jq >"$TMP_PATH_SCRIPT"/raw_output.json

    printf '\n'
    echo_status "Cluster States"
    i=0
    for cluster in "${cluster_names[@]}"; do
        if [ "${cluster_states[$i]}" == "running" ] || [ "${cluster_states[$i]}" == "streaming" ]; then
            print_colour "$cluster" "${cluster_states[$i]}"
            alarm_check_up "$cluster" "Cluster $cluster, ${cluster_states[$i]} again"
        else
            print_colour "$cluster" "${cluster_states[$i]}" "error"
            alarm_check_down "$cluster" "Cluster $cluster, ${cluster_states[$i]}"
        fi
        i=$((i + 1))
    done
}

function main() {
    parse_config_pgsql
    pid_file=$(create_pid)

    printf '\n'
    echo "Monodb PostgreSQL Health $VERSION - $(date)"
    printf '\n'
    postgresql_status
    printf '\n'
    pgsql_uptime
    printf '\n'
    check_active_connections
    printf '\n'
    check_running_queries
    if [[ -n "$PATRONI_API" ]]; then
        printf '\n'
        cluster_status
    fi
}

main

rm "${pid_file}"
