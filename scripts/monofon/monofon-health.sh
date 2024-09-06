#!/bin/bash
###~ description: Checks the status of monofon and related services

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

VERSION=v2.5.0

#shellcheck disable=SC2034
SCRIPT_NAME="monofon-health"

#shellcheck disable=SC2034
SCRIPT_NAME_PRETTY="Monofon Health Check"

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$(
    cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit
    pwd -P
)"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

create_tmp_dir

parse_config_monofon() {
    CONFIG_PATH_MONOFON="monofon"
    export REQUIRED=true

    readarray -t IGNORED_SERVICES < <(yaml .ignored_services[] $CONFIG_PATH_MONOFON)
    readarray -t IGNORED_TRUNKS < <(yaml .ignored_trunks[] $CONFIG_PATH_MONOFON)
    AUTO_RESTART=$(yaml .restart.auto $CONFIG_PATH_MONOFON)
    CONCURRENT_CALLS=$(yaml .concurrent_calls $CONFIG_PATH_MONOFON)
    #TRUNK_CHECK_INTERVAL=$(yaml .trunk_check_interval $CONFIG_PATH_MONOFON 5)
    RESTART_ATTEMPT_INTERVAL=$(yaml .restart.attempt_interval $CONFIG_PATH_MONOFON)

    SEND_ALARM=$(yaml .alarm.enabled $CONFIG_PATH_MONOFON "$SEND_ALARM")
}

parse_config_monofon

SERVICES=("asterniclog" "fop2" "freepbx" "httpd" "mariadb")

containsElement() {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

function check_service() {
    if [ "$is_old" == "0" ]; then
        if systemctl status "$1" >/dev/null; then
            alarm_check_up "$1" "Service $1 started running again at $IDENTIFIER" "service"
            print_colour "$1" "running"
        else
            print_colour "$1" "not running" "error"
            alarm_check_down "$1" "Service $1 is not running at $IDENTIFIER" "service"
            if [ "$AUTO_RESTART" == "1" ]; then
                if [[ "$1" == "freepbx" || "$1" == "asterisk" ]]; then
                    restart_asterisk
                else
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= RESTART_ATTEMPT_INTERVAL)) || ((time_diff == 0)); then
                        print_colour "$1" "not running - starting" "error"
                        alarm "Starting $1 at $IDENTIFIER"
                        if ! systemctl start "$1"; then
                            print_colour "Couldn't start" "$1"
                            alarm "Couldn't start $1 at $IDENTIFIER"
                        else
                            alarm_check_up "$1" "Service $1 started running again at $IDENTIFIER" "service"
                        fi
                    fi
                fi
            fi
        fi
    else
        if service "$1" status >/dev/null; then
            alarm_check_up "$1" "Service $1 started running again at $IDENTIFIER" "service"
            print_colour "$1" "running"
        else
            print_colour "$1" "not running" "error"
            alarm_check_down "$1" "Service $1 is not running at $IDENTIFIER" "service"
            if [ "$AUTO_RESTART" == "1" ]; then
                if [[ "$1" == "freepbx" || "$1" == "asterisk" ]]; then
                    restart_asterisk
                else
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= RESTART_ATTEMPT_INTERVAL)) || ((time_diff == 0)); then
                        print_colour "$1" "not running - starting" "error"
                        alarm "Starting $1 at $IDENTIFIER"
                        if ! service "$1" start; then
                            print_colour "Couldn't start" "$1"
                            alarm "Couldn't start $1 at $IDENTIFIER"
                        else
                            alarm_check_up "$1" "Service $1 started running again at $IDENTIFIER" "service"
                        fi
                    fi
                fi
            fi
        fi
    fi
}

