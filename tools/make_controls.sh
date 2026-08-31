#!/bin/sh
# Regenerates controls_neatolocal.txt for the FHEM update mechanism.
# Run after every change to a file below FHEM/ and commit the result.
set -e
cd "$(dirname "$0")/.."
: > controls_neatolocal.txt
for f in FHEM/*.pm; do
    printf 'UPD %s %s %s\n' \
        "$(date -u -r "$f" '+%Y-%m-%d_%H:%M:%S')" \
        "$(wc -c < "$f" | tr -d ' ')" \
        "$f" >> controls_neatolocal.txt
done
cat controls_neatolocal.txt
