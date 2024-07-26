#!/usr/bin/env bash
###~ description: Upload K8s resource logs to S3 bucket

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

VERSION=v0.5.0

#shellcheck disable=SC2034
SCRIPT_NAME="k8s-s3-uploader"

#shellcheck disable=SC2034
SCRIPT_NAME_FANCY="K8s S3 Uploader"

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

[[ -f "/var/lib/rancher/rke2/bin/kubectl" ]] && {
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
}

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

create_tmp_dir

parse_config_monok8s_s3() {
    CONFIG_PATH_MONOK8S="k8s"
    export REQUIRED=true

    readarray -t K8S_LOG_LIST < <(yaml .k8s.log_list[] "$CONFIG_PATH_MONOK8S")

    AWS_ACCESS_KEY_ID=$(yaml .aws.access_key_id $CONFIG_PATH_MONOK8S)
    AWS_SECRET_ACCESS_KEY=$(yaml .aws.secret_access_key $CONFIG_PATH_MONOK8S)
    S3_BUCKET=$(yaml .aws.bucket $CONFIG_PATH_MONOK8S)
    AWS_ENDPOINT_URL=$(yaml .aws.endpoint_url $CONFIG_PATH_MONOK8S)
    AWS_DEFAULT_REGION=$(yaml .aws.default_region $CONFIG_PATH_MONOK8S "us-east-1")

    SEND_ALARM=$(yaml .alarm.enabled $CONFIG_PATH_MONOK8S "$SEND_ALARM")
}

parse_config_monok8s_s3

if ! command -v aws &>/dev/null; then
    echo "AWS CLI is not installed"
    exit 1
fi

function configure_s3() {
    aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
    aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
    aws configure set default.region "$AWS_DEFAULT_REGION"
}

function upload_to_s3() {
    
    configure_s3

    [ -d "$TMP_PATH_SCRIPT/logs" ] && rm -r "$TMP_PATH_SCRIPT"/logs
    mkdir -p "$TMP_PATH_SCRIPT"/logs

    for resource in "${K8S_LOG_LIST[@]}"; do
        # example resource: test-namespace/pod/test-pod
        IFS='/' read -ra parts <<< "$resource"
        
        namespace=${parts[0]}
        resource_type=${parts[1]}
        resource_name=${parts[2]}
        date_day="$(date +'%Y-%m-%d')"
        date="$(date +'%Y-%m-%d-%H:%M:%S')"
        p="$TMP_PATH_SCRIPT/logs/$namespace/$resource_type/$resource_name/$date-$resource_name.log"
        mkdir -p "$TMP_PATH_SCRIPT/logs/$namespace/$resource_type/$resource_name"
        if ! kubectl logs -n "$namespace" "$resource_type/$resource_name" &>"$p"; then
            print_colour "$resource_name" "failed to get" "error"
            alarm_check_down "$resource_name" "Failed to get logs"
        else
            print_colour "$resource" "logs fetched"
            alarm_check_up "$resource_name" "Logs fetched"
        fi
        
        if [[ -n "$AWS_ENDPOINT_URL" ]]; then
            if aws s3 cp --quiet "$p" "s3://$S3_BUCKET/monok8s-logs/$date_day/$namespace/$resource_type/$resource_name/$date-$resource_name.log" --endpoint-url "$AWS_ENDPOINT_URL" 2>/dev/null; then
                print_colour "$resource" "uploaded"
                alarm_check_up "$resource" "Logs uploaded"
            else
                print_colour "$resource" "failed to upload" "error"
                alarm_check_down "$resource" "Failed to upload logs for namespace '$namespace', resource type '$resource_type' and resource name '$resource_name'"
            fi 
        else
            if aws s3 cp --quiet "$p" "s3://$S3_BUCKET/monok8s-logs/$date_day/$namespace/$resource_type/$resource_name/$date-$resource_name.log" 2>/dev/null; then
                print_colour "$resource" "uploaded"
                alarm_check_up "$resource" "Logs uploaded"
            else
                print_colour "$resource" "failed to upload" "error"
                alarm_check_down "$resource" "Failed to upload logs for namespace '$namespace', resource type '$resource_type' and resource name '$resource_name'"
            fi 
        fi
    done
}

function main() {
    pid_file="$(create_pid)"
    printf '\n'
    echo "MonoK8s S3 Uploader $VERSION - $(date)"
    printf '\n'
    upload_to_s3
}

main

rm "${pid_file}"
