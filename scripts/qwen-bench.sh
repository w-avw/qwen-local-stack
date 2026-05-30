#!/usr/bin/env bash
# Single benchmark request; prints tps and VRAM peak.
# Uses /no_think to skip the reasoning trace so we measure pure generation speed.
set -e

PROMPT='/no_think Write a 600-word explanation of how flash attention reduces memory for transformer attention. Be technical and specific.'
PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({\"model\":\"qwen3.6-35b\",\"messages\":[{\"role\":\"user\",\"content\":sys.argv[1]}],\"max_tokens\":800,\"stream\":False}))" "$PROMPT")

# Sample VRAM during the call (background).
VRAMLOG=$(mktemp)
( for i in $(seq 1 90); do nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits >> "$VRAMLOG"; sleep 1; done ) &
SAMPLER=$!

RESP=$(curl -s -m 240 http://localhost:8001/v1/chat/completions -H 'Content-Type: application/json' -d "$PAYLOAD")

kill $SAMPLER 2>/dev/null || true
wait $SAMPLER 2>/dev/null || true

echo "$RESP" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
t=r.get('timings',{})
u=r.get('usage',{})
ct=u.get('completion_tokens',0)
ms=t.get('predicted_ms',0) or 1
tps=ct*1000.0/ms
print(f'completion_tokens={ct}')
print(f'predicted_ms={ms:.1f}')
print(f'prompt_ms={t.get(\"prompt_ms\",0):.1f}')
print(f'tps={tps:.2f}')
print(f'finish={r[\"choices\"][0].get(\"finish_reason\")}')
"
echo "vram_peak_mib=$(sort -n "$VRAMLOG" | tail -1)"
rm -f "$VRAMLOG"