function restart_asterisk() {
    for service in "${SERVICES[@]}"; do
        if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
            continue
        fi
        if [ "$is_old" == "0" ]; then
            if ! systemctl stop "$service"; then
                print_colour "Couldn't restart" "$service"
                alarm "Couldn't restart ${SERVICES[2]} at $IDENTIFIER couldn't restart service $service"
                return
            fi
        else
            if ! service "$service" stop; then
                print_colour "Couldn't restart" "$service"
                alarm "Couldn't restart ${SERVICES[2]} at $IDENTIFIER couldn't restart service $service"
                return
            fi
        fi
    done
    if ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
        OLDIFS=$IFS
        IFS=$'\n'
        if [ -z "$(command -v supervisorctl)" ]; then
            mono_services=$(supervisord ctl status | grep monofon | grep -i RUNNING)
        else
            mono_services=$(supervisorctl status 2>/dev/null | grep monofon | grep RUNNING)
        fi
        active_services=$(echo "$mono_services" | awk '{print $service}')
        for service in $active_services; do
            if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
                continue
            fi
            if [ -z "$(command -v supervisorctl)" ]; then
                supervisord ctl stop "${service[1]}"
            else
                supervisorctl stop "${service[1]}"
            fi
        done
        IFS=$OLDIFS
    fi
    for service in $(printf '%s\n' "${SERVICES[@]}" | tac); do
        if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
            continue
        fi
        if [ "$is_old" == "0" ]; then
            if ! systemctl start "$service"; then
                print_colour "Couldn't restart" "$service"
                alarm "Couldn't restart ${SERVICES[2]} at $IDENTIFIER couldn't restart service $service"
                return
            fi
        else
            if ! service "$service" start; then
                print_colour "Couldn't restart" "$service"
                alarm "Couldn't restart ${SERVICES[2]} at $IDENTIFIER couldn't restart service $service"
                return
            fi
        fi
    done
    if ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
        OLDIFS=$IFS
        IFS=$'\n'
        for service in $active_services; do
            if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
                continue
            fi
            if [ -z "$(command -v supervisorctl)" ]; then
                supervisord ctl start "${service[1]}"
            else
                supervisorctl start "${service[1]}"
            fi
        done
        IFS=$OLDIFS
    fi
    echo "Restarted ${BLUE_FG}${SERVICES[2]}${RESET}" "at $IDENTIFIER"
    alarm_check_up "Restarted ${SERVICES[2]} at $IDENTIFIER" "service"
}

function check_monofon_services() {
    OLDIFS=$IFS
    IFS=$'\n'

    if [ -z "$(command -v supervisorctl)" ]; then
        mono_services=$(supervisord ctl status | grep monofon)
    else
        if supervisorctl status | grep -q "unix://"; then
            mono_services=$(supervisorctl -c /etc/supervisord.conf status 2>/dev/null | grep monofon)
        else
            mono_services=$(supervisorctl status 2>/dev/null | grep monofon)
        fi
    fi

    if [ -n "$mono_services" ]; then
        alarm_check_up "monofon_services" "Monofon services are available at $IDENTIFIER" "service"

        for service in $mono_services; do
            if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
                continue
            fi
            is_active=$(echo "$service" | awk '{print $2}')
            service_name=$(echo "$service" | awk '{print $1}')

            if [ "${is_active,,}" != 'running' ]; then
                print_colour "$service_name" "not running" "error"
                alarm_check_down "$service_name" "$service_name is not running at $IDENTIFIER" "service"
                if [ "$AUTO_RESTART" == "1" ]; then
                    time_diff=$(get_time_diff "$service_name")
                    if ((time_diff >= RESTART_ATTEMPT_INTERVAL)) || ((time_diff == 0)); then
                        print_colour "$service_name" "not running - starting" "error"
                        alarm "Starting $service_name at $IDENTIFIER"
                        if ! supervisorctl restart "$service_name"; then
                            print_colour "Couldn't restart" "$service"
                            alarm "Couldn't restart $service at $IDENTIFIER"
                        else
                            alarm_check_up "$service_name" "Service $service_name started running again at $IDENTIFIER" "service"
                        fi
                    fi
                fi
            else
                alarm_check_up "$service_name" "Service $service_name started running again at $IDENTIFIER" "service"
                print_colour "$service_name" "running"
            fi
        done
    else
        echo "${RED_FG}No monofon services found!${RESET}"
        alarm_check_down "monofon_services" "No monofon services found at $IDENTIFIER" "service"
    fi

    IFS=$OLDIFS
}

