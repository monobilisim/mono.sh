#!/usr/bin/env bash
###~ description: This script is used to check the health of the server

#~ variables
#shellcheck disable=SC2034
script_version="v5.0.0"
SCRIPT_NAME=os-health
SCRIPT_NAME_PRETTY="OS Health"

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

create_tmp_dir &> /dev/null

cron_mode "$ENABLE_CRON"

parse_monocloud() {
    CONFIG_PATH_MONOCLOUD="os"
    export REQUIRED=true

    readarray -t FILESYSTEMS < <(yaml .filesystems[] "$CONFIG_PATH_MONOCLOUD")
    
    SYSTEM_LOAD_AND_RAM=$(yaml .system_load_and_ram "$CONFIG_PATH_MONOCLOUD" 1)
    
    LOAD_LIMIT_MULTIPLIER=$(yaml .load.limit_multiplier "$CONFIG_PATH_MONOCLOUD" 0.8)
    
    PART_USE_LIMIT=$(yaml .part_use_limit "$CONFIG_PATH_MONOCLOUD")
    LOAD_LIMIT=$(yaml .load.limit "$CONFIG_PATH_MONOCLOUD" 20)
    RAM_LIMIT=$(yaml .ram_limit "$CONFIG_PATH_MONOCLOUD")

    SEND_ALARM=$(yaml .alarm.enabled "$CONFIG_PATH_MONOCLOUD" "$SEND_ALARM")
}

grep_custom() {
    if command -v pcregrep &>/dev/null; then
        pcregrep "$@"
    else
        grep -P "$@"
    fi
}

#~ check partitions
check_partitions() {
    local partitions="$(df -l -T | awk '{print $1,$2,$7}' | sed '1d' | sort | uniq | grep -E $(echo ${FILESYSTEMS[@]} | sed 's/ /|/g') | awk '$2 != "zfs" {print} $2 == "zfs" && $1 !~ /\//')"
    oldIFS=$IFS
    local json="["
    IFS=$'\n'
    for partition in $partitions; do
        IFS=$oldIFS info=($partition)
        local partition="${info[0]}"
        local filesystem="${info[1]}"
        local mountpoint="${info[2]}"
        if [[ "${FILESYSTEMS[@]}" =~ "$filesystem" ]]; then
            case $filesystem in
            "fuse.zfs")
                note="Fuse ZFS is not supported yet."
                usage="0"
                avail="0"
                total="0"
                percentage="0"
                ;;
            "zfs")
                usage=$(zfs list -H -p -o used "$partition")
                avail=$(zfs list -H -p -o avail "$partition")
                total=$((usage + avail))
                percentage=$((usage * 100 / total))
                ;;
            "btrfs")
                usage=$(btrfs filesystem us -b "$mountpoint" | grep_custom '^\s.+Used' | awk '{print $2}')
                total=$(btrfs filesystem us -b "$mountpoint" | grep_custom 'Device size' | awk '{print $3}')
                percentage=$(echo "scale=2; $usage / $total * 100" | bc)
                ;;
            *)
                stat=($(df -P $mountpoint | sed '1d' | awk '{printf "%s %-12s   %s\n", $3*1024, $2*1024, $5}'))
                usage=${stat[0]}
                total=${stat[1]}
                percentage=${stat[2]}
                ;;
            esac
        fi
        [[ "$usage" != "0" ]] && usage=$(convertToProper "$usage")
        [[ "$total" != "0" ]] && total=$(convertToProper "$total")
        json+="{\"partition\":\"$partition\",\"filesystem\":\"$filesystem\",\"mountpoint\":\"$mountpoint\",\"percentage\":\"${percentage//%/}\",\"usage\":\"$usage\",\"total\":\"$total\", \"note\":\"${note:-OK}\"},"
    done
    json=${json/%,/}
    json+="]"
    IFS=$oldifs
    echo "$json"
}

