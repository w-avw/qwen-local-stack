#!/usr/bin/env bash
set -euo pipefail

docker stop qwen36-server 2>/dev/null || true
docker rm   qwen36-server 2>/dev/null || true

docker run -d --name qwen36-server   --gpus all   --cap-add IPC_LOCK   --ulimit memlock=-1:-1   --restart unless-stopped   -p 127.0.0.1:8001:8001   -v /home/qwen/models/qwen36:/models:ro   ghcr.io/ggml-org/llama.cpp:server-cuda   --model /models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf   --alias qwen3.6-35b   --host 0.0.0.0 --port 8001   --jinja   -ngl 50   --n-cpu-moe 40   -fa on   -ctk q8_0 -ctv q8_0   -c 16384   --no-mmap   --mlock   -t 8 -tb 16   -b 2048 -ub 512   --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0   --presence-penalty 1.5
