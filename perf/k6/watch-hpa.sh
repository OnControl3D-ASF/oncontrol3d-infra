#!/usr/bin/env bash
# Records the clinical HPA every INTERVAL seconds while a k6 run is going (report section 4.4.3: autoscaling
# behaviour). Writes a CSV for the report chart and echoes each row so the terminal can be captured too.
#
# Usage: perf/k6/watch-hpa.sh [deployment] [interval-seconds]    (Ctrl+C to stop)
set -euo pipefail

DEPLOY="${1:-clinical}"
INTERVAL="${2:-10}"
NAMESPACE="${NAMESPACE:-oncontrol}"
OUT_DIR="$(dirname "$0")/results"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/hpa-${DEPLOY}-$(date +%Y%m%dT%H%M%S).csv"

echo "time,cpu_percent,target_percent,current_replicas,desired_replicas,ready_pods" | tee "$OUT"
while true; do
  # currentMetrics is empty until metrics-server has a sample: print "-" instead of failing.
  row=$(kubectl -n "$NAMESPACE" get hpa "$DEPLOY" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}{","}{.spec.metrics[0].resource.target.averageUtilization}{","}{.status.currentReplicas}{","}{.status.desiredReplicas}')
  ready=$(kubectl -n "$NAMESPACE" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}')
  IFS=, read -r cpu target current desired <<<"$row"
  echo "$(date +%H:%M:%S),${cpu:--},${target:--},${current:--},${desired:--},${ready:-0}" | tee -a "$OUT"
  sleep "$INTERVAL"
done
