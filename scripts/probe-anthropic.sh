#!/usr/bin/env bash
curl -s -m 60 http://localhost:8001/v1/messages \
  -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"qwen3.6-35b","max_tokens":50,"messages":[{"role":"user","content":"/no_think Reply with the single word: READY"}]}'
echo
