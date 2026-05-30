#!/usr/bin/env bash
LOG=~/qwen-installer-logs/safe-mode-gpu.csv
mkdir -p ~/qwen-installer-logs
echo "ts_utc,gpu_temp_c,vram_used_mib" > "$LOG"
end=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$end" ]; do
  ts=$(date -u +%FT%TZ)
  data=$(nvidia-smi --query-gpu=temperature.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
  echo "$ts,$data" | tee -a "$LOG"
  sleep 5
done
