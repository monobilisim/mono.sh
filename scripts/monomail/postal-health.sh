#!/bin/bash
###~ description: Checks the status of postal and related services

VERSION=v2.5.0

#shellcheck disable=SC2034
SCRIPT_NAME="postal-health"

#shellcheck disable=SC2034
SCRIPT_NAME_PRETTY="Postal Health"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

create_tmp_dir

parse_config_postal() {
    CONFIG_PATH_POSTAL="mail"
    export REQUIRED=true

    message_threshold=$(yaml .postal.message_threshold $CONFIG_PATH_POSTAL)
    held_threshold=$(yaml .postal.held_threshold $CONFIG_PATH_POSTAL)

    SEND_ALARM=$(yaml .alarm.enabled $CONFIG_PATH_POSTAL "$SEND_ALARM")
}

parse_config_postal


if [ "$1" == "test" ]; then postal_config="./test.yaml"; else postal_config=/opt/postal/config/postal.yml; fi

if [ -z "$(command -v mysql)" ]; then
    echo "Couldn't find mysql on the server - Aborting"
    alarm_check_down "mysql" "Can't find mysql on $IDENTIFIER - Aborting"
    exit 1
fi
alarm_check_up "mysql" "Found mysql on $IDENTIFIER"
# ------- MySQL main_db stats -------
main_db_host=$(yq -r .main_db.host $postal_config)
main_db_port=$(yq -r .main_db.port $postal_config)
if [ "$main_db_port" = "null" ]; then
    main_db_port="3306"
fi
main_db_user=$(yq -r .main_db.username $postal_config)
main_db_pass=$(yq -r .main_db.password $postal_config)
if ! main_db_status=$(mysqladmin -h"$main_db_host" -P"$main_db_port" -u"$main_db_user" -p"$main_db_pass" ping 2>&1); then
    alarm_check_down "maindb" "Can't connect to main_db at host $main_db_host with the parameters on $postal_config at $IDENTIFIER"
else
    alarm_check_up "maindb" "Able to connect main_db at host $main_db_host at $IDENTIFIER"
fi

# ------- MySQL message_db stats -------
message_db_host=$(yq -r .message_db.host $postal_config)
message_db_port=$(yq -r .message_db.port $postal_config)
if [ "$message_db_port" = "null" ]; then
    message_db_port="3306"
fi
message_db_user=$(yq -r .message_db.username $postal_config)
message_db_pass=$(yq -r .message_db.password $postal_config)
if ! message_db_status=$(mysqladmin -h"$message_db_host" -P"$message_db_port" -u"$message_db_user" -p"$message_db_pass" ping 2>&1); then
    alarm_check_down "messagedb" "Can't connect to messagedb at host $message_db_host with the parameters on $postal_config at $IDENTIFIER"
else
    alarm_check_up "messagedb" "Able to connect messagedb at host $message_db_host at $IDENTIFIER"
fi

fnServices() {
    if systemctl status postal >/dev/null; then
        if [ -z "$(command -v docker)" ]; then
            echo "Couldn't find docker on the server - Aborting"
            alarm_check_down "docker" "Can't find docker on $IDENTIFIER - Aborting"
            exit 1
        fi
        alarm_check_up "postal" "Postal is running again at $IDENTIFIER"
        alarm_check_up "docker" "Docker found at $IDENTIFIER"
        echo_status "Postal status:"
        postal_status=$(docker ps --format "table {{.Names}} {{.Status}}" | grep postal)
        if [ -z "$postal_status" ]; then
            alarm_check_down "postal" "Couldn't find any postal services at $IDENTIFIER. Postal might have been stopped. Please check!"
            echo "  Couldn't find any postal services. Postal might have been stopped. Please check!"
        else
            postal_services=$(echo "$postal_status" | awk '{print $1}')

            for service in $postal_services; do
                service_status=$(echo "$postal_status" | grep "$service" | awk '{print substr($0, index($0,$2))}')
                if [ "$(echo "$service_status" | awk '{print $1}')" == "Up" ]; then
                    alarm_check_up "$service" "Postal service $service is $service_status at $IDENTIFIER"
                    printf "  %-40s %s\n" "${BLUE_FG}$service${RESET}" "is ${GREEN_FG}$service_status${RESET}"
                else
                    alarm_check_down "$service" "Postal service $service is $service_status at $IDENTIFIER"
                    printf "  %-40s %s\n" "${BLUE_FG}$service${RESET}" "is ${RED_FG}$service_status${RESET}"
                fi
            done
        fi
    else
        echo_status "Postal status:"
        alarm_check_down "postal" "Postal is not running at $IDENTIFIER"
        printf "  %-40s %s\n" "${BLUE_FG}Postal${RESET}" "is ${RED_FG}not running${RESET}"
    fi
}

