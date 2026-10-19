#! /bin/bash
# SPDX-License-Identifier: MIT
# author: mamcgove at microsoft aka @mcgov on github

# summarize the periodic throughput stats (--stats <n>) from a dpdk-testpmd log:
# avg/max/min pps and bps per port, plus the total across all ports.
# samples where a port shows 0 pps are skipped, then the first and last remaining samples of each port
# are dropped since they usually cover a partial stats period.
# usage: testpmd-summary.sh [--direction rx|tx] [--label <name>] <testpmd log>

DIRECTION="rx"
LABEL=""
OPTIONS="h"
LONGOPTIONS="help,direction:,label:"
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"
while true; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [--direction rx|tx] [--label <name>] <testpmd log>"
            exit 0
            ;;
        --direction)
            DIRECTION="${2,,}"
            if [[ "$DIRECTION" != "rx" ]] && [[ "$DIRECTION" != "tx" ]]; then
                echo "Error: --direction must be rx or tx"
                exit 1
            fi
            shift 2
            ;;
        --label)
            LABEL="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "unrecognized argument: $1"
            exit 1
            ;;
    esac
done
LOG="$1"
[[ -f "$LOG" ]] || { echo "Error: log file '$LOG' not found" 1>&2; exit 1; }

# testpmd prints, for each port every stats period:
#   ######## NIC statistics for port 0 ########
#   ...
#   Rx-pps:      1234          Rx-bps:      5678
#   Tx-pps:      1234          Tx-bps:      5678
awk -v dir="${DIRECTION^}" -v label="${LABEL:-$LOG}" '
{
    # strip terminal control codes (testpmd clears the screen between stats)
    gsub(/\033\[[0-9;]*[A-Za-z]/, "")
}
/NIC statistics for port/ {
    for (i = 1; i <= NF; i++) if ($i == "port") port = $(i + 1)
    next
}
$1 == dir "-pps:" && port != "" {
    if ($2 + 0 == 0) next
    if (!(port in n)) ports[++nports] = port
    n[port]++
    sp[port, n[port]] = $2 + 0
    sb[port, n[port]] = $4 + 0
}
END {
    printf "== %s (%s)\n", label, tolower(dir)
    if (nports == 0) { print "no non-zero " tolower(dir) " throughput samples found"; exit 1 }
    printf "%-6s %8s   %-30s   %-30s\n", "port", "samples", "Mpps avg / max / min", "Gbps avg / max / min"
    for (i = 1; i <= nports; i++) {
        p = ports[i]
        # drop the first and last samples, they usually cover a partial stats period
        first = 1; last = n[p]; note = ""
        if (n[p] >= 3) { first = 2; last = n[p] - 1 } else note = " *"
        count = last - first + 1
        psum = bsum = 0
        pmax = pmin = sp[p, first]; bmax = bmin = sb[p, first]
        for (k = first; k <= last; k++) {
            psum += sp[p, k]; bsum += sb[p, k]
            if (sp[p, k] > pmax) pmax = sp[p, k]
            if (sp[p, k] < pmin) pmin = sp[p, k]
            if (sb[p, k] > bmax) bmax = sb[p, k]
            if (sb[p, k] < bmin) bmin = sb[p, k]
        }
        pavg = psum / count; bavg = bsum / count
        tp += pavg; tb += bavg
        if (note != "") short = 1
        printf "%-6s %8d   %8.3f / %8.3f / %8.3f   %8.3f / %8.3f / %8.3f%s\n", p, count,
            pavg / 1e6, pmax / 1e6, pmin / 1e6, bavg / 1e9, bmax / 1e9, bmin / 1e9, note
    }
    printf "%-6s %8s   %8.3f %21s   %8.3f\n", "total", "", tp / 1e6, "", tb / 1e9
    if (short) print "* fewer than 3 samples, first/last samples were not dropped"
}' "$LOG"
