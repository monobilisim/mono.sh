#!/usr/bin/env bash

SCRIPT_NAME=patroni-leadercheck
SCRIPT_NAME_PRETTY="Patroni leader check"

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$(
    cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit
    pwd -P
)"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

create_tmp_dir

cron_mode "$ENABLE_CRON"

function parse_config_patronileadercheck() {
    CONFIG_PATH_PATRONILEADERCHECK="patroni-leader-check"
    export REQUIRED=true

    CF_API_TOKEN=$(yaml .cloudflare.token $CONFIG_PATH_PATRONILEADERCHECK)

    CF_ZONE_NAME=$(yaml .cloudflare.zone_name $CONFIG_PATH_PATRONILEADERCHECK)

    DOMAIN=$(yaml .haproxy_domain $CONFIG_PATH_PATRONILEADERCHECK)
    
    REDIS_ADDR=$(yaml .redis.addr $CONFIG_PATH_PATRONILEADERCHECK)

    REDIS_PORT=$(yaml .redis.sentinel_port $CONFIG_PATH_PATRONILEADERCHECK "26379")

    MASTER_NAME=$(yaml .redis.master_name $CONFIG_PATH_PATRONILEADERCHECK "mymaster")

}

parse_config_patronileadercheck

get_master() {
    # Master'ı al
    redis-cli -h "$REDIS_ADDR" -p "$REDIS_PORT" SENTINEL get-master-addr-by-name "$MASTER_NAME" | head -1 2> /dev/null
}

force_failover() {
    echo "Changing master..."
    redis-cli -h "$REDIS_ADDR" -p "$REDIS_PORT" SENTINEL failover "$MASTER_NAME"
    sleep 5
}


alarm_exit() {
    monokit alarm send --message "[patroni-leader-check] [:x:] $1"
    exit 1
}


PATRONI_ENDPOINT="$(/usr/local/bin/yq -r .restapi.connect_address /etc/patroni/patroni.yml)"
PATRONI_IP=$(echo "$PATRONI_ENDPOINT" | cut -d':' -f1)

response_code=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" "http://$PATRONI_ENDPOINT")

if [ "$response_code" -eq 200 ]; then
    echo "Master node confirmed."

    redis_master_ip="$(get_master)"

    if [ "$redis_master_ip" == "$(dig +short "$REDIS_ADDR")" ]; then
        echo "Redis role is master already."
        exit
    fi

    echo "Redis role is not master. Promoting to master."

    force_failover

    # Check redis role again
    redis_master_ip="$(get_master)"

    if [ "$redis_master_ip" != "$(dig +short "$REDIS_ADDR")" ]; then
        echo "Redis could not be promoted to master."
        alarm_exit "Redis could not be promoted to master on $(hostname)"
    fi

    monokit alarm send --message "[patroni-leader-check] [:check:] Redis promoted to master on hostname $(hostname) with redis address $REDIS_ADDR"


    current_record=$(/usr/local/bin/flarectl dns list --zone "$CF_ZONE_NAME" --type "A" | grep "$DOMAIN")
    record_id=$(echo "$current_record" | awk '{print $1}')
    current_ip=$(echo "$current_record" | awk '{for(i=1;i<=NF;i++) if($i ~ /^10\./) print $i; exit}')

    echo "Extracted Record ID: '$record_id'"
    echo "Current IP: '$current_ip'"

    new_ip="$PATRONI_IP"


    if [ -z "$record_id" ]; then
        echo "Record ID not found."
        exit 1
    fi

    # Compare IP addresses
    if [ "$current_ip" != "$new_ip" ]; then
        echo "Updating DNS record from $current_ip to $new_ip"
        # Update DNS record
        /usr/local/bin/flarectl dns update --zone "$CF_ZONE_NAME" --id "$record_id" --name "$DOMAIN" --content "$new_ip" --type "A" || alarm_exit "Could not update DNS record for $DOMAIN"
    else
        echo "IP address has not changed. No update required."
    fi
else
    echo "This node is not a master or could not be accessed."
fi
