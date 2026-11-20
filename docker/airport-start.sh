#!/bin/sh
set -eu
SCHEDULERS="${SCHEDULERS:-1}"
MODE="${MODE:-tower}"
BIND="${BIND:-0.0.0.0}"
CONFIG="${CONFIG:-none}"
LOG_DIR="${LOG_DIR:-/logs}"
if [ -z "${ICAO}" ]; then
    echo "ICAO is required"
    exit 1
fi
if [ -z "${FREQS}" ]; then
    echo "FREQS is required"
    exit 1
fi
cd /opt/atc
set --
for dir in /opt/atc/_build/default/lib/*/ebin; do
    set -- "$@" -pa "$dir"
done
exec erl +S "${SCHEDULERS}:${SCHEDULERS}" -noshell "$@" -eval "atc_radio_cli:main([\"${ICAO}\",\"${BIND}\",\"${CONFIG}\",\"${LOG_DIR}\",\"${MODE}\",\"${FREQS}\"]), receive stop -> ok end."
