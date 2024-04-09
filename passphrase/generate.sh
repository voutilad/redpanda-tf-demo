#!/bin/sh
set -e

SCRIPT=$(realpath "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

WORDLIST="${WORDLIST:-${SCRIPTPATH}/eff_large_wordlist.txt}"
DELIM="${DELIM:--}"

if ! [ -r "${WORDLIST}" ]; then
    echo "${WORDLIST} not found or not readable" 2>&1
    exit 1
fi

random() {
    MODULO="${1:-32767}"
    SEED=$(date '+%N')
    awk "BEGIN { srand(${SEED}); print(int(rand() * ${MODULO})); }"
}

LEN=$(wc -l < "${WORDLIST}")
RAND1=$(head -n "$(random "${LEN}")" "${WORDLIST}" | tail -n 1 | awk '{ print $2 }')
RAND2=$(head -n "$(random "${LEN}")" "${WORDLIST}" | tail -n 1 | awk '{ print $2 }')
RAND3=$(head -n "$(random "${LEN}")" "${WORDLIST}" | tail -n 1 | awk '{ print $2 }')

echo "${RAND1}-${RAND2}-${RAND3}"