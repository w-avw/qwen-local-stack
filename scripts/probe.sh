#!/usr/bin/env bash
curl -s -m 30 http://localhost:8001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-35b","messages":[{"role":"user","content":"Say hi in one word."}],"max_tokens":10,"stream":false}'
echo
