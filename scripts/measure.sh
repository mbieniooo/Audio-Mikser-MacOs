#!/bin/bash
# Samples the running Mikser process. Usage: scripts/measure.sh <seconds> [interval=2] [label]
# Prints CSV (t_s,cpu_pct,rss_mb) and a summary; the strict number is the CPU-time delta over the window.
set -euo pipefail
cd "$(dirname "$0")/.."

SECONDS_TOTAL="${1:?usage: measure.sh <seconds> [interval] [label]}"
INTERVAL="${2:-2}"
LABEL="${3:-$(date +%Y%m%d-%H%M%S)}"
PID="$(pgrep -x Mikser | head -1 || true)"
[[ -n "$PID" ]] || { echo "Mikser is not running"; exit 1; }

mkdir -p build
CSV="build/measure-$LABEL.csv"

cputime_seconds() {
  # ps cputime formats: mm:ss.cs | hh:mm:ss.cs | dd-hh:mm:ss.cs
  ps -o cputime= -p "$1" | awk '{
    t=$1; days=0
    if (index(t,"-")>0) { split(t,a,"-"); days=a[1]; t=a[2] }
    n=split(t,p,":")
    if (n==3) s=p[1]*3600+p[2]*60+p[3]; else if (n==2) s=p[1]*60+p[2]; else s=p[1]
    printf "%.2f", days*86400+s }'
}

START_CPU="$(cputime_seconds "$PID")"
START_T="$(date +%s)"
echo "t_s,cpu_pct,rss_mb" | tee "$CSV"
ELAPSED=0
while (( ELAPSED < SECONDS_TOTAL )); do
  sleep "$INTERVAL"
  ELAPSED=$(( $(date +%s) - START_T ))
  read -r CPU RSS < <(ps -o %cpu=,rss= -p "$PID" | awk '{print $1, $2}') || { echo "Mikser exited"; exit 1; }
  RSS_MB="$(awk -v r="$RSS" 'BEGIN{printf "%.1f", r/1024}')"
  echo "$ELAPSED,$CPU,$RSS_MB" | tee -a "$CSV"
done
END_CPU="$(cputime_seconds "$PID")"
WALL=$(( $(date +%s) - START_T ))

awk -F, -v sc="$START_CPU" -v ec="$END_CPU" -v wall="$WALL" 'NR>1 {
  n++; if ($2>maxc) maxc=$2; sumc+=$2; if ($3>maxr) maxr=$3 }
  END { strict=(wall>0)?(ec-sc)/wall*100:0
        printf "summary: samples=%d max_cpu_pct=%.1f mean_cpu_pct=%.2f max_rss_mb=%.1f strict_cpu_pct=%.3f (cputime delta %.2fs over %ds)\n",
               n, maxc, (n>0?sumc/n:0), maxr, strict, ec-sc, wall }' "$CSV"