function sum_array() {
    sum=0
    local sum
    for num in "$@"; do
        sum=$(echo "$sum + $num" | bc)
    done
    echo "$sum"
}

#~ check status
check_status() {
    printf "\n"
    echo "Mono Cloud Health Check - $script_version - $(date)"
    printf "\n"

    echo_status "Disk Usages"
    readarray -t info < <(check_partitions | jq -r '.[] | [.percentage, .usage, .total, .partition, .mountpoint, .note] | @tsv')
    oldIFS=$IFS
    IFS=$'\n'
    for i in "${info[@]}"; do
        IFS=$oldIFS a=($i)
        if [[ ${a[0]} -gt $PART_USE_LIMIT ]]; then
            print_colour "Disk Usage is ${a[3]}" "greater than $PART_USE_LIMIT (${a[0]}%)" "error"
        else
            print_colour "Disk Usage is ${a[3]}" "less than $PART_USE_LIMIT (${a[0]}%)"
        fi
    done

    printf "\n"

    if [[ "${SYSTEM_LOAD_AND_RAM:-1}" -eq 1 ]]; then
        echo_status "System Load and RAM"
        systemstatus="$(check_system_load_and_ram)"

        if [[ -n $(echo "$systemstatus" | jq -r ". | select(.load | tonumber > $LOAD_LIMIT_CPU)") ]]; then
            print_colour "System Load" "greater than $LOAD_LIMIT_CPU ($(echo "$systemstatus" | jq -r '.load'))" "error"
        else
            print_colour "System Load" "less than $LOAD_LIMIT_CPU ($(echo "$systemstatus" | jq -r '.load'))"
        fi

        if [[ -n $(echo "$systemstatus" | jq -r ". | select(.ram | tonumber > $RAM_LIMIT)") ]]; then
            print_colour "RAM Usage" "greater than $RAM_LIMIT ($(echo "$systemstatus" | jq -r '.ram'))" "error"
        else
            print_colour "RAM Usage" "less than $RAM_LIMIT ($(echo "$systemstatus" | jq -r '.ram'))"
        fi
    fi

    printf "\n"

    report_status &>/dev/null
}

freebsd_mib() {
    if [[ "$1" == "vmstat" ]]; then
        bytes="$(echo "$(vmstat_jq "$2") * 1024" | bc)"
    else
        bytes="$(sysctl -n "$1")"
    fi
    local bytes
    mib=$(echo "($bytes + 524288) / 1048576" | bc) # Round to the nearest MiB
    local mib
    echo "$mib"
}

free_custom() {

    if command -v free &>/dev/null; then
        free -m
        return $?
    fi

    # Mem: Total, Used, Free, Shared, Buff/Cache, Available
    total="$(freebsd_mib hw.physmem)" # Correct
    used="$(echo "$total - $(freebsd_mib hw.usermem)" | bc)"

    echo "Mem: $total $used" # Rest we dont need for now
}