function check_concurrent_calls() {
    echo_status "Checking the number of concurrent calls"
    active_calls=$(asterisk -rx "core show channels" | grep "active calls" | awk '{print $1}')

    if [[ $active_calls -gt $CONCURRENT_CALLS ]]; then
        alarm_check_down "active_calls" "Number of active calls at $IDENTIFIER is ${active_calls}" "service"
        print_colour "Number of active calls" "${active_calls}" "error"
    else
        alarm_check_up "active_calls" "Number of active calls at $IDENTIFIER is below $CONCURRENT_CALLS - Active calls: ${active_calls}" "service"
        print_colour "Number of active calls" "${active_calls}"
    fi
}

function check_trunks() {
    echo_status "Checking the statuses of the Trunks"
    trunk_list=$(asterisk -rx "sip show peers" | grep -E '^[a-zA-Z]' | sed '1d')

    OLDIFS=$IFS
    IFS=$'\n'
    for trunk in $trunk_list; do
        trunk_status=$(echo "$trunk" | awk '{print $6}')
        trunk_name=$(echo "$trunk" | awk '{print $1}')
        if containsElement "$trunk_name" "${IGNORED_TRUNKS[@]}"; then
            continue
        fi
        if [ "$trunk_status" != "OK" ]; then
            print_colour "$trunk_name" "${trunk_status}" "error"
            alarm_check_down "$trunk_name" "Trunk $trunk_name is ${trunk_status} at $IDENTIFIER" "trunk"
        else
            alarm_check_up "$trunk_name" "Trunk $trunk_name is ${trunk_status} again at $IDENTIFIER" "trunk"
            print_colour "$trunk_name" "OK"
        fi
    done
    IFS=$OLDIFS
}

