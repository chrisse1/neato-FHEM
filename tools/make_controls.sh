#!/bin/sh
# Regenerates controls_neatolocal.txt, the index FHEM's update mechanism reads.
#
# One line per module: UPD <timestamp> <bytes> <path>. FHEM compares the
# timestamp and size against what it has installed, so the timestamp has to
# move whenever a file changes -- hence the current UTC time rather than the
# file's mtime, which a fresh clone would reset anyway.
#
# Normally CI does this on every push to main that touches FHEM/. Run it by
# hand if you want the file up to date in your working copy.
set -e
cd "$(dirname "$0")/.."

stamp=$(date -u '+%Y-%m-%d_%H:%M:%S')

# The module itself and the libraries beside it. FHEM's update creates the
# subdirectory, the same way it does for every other module that ships one --
# without the lib line the plan would simply be missing after "update add".
: > controls_neatolocal.txt
for f in FHEM/*.pm FHEM/lib/*.pm; do
    [ -e "$f" ] || continue
    printf 'UPD %s %s %s\n' "$stamp" "$(wc -c < "$f" | tr -d ' ')" "$f" \
        >> controls_neatolocal.txt
done
cat controls_neatolocal.txt
