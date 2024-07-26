#!/usr/bin/env bash
###~ description: Common functions for all scripts

#shellcheck disable=SC2034
#shellcheck disable=SC2120

CONFIG_PATH=/etc/mono.sh
TMP_PATH=/tmp/mono.sh

if [[ "$NO_COLORS" != "1" || "$TERM" != "dumb" ]]; then
    RED_FG=$(tput setaf 1) 
    GREEN_FG=$(tput setaf 2)
    BLUE_FG=$(tput setaf 4)
    RESET=$(tput sgr0)
fi

export TMP_PATH_SCRIPT="$TMP_PATH"/"$SCRIPT_NAME"

function cron_mode() {
    if [[ "$1" == "1" ]]; then
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    
        RED_FG=""
        GREEN_FG=""
        YELLOW_FG=""
        BLUE_FG=""
        RESET=""
    
        #~ log file prefix
        echo "=== ( $(date) - $HOSTNAME ) =========================================" >"$TMP_PATH"/"$SCRIPT_NAME".log
    
        #~ redirect all outputs to file
        exec &>>$TMP_PATH/"$SCRIPT_NAME".log
    fi
}

function yaml() {

    if [[ -f "$CONFIG_PATH"/$2.yaml ]]; then
        CONFIG_PATH_DATA="$2.yaml"
    elif [[ -f "$CONFIG_PATH"/$2.yml ]]; then
        CONFIG_PATH_DATA="$2.yml"
    else
        echo "Config file $CONFIG_PATH/$2.yaml nor $CONFIG_PATH/$2.yml not found"
        exit 1
    fi

    OUTPUT=$(yq -r "$1" "$CONFIG_PATH"/"$CONFIG_PATH_DATA" 2> /dev/null)

    case $OUTPUT in
    null)
        if [[ "$REQUIRED" == "true" && -z $2 ]]; then
            echo "Required field '$1' not found in $CONFIG_PATH/$2"
            exit 1
        fi

        if [[ -z $2 ]]; then
            echo "''"
        else
            echo "$3"
        fi
        ;;
    true | True)
        echo "1"
        ;;
    false | False)
        echo "0"
        ;;
    *)
        echo "$OUTPUT"
        ;;
    esac
}

function check_yq() {
    # https://github.com/mikefarah/yq v4.43.1 sürümü ile test edilmiştir
    if [ -z "$(command -v yq)" ]; then

        if [[ "$INSTALL_YQ" == "1" ]]; then
            echo "Couldn't find yq. Installing it..."
            yn="y"
        else
            read -r -p "Couldn't find yq. Do you want to download it and put it under /usr/local/bin? [y/n]: " yn
        fi

        case $yn in
        [Yy]*)
            curl -sL "$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep browser_download_url | cut -d\" -f4 | grep 'yq_linux_amd64' | grep -v 'tar.gz')" --output /usr/local/bin/yq
            chmod +x /usr/local/bin/yq
            ;;
        [Nn]*)
            echo "Aborted"
            exit 1
            ;;
        esac
    fi
}

function parse_common() {
    # Alarm
    readarray -t ALARM_WEBHOOK_URLS < <(yaml .alarm.webhook_urls[] "global")
    IDENTIFIER="$(yaml .identifier "global" "$(hostname)")"
    SEND_ALARM="$(yaml '.send_alarm' "global" 1)"
    ALARM_INTERVAL="$(yaml .alarm.interval "global" 3)"

    ## Bot
    SEND_DM_ALARM="$(yaml '.alarm.bot.enabled' "global" 0)"
    ALARM_BOT_API_URL="$(yaml .alarm.bot.alarm_url "global")"
    ALARM_BOT_EMAIL="$(yaml .alarm.bot.email "global")"
    ALARM_BOT_API_KEY="$(yaml .alarm.bot.api_key "global")"
    readarray -t ALARM_BOT_USER_EMAILS < <(yaml .alarm.bot.user_emails[] "global")

    ## Redmine (WIP)
    REDMINE_API_KEY="$(yaml .redmine.api_key "global")"
    REDMINE_URL="$(yaml .redmine.url "global")"
    REDMINE_ENABLE="$(yaml '.redmine.enabled' "global" 1)"
    REDMINE_PROJECT_ID="$(yaml .redmine.project_id "global")"
    REDMINE_TRACKER_ID="$(yaml .redmine.tracker_id "global")"
    REDMINE_PRIORITY_ID="$(yaml .redmine.priority_id "global")"
    REDMINE_STATUS_ID="$(yaml .redmine.status_id "global")"
    REDMINE_STATUS_ID_CLOSED="$(yaml .redmine.status_id_closed "global")"
}

