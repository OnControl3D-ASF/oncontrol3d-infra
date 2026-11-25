#!/usr/bin/env bash
# Prints the HTTP status of a clinical endpoint every 2 s, to show there is no downtime during a rollout or a
# rollback (report section 4.2). Without a token clinical answers 401: 401 = clinical up, 502/503 = down.
#
# Usage: perf/watch-availability.sh [url]    (Ctrl+C to stop)
URL="${1:-https://oc3d-asf-dev.brazilsouth.cloudapp.azure.com/api/dashboard/doctor/1/stats}"
while true; do
  code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "$URL")
  case "$code" in
    401) state="clinical UP" ;;
    502|503|504|000) state="DOWN" ;;
    *) state="unexpected" ;;
  esac
  echo "$(date +%T) $code $state"
  sleep 2
done
