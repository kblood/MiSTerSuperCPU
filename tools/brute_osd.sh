#!/bin/bash
# Brute-force find the OSD file load menu item position
for downs in 0 1 2 3 4 5 6; do
    echo "load_core /media/fat/_Test/C64.rbf" > /dev/MiSTer_cmd
    sleep 4
    python3 /tmp/osd_load.py $downs 0
    sleep 3
    echo "screenshot" > /dev/MiSTer_cmd
    sleep 2
    LATEST=$(ls -t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1)
    NAME=$(basename "$LATEST" 2>/dev/null)
    echo "downs=$downs -> $NAME"
done