function create_tmp_dir() {
    mkdir -p "$TMP_PATH"/"$SCRIPT_NAME"
}

function echo_status() {
    echo "$1"
    echo ---------------------------------------------------
}

function print_colour() {
    if [ "$3" != 'error' ]; then
        printf "  %-40s %s\n" "${BLUE_FG}$1${RESET}" "${GREEN_FG}$2${RESET}"
    else
        printf "  %-40s %s\n" "${BLUE_FG}$1${RESET}" "${RED_FG}$2${RESET}"
    fi
}

function alarm() {
    if [ "$SEND_ALARM" == "1" ]; then
        for webhook in "${ALARM_WEBHOOK_URLS[@]}"; do
            curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$1\"}" "$webhook" 1>/dev/null
        done
    fi

    if [ "$SEND_DM_ALARM" = "1" ] && [ -n "$ALARM_BOT_API_KEY" ] && [ -n "$ALARM_BOT_EMAIL" ] && [ -n "$ALARM_BOT_API_URL" ] && [ -n "${ALARM_BOT_USER_EMAILS[*]}" ]; then
        for user_email in "${ALARM_BOT_USER_EMAILS[@]}"; do
            curl -s -X POST "$ALARM_BOT_API_URL"/api/v1/messages \
                -u "$ALARM_BOT_EMAIL:$ALARM_BOT_API_KEY" \
                --data-urlencode type=direct \
                --data-urlencode "to=$user_email" \
                --data-urlencode "content=$1" 1>/dev/null
        done
    fi
}

function get_time_diff() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=${1//\//-}
    file_path="$TMP_PATH_SCRIPT/${service_name}_status.txt"

    if [ -f "${file_path}" ]; then

        old_date=$(awk '{print $1, $2}' <"${file_path}")
        if [ "$(uname -s | tr '[:upper:]' '[:lower:]')" == "freebsd" ]; then
            old=$(date -j -f "%Y-%m-%d %H:%M" "$old_date" "+%s")
            new=$(date -j -f "%Y-%m-%d %H:%M" "$(date '+%Y-%m-%d %H:%M')" "+%s")
        else
            old=$(date -d "$old_date" "+%s")
            new=$(date "+%s")
        fi

        time_diff=$(((new - old) / 60))

        if ((time_diff >= ALARM_INTERVAL)); then
            date "+%Y-%m-%d %H:%M" >"${file_path}"
        fi
    else
        date "+%Y-%m-%d %H:%M" >"${file_path}"
        time_diff=0
    fi

    echo $time_diff
}

function alarm_check_down() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=${1//\//-}
    file_path="$TMP_PATH_SCRIPT/${service_name}_status.txt"

    if [ -z "$3" ]; then
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M" >"${file_path}"
                alarm "[$SCRIPT_NAME_PRETTY - $IDENTIFIER] [:red_circle:] $2"
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "[$SCRIPT_NAME_PRETTY - $IDENTIFIER] [:red_circle:] $2"
        fi
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "[$SCRIPT_NAME_PRETTY - $IDENTIFIER] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= ALARM_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "[$SCRIPT_NAME_PRETTY - $IDENTIFIER] [:red_circle:] $2"
                    fi
                fi
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
        fi
    fi
}

function alarm_check_up() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=${1//\//-}
    file_path="$TMP_PATH_SCRIPT/${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then
        if [ -z "$3" ]; then
            rm -rf "${file_path}"
            alarm "[$SCRIPT_NAME_PRETTY - $IDENTIFIER] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "[$SCRIPT_NAME_PRETTY - $IDENTIFIER] [:check:] $2"
            fi
        fi
    fi
}

function create_pid() {
    pidfile=/var/run/$SCRIPT_NAME.sh.pid
    if [ -f "${pidfile}" ]; then
        oldpid=$(cat "${pidfile}")

        if ! ps -p "${oldpid}" &>/dev/null; then
            rm "${pidfile}" # pid file is stale, remove it
        else
            echo "Old process still running"
            exit 1
        fi
    fi

    echo $$ >"${pidfile}"

    echo "$pidfile"
}

function main() {
    check_yq
    parse_common
}

main
