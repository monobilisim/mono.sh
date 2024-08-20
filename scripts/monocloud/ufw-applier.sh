#!/usr/bin/env bash
###~ description: This script is used to apply ufw rules to the system

#~ variables
#shellcheck disable=SC2034
script_version="v1.1.0"
SCRIPT_NAME=ufw-applier
SCRIPT_NAME_PRETTY="UFW Applier"

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

create_tmp_dir &> /dev/null

cron_mode "$ENABLE_CRON"

function parse_config() {
    CONFIG_PATH_UFW="ufw"
    export REQUIRED=true

    readarray -t RULE_URLS < <(yaml .rule_urls[] "$CONFIG_PATH_UFW")
}

function remove_file() {
    protocol=$(awk '{print $1}' < /etc/mono.sh/ufw-applier-ruleset/"$(basename "$1")")
    port=$(awk '{print $2}' < /etc/mono.sh/ufw-applier-ruleset/"$(basename "$1")")
    description=$(cut -f4- -d ' ' < /etc/mono.sh/ufw-applier-ruleset/"$(basename "$1")")
    echo "Removing old rulefile $1..."
    while IFS=: read -r line; do
        # Get IP address
        ip_address=$(echo "$line" | awk '{print $1}')

        # Get the comment
        comment=$(echo "$line" | sed -E 's/^[^#]+#([^#]+).*/\1/' | xargs)

        # Generate the command

        if [[ "$protocol" == "all" ]]; then
            ufw_command="ufw delete allow from"
        else
            ufw_command="ufw delete allow proto $protocol from"
        fi

        if [[ -n "$description" ]]; then
            comment="$description"
        fi

        if [[ "$port" == "all" ]]; then
            ufw_command="$ufw_command $ip_address comment '$comment'"
        else
            ufw_command="$ufw_command $ip_address comment '$comment' to any port $port"
        fi

        # Display and execute the command
        [[ ! "$NO_CMD_OUT" == 1 ]] && echo "$ufw_command"
        [[ ! "$DRY_RUN" == "1" ]] && eval "$ufw_command"
    done < <(grep "" "$1")
    echo "Done processing $1"
}

function apply_file() {
    echo "Processing $1..."
    mkdir -p /etc/mono.sh/ufw-applier-ruleset

    if [[ "$4" != "default" ]]; then
        echo "$2 $3 $4" > /etc/mono.sh/ufw-applier-ruleset/"$(basename "$1")"
    else
        echo "$2 $3" > /etc/mono.sh/ufw-applier-ruleset/"$(basename "$1")"
    fi

    while IFS=: read -r line; do
        # Get IP address
        ip_address=$(echo "$line" | awk '{print $1}')

        if [[ "$4" != "default" ]]; then
            # Get the comment
            comment="$4"
        else
            # Get the comment
            comment=$(echo "$line" | sed -E 's/^[^#]+#([^#]+).*/\1/' | xargs)
        fi

        if [[ "$2" == "all" ]]; then
            # Accept tcp and udp
            ufw_command="ufw allow from"
        else
            # Accept only tcp/udp
            ufw_command="ufw allow proto $2 from"
        fi

        if [[ "$3" == "all" ]]; then
            # Generate the command
            ufw_command="$ufw_command $ip_address comment '$comment'"
        else
            # Generate the command
            ufw_command="$ufw_command $ip_address comment '$comment' to any port $3"
        fi

        # Display and execute the command
        [[ ! "$NO_CMD_OUT" == 1 ]] && echo "$ufw_command"
        [[ ! "$DRY_RUN" == "1" ]] && eval "$ufw_command"
    done < <(grep "" "$1")
    echo "Done processing $1"
}

is_in_array() {
    local value=$1
    local array=$2
    for element in "${array[@]}"; do
        if [[ "$element" == "$value" ]]; then
            return 0
        fi
    done
    return 1
}

main() {
    mkdir /etc/mono.sh/ufw-applier/ &> /dev/null
    parse_config
    FILES_PROCESSED=()
    for rule in "${RULE_URLS[@]}"; do
        rule_url=$(echo "$rule" | awk '{print $1}')
        rule_file=$(basename "$rule_url")
        rule_protocol=$(echo "$rule" | awk '{print $2}')
        rule_port=$(echo "$rule" | awk '{print $3}')
        rule_description=$(echo "$rule" | cut -f4- -d ' ')
        curl -s -o "$TMP_PATH_SCRIPT/$rule_file-tmp" "$rule_url"
        if [[ -f "/etc/mono.sh/ufw-applier/$rule_file" ]]; then
            SUM_ORIG=$(sha256sum "/etc/mono.sh/ufw-applier/$rule_file" | awk '{print $1}')
            PORTFILE=$(cat "/etc/mono.sh/ufw-applier-ruleset/$rule_file")

            PORTFILE_NEW="$rule_protocol $rule_port"

            if [[ -n "$rule_description" ]]; then
                PORTFILE_NEW="$PORTFILE_NEW $rule_description"
            fi

            if [[ $(sha256sum "$TMP_PATH_SCRIPT/$rule_file-tmp" | awk '{print $1}') != "$SUM_ORIG" || "$PORTFILE" != "$PORTFILE_NEW" ]]; then
                echo "Sum mismatch, updating $rule_file"
                remove_file "/etc/mono.sh/ufw-applier/$rule_file"
                mv "$TMP_PATH_SCRIPT/$rule_file-tmp" "/etc/mono.sh/ufw-applier/$rule_file"
                apply_file "/etc/mono.sh/ufw-applier/$rule_file" "${rule_protocol:-tcp}" "${rule_port:?no port specified}" "${rule_description:-default}"
            else
                echo "No sum mismatch, no change necessary"
                rm -f "$TMP_PATH_SCRIPT/$rule_file-tmp" # No change necessary
            fi
        else
            echo "No existing rule file, creating $rule_file"
            mv "$TMP_PATH_SCRIPT/$rule_file-tmp" "/etc/mono.sh/ufw-applier/$rule_file"
            apply_file "/etc/mono.sh/ufw-applier/$rule_file" "${rule_protocol:-tcp}" "${rule_port:?no port specified}" "${rule_description:-default}"
        fi

        FILES_PROCESSED+=("$rule_file")
    done

    echo "Files processed: '${FILES_PROCESSED[*]}'"

    for file in /etc/mono.sh/ufw-applier/*; do
        for rule_file in "${FILES_PROCESSED[@]}"; do
            if [[ "$(basename "$file")" == "$rule_file" ]]; then
                continue 2
            fi
        done
        echo "File $file not in list, removing..."
        remove_file "$file"
        rm -f "$file"
    done
}

main
