#!/usr/bin/env bash
###~ description: Check the status of WPPConnect sessions

#shellcheck disable=SC2034
SCRIPT_NAME=wppconnect-health

#shellcheck disable=SC2034
SCRIPT_NAME_PRETTY="WPPConnect Health"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

VERSION=v1.0.0

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

create_tmp_dir

parse_wppconnect() {
    CONFIG_PATH_WPPCONNECT="wppconnect"
    export REQUIRED=true
    
    WPP_SECRET=$(yaml .wpp.secret "$CONFIG_PATH_WPPCONNECT")    
    WPP_URL=$(yaml .wpp.url "$CONFIG_PATH_WPPCONNECT")

    SEND_ALARM=$(yaml .alarm.enabled "$CONFIG_PATH_WPPCONNECT" "$SEND_ALARM")
}

parse_wppconnect

function wpp_check() {
    curl -fsSL -X GET --location "$WPP_URL/api/$WPP_SECRET/show-all-sessions" \
	-H "Accept: application/json" \
	-H "Content-Type: application/json" | jq -c -r '.response[]' | while read -r SESSION; do
	TOKEN="$(curl -fsSL -X POST --location "$WPP_URL/api/$SESSION/$WPP_SECRET/generate-token" | jq -r '.token')"
	STATUS="$(curl -fsSL -X GET --location "$WPP_URL/api/$SESSION/check-connection-session" \
	    -H "Accept: application/json" \
	    -H "Content-Type: application/json" \
	    -H "Authorization: Bearer $TOKEN" | jq -c -r '.message')"
	CONTACT_NAME="$(curl -fsSL -X GET --location "$WPP_URL/api/$SESSION/contact/$SESSION" \
	    -H "Accept: application/json" \
	    -H "Content-Type: application/json" \
	    -H "Authorization: Bearer $TOKEN" | jq -c -r '.response.name // .response.pushname // "No Name"')"

	if [[ "$STATUS" == "Connected" ]]; then
	    print_colour "$CONTACT_NAME, Session $SESSION" "$STATUS"
	    alarm_check_up "wpp_session_$SESSION" "Session $SESSION with name $CONTACT_NAME is connected again" "$ALARM_INTERVAL"
	else
	   alarm_check_down "wpp_session_$SESSION" "Session $SESSION with name $CONTACT_NAME is not connected, status '$STATUS'" "$ALARM_INTERVAL"
	    print_colour "$CONTACT_NAME, Session $SESSION" "$STATUS" "error"
	fi
    done
}


function main() {
    create_pid
    printf '\n'
    echo "Mono Cloud WPPConnect $VERSION - $(date)"
    printf '\n'
    wpp_check
}

main

remove_pid