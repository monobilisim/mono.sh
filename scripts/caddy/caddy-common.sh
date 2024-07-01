#!/usr/bin/env bash
###~ description: Common functions for Caddy scripts

#https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

parse_caddy() {
   CONFIG_PATH_CADDY="caddy" 
   export REQUIRED=true

   readarray -t CADDY_API_URLS <(yaml .caddy.api_urls[] "$CONFIG_PATH_CADDY")
   readarray -t CADDY_SERVERS <(yaml .caddy.servers[] "$CONFIG_PATH_CADDY")
   readarray -t CADDY_LB_URLS <(yaml .caddy.lb_urls[] "$CONFIG_PATH_CADDY")
   
   SERVER_OVERRIDE_CONFIG=$(yaml .caddy.override_config "$CONFIG_PATH_CADDY" "0")

   SERVER_NOCHANGE_EXIT_THRESHOLD=$(yaml .caddy.nochange_exit_threshold "$CONFIG_PATH_CADDY" "3")
    
   SEND_ALARM=$(yaml .alarm.enabled "$CONFIG_PATH_CADDY" "$SEND_ALARM")

   DYNAMIC_API_URLS=$(yaml .caddy.dynamic_api_urls "$CONFIG_PATH_CADDY" "1")

   LOOP_ORDER=$(yaml .caddy.loop_order "$CONFIG_PATH_CADDY" "API_URLS")
}
