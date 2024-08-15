#!/usr/bin/env bash
###~ description: This script is used to apply ufw rules to the system

#~ variables
#shellcheck disable=SC2034
script_version="v1.0.0"
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
    echo "Removing old rulefile $1..."
    while IFS= read -r line; do
        # Get IP address
        ip_address=$(echo "$line" | awk '{print $1}')
        
        # Get the comment
        comment=$(echo "$line" | sed -E 's/^[^#]+#([^#]+).*/\1/' | xargs)
        
        # Generate the command
        ufw_command="ufw delete allow proto tcp from $ip_address comment '$comment'"
        
        # Display and execute the command
        [[ ! "$NO_CMD_OUT" == 1 ]] && echo "$ufw_command"
        [[ ! "$DRY_RUN" == "1" ]] && eval "$ufw_command"
    done < "$1"
    echo "Done processing $1"
}

function apply_file() {
    echo "Processing $1..."
    while IFS= read -r line; do
        # Get IP address
        ip_address=$(echo "$line" | awk '{print $1}')
        
        # Get the comment
        comment=$(echo "$line" | sed -E 's/^[^#]+#([^#]+).*/\1/' | xargs)
        
        # Generate the command
        ufw_command="ufw allow proto tcp from $ip_address comment '$comment'"
        
        # Display and execute the command
        [[ ! "$NO_CMD_OUT" == 1 ]] && echo "$ufw_command"
        [[ ! "$DRY_RUN" == "1" ]] && eval "$ufw_command"
    done < "$1"
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
    for rule_url in "${RULE_URLS[@]}"; do
        rule_file=$(basename "$rule_url")
        curl -s -o "$TMP_PATH_SCRIPT/$rule_file-tmp" "$rule_url"
        if [[ -f "/etc/mono.sh/ufw-applier/$rule_file" ]]; then
            SUM_ORIG=$(sha256sum "/etc/mono.sh/ufw-applier/$rule_file" | awk '{print $1}')

            if [[ $(sha256sum "$TMP_PATH_SCRIPT/$rule_file-tmp" | awk '{print $1}') != "$SUM_ORIG" ]]; then
                echo "Sum mismatch, updating $rule_file"
                remove_file "/etc/mono.sh/ufw-applier/$rule_file"
                mv "$TMP_PATH_SCRIPT/$rule_file-tmp" "/etc/mono.sh/ufw-applier/$rule_file"
                apply_file "/etc/mono.sh/ufw-applier/$rule_file"
            else
                echo "No sum mismatch, no change necessary"
                rm -f "$TMP_PATH_SCRIPT/$rule_file-tmp" # No change necessary
            fi
        else
            echo "No existing rule file, creating $rule_file"
            mv "$TMP_PATH_SCRIPT/$rule_file-tmp" "/etc/mono.sh/ufw-applier/$rule_file"
            apply_file "/etc/mono.sh/ufw-applier/$rule_file"
        fi
        
        FILES_PROCESSED+=("$rule_file")
    done

    for file in /etc/mono.sh/ufw-applier/*; do
        if ! is_in_array "$(basename "$file")" "${FILES_PROCESSED[@]}"; then
            echo "File $file not in list, removing..."
            remove_file "$file"
            rm -f "$file"
        fi
    done
}

main
