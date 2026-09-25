#!/bin/sh

. /lib/functions.sh

config_load gmediarender
config_get_bool cleanup  main log_cleanup  1
[ "$cleanup" -eq 1 ] || exit 0

config_get logfile  main logfile    "/var/log/gmediarender.log"
config_get limit_mb main log_limit_mb 5

[ -f "$logfile" ] || exit 0

limit_bytes=$((limit_mb * 1024 * 1024))
current=$(stat -c %s "$logfile" 2>/dev/null || echo 0)

if [ "$current" -gt "$limit_bytes" ]; then
    truncate -s 0 "$logfile"
fi

exit 0
