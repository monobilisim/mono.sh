#!/usr/bin/env bash
###~ description: This script is used to alert whenever a ssh session is started

#~ for debugging
set -xe
exec &>/var/log/ssh-notifier.log

#~ variables
#shellcheck disable=SC2034
script_version="v2.0.1"

#shellcheck disable=SC2034
SCRIPT_NAME=ssh-notifier

#shellcheck disable=SC2034
NO_COLORS=1

#shellcheck disable=SC2034
SCRIPT_NAME_PRETTY="SSH Notifier"

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

create_tmp_dir &> /dev/null

cron_mode "$ENABLE_CRON"

parse_sshnotifier() {
    CONFIG_PATH_SSH="ssh-notifier"
    export REQUIRED=true

    readarray -t EXCLUDE_DOMAINS < <(yaml .exclude.domains[] "$CONFIG_PATH_SSH")
    readarray -t EXCLUDE_IPS < <(yaml .exclude.ips[] "$CONFIG_PATH_SSH")
    readarray -t EXCLUDE_USERS < <(yaml .exclude.users[] "$CONFIG_PATH_SSH")
   
    OS_TYPE="$(yaml .server.os_type "$CONFIG_PATH_SSH")"

    SERVER_ADDRESS="$(yaml .server.address "$CONFIG_PATH_SSH")"

    SSH_POST_URL="$(yaml .ssh_post_url "$CONFIG_PATH_SSH")"
    SSH_POST_URL_BACKUP="$(yaml .ssh_post_url_backup "$CONFIG_PATH_SSH")"

    WEBHOOK_URL="${ALARM_WEBHOOK_URLS[0]}"
    
    # Remove the topic and the stream
    WEBHOOK_URL_FILTERED="${WEBHOOK_URL%%&*}"

    WEBHOOK_STREAM="$(yaml .webhook.stream "$CONFIG_PATH_SSH" "ssh")"
}

