#!/usr/bin/env bash
LOG=~/qwen-installer-logs/safe-mode-ram.csv
mkdir -p ~/qwen-installer-logs
echo "ts_utc,used_mib,free_mib,available_mib" > "$LOG"
end=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$end" ]; do
  ts=$(date -u +%FT%TZ)
  vals=$(free -m | awk '/^Mem:/{print $3","$4","$7}')
  echo "$ts,$vals" | tee -a "$LOG"
  sleep 10
done
