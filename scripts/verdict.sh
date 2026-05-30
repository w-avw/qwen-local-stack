#!/usr/bin/env bash
GPU=~/qwen-installer-logs/safe-mode-gpu.csv
RAM=~/qwen-installer-logs/safe-mode-ram.csv

echo "=== Sample counts ==="
echo "gpu_lines=$(wc -l < "$GPU")"
echo "ram_lines=$(wc -l < "$RAM")"

echo "=== GPU temp stats (degC) ==="
awk -F, 'NR>1{print $2}' "$GPU" | sort -n > /tmp/temps.txt
N=$(wc -l < /tmp/temps.txt)
P95_LINE=$(( N * 95 / 100 ))
[ $P95_LINE -lt 1 ] && P95_LINE=1
echo "n=$N min=$(head -1 /tmp/temps.txt) max=$(tail -1 /tmp/temps.txt) p95=$(sed -n "${P95_LINE}p" /tmp/temps.txt)"

echo "=== VRAM stats (MiB) ==="
awk -F, 'NR>1{print $3}' "$GPU" | sort -n > /tmp/vram.txt
echo "min=$(head -1 /tmp/vram.txt) max=$(tail -1 /tmp/vram.txt)"

echo "=== Available RAM stats (MiB) ==="
awk -F, 'NR>1{print $4}' "$RAM" | sort -n > /tmp/ram.txt
echo "min=$(head -1 /tmp/ram.txt) max=$(tail -1 /tmp/ram.txt)"
