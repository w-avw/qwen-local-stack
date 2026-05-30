#!/usr/bin/env bash
LOG=~/qwen-installer-logs/safe-mode-gen.log
mkdir -p ~/qwen-installer-logs
: > "$LOG"
PROMPT='Write a detailed 800-word explanation of how mixture-of-experts language models route tokens to experts. Include the role of the gating function, top-k selection, and load balancing.'
PAYLOAD=$(printf '{"model":"qwen3.6-35b","messages":[{"role":"user","content":%s}],"max_tokens":1024,"stream":false}' "$(printf '%s' "$PROMPT" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read()))")")
for i in 1 2 3 4 5 6; do
  ts=$(date -u +%FT%TZ)
  echo "[$ts] gen iter $i start" | tee -a "$LOG"
  resp=$(curl -s -m 240 http://localhost:8001/v1/chat/completions -H 'Content-Type: application/json' -d "$PAYLOAD" || true)
  words=$(printf '%s' "$resp" | python3 -c "import sys,json;
try:
  d=json.loads(sys.stdin.read());
  print(len(d['choices'][0]['message']['content'].split()))
except Exception as e:
  print('ERR',e)" 2>/dev/null)
  echo "[$ts] iter $i words=$words" | tee -a "$LOG"
  sleep 5
done
echo "GEN_DONE" | tee -a "$LOG"
