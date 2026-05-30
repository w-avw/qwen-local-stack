#!/usr/bin/env bash
# Wait for /health=ok up to 4 min
for i in $(seq 1 48); do
  out=$(curl -s -m 4 http://localhost:8001/health 2>/dev/null || true)
  if echo "$out" | grep -q '"status":"ok"'; then
    echo "ready_after=${i}x5s"
    exit 0
  fi
  sleep 5
done
echo "NOT_READY"
docker logs --tail 80 qwen36-server || true
exit 1