#~ check system load and ram
check_system_load_and_ram() {
    [[ -z "$(command -v systemctl)" ]] && is_old=1 || is_old=0
    [[ -z "$(command -v pkg)" ]] && average="average:" || average="averages:" # its 'averages:' instead of 'average:' on freebsd
    load=$(uptime | awk -F"$average" '{print $2}' | awk -F',' '{print $1}' | xargs)
    
    #shellcheck disable=SC2119
    [[ $is_old == 0 ]] && ram_usage=$(free_custom | awk '/Mem/{printf("%.2f", $3/$2*100)}') || ram_usage=$(free_custom | awk '/Mem/{printf("%.2f", ($3-$6-$7)/$2*100)}')
    local json="{\"load\":\"$load\",\"ram\":\"$ram_usage\"}"

    if [[ $(echo "$load <= $LOAD_LIMIT_CPU" | bc -l) -eq 1 ]]; then
        message="System load limit went below $LOAD_LIMIT_CPU (Current: $load, Multiplier: $LOAD_LIMIT_MULTIPLIER, CPU: $(nproc))"
        alarm_check_up "load" "$message" "system"
    else
        message="The system load limit has exceeded $LOAD_LIMIT_CPU (Current: $load, Multiplier: $LOAD_LIMIT_MULTIPLIER, CPU: $(nproc))"
        alarm_check_down "load" "$message" "system"
    fi

    ram_u=$(echo "$ram_usage" | awk -F '.' '{print $1}')

    if [[ "$ram_u" == "$ram_usage" ]]; then
        ram_u=$(echo "$ram_usage" | awk -F ',' '{print $1}')
    fi

    if [[ $(echo "$ram_usage <= $RAM_LIMIT" | bc -l) -eq 1 ]]; then
        message="RAM usage limit went below $RAM_LIMIT (Current: $ram_usage%)"
        alarm_check_up "ram" "$message" "system"
    else
        message="RAM usage limit has exceeded $RAM_LIMIT (Current: $ram_usage%)"
        alarm_check_down "ram" "$message" "system"
    fi

    [ ! -d "$TMP_PATH_SCRIPT/checks" ] && mkdir -p "$TMP_PATH_SCRIPT"/checks
    echo "$json" >"$TMP_PATH_SCRIPT"/checks/"$(date +%s)".json

    echo "$json"
}

#~ convert to proper
convertToProper() {
    value=$1
    dummy=$value
    for i in {0..7}; do
        if [[ ${dummy:0:1} == 0 ]]; then
            dummy=$((dummy * 1024))
            result=$(echo "scale=1; $value / 1024^($i-1)" | bc)
            case $i in
            1)
                result="${result}B"
                ;;
            2)
                result="${result}KiB"
                ;;
            3)
                result="${result}MiB"
                ;;
            4)
                result="${result}GiB"
                ;;
            5)
                result="${result}TiB"
                ;;
            6)
                result="${result}PiB"
                ;;
            esac
            break
        else
            dummy=$((dummy / 1024))
        fi
    done
    echo "$result"
}

