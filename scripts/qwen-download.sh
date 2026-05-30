#!/usr/bin/env bash
set -euo pipefail
cd ~/models/qwen36
mkdir -p ~/qwen-installer-logs
exec ~/.local/bin/hf download unsloth/Qwen3.6-35B-A3B-GGUF   --local-dir .   --include *UD-Q4_K_XL*   --include *mmproj-F16*