fnMySQL() {
    echo_status "MySQL status:"
    if [ "$main_db_status" = "mysqld is alive" ]; then
        alarm_check_up "maindb" "MySQL main_db: $main_db_status at $IDENTIFIER"
        printf "  %-40s %s\n" "${BLUE_FG}main_db${RESET}" "${GREEN_FG}$main_db_status${RESET}"
    else
        alarm_check_down "maindb" "MySQL main_db: $main_db_status at $IDENTIFIER"
        printf "  %-40s %s\n" "${BLUE_FG}main_db${RESET}" "${RED_FG}$main_db_status${RESET}"
    fi
    if [ "$message_db_status" = "mysqld is alive" ]; then
        alarm_check_up "messagedb" "MySQL message_db: $message_db_status at $IDENTIFIER"
        printf "  %-40s %s\n" "${BLUE_FG}message_db${RESET}" "${GREEN_FG}$message_db_status${RESET}"
    else
        alarm_check_down "messagedb" "MySQL message_db: $message_db_status at $IDENTIFIER"
        printf "  %-40s %s\n" "${BLUE_FG}message_db${RESET}" "${RED_FG}$message_db_status${RESET}"
    fi
}
fnMessageQueue() {
    if ! db_message_queue=$(mysql -h"$message_db_host" -P"$message_db_port" -u"$message_db_user" -p"$message_db_pass" -sNe "select count(*) from postal.queued_messages;" 2>&1); then
        alarm_check_down "status_db_message_queue" "Couldn't retrieve message queue information from message_db at host $message_db_host with the parameters on $postal_config at $IDENTIFIER" "queue"
        db_message_queue_error="$db_message_queue"
        db_message_queue=-1
    else
        alarm_check_up "status_db_message_queue" "Able to retrieve message queue information from message_db at host $message_db_host at $IDENTIFIER" "queue"
    fi
    echo_status "Message Queue:"
    if [ "$db_message_queue" -lt "$message_threshold" ] && ! [ "$db_message_queue" -lt 0 ]; then
        alarm_check_up "db_message_queue" "Number of queued messages is back to normal - $db_message_queue/$message_threshold at $IDENTIFIER" "queue"
        printf "  %-40s %s\n" "${BLUE_FG}Queued messages${RESET}" "are smaller than ${GREEN_FG}$message_threshold - Queue: $db_message_queue${RESET}"
    elif [ "$db_message_queue" -eq -1 ]; then
        printf "  %-40s %s\n" "${BLUE_FG}Queued messages${RESET}" "${RED_FG}$db_message_queue_error${RESET}"
    else
        alarm_check_down "db_message_queue" "Number of queued messages is above threshold - $db_message_queue/$message_threshold at $IDENTIFIER" "queue"
        printf "  %-40s %s\n" "${BLUE_FG}Queued messages${RESET}" "are greater than ${RED_FG}$message_threshold - Queue: $db_message_queue${RESET}"
    fi
}

fnMessageHeld() {
    echo_status "Held Messages:"
    readarray -t postal_servers <<< "$(mysql -h"$message_db_host" -P"$message_db_port" -u"$message_db_user" -p"$message_db_pass" -sNe "select id, permalink from postal.servers;" | sort -n)"
    for i in "${postal_servers[@]}"; do
        id=$(echo "$i" | awk '{print $1}')
        name=$(echo "$i" | awk '{print $2}')
        variable="postal-server-$id"
        if ! db_message_held=$(mysql -h"$message_db_host" -P"$message_db_port" -u"$message_db_user" -p"$message_db_pass" -sNe "USE $variable; SELECT COUNT(id) FROM messages WHERE status = 'Held';" 2>&1); then
            alarm_check_down "status_$variable" "Couldn't retrieve information of held messages for $name ($variable) from message_db at host $message_db_host with the parameters on $postal_config at $IDENTIFIER"
            db_message_held_error="$db_message_held"
            db_message_held=-1
        else
            alarm_check_up "status_$variable" "Able to retrieve information of held messages for $name ($variable) from message_db at host $message_db_host at $IDENTIFIER"
        fi
        if [ "$db_message_held" -lt "$held_threshold" ] && ! [ "$db_message_held" -lt 0 ]; then
            alarm_check_up "$variable" "Number of Held messages of $name ($variable) is back to normal - $db_message_held/$held_threshold at $IDENTIFIER"
            printf "  %-40s %s\n" "${BLUE_FG}$name ($variable)${RESET}" "Held messages are smaller than ${GREEN_FG}$held_threshold - Held: $db_message_held${RESET}"
        elif [ "$db_message_held" -eq -1 ]; then
            printf "  %-40s %s\n" "${BLUE_FG}$name ($variable)${RESET}" "Held messages ${RED_FG}$db_message_held_error${RESET}"
        else
            alarm_check_down "$variable" "Number of Held messages of $name ($variable) is above threshold - $db_message_held/$held_threshold at $IDENTIFIER"
            printf "  %-40s %s\n" "${BLUE_FG}$name ($variable)${RESET}" "Held messages are greater than ${RED_FG}$held_threshold - Held: $db_message_held${RESET}"
        fi
    done
}

main() {
    create_pid
    fnServices
    printf '\n'
    fnMySQL
    printf '\n'
    if [ "$CHECK_MESSAGE" == "1" ]; then
        fnMessageQueue
        printf '\n'
        fnMessageHeld
        printf '\n'
    fi
}

main

remove_pid