function asterisk_error_check() {
    if tail /var/log/asterisk/full | grep -q Autodestruct; then
        alarm_check_down "autodestruct" "Found \"Autodestruct\" at log: /var/log/asterisk/full - Server: $IDENTIFIER"
    # else
    #     alarm_check_up "autodestruct" ""
    fi

    if [ $((10#$(date +%M) % 5)) -eq 0 ]; then
        if tail -n 1000 /var/log/asterisk/full | grep res_rtp_asterisk.so | grep Error; then
            alarm_check_down "module" "module alarm" # TODO alarm ekle
            asterisk -rx "module load res_pjproject.so"
            asterisk -rx "module load res_rtp_asterisk.so"
        fi
    fi
}

# function delete_time_diff() {
#     file_path="$TMP_PATH_SCRIPT/monofon_$1_time.txt"
#     if [ -f "${file_path}" ]; then
#         rm -rf "${file_path}"
#     fi
# }

function check_db() {
    check_out=$(mysqlcheck --auto-repair --all-databases)
    tables=$(echo "$check_out" | sed -n '/Repairing tables/,$p' | tail -n +2)
    message=""
    if [ -n "$tables" ]; then
        message="[Monofon - $IDENTIFIER] [:info:] MySQL - \`mysqlcheck --auto-repair --all-databases\` result"
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

check_voice_records() {
    echo_status "Checking Voice Recordings"
    # Since this only runs once a day and only checks todays recordings, older alarm file stays there.
    # So we check if any older alarm file exists and delete if it exists, since we don't need it anymore.
    old_alarm_path="$TMP_PATH_SCRIPT/monofon_recording_folder_status.txt"
    if [ -f "$old_alarm_path" ]; then
        rm -rf "$old_alarm_path"
    fi

    recordings_path="/var/spool/asterisk/monitor/$(date "+%Y/%m/%d")"
    if [ -d "$recordings_path" ]; then
        #shellcheck disable=SC2012
        file_count=$(ls "$recordings_path" | wc -l)
        if [ "$file_count" -eq 0 ]; then
            alarm "[Monofon - $IDENTIFIER] [:red_circle:] No recordings at: $recordings_path"
            print_colour "Number of Recordings" "No Recordings found" "error"
        else
            print_colour "Number of Recordings" "$file_count"
        fi
    else
        alarm_check_down "recording_folder" "Folder: $recordings_path doesn't exists. Creating..."
        echo "Folder: $recordings_path doesn't exists. Creating..."
        mkdir -p "$recordings_path"
        chown asterisk:asterisk "$recordings_path"
        if [ -d "$recordings_path" ]; then
            alarm_check_up "recording_folder" "Successfully created folder: $recordings_path"
            echo "Successfully created folder: $recordings_path"
        else
            alarm "[Monofon - $IDENTIFIER] [:red_circle:] Couldn't create folder: $recordings_path"
            echo "Couldn't create folder: $recordings_path"
        fi
    fi
}

function rewrite_monofon_data() {
    if ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
        file="$TMP_PATH_SCRIPT/rewrite-monofon-data-row-count.txt"
        if [[ -f /var/www/html/monofon-pano-yeni/scripts/asterniclog-manual-mysql.php ]] && ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
            if [[ "$(date "+%H:%M")" == "01:00" ]]; then
                screen -dm php /var/www/html/monofon-pano-yeni/scripts/asterniclog-manual-mysql.php "$(date -d "yesterday" '+%Y-%m-%d')"
            fi
        fi

        if [ -f "$file" ]; then
            # row_count=$(cat $file)
            #alarm "Monofon verilerin yeniden yazılması tamamlandı. Satır sayısı: $row_count"
            rm "$file"
        fi
    fi
}

function check_data_file() {
    echo_status "Checking data.json"
    data_timestamp="$TMP_PATH_SCRIPT/monofon_data-json.txt"
    data_file="/var/www/html/monofon-pano-yeni/data/data.json"
    if [ -f "$data_timestamp" ]; then
        before=$(cat "$data_timestamp")
        now=$(stat -c %y $data_file)
        if [ "$before" == "$now" ]; then
            alarm_check_down "data-json" "No changes made to file: $data_file"
            print_colour "data.json" "not updated"
        else
            alarm_check_up "data-json" "Data file updated. File: $data_file"
            print_colour "data.json" "updated"
        fi
        echo "$now" >"$data_timestamp"
    fi
    stat -c %y $data_file >"$data_timestamp"
}

function main() {
    create_pid
    is_old=0
    # Checks if systemctl is present, if not it uses service instead
    if [ -z "$(command -v systemctl)" ]; then
        is_old=1
        SERVICES[2]="asterisk"
        SERVICES[4]="mysql"
        out=$(service mysql status 2>&1)
        if [ "$out" == "mysql: unrecognized service" ]; then
            SERVICES[4]="mysqld"
        fi
    fi
    echo "Monofon-health.sh started health check at $(date)"
    printf '\n'
    echo_status "Checking the statuses of the Services"
    for service in "${SERVICES[@]}"; do
        if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
            continue
        fi
        check_service "$service"
    done
    if ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
        check_monofon_services
    fi
    printf '\n'
    check_concurrent_calls
    printf '\n'
    if [[ $(date "+%-H") -ge 8 ]] && [[ $(date "+%-H") -lt 18 ]]; then
        check_trunks
    fi
    printf '\n'
    if [ "$(date "+%H:%M")" == "05:00" ]; then
        check_db
    fi
    asterisk_error_check
    if [ "$(date "+%H:%M")" == "12:00" ] && echo "$IDENTIFIER" | grep sip >/dev/null; then
        if ! containsElement "recordings" "${IGNORED_SERVICES[@]}"; then
            check_voice_records
        fi
    fi
    if ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
        check_data_file
    fi
    rewrite_monofon_data
}

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

main

remove_pid
