#!/bin/bash
###~ description: This script checks zimbra and zextras health

VERSION=v1.1.0

#shellcheck disable=SC2034
SCRIPT_NAME="zimbra-health"
#shellcheck disable=SC2034
SCRIPT_NAME_PRETTY="Zimbra Health"

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

parse_config_zimbra() {
    CONFIG_PATH_ZIMBRA="mail"
    export REQUIRED=true

    RESTART=$(yaml .zimbra.restart $CONFIG_PATH_ZIMBRA)
    RESTART_LIMIT=$(yaml .zimbra.restart_limit $CONFIG_PATH_ZIMBRA)
    QUEUE_LIMIT=$(yaml .zimbra.queue_limit $CONFIG_PATH_ZIMBRA)
    Z_URL=$(yaml .zimbra.z_url $CONFIG_PATH_ZIMBRA)

    SEND_ALARM=$(yaml .alarm.enabled $CONFIG_PATH_ZIMBRA "$SEND_ALARM")
}

parse_config_zimbra

RESTART_COUNTER=0

function check_ip_access() {
    echo_status "Access through IP"
    [[ -d "/opt/zimbra" ]] && {
        ZIMBRA_PATH='/opt/zimbra'
        PRODUCT_NAME='zimbra'
    }
    [[ -d "/opt/zextras" ]] && {
        ZIMBRA_PATH='/opt/zextras'
        PRODUCT_NAME='carbonio'
    }
    [[ -z $ZIMBRA_PATH ]] && {
        echo "Zimbra not found in /opt, aborting..."
        exit 1
    }

    #~ define variables
    templatefile="$ZIMBRA_PATH/conf/nginx/templates/nginx.conf.web.https.default.template"
    certfile="$ZIMBRA_PATH/ssl/$PRODUCT_NAME/server/server.crt"
    keyfile="$ZIMBRA_PATH/ssl/$PRODUCT_NAME/server/server.key"
    message="Hello World!"

    #~ check template file and ip
    [[ ! -e $templatefile ]] && {
        echo "File \"$templatefile\" not found, aborting..."
        exit 1
    }
    [[ -e "$ZIMBRA_PATH/conf/nginx/external_ip.txt" ]] && ipaddress="$(cat "$ZIMBRA_PATH"/conf/nginx/external_ip.txt)" || ipaddress="$(curl -fsSL ifconfig.co)"
    [[ -z "$(echo "$ipaddress" | grep -Pzi '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\0' '\n')" ]] && {
        echo "IP address error, aborting..."
        exit 1
    }

    #~ define regex pattern and proxy block
    regexpattern="\\n?(server\\s+?{\\n?\\s+listen\\s+443\\sssl\\shttp2;\\n?\\s+server_name\\n?\\s+$ipaddress;\\n?\\s+ssl_certificate\\s+$certfile;\\n?\\s+ssl_certificate_key\\s+$keyfile;\\n?\\s+location\\s+\\/\\s+{\\n?\\s+return\\s200\\s\'$message\';\\n?\\s+}\\n?})"
    proxyblock="
server {
        listen                  443 ssl http2;
        server_name             $ipaddress;
        ssl_certificate         $certfile;
        ssl_certificate_key     $keyfile;
        location / {
                return 200 '$message';
        }
}"

    #~ check block from templatefile
    if [[ -z $(grep -Pzio "$regexpattern" "$templatefile" | tr '\0' '\n') ]]; then
        echo "Adding proxy control block in $templatefile file..."
        echo -e "$proxyblock" >>"$templatefile"
        echo "Added proxy control block in $templatefile file..."
    fi
    ip=$(wget -qO- ifconfig.me/ip)
    if ! curl -s --insecure --connect-timeout 15 https://"$ip" | grep -iq zimbra; then
        alarm_check_up "ip_access" "Can't access to zimbra through plain ip: $ip"
        print_colour "Access with ip" "not accessible"
    else
        alarm_check_down "ip_access" "Can access to zimbra through plain ip: $ip"
        print_colour "Access with ip" "accessible" "error"
    fi
}