#~ getlogininfo() gets the login information from the log files and authorized_keys file
getlogininfo() {
	if [[ -e "/var/log/secure" ]]; then
        logfile="/var/log/secure"
    else
        logfile="/var/log/auth.log"
    fi

	if [[ "$OS_TYPE" == "RHEL6" ]]; then
		keyword="Found matching"
	elif [[ "$OS_TYPE" == "GENERIC" ]]; then
		keyword="Accepted publickey"
	fi

	[[ ! -e $logfile ]] && {
		echo "Logfile \"$logfile\" does not exists, aborting..."
		exit 1
	}
	fingerprint=$(grep "$keyword" "$logfile" | grep $PPID | tail -n 1 | awk '{print $NF}')

	[[ "$PAM_USER" == "root" ]] && authorized_keys="/root/.ssh/authorized_keys" || authorized_keys="/home/$PAM_USER/.ssh/authorized_keys"

	if [[ -e $authorized_keys ]]; then
		if [[ "$OS_TYPE" == "RHEL6" ]]; then
			mkdir -p "$TMP_PATH_SCRIPT"

			ssh_keys_cmdout="$(cat "$authorized_keys")"

            mapfile -t ssh_keys <<<"$ssh_keys_cmdout"
            
			for key in "${ssh_keys[@]}"; do
				comment="$(echo "$key" | awk '{print $3}')"
				[[ -z "$comment" ]] && { comment="empty_comment"; }
				echo "$key" >"$TMP_PATH_SCRIPT"/"$comment"
			done

			for ssh_user in "$TMP_PATH_SCRIPT"/*; do
                #shellcheck disable=SC2076
				[[ -n "$fingerprint" && "$(ssh-keygen -lf "$TMP_PATH_SCRIPT"/"$ssh_user")" =~ "$fingerprint" ]] && {
					user=$ssh_user
					login_method="ssh-key"
					break
				}
			done

			rm -rf /tmp/ssh_keys
		elif [[ "$OS_TYPE" == "GENERIC" ]]; then
			keys_out="$(ssh-keygen -lf "$authorized_keys")"
            
            mapfile -t keys <<<"$keys_out"

			for key in "${keys[@]}"; do
                #shellcheck disable=SC2076
				[[ -n "$fingerprint" && "$key" =~ "$fingerprint" ]] && {
					user=$(echo "$key" | awk '{print $3}')
					login_method="ssh-key"
					break
				}
			done
		fi
	else
		user=$PAM_USER
	fi


    if [[ -n "${EXCLUDE_USERS[*]}" ]]; then
        for exclude_user in "${EXCLUDE_USERS[@]}"; do
            # if $user has @ in it
            if [[ "${user:-$PAM_USER}" =~ "@" ]]; then
                # Remove everything after and including @
                if [[ -n "$user" ]]; then
                    user="${user%%@*}"
                else
                    user="${PAM_USER%%@*}"
                fi
            fi

            if [[ "${user:-$PAM_USER}" == "$exclude_user" && -n "${user-$PAM_USER}" ]]; then
                return
            fi
        done
    fi

    if [[ -n "${EXCLUDE_DOMAINS[*]}" ]]; then
        for exclude_domain in "${EXCLUDE_DOMAINS[@]}"; do
            if [[ "$user" == *"$exclude_domain" && -n "$user" ]]; then
                return
            fi
        done
    fi

    if [[ -n "${EXCLUDE_IPS[*]}" ]]; then
        for exclude_ip in "${EXCLUDE_IPS[@]}"; do
            if [[ "$PAM_RHOST" == "$exclude_ip" && -n "$PAM_RHOST" ]]; then
                return
            fi
        done
    fi

	echo "{\"username\": \"${user:-$PAM_USER}\", \"fingerprint\": \"${fingerprint:-no_fingerprint}\", \"server\": \"$PAM_USER@$IDENTIFIER\", \"remote_ip\": \"$PAM_RHOST\", \"date\": \"$(date +'%d.%m.%Y %H:%M:%S')\", \"type\": \"$PAM_TYPE\", \"login_method\": \"${login_method:-password}\"}"
}

#~ notify_and_save() sends the notification to the webhook and saves the login information to the database
notify_and_save() {
	username=$(echo "$@" | jq -r .username)
	fingerprint=$(echo "$@" | jq -r .fingerprint)
	server=$(echo "$@" | jq -r .server)
	remote_ip=$(echo "$@" | jq -r .remote_ip)
	#date=$(echo "$@" | jq -r .date)
	type=$(echo "$@" | jq -r .type)
	login_method=$(echo "$@" | jq -r .login_method)

	for a in username remote_ip type; do
		[[ -z ${!a} ]] && { return; }
	done

	if [[ "$type" == "open_session" ]]; then
		# message="🟢 - [GİRİŞ] - [$PPID] - [$date] ${username}@$remote_ip ➡️ $server"
		# message="🟢 - [GİRİŞ] - { ${username}@$remote_ip } >> { $server - $PPID }"
		# message="[ ${IDENTIFIER} ] [:green: Login] { ${username}@$remote_ip } >> { $server - $PPID }"
		message="[ ${IDENTIFIER} ] [ :green: Login ] { ${username}@$remote_ip } >> { $SERVER_ADDRESS - $PPID }"
	else
		# message="🔴 - [ÇIKIŞ] - [$PPID] - [$date] ${username}@$remote_ip ⬅️ $server"
		# message="🔴 - [ÇIKIŞ] - { ${saved_username:-$username}@${saved_remote_ip:-$remote_ip} } << { $server - $PPID }"
		# message="[ ${IDENTIFIER} ] [:red_circle: Logout] { ${username}@$remote_ip } >> { $server - $PPID }"
		message="[ ${IDENTIFIER} ] [ :red_circle: Logout ] { ${saved_username:-$username}@${saved_remote_ip:-$remote_ip} } << { $SERVER_ADDRESS - $PPID }"
	fi

	curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$message\"}" "${WEBHOOK_URL_FILTERED}&stream=$WEBHOOK_STREAM&topic=${username%@*}"
	for f in /tmp/mono.sh/*; do
		if [[ -d $f ]]; then
			files=$(shopt -s nullglob dotglob; echo "$f"/*_status.txt)
			if ((${#files})); then
				curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$message\"}" "$WEBHOOK_URL"
                break
			fi
		fi
	done

	json_data_for_db='{
		"PPID": "'"$PPID"'",
		"linux_user": "'"$PAM_USER"'",
		"type": "'"$type"'",
		"key_comment": "'"$username"'",
		"host": "'"$server"'",
		"connected_from": "'"$remote_ip"'",
		"login_type": "'"$login_method"'"
	}'
   
    if ! curl --connect-timeout 1 -X POST -H "Content-Type: application/json" -d "$json_data_for_db" "$SSH_POST_URL" 2>/dev/null; then
        curl --connect-timeout 1 -X POST -H "Content-Type: application/json" -d "$json_data_for_db" "$SSH_POST_URL_BACKUP" 2>/dev/null;
    fi
}

#~ main() function
main() {
	sleep 1 # wait for PAM to finish
    
    parse_sshnotifier

	out="$(getlogininfo)"

	if [[ "$(echo "$out" | jq -r .type)" == "open_session" ]]; then
		[[ ! -d "/var/run/ssh-session" ]] && mkdir -p "/var/run/ssh-session"
		echo "$out" >/var/run/ssh-session/${PPID}-cred.json
		notify_and_save "$out" || exit 0
	elif [[ "$(echo "$out" | jq -r .type)" == "close_session" ]]; then
		[[ -e "/var/run/ssh-session/${PPID}-cred.json" ]] && rm -f "/var/run/ssh-session/${PPID}-cred.json"
		notify_and_save "$out" || exit 0
	fi
}

main "$@" &
