#!/usr/bin/env bash
###~ description: This script sends an alarm to a channel when the server is up or shutting down.

#~ variables
#shellcheck disable=SC2034
script_version="v2.0.0"
SCRIPT_NAME=shutdown-notifier
SCRIPT_NAME_PRETTY="Shutdown Notifier"

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

#shellcheck disable=SC1091
. "$SCRIPTPATH"/../common.sh

usage() {
	echo -e "Usage: $0 [--poweron] [--poweroff] [-h]"
	echo -e "\t-1 | --poweron   : Send power on alarm."
	echo -e "\t-0 | --poweroff  : Send power off alarm."
	echo -e "\t-h | --help      : Print this message."
}

main() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		-1|--poweron)
			alarm "[ $IDENTIFIER ] [:info: Info] Server is up..."
		;;
		-0|--poweroff)
			alarm "[ $IDENTIFIER ] [:warning: Warning] Server is shutting down..."
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