function check_zimbra_services() {
    echo_status "Zimbra services"
    OLDIFS=$IFS
    IFS=$'\n'
    if id "zimbra" &>/dev/null; then
        zimbra_services="$(su - zimbra -c "zmcontrol status" 2>/dev/null | sed '1d')"
    else
        zimbra_services="$(su - zextras -c "zmcontrol status" 2>/dev/null | sed '1d')"
    fi
    # should_restart=0
    i=0
    for service in $zimbra_services; do
        i=$((i + 1))
        is_active=$(echo "$service" | awk '{print $NF}')
        service_name=$(echo "$service" | awk '{NF--; print}')
        if [[ $is_active =~ [A-Z] ]]; then
            if [ "${is_active,,}" != 'running' ]; then
                [[ $RESTART_COUNTER -gt "$RESTART_LIMIT" ]] && {
                    alarm_check_down "$service_name" "Couldn't restart stopped services in $((RESTART_LIMIT + 1)) tries" "service"
                    echo "${RED_FG}Couldn't restart stopped services in $((RESTART_LIMIT + 1)) tries${RESET}"
                    return
                }
                print_colour "$service_name" "$is_active" "error"
                alarm_check_down "$service_name" "Service: $service_name is not running" "service"
                if [ "$RESTART" == 1 ]; then
                    if id "zimbra" &>/dev/null; then
                        z_user="zimbra"
                    else
                        z_user="zextras"
                    fi

                    su - "$z_user" -c "zmcontrol start"
                    RESTART_COUNTER=$((RESTART_COUNTER + 1))

                    printf '\n'
                    check_zimbra_services
                    break
                fi
            else
                print_colour "$service_name" "$is_active"
                alarm_check_up "$service_name" "Service: $service_name started running" "service"
            fi
        fi
    done
    IFS=$OLDIFS
}

function check_z-push() {
    echo_status "Checking Z-Push:"
    if curl -Isk "$Z_URL" | grep -i zpush >/dev/null; then
        alarm_check_up "z-push" "Z-Push started working"
        print_colour "Z-Push" "Working"
    else
        alarm_check_down "z-push" "Z-Push is not working"
        print_colour "Z-Push" "Not Working" "error"
    fi
}

function queued_messages() {
    echo_status "Queued Messages"
    if [ -d /opt/zimbra ]; then
        queue=$(/opt/zimbra/common/sbin/mailq | grep -c "^[A-F0-9]")
    else
        queue=$(/opt/zextras/common/sbin/mailq | grep -c "^[A-F0-9]")
    fi
    if [[ $queue -le $QUEUE_LIMIT ]]; then
        alarm_check_up "queued" "Number of queued messages is below limit - $queue/$QUEUE_LIMIT" "queue"
        print_colour "Number of queued messages" "$queue"
    else
        alarm_check_down "queued" "Number of queued messages is above limit - $queue/$QUEUE_LIMIT" "queue"
        print_colour "Number of queued messages" "$queue" "error"
    fi
}

function check_install() {
    mapfile -t ps_out < <(pgrep install.sh)
    if [ ${#ps_out[@]} -gt 1 ]; then
        echo install.sh is working
        echo Exiting...
        exit 1
    fi
}

function check_ssl() {
    echo_status "SSL Expiration"
    if id "zimbra" &>/dev/null; then
        cert_info="$(su - zimbra -c "echo | openssl s_client -servername zimbra.monomail.biz.tr -connect zimbra.monomail.biz.tr:443 2>/dev/null | openssl x509 -noout -dates")"
    else
        cert_info="$(su - zextras -c "echo | openssl s_client -servername zimbra.monomail.biz.tr -connect zimbra.monomail.biz.tr:443 2>/dev/null | openssl x509 -noout -dates")"
    fi
    if [ -z "$cert_info" ]; then
        echo "Couldn't get cert info."
        alarm_check_down "ssl-expire" "Couldn't get cert info."
        return
    fi
    expiry_date=$(echo "$cert_info" | grep "notAfter" | cut -d'=' -f2)
    expiry_timestamp=$(date -d "$expiry_date" +%s)
    current_timestamp=$(date +%s)
    remaining_seconds=$((expiry_timestamp - current_timestamp))
    days_to_expiry=$((remaining_seconds / 86400))
    if [ $days_to_expiry -lt 10 ]; then
        alarm_check_down "ssl-expire" "SSl expiration: $days_to_expiry days left"
        print_colour "SSl expiration" "$days_to_expiry days" "error"
    else
        alarm_check_up "ssl-expire" "SSl expiration: $days_to_expiry days left"
        print_colour "SSl expiration" "$days_to_expiry days"
    fi
}

function main() {
    create_pid
    printf '\n'
    echo "Zimbra Health $VERSION - $(date)"
    printf '\n'
    check_install
    check_ip_access
    printf '\n'
    check_zimbra_services
    if [ -n "$Z_URL" ]; then
        printf '\n'
        check_z-push
    fi
    printf '\n'
    queued_messages
    printf '\n'
    check_ssl

    rm -rf "$TMP_PATH_SCRIPT"/zimbra_session_*_status.txt
}

main

remove_pid