report_status() {
    diskstatus="$(check_partitions)"
    local diskstatus
    echo "$diskstatus"
    
    if [[ "${SYSTEM_LOAD_AND_RAM:-1}" -eq 1 ]]; then 
        systemstatus="$(check_system_load_and_ram)"
        local systemstatus
    fi

    if [[ -n "$IDENTIFIER" ]]; then
        alarm_hostname="$IDENTIFIER"
        alarm_hostname="$(hostname)"
    fi

    underthreshold_disk=0
    REDMINE_CLOSE=1
    REDMINE_SEND_UPDATE=0
    
    local underthreshold_disk
    local REDMINE_CLOSE
    local REDMINE_SEND_UPDATE

    message="Partition usage levels went below ${PART_USE_LIMIT}% for the following partitions;\n\`\`\`\n"
    table_md="$(printf '|%s |%s |%s |%s |%s |' '%' 'Used' 'Total' 'Partition' 'Mount Point')"
    table="$(printf '%-5s | %-10s | %-10s | %-50s | %s' '%' 'Used' 'Total' 'Partition' 'Mount Point')"
    table_md+="\n"
    table_md+="|--|--|--|--|--|"
    table+='\n'
    diskcount="$(echo "$diskstatus" | jq -r '.[].partition' | wc -l)"
    local diskcount
    for z in $(seq 1 110); do table+="$(printf '-')"; done
    if [[ -n "$(echo "$diskstatus" | jq -r ".[] | select(.percentage | tonumber < $PART_USE_LIMIT)")" ]]; then
        oldifs=$IFS
        local oldifs
        IFS=$'\n'
        for info in $(echo "$diskstatus" | jq -r ".[] | select(.percentage | tonumber < $PART_USE_LIMIT) | [.percentage, .usage, .total, .partition, .mountpoint] | @tsv"); do
            IFS=$oldifs read -ra a <<< "$info"
            percentage=${a[0]}
            usage=${a[1]}
            total=${a[2]}
            partition=${a[3]}
            mountpoint=${a[4]}

            [[ "$mountpoint" == "/" ]] && mountpoint="/sys_root"

            if [[ -f "$TMP_PATH_SCRIPT/${mountpoint//\//_}-redmine-down" ]]; then
                curl -fsSL -X PUT -H "Content-Type: application/json" -H "X-Redmine-API-Key: $REDMINE_API_KEY" -d "{\"issue\": { \"id\": $(cat "$TMP_PATH_SCRIPT"/redmine_issue_id), \"notes\": \"${partition}, %$PART_USE_LIMIT altına indi.\"}}" "$REDMINE_URL"/issues/"$(cat "$TMP_PATH_SCRIPT"/redmine_issue_id)".json 
                rm -f "$TMP_PATH_SCRIPT/${mountpoint//\//_}-redmine-down"
            fi
            
            [[ -f "$TMP_PATH_SCRIPT/${mountpoint//\//_}" ]] && {
                table_md+="\n$(printf '| %s | %s | %s | %s | %s |\n' "$percentage"% "$usage" "$total" "$partition" "${mountpoint//sys_root/}")"
                table+="\n$(printf '%-5s | %-10s | %-10s | %-50s | %-35s' "$percentage"% "$usage" "$total" "$partition" "${mountpoint//sys_root/}")"
                underthreshold_disk=$((underthreshold_disk + 1))
                rm -f "$TMP_PATH_SCRIPT"/"${mountpoint//\//_}"
            }
        done
        message+="$table\n\`\`\`"

        if [[ "$underthreshold_disk" == "$diskcount" && "${REDMINE_ENABLE:-1}" == "1" && -f "$TMP_PATH_SCRIPT/redmine_issue_id" ]]; then
            curl -fsSL -X PUT -H "Content-Type: application/json" -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
-d "{\"issue\": { \"id\": $(cat "$TMP_PATH_SCRIPT"/redmine_issue_id), \"notes\": \"Disk kullanım oranları, %$PART_USE_LIMIT altına geri indiği için iş kapatılıyor\", \"status_id\": \"${REDMINE_STATUS_ID_CLOSED:-5}\", \"assigned_to_id\": \"me\" }}" \
"$REDMINE_URL"/issues/"$(cat "$TMP_PATH_SCRIPT"/redmine_issue_id)".json

            rm -f "$TMP_PATH_SCRIPT"/redmine_issue_id
        fi

        IFS=$oldifs
        #[[ "$underthreshold_disk" == "1" ]] && echo $message || { echo "There's no alarm for Underthreshold today..."; }
        if [[ "$underthreshold_disk" -ge 1 ]]; then
            alarm_check_up "disk" "$message"
        fi
    fi

    local overthreshold_disk=0
    message="Partition usage level has exceeded ${PART_USE_LIMIT}% for the following partitions;\n\`\`\`\n"
    table_md="$(printf '|%s |%s |%s |%s |%s |' '%' 'Used' 'Total' 'Partition' 'Mount Point')"
    table_md+="\n"
    table_md+="|--|--|--|--|--|"
    table="$(printf '%-5s | %-10s | %-10s | %-50s | %s' '%' 'Used' 'Total' 'Partition' 'Mount Point')\n"
    for z in $(seq 1 110); do table+="$(printf '-')"; done
    if [[ -n "$(echo "$diskstatus" | jq -r ".[] | select(.percentage | tonumber > $PART_USE_LIMIT)")" ]]; then
        local oldifs=$IFS
        IFS=$'\n'
        for info in $(echo "$diskstatus" | jq -r ".[] | select(.percentage | tonumber > $PART_USE_LIMIT) | [.percentage, .usage, .total, .partition, .mountpoint] | @tsv"); do
            IFS=$oldifs read -ra a <<< "$info"
            percentage=${a[0]}
            usage=${a[1]}
            total=${a[2]}
            partition=${a[3]}
            mountpoint=${a[4]}

            [[ "$mountpoint" == "/" ]] && mountpoint="/sys_root"

            if [[ -f "$TMP_PATH_SCRIPT/${mountpoint//\//_}-redmine" && "$(cat "$TMP_PATH_SCRIPT"/"${mountpoint//\//_}"-redmine)" != "$percentage" ]]; then
                REDMINE_SEND_UPDATE=1
            fi

            echo "$percentage" >"$TMP_PATH_SCRIPT"/"${mountpoint//\//_}"-redmine

            if [[ -f "$TMP_PATH_SCRIPT/${mountpoint//\//_}" ]]; then
                if [[ "$(cat "$TMP_PATH_SCRIPT"/"${mountpoint//\//_}")" == "$(date +%Y-%m-%d)" ]]; then
                    overthreshold_disk=0
                    continue
                else
                    date +%Y-%m-%d >"$TMP_PATH_SCRIPT"/"${mountpoint//\//_}"
                    date +%Y-%m-%d >"$TMP_PATH_SCRIPT"/"${mountpoint//\//_}"-redmine-down
                    overthreshold_disk=1
                fi
            else
                date +%Y-%m-%d >"$TMP_PATH_SCRIPT"/"${mountpoint//\//_}"
                date +%Y-%m-%d >"$TMP_PATH_SCRIPT"/"${mountpoint//\//_}"-redmine-down
                overthreshold_disk=1
            fi

            table_md+="\n$(printf '| %s | %s | %s | %s | %s |' "$percentage"% "$usage" "$total" "$partition" "${mountpoint//sys_root/}")"
            table+="\n$(printf '%-5s | %-10s | %-10s | %-50s | %-35s' "$percentage"% "$usage" "$total" "$partition" "${mountpoint//sys_root/}")"
        done
        IFS=$oldifs
        if [[ "$overthreshold_disk" == "1" ]]; then
            message+="$table\n\n"

            if [ "${REDMINE_ENABLE:-1}" == "1" ]; then
                if [[ ! -f "$TMP_PATH_SCRIPT/redmine_issue_id" ]]; then

                    curl -fsSL -X POST -H "Content-Type: application/json" -H "X-Redmine-API-Key: $REDMINE_API_KEY" -d "{\"issue\": { \"project_id\": \"${REDMINE_PROJECT_ID:-$(echo "$IDENTIFIER" | cut -d '-' -f 1)}\", \"tracker_id\": \"${REDMINE_TRACKER_ID:-7}\", \"subject\": \"$alarm_hostname - Diskteki bir (ya da birden fazla) bölümün doluluk seviyesi %${PART_USE_LIMIT} üstüne çıktı\", \"description\": \"$table_md\", \"status_id\": \"${REDMINE_STATUS_ID:-open}\", \"priority_id\": \"${REDMINE_PRIORITY_ID:-5}\" }}" "$REDMINE_URL"/issues.json -o "$TMP_PATH_SCRIPT"/redmine.json
                    echo "$"
                    jq -r '.issue.id' "$TMP_PATH_SCRIPT"/redmine.json >"$TMP_PATH_SCRIPT"/redmine_issue_id
                    rm -f "$TMP_PATH_SCRIPT"/redmine.json
                elif [[ "$REDMINE_SEND_UPDATE" == "1" ]]; then
                    curl -fsSL -X PUT -H "Content-Type: application/json" -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
                        -d "{\"issue\": { \"id\": $(cat "$TMP_PATH_SCRIPT"/redmine_issue_id), \"notes\": \"$table_md\" }}" \
                        "$REDMINE_URL"/issues/"$(cat "$TMP_PATH_SCRIPT"/redmine_issue_id)".json
                fi
                message+="\n\`\`\`\n"
                message+="Redmine issue: $REDMINE_URL/issues/$(cat "$TMP_PATH_SCRIPT"/redmine_issue_id)"
                message+="\n"
            else
                message+="\n\`\`\`"
            fi
            alarm_check_down "disk" "$message" 
        else
            echo "There's no alarm for Overthreshold (DISK) today..."
        fi
    fi
}

#~ usage
usage() {
    echo -e "Usage: $0 [-c <configfile>] [-h] [-l] [-V] [-v]"
    echo -e "\t-c | --config   <configfile> : Use custom config file. (default: $CONFIG_PATH)"
    echo -e "\t-l | --list                  : List partition status."
    echo -e "\t-V | --validate              : Validate temporary directory and config."
    echo -e "\t-v | --version               : Print script version."
    echo -e "\t-h | --help                  : Print this message."
}

#~ validate
validate() {
    required_apps=("bc" "curl" "jq")
    missing_apps=""
    for a in "${required_apps[@]}"; do
        [[ ! -e "$(command -v "$a")" ]] && missing_apps+="$a, "
    done
    
    if [[ -n "$missing_apps" ]]; then
        echo -e "${RED_FG}[ FAIL ] Please install these apps before proceeding: (${missing_apps%, })"
    else
        echo -e "${GREEN_FG}[ OK ] Required apps are already installed."
    fi

    for ALARM_WEBHOOK_URL in "${ALARM_WEBHOOK_URLS[@]}"; do
        if curl -fsSL "$(echo "$ALARM_WEBHOOK_URL" | grep_custom -o '(?<=\:\/\/)(([a-z]|\.)+)')" &>/dev/null; then
            echo -e "${GREEN_FG}[  OK  ] Webhook URL is reachable."
        else
            echo -e "${RED_FG}[ FAIL ] Webhook URL is not reachable."
        fi
    done

    if touch "$TMP_PATH_SCRIPT"/.testing &>/dev/null; then
        echo -e "${GREEN_FG}[  OK  ] $TMP_PATH_SCRIPT is writable."
        rm "$TMP_PATH_SCRIPT"/.testing
    else
        echo -e "${RED_FG}[ FAIL ] $TMP_PATH_SCRIPT is not writable."
    fi
}

#~ main
main() {
    pid_file=$(create_pid)

    if [ "$1" == "--debug" ] || [ "$1" == "-d" ]; then
        set -x
        shift
    fi

    if [[ "$1" == "--config="* ]] || [[ "$1" == "-c="* ]]; then
        local config_path_tmp="${1#*=}"
        local config_path_tmp="${config_path_tmp:-false}"
        shift
    elif [[ ("$1" == "--config" || "$1" == "-c") && ! "$2" =~ ^- ]]; then
        local config_path_tmp="${2:-false}"
        shift 2
    fi

    if [[ "$config_path_tmp" == "false" ]]; then
        echo "$0: option requires an argument -- 'config/-c'"
        shift
    elif [[ -n "$config_path_tmp" ]]; then
        CONFIG_PATH="$config_path_tmp"
    fi

    parse_monocloud

    LOAD_LIMIT_CPU="$(echo "$(nproc) * ${LOAD_LIMIT_MULTIPLIER:-1}" | bc) "
    export LOAD_LIMIT_CPU

    [[ $# -eq 0 ]] && {
        check_status
        exit 1
    }

    while [[ $# -gt 0 ]]; do
        case $1 in
        -l | --list)
            check_partitions | jq
            ;;
        -V | --validate)
            validate
            ;;
        -v | --version)
            echo "Script Version: $script_version"
            ;;
        --)
            shift
            return 0
            ;;
        -h | --help)
            usage
            break
            ;;
        esac
        _status="$?"
        [[ "${_status}" != "0" ]] && { exit ${_status}; }
        shift
    done

}

main "$@"

rm "${pid_file}"
