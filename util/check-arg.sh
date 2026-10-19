#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# check if a command supports an argument by searching its --help output.
# usage: check-arg.sh <argument> <command> [command args...]
#
# the help flag is appended after any command args, so for apps that take
# their own args after an EAL separator (ex: testpmd), pass the separator:
#   check-arg.sh --tx-ip sudo dpdk-testpmd --no-pci --
#   -> runs: sudo dpdk-testpmd --no-pci -- --help
#
# env vars:
#   HELP_FLAG     flag used to print help (default: --help)
#   HELP_TIMEOUT  seconds to wait for the command (default: 30)
#   QUIET         if set, print nothing; only use the exit code
#
# exit codes: 0 = argument found, 1 = not found, 2 = usage error/no help output

usage() {
    echo "Usage: $0 <argument> <command> [command args...]"
    echo "  ex: $0 --tx-ip sudo dpdk-testpmd --no-pci --"
}

if [[ $# -lt 2 ]]; then
    usage
    exit 2
fi

ARG="$1"
shift
HELP_FLAG="${HELP_FLAG:---help}"
HELP_TIMEOUT="${HELP_TIMEOUT:-30}"

if ! command -v "$1" > /dev/null 2>&1; then
    echo "Error: command not found: $1"
    exit 2
fi

# many tools print help to stderr and/or exit non-zero, so ignore the exit code
HELP_OUTPUT=$(timeout "$HELP_TIMEOUT" "$@" "$HELP_FLAG" 2>&1)
if [[ -z "$HELP_OUTPUT" ]]; then
    echo "Error: no output from: $* $HELP_FLAG"
    exit 2
fi

# escape regex metacharacters so the argument is matched literally
ARG_RE=$(printf '%s' "$ARG" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
# match the whole argument, so --tx-ip doesn't match --tx-ip-foo or --no-tx-ip
MATCHES=$(grep -E -- "(^|[^[:alnum:]_-])${ARG_RE}([^[:alnum:]_-]|$)" <<< "$HELP_OUTPUT")

if [[ -n "$MATCHES" ]]; then
    [[ -z "$QUIET" ]] && echo "$MATCHES"
    exit 0
fi
[[ -z "$QUIET" ]] && echo "'$ARG' not found in: $* $HELP_FLAG"
exit 1
