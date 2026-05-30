# Qwen Local Stack

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Model](https://img.shields.io/badge/model-Qwen3.6--35B--A3B-blue)
![Quant](https://img.shields.io/badge/quant-UD--Q4__K__XL-blue)
![Engine](https://img.shields.io/badge/engine-llama.cpp-orange)
![Runtime](https://img.shields.io/badge/runtime-WSL2_+_Docker-2496ED)
![GPU](https://img.shields.io/badge/GPU-RTX_3050_6GB-green)

> **Local LLM agentic coding stack** — run Anthropic's Claude Code CLI against a self-hosted Qwen3.6-35B-A3B (35B MoE) model on consumer hardware. Tested at ~23 tok/s on an RTX 3050 6 GB + Ryzen 7 8700F + 32 GB DDR5.

---

## Quickstart

```bash
# Inside WSL2 Ubuntu-24.04 with Docker + NVIDIA Container Toolkit
git clone https://github.com/<you>/qwen-local-stack.git
cd qwen-local-stack

# 1. Download GGUF weights (~21 GB) from HuggingFace
mkdir -p ~/models/qwen36
cp scripts/qwen-download.sh ~/
bash ~/qwen-download.sh

# 2. Install claude-code-router + start its proxy on :3456
npm i -g @musistudio/claude-code-router
mkdir -p ~/.claude-code-router
cp config/ccr-config.json ~/.claude-code-router/config.json
ccr start &

# 3. Boot the llama.cpp server in Docker
bash scripts/qwen-start-safe.sh
bash scripts/qwen-wait.sh

# 4. Smoke test
bash scripts/probe.sh
bash scripts/probe-anthropic.sh

# 5. Wire Claude Code on Windows host
#    Set ANTHROPIC_BASE_URL=http://127.0.0.1:3456 in %USERPROFILE%\.claude\settings.json
#    (template: config/claude-settings.template.json)
```

## Repo layout

```
qwen-local-stack/
├── README.md                              ← this file (auto-generated from docs/*.docx)
├── LICENSE                                ← MIT
├── .gitignore
├── scripts/
│   ├── qwen-download.sh                   ← pull GGUF from HF
│   ├── qwen-start-safe.sh                 ← docker run llama.cpp (safe defaults)
│   ├── qwen-restart.sh                    ← parameterized restart (NCPUMOE NGL CTX)
│   ├── qwen-bench.sh                      ← tps + VRAM-peak measurement
│   ├── qwen-wait.sh                       ← poll /health until ready
│   ├── watch-ram.sh / watch-gpu.sh        ← 10-min telemetry loggers
│   ├── verdict.sh                         ← summarize telemetry CSVs
│   ├── generator.sh                       ← 6-iter sustained load test
│   ├── probe.sh                           ← curl OpenAI-format sanity check
│   └── probe-anthropic.sh                 ← curl Anthropic-format sanity check
├── config/
│   ├── wslconfig                          ← .wslconfig (26 GB / 8 cores / 8 GB swap)
│   ├── ccr-config.json                    ← claude-code-router provider + router
│   └── claude-settings.template.json      ← minimal Claude Code wiring
└── docs/
    └── Local-LLM-Stack-Implementation-Report.docx
```

## Requirements

| Component | Minimum |
|---|---|
| GPU | NVIDIA, 6 GB VRAM (Ampere or newer) |
| RAM | 32 GB DDR5 (26 GB allocated to WSL2 + 6 GB host headroom) |
| CPU | 8 cores / 16 threads |
| Disk | 30 GB free (20.82 GB model + container layers + KV cache) |
| OS | Windows 11 + WSL2 + Ubuntu 24.04 + Docker Desktop + NVIDIA Container Toolkit |

## Performance (measured)

| Metric | Value |
|---|---|
| Generation throughput | ~23 tok/s |
| End-user response latency | 5–15 s/turn (post-cache warmup) |
| VRAM peak | 5,354 MiB / 6,144 MiB |
| GPU temp peak | 71 °C |
| Context window | 16 K (32 K possible with retune) |

---

> **The rest of this document is the full implementation report**, including architecture deep-dive, OODA-framed history, troubleshooting catalog, configuration reference, and known limitations. Read it linearly if you intend to reproduce the stack from scratch.

---
**Local LLM Agentic Coding Stack**

*Implementation, OODA-Framed Challenges, and Operational State*

Running Qwen3.6-35B-A3B with Claude Code on Consumer Hardware

(NVIDIA RTX 3050 6 GB Â· AMD Ryzen 7 8700F Â· 32 GB DDR5)

Implementation Report

May 2026

**Table of Contents**

**1. Executive Summary**

This document describes the design, implementation, and operational characteristics of a fully local AI-assisted coding stack running on consumer hardware not generally considered viable for 35-billion-parameter language models. The stack pairs Anthropic's Claude Code agentic coding client with a locally hosted, hand-tuned llama.cpp inference server running the Qwen3.6-35B-A3B mixture-of-experts model, mediated by a format-translation proxy that bridges Claude Code's Anthropic-native tool-call protocol with llama.cpp's OpenAI-compatible endpoint.

The hardware target was deliberately constrained: a single NVIDIA RTX 3050 with 6 GB of VRAM, an 8-core AMD Ryzen 8700F CPU, 32 GB DDR5 system memory, and a 477 GB NVMe SSD running Windows 11 Professional. This is below the comfortable threshold for hosting models of this scale, and the project served partly as an empirical test of whether a hand-tuned stack could overcome the floor.

The final operational state is a working agentic coding environment delivering approximately 23 tokens per second of generation throughput from the model engine itself, with end-user response latency of 5â€“15 seconds per turn after KV cache warmup. The full toolchain â€” file editing, shell execution, repository navigation, multi-step agent loops â€” is functional. Total VRAM utilization peaks at 5,354 MiB out of 6,144 available, leaving 790 MiB of headroom for context expansion. GPU thermal load peaks at 71 Â°C under sustained inference, well within manufacturer specifications.

**1.1 Reading This Document**

Section 2 describes the runtime architecture and component responsibilities. Section 3 expands each component layer. Section 4 narrates the implementation journey through six OODA-framed decision loops, capturing both the technical pivots and the reasoning behind them. Section 5 catalogs every significant technical challenge encountered and the resolution applied. Section 6 analyzes performance with measured numbers. Sections 7â€“9 cover configuration reference, operational procedures, and known limitations.

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p><strong>On the OODA framing</strong></p>
<p>The document uses Colonel John Boyd's OODA loop (Observe â†’ Orient â†’ Decide â†’ Act) as a narrative device for the implementation history. This is not academic gloss. Each architectural pivot in the project corresponds to a complete OODA cycle where new observations forced orientation changes that invalidated prior decisions. The framing is honest about how engineering judgment evolved as evidence accumulated, rather than presenting the final architecture as if it were planned from the outset.</p></td>
</tr>
</tbody>
</table>

**2. System Architecture**

**2.1 Runtime Stack Overview**

The stack runs across two separate operating system contexts on a single physical machine: a Windows 11 host where the user interacts with the developer tool, and a Linux virtual machine (Ubuntu 24.04 inside WSL2) where the model server, format-translation proxy, and container runtime live. The boundary between these contexts is crossed via localhost network ports, with WSL2's localhost-forwarding feature making services in the Linux VM addressable from the Windows side without any explicit port forwarding configuration.

The full path of a single request from user keystroke to model response traverses six layers, each with a distinct responsibility. The diagram below illustrates the call chain.

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p>â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”</p>
<p>â”‚ Windows 11 Host â”‚</p>
<p>â”‚ â”‚</p>
<p>â”‚ â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â” â”‚</p>
<p>â”‚ â”‚ PowerShell Terminal â”‚ â† user types: claude â”‚</p>
<p>â”‚ â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜ â”‚</p>
<p>â”‚ â”‚ spawns â”‚</p>
<p>â”‚ â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â–¼â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â” â”‚</p>
<p>â”‚ â”‚ Claude Code (Node.js) â”‚ reads %USERPROFILE%\.claude\ â”‚</p>
<p>â”‚ â”‚ v2.1.129 â”‚ settings.json â”‚</p>
<p>â”‚ â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜ â”‚</p>
<p>â”‚ â”‚ HTTP POST /v1/messages â”‚</p>
<p>â”‚ â”‚ (Anthropic Messages API format) â”‚</p>
<p>â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¼â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜</p>
<p>â–¼ 127.0.0.1:3456</p>
<p>â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”</p>
<p>â”‚ WSL2 â€” Ubuntu 24.04 Linux VM â”‚</p>
<p>â”‚ â”‚</p>
<p>â”‚ â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â” â”‚</p>
<p>â”‚ â”‚ claude-code-router (ccr) â”‚ â”‚</p>
<p>â”‚ â”‚ v1.0.51 Â· Node.js process â”‚ â”‚</p>
<p>â”‚ â”‚ â”‚ â”‚</p>
<p>â”‚ â”‚ Translates: â”‚ â”‚</p>
<p>â”‚ â”‚ Anthropic /v1/messages â”‚ â”‚</p>
<p>â”‚ â”‚ â†’ OpenAI /v1/chat/... â”‚ â”‚</p>
<p>â”‚ â”‚ OpenAI tool_calls â”‚ â”‚</p>
<p>â”‚ â”‚ â†’ Anthropic tool_use â”‚ â”‚</p>
<p>â”‚ â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜ â”‚</p>
<p>â”‚ â”‚ HTTP POST /v1/chat/completions â”‚</p>
<p>â”‚ â”‚ (OpenAI Chat Completions format) â”‚</p>
<p>â”‚ â–¼ 127.0.0.1:8001 â”‚</p>
<p>â”‚ â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â” â”‚</p>
<p>â”‚ â”‚ Docker Container â”‚ â”‚</p>
<p>â”‚ â”‚ qwen36-server â”‚ â”‚</p>
<p>â”‚ â”‚ â”‚ â”‚</p>
<p>â”‚ â”‚ ghcr.io/ggml-org/ â”‚ â”‚</p>
<p>â”‚ â”‚ llama.cpp:server-cuda â”‚ â”‚</p>
<p>â”‚ â”‚ â”‚ â”‚</p>
<p>â”‚ â”‚ â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â” â”‚ â”‚</p>
<p>â”‚ â”‚ â”‚ llama-server process â”‚ â”‚ â”‚</p>
<p>â”‚ â”‚ â”‚ - 40-layer MoE model â”‚ â”‚ â”‚</p>
<p>â”‚ â”‚ â”‚ - dense parts on GPU â”‚ â”‚ â—„â”€â”€ 60 layers requested â”‚</p>
<p>â”‚ â”‚ â”‚ - experts on CPU RAM â”‚ â”‚ â—„â”€â”€ 38 layers' MoE on CPUâ”‚</p>
<p>â”‚ â”‚ â”‚ - 64 K context window â”‚ â”‚ â”‚</p>
<p>â”‚ â”‚ â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜ â”‚ â”‚</p>
<p>â”‚ â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¼â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜ â”‚</p>
<p>â”‚ â”‚ CUDA â”‚</p>
<p>â”‚ â–¼ â”‚</p>
<p>â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¼â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜</p>
<p>â”‚ WSL GPU passthrough</p>
<p>â–¼</p>
<p>â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”</p>
<p>â”‚ Hardware â”‚</p>
<p>â”‚ â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â” â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â” â”‚</p>
<p>â”‚ â”‚ RTX 3050 6 GB â”‚ â”‚ Ryzen 7 8700F â”‚ 32 GB DDR5â”‚ â”‚</p>
<p>â”‚ â”‚ (Ampere) â”‚ â”‚ 8C / 16T â”‚ expert â”‚ â”‚</p>
<p>â”‚ â”‚ attention + â”‚ â”‚ routes experts â”‚ storage â”‚ â”‚</p>
<p>â”‚ â”‚ 4 Ã— MoE layers â”‚ â”‚ per-token â”‚ â”‚ â”‚</p>
<p>â”‚ â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜ â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”´â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜ â”‚</p>
<p>â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜</p></td>
</tr>
</tbody>
</table>

**2.2 Component Responsibilities**

Each layer has a narrow, well-defined responsibility. The decoupling is what made the implementation tractable: when one layer failed, only that layer needed swapping.

| **Layer** | **Component** | **Purpose** |
|----|----|----|
| 1 | **Claude Code (Windows)** | Agentic coding orchestrator. Reads project files, plans actions, formats prompts, parses tool-call responses, executes returned tool invocations on the host, and feeds results back to the model. Speaks Anthropic Messages API format exclusively. |
| 2 | **WSL2 + .wslconfig** | Provides a Linux kernel and userland on Windows. The .wslconfig caps the Linux VM at 26 GB of memory and 8 CPU cores, leaving headroom for the host. localhostForwarding=true makes Linux-side ports reachable as 127.0.0.1 from Windows. |
| 3 | **Docker Desktop + WSL Integration** | Provides container runtime inside the WSL distro. The NVIDIA Container Toolkit (auto-installed) handles GPU passthrough into containers. |
| 4 | **claude-code-router (ccr)** | Format-translation proxy. Listens on port 3456 in Anthropic Messages format, forwards to llama.cpp on port 8001 in OpenAI format. Critical for tool-call compatibility â€” Qwen3.6's native tool-call format does not translate cleanly through llama.cpp's built-in Anthropic shim. |
| 5 | **llama-server in container** | C++ inference engine with CUDA support. Loads the GGUF model file, manages KV cache, performs token-by-token sampling, exposes both OpenAI and Anthropic-compatible HTTP endpoints. Executes the per-token MoE expert routing logic. |
| 6 | **Qwen3.6-35B-A3B GGUF** | The model itself. 40-layer mixture-of-experts: 256 routed experts plus 1 shared expert per layer, 8 routed experts active per token. 35 B total parameters, 3 B active per token. Quantized to UD-Q4_K_XL by Unsloth (~5.0 effective bits per parameter). |

**2.3 Request Lifecycle**

A single user message in Claude Code triggers the following sequence of events. Understanding this lifecycle clarifies which components affect latency and where failures most commonly originate.

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p>USER TYPES MESSAGE in Claude Code prompt</p>
<p>â”‚</p>
<p>â–¼</p>
<p>Claude Code constructs an Anthropic-format request:</p>
<p>{</p>
<p>"model": "qwen3.6-35b",</p>
<p>"messages": [...], â† conversation history</p>
<p>"system": "...", â† Claude Code system prompt</p>
<p>"tools": [...], â† Bash, Read, Edit, Glob, Grep, ...</p>
<p>"max_tokens": 8192 â† from settings.json</p>
<p>}</p>
<p>â”‚</p>
<p>â–¼ POST http://127.0.0.1:3456/v1/messages</p>
<p>ccr receives, transforms to OpenAI format:</p>
<p>{</p>
<p>"model": "qwen3.6-35b",</p>
<p>"messages": [...], â† system rolled into messages</p>
<p>"tools": [{ â† Anthropic tool â†’ OpenAI function</p>
<p>"type": "function",</p>
<p>"function": { ... }</p>
<p>}],</p>
<p>"stream": false â† (or true for streaming)</p>
<p>}</p>
<p>â”‚</p>
<p>â–¼ POST http://127.0.0.1:8001/v1/chat/completions</p>
<p>llama-server processes prompt:</p>
<p>1. Tokenize prompt (~ 39 K tokens incl. system + tools + history)</p>
<p>2. Look up KV cache prefix match (--cache-reuse 256)</p>
<p>â–¶ HIT: skip prompt processing for cached tokens</p>
<p>â–¶ MISS: process all tokens</p>
<p>3. For each new token:</p>
<p>a. Compute attention over context</p>
<p>b. Run gating fn â†’ pick top-8 experts of 256</p>
<p>c. Fetch experts from CPU RAM (PCIe transfer)</p>
<p>d. Run experts on GPU, reduce, project to vocab</p>
<p>e. Sample next token (temp=0.7 top_p=0.8 ...)</p>
<p>4. Stop on EOS / stop sequence / max_tokens</p>
<p>â”‚</p>
<p>â–¼ OpenAI-format response (with tool_calls if present)</p>
<p>ccr transforms back to Anthropic format:</p>
<p>OpenAI tool_calls â†’ Anthropic tool_use blocks</p>
<p>â”‚</p>
<p>â–¼ Anthropic-format response</p>
<p>Claude Code parses response:</p>
<p>- text content â†’ printed to terminal</p>
<p>- tool_use blocks â†’ execute tool on Windows host</p>
<p>(e.g. PowerShell, file system ops)</p>
<p>- results â†’ next message in conversation</p>
<p>â”‚</p>
<p>â–¼</p>
<p>Loop until stop_reason = end_turn</p></td>
</tr>
</tbody>
</table>

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p><strong>Where time goes in a typical turn</strong></p>
<p>Network hops between layers contribute under 10 ms total. The dominant costs are prompt processing (~600 t/s on cold cache, instant on warm cache thanks to --cache-reuse) and token generation (~23 t/s). For a typical 200-token reply: ~9 s generation + 0â€“2 s for any new prompt tokens that miss the cache. Cold-start first turn includes a one-time ~30â€“60 s prompt-processing penalty for the ~39 K tokens of system prompt, after which subsequent turns reuse most of that work via prefix caching.</p></td>
</tr>
</tbody>
</table>

**3. Component Deep-Dive**

**3.1 Windows Host Layer**

Windows 11 Professional serves as the user-facing operating system. The user opens PowerShell, navigates to a project directory, and runs the claude command. Claude Code is installed as a single-binary native Node.js application at C:\Users\USER\\local\bin\claude.exe (installed via PowerShell installer script, with the directory added to the user's PATH). All keyboard input, terminal rendering, and tool execution (PowerShell command spawning, file reads/writes) happen in the Windows process space. No model code runs on Windows.

Windows reads two configuration files relevant to this stack:

- %USERPROFILE%\\claude\settings.json â€” global Claude Code configuration. Contains the env block that points ANTHROPIC_BASE_URL at the router and disables the cache-busting attribution header.

- %USERPROFILE%\\wslconfig â€” global WSL2 tuning. Caps the Linux VM at 26 GB RAM and 8 processor cores; enables localhost forwarding.

**3.2 WSL2 Subsystem**

WSL2 (Windows Subsystem for Linux, version 2) runs a real Linux kernel inside a lightweight Hyper-V virtual machine. The Ubuntu 24.04 distribution sits in a single virtual disk file at C:\Users\USER\AppData\Local\Packages\CanonicalGroupLimited.Ubuntu24.04LTS\_\*\LocalState\ext4.vhdx. This VHDX expands dynamically up to a virtual ceiling of 1 TB but only consumes as much physical disk space as actually written. After installation, this file holds approximately 25 GB: roughly 4 GB for Ubuntu base packages, ~21 GB for the model GGUF, and minor overhead.

WSL2's GPU passthrough is the critical capability that makes this entire stack possible. NVIDIA's Windows driver exposes the physical GPU through DirectX virtualization to the WSL2 kernel, and a thin Linux-side userland (libcuda.so.1) is auto-installed by WSL when an NVIDIA card is detected. The result is that nvidia-smi run inside Ubuntu shows the same RTX 3050 visible on Windows, with the same driver version, with full CUDA support.

The .wslconfig settings deserve attention. Without the memory cap, WSL2 by default may consume up to 50% of host RAM, which on a 32 GB system could leave Windows fighting for memory once the model file is mlock'd. The cap of 26 GB leaves Windows a guaranteed 6 GB. The processors=8 setting matches the Ryzen 8700F's physical core count; over-allocating logical cores (16) to WSL did not improve inference performance in testing because the model is memory-bound rather than compute-bound during MoE expert routing.

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p># /mnt/c/Users/USER/.wslconfig</p>
<p>[wsl2]</p>
<p>memory=26GB # leaves 6 GB for Windows host</p>
<p>processors=8 # matches physical core count</p>
<p>swap=8GB # Linux swap inside the VHDX</p>
<p>localhostForwarding=true # binds WSL ports as 127.0.0.1 on Windows</p></td>
</tr>
</tbody>
</table>

**3.3 Docker Desktop + WSL Integration**

Docker Desktop runs as a Windows application but executes containers inside a dedicated WSL2 distribution called docker-desktop. When WSL Integration is enabled for a user distribution (Ubuntu-24.04), Docker exposes the docker CLI binary and Unix socket inside that distribution, so commands like docker ps and docker run executed from Ubuntu actually communicate with the Docker daemon running in docker-desktop.

The NVIDIA Container Toolkit, bundled with recent Docker Desktop versions, handles the additional layer required to expose host GPUs to containers. The --gpus all flag on docker run causes the toolkit to mount /dev/dxg (the WSL GPU device), the NVIDIA driver libraries, and CUDA tools into the container, making the GPU accessible to processes inside it.

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p><strong>Why containerize llama.cpp?</strong></p>
<p>Running llama.cpp directly in Ubuntu would have eliminated one layer. It was containerized for three reasons: (1) the upstream-built ghcr.io/ggml-org/llama.cpp:server-cuda image is signed, frequently updated, and pre-compiled with the right CUDA architecture flags for Ampere (RTX 3050's compute capability 8.6); (2) the read-only model mount (-v ~/models/qwen36:/models:ro) provides isolation â€” the container literally cannot modify the model file even if compromised; (3) container --restart unless-stopped provides automatic recovery across WSL restarts.</p></td>
</tr>
</tbody>
</table>

**3.4 llama.cpp Inference Server**

llama-server is a C++ HTTP server that wraps llama.cpp's inference engine. It loads a GGUF (GPT-Generated Unified Format) model file at startup, maintains an in-memory KV cache, and exposes a small set of HTTP endpoints. Two endpoints matter for this stack: /v1/chat/completions (OpenAI Chat Completions API) and /v1/messages (Anthropic Messages API, added in PR \#17570 in early 2026). Both endpoints are served from the same model state â€” the choice is purely about wire format compatibility with the calling client.

**3.4.1 The Critical Flags**

The Docker run command launching llama-server contains 27 explicit flags. Each was chosen deliberately. The most consequential ones, grouped by effect:

***Memory layout***

| **Flag** | **Value** | **Effect** |
|----|----|----|
| -ngl | 60 | Number of layers to attempt to offload to GPU. The model has 40 layers, so 60 means "as many as fit." |
| --n-cpu-moe | 38 | Of those 40 layers, the routed-expert weights of 38 of them stay on CPU RAM. Only the dense parts (attention, layernorm, the 1 shared expert) of all 40 layers go to GPU, plus the routed experts of just 2 layers. This is the surgical split that makes the 35 B model fit in 6 GB VRAM. |
| --mlock | (flag) | Pin all loaded model bytes in physical RAM. Combined with --cap-add IPC_LOCK and --ulimit memlock=-1:-1 on Docker, prevents the kernel from paging experts back to disk under memory pressure. |
| --no-mmap | (flag) | Read the model file into RAM at startup rather than memory-mapping it lazily. Trades slow startup for predictable steady-state inference. |

***Performance & caching***

| **Flag** | **Value** | **Effect** |
|----|----|----|
| -fa on | (on) | Flash Attention. Significantly faster attention computation, required when using compressed KV cache types. |
| -ctk q8_0 -ctv q8_0 | Q8_0 | KV cache (the model's working memory of the conversation) compressed to 8-bit. Effectively lossless for quality, halves memory vs FP16. |
| -c | 65536 | Maximum context length: 64 K tokens. Limited by VRAM headroom; could go to 128 K with more VRAM. |
| -b / -ub | 4096 / 2048 | Prompt-processing batch sizes. Raised from defaults (2048 / 512) to roughly double cold-start prompt processing throughput. |
| --cache-reuse | 256 | Enables prefix-match KV cache reuse between requests. With Claude Code's largely-stable system prompt, this drops post-warmup turn latency by an order of magnitude. |
| --parallel | 1 | Single concurrent slot. Forces all requests through the same KV cache, maximizing cache hits. Multi-slot was found to fragment cache and prevent reuse. |

***Behavior***

| **Flag** | **Value** | **Effect** |
|----|----|----|
| --jinja | (flag) | Use the Jinja2 chat template embedded in the GGUF metadata. Required for proper tool-use prompting. |
| --chat-template-kwargs | {...false} | Disable Qwen3.6's reasoning trace by default. Reasoning would otherwise add 30â€“60 s of hidden generation per turn â€” unusable for agentic loops. |
| Sampling group | â€” | temp 0.7, top_p 0.8, top_k 20, min_p 0.0, presence_penalty 1.5: the values Alibaba/Unsloth recommend for non-thinking-mode coding tasks. |

**3.4.2 Why MoE Expert Offloading Works**

The Qwen3.6-35B-A3B architecture is the single reason this entire setup is feasible on 6 GB of VRAM. A traditional dense 35 B model has 35 billion parameters that all activate for every token; loading even a Q4-quantized version (~21 GB) requires at least 21 GB of fast memory. A mixture-of-experts model is structured differently: most of the weights live in expert blocks that are gated. For Qwen3.6-35B-A3B, only 8 routed experts (out of 256) plus 1 shared expert activate per token. The remaining 248 experts of each layer are dormant for that token's computation, only consuming memory for storage.

This asymmetry â€” most parameters dormant most of the time â€” means CPU RAM is acceptable rent for sleeping experts. Inference per token requires three steps: (1) the GPU runs attention and the dense parts; (2) the gating network selects which experts are needed; (3) those 8 experts' weights are fetched (from CPU RAM over PCIe to GPU memory) and run; (4) results are reduced and projection completes. The PCIe bus transfer is the new bottleneck, but it is far cheaper than running everything on CPU compute.

The --n-cpu-moe flag exploits this by selectively keeping only the routed-expert weights on CPU, while the always-on dense parts (attention, layernorm, projections) and the always-on shared expert remain on GPU. This is finer granularity than "whole layer on GPU vs CPU" â€” the operative mode in Ollama and most other engines â€” and is what allows ~12 GB of model weights to behave as if they were on a 6 GB card.

**3.5 claude-code-router (ccr)**

ccr is a Node.js application that listens on 127.0.0.1:3456 and acts as a protocol-translating reverse proxy. It accepts requests in Anthropic Messages API format, transforms them into OpenAI Chat Completions API format, forwards them to a configured upstream (in this case llama-server on port 8001), receives the response, transforms it back to Anthropic format, and returns it to the caller.

The transformation is non-trivial in two specific places:

- Tool definitions: Anthropic uses a tools array with input_schema; OpenAI uses a tools array with type: "function" and parameters. ccr maps between these representations bidirectionally.

- Tool calls: When the model returns a tool invocation, OpenAI emits a tool_calls field on a single message; Anthropic emits one or more tool_use blocks within content. ccr re-shapes the response.

The configuration file at ~/.claude-code-router/config.json registers a single provider (llamacpp) pointed at the llama-server's OpenAI endpoint, and configures all four routing slots (default, background, think, longContext) to use that provider. Multi-provider routing is a feature of ccr but unnecessary for single-model setups.

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p>// ~/.claude-code-router/config.json</p>
<p>{</p>
<p>"LOG": false,</p>
<p>"OPENAI_API_KEY": "sk-no-key-required",</p>
<p>"OPENAI_BASE_URL": "",</p>
<p>"OPENAI_MODEL": "",</p>
<p>"Providers": [</p>
<p>{</p>
<p>"name": "llamacpp",</p>
<p>"api_base_url": "http://127.0.0.1:8001/v1/chat/completions",</p>
<p>"api_key": "sk-no-key-required",</p>
<p>"models": ["qwen3.6-35b"],</p>
<p>"transformer": { "use": ["openai"] }</p>
<p>}</p>
<p>],</p>
<p>"Router": {</p>
<p>"default": "llamacpp,qwen3.6-35b",</p>
<p>"background": "llamacpp,qwen3.6-35b",</p>
<p>"think": "llamacpp,qwen3.6-35b",</p>
<p>"longContext": "llamacpp,qwen3.6-35b"</p>
<p>}</p>
<p>}</p></td>
</tr>
</tbody>
</table>

**3.6 Claude Code Client**

Claude Code is the user-facing terminal application. It implements the agent loop: read user input, construct system prompt + tool definitions + conversation history, send to the configured base URL, parse response, execute any returned tool calls (PowerShell commands, file edits, etc.), feed results back into the next turn, repeat until end_turn. Two settings.json keys are critical for local-model operation:

- env.ANTHROPIC_BASE_URL: redirects API calls from Anthropic's cloud to the configured local URL. With an unset or empty ANTHROPIC_API_KEY (and a placeholder ANTHROPIC_AUTH_TOKEN), Claude Code skips its login flow and treats the local endpoint as authenticated.

- claudeCodeAttributionHeader: false (also writable as env CLAUDE_CODE_ATTRIBUTION_HEADER=0): disables a header that Claude Code injects into every request. This header contains a session timestamp that, when present, breaks the prompt prefix exact match required by --cache-reuse, causing every turn to re-process the entire system prompt â€” observed cost: ~3-minute turns instead of ~10 seconds.

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p><strong>The attribution header gotcha</strong></p>
<p>This single configuration line is the difference between a usable local-model setup and an unusable one. Multiple guides and forum posts describe Claude Code with local models as inherently slow, mistaking the cache-busting effect of the attribution header for fundamental local-inference speed. Disabling the header was the second-most-important fix in the entire project, after introducing the format-translating router.</p></td>
</tr>
</tbody>
</table>

**4. Implementation Journey â€” OODA-Framed**

**4.1 The OODA Framework Applied**

Colonel John Boyd's OODA loop â€” Observe, Orient, Decide, Act â€” was originally developed for fighter combat: the pilot who could cycle through these phases faster than the opponent would win. The framework generalizes well to any environment where assumptions are unreliable and feedback is rapid. Infrastructure projects qualify.

This section narrates the implementation through six discrete OODA cycles. Each cycle began with an observation that disconfirmed a prior assumption, forcing a re-orientation, a new decision, and concrete action. The final architecture was not designed up-front; it emerged through six successive refinements as evidence accumulated.

**4.2 Loop 1 â€” Initial Architecture Selection**

| **Phase** | **Content** |
|----|----|
| Observe | Project goals stated: run a 35 B-class agentic-coding model locally on consumer hardware, accessible from Claude Code, without LiteLLM or routing proxies (per user constraints). Available open-weight models: Qwen3.6-35B-A3B (Apache 2.0, 35 B MoE with 3 B active), released April 2026. |
| Orient | Evaluated three engines: (a) llama.cpp with PR \#17570's native Anthropic Messages API shim â€” most direct, least moving parts; (b) Ollama with its own Anthropic shim â€” friendlier but limited control over MoE offloading; (c) vLLM â€” production-grade but designed for â‰¥24 GB VRAM. |
| Decide | Chose llama.cpp with native /v1/messages endpoint. Rationale: maximum control via --n-cpu-moe (the surgical MoE split), explicit support for the Unsloth UD-Q4_K_XL dynamic quant, and a route that satisfied the "no router" constraint. |
| Act | Authored the autonomous installer (CLAUDE.md) targeting llama.cpp Docker container with hand-tuned flags, mlock'd memory, KV cache compression, etc. Phase plan: detect hardware â†’ install WSL2 â†’ install Docker â†’ download model â†’ safe-mode burn-in â†’ tune flags â†’ wire Claude Code â†’ smoke test. |

**4.3 Loop 2 â€” Hardware Reality Check**

| **Phase** | **Content** |
|----|----|
| Observe | Phase 0 hardware detection ran nvidia-smi inside WSL. Output: NVIDIA GeForce RTX 3050, 6144 MiB VRAM (the 6 GB variant, not the 8 GB variant). Driver 591.86, CUDA 13.1. Storage: NVMe SSD 477 GB. WSL not yet installed. |
| Orient | The 6 GB variant has 25% less VRAM bandwidth and 10% fewer CUDA cores than the 8 GB sibling, despite identical model name. Tuning targets shift downward: max comfortable context drops from ~256 K (8 GB plan) to ~64 K (6 GB plan); n_cpu_moe baseline shifts from 32 to 38. |
| Decide | Continue with 6 GB tuning plan. Quant remains UD-Q4_K_XL (effective ~Q5 average), context expectations capped at 64 K. PSU wattage marked as unknown by user, so tuning to be additionally clamped at -ngl â‰¤ 60. |
| Act | Updated install_state.json with measured hardware. Adjusted Phase 5 walk plan to start at higher --n-cpu-moe values. Proceeded with installation. |

**4.4 Loop 3 â€” Disk Space Crisis**

| **Phase** | **Content** |
|----|----|
| Observe | Mid-download of the 21 GB model GGUF, the WSL distribution started returning EIO errors on every command. nvidia-smi failed, getpwnam(qwen) failed 5, file system reads errored. Windows side: C: had only 8 GB free of 477 GB. |
| Orient | Two compounding errors: (1) the runbook's pre-flight disk-space check looked at WSL's internal df, which showed 955 GB available because the VHDX virtual ceiling is 1 TB â€” but the underlying physical disk had no room; (2) the user's Windows install had only 8 GB free at session start, with 189 GB in Downloads, 94 GB in AppData, and 47 GB on Desktop. The download stalled when the VHDX hit the physical disk wall, leaving the WSL VM's filesystem in a partial-write state. |
| Decide | Stop all operations. Run wsl --shutdown to release the stuck VHDX. Have user manually free â‰¥ 50 GB on C: (Downloads folder identified as easiest target). Then resume download â€” Hugging Face's hf download tool checkpoints partial downloads, so no full re-download required. |
| Act | User freed 60 GB by deleting unused files in Downloads. WSL recovered after restart. Hugging Face download resumed; the partial file failed integrity check and was discarded, restarting from zero rather than resuming from 9.5 GB. Total re-download took ~25 minutes at ~14â€“17 MB/s. |

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p><strong>Lesson encoded for future installs</strong></p>
<p>The runbook's disk pre-flight should check the host filesystem of the WSL distribution (the Windows-side VHDX location), not just the WSL-side df. This is added to the runbook's troubleshooting reference for any re-deployment.</p></td>
</tr>
</tbody>
</table>

**4.5 Loop 4 â€” Tool-Call Format Incompatibility (the central crisis)**

| **Phase** | **Content** |
|----|----|
| Observe | After Phase 5 tuning achieved 20.89 t/s and Phase 6 wired Claude Code's settings.json directly at llama-server's /v1/messages endpoint, the smoke test crashed Claude Code with a JavaScript runtime error: undefined is not an object (evaluating 'H.command') in the PowerShell tool's isSearchOrReadCommand function. Plain-chat queries worked fine; only tool-using queries crashed. |
| Orient | The crash occurred when Claude Code attempted to render a tool-use message whose input field was missing a command property. Plain chat through llama.cpp's Anthropic shim worked, so the wire format was at least partially correct. The model was producing tool-call syntax that, after format translation by llama.cpp's shim, did not match Claude Code's expected schema. Disabling Qwen's reasoning mode (a suspected culprit) did not resolve the crash. The shim's tool-call parity was identified as the failing component. |
| Decide | The original architectural premise ("llama.cpp's native Anthropic shim is sufficient, no router needed") was wrong for this specific model. Three options: (a) accept Claude Code as chat-only, abandoning agentic loops; (b) pivot to Ollama, which has battle-tested Claude Code integration but limited control over MoE offloading; (c) introduce claude-code-router as a translation layer, keeping the tuned llama.cpp container as the inference engine. Option (c) preserves the 20.89 t/s tuning while bridging the format gap. |
| Act | First attempted option (b) â€” Ollama â€” partly to test the user's earlier intuition that Ollama would work. Ollama installed cleanly via curl install script after installing the missing zstd dependency. Imported the existing GGUF via Modelfile (no re-download). Discovered Ollama's auto-offload offers only whole-layer granularity, not the surgical MoE split llama.cpp supports; benchmark measured 4.79 t/s â€” approximately one-quarter the speed of the llama.cpp configuration. Speed too low to accept. Reverted to option (c). |

**4.6 Loop 5 â€” Engine Pivot (Ollama â†’ Router + llama.cpp)**

| **Phase** | **Content** |
|----|----|
| Observe | Ollama benchmark: 4.79 t/s on identical hardware running the same GGUF that achieves 20.89 t/s on llama.cpp. The differential is entirely architectural â€” Ollama lacks --n-cpu-moe equivalent. On a 6 GB card with a 35 B MoE model, this is a structural disadvantage. |
| Orient | claude-code-router is the standard solution for the exact problem: Claude Code's Anthropic-format requests need to reach an OpenAI-format inference server. The router is well-maintained, npm-installable, and adds negligible latency (single-millisecond format translation). It allows keeping the tuned llama.cpp container intact. |
| Decide | Stop Ollama, disable its systemd unit, fully remove its installation. Restart the llama.cpp Docker container with the same Phase-5-tuned flags. Install Node.js 20 LTS in WSL, install @musistudio/claude-code-router globally via npm. Configure ccr to forward requests to llama.cpp on port 8001. Repoint Claude Code's ANTHROPIC_BASE_URL at the router on port 3456 instead of llama.cpp on port 8001. |
| Act | Executed the pivot in approximately 15 minutes. First test message ("Reply with the word READY") returned cleanly. Second test (Bash tool with date -u) executed successfully â€” the model invoked the tool, llama.cpp returned the OpenAI tool-call format, ccr translated to Anthropic format, Claude Code parsed and executed it on the Windows host. The agentic loop closed end-to-end. |

**4.7 Loop 6 â€” Performance Tuning Convergence**

| **Phase** | **Content** |
|----|----|
| Observe | First post-router smoke test still measured 2 minutes 56 seconds for a single "READY" response. Direct llama.cpp benchmarks (curl bypassing Claude Code) confirmed 23 t/s generation throughput. Direct API call: 21 input tokens, 2 output tokens, response near-instant. Claude Code request: ~39,442 input tokens. The gap was prompt size. |
| Orient | Three contributors to the 39 K prompt: (a) Claude Code's system prompt and tool definitions (~10â€“15 K tokens, unavoidable); (b) project-folder CLAUDE.md auto-injection (~9 K tokens, the runbook itself was sitting in the test directory); (c) install_state.json injection (~1 K). Crucially, server logs showed cache_read_input_tokens: 0 â€” every turn was reprocessing all 39 K tokens because no prefix caching was enabled. |
| Decide | Two compounding fixes: (1) add --cache-reuse 256 to llama.cpp container so consecutive turns skip reprocessing the unchanged system prompt; (2) move CLAUDE.md and install_state.json out of any working directory used for testing, so Claude Code does not auto-inject them as project memory; (3) raise --b/-ub batch sizes from 2048/512 to 4096/2048 to roughly double cold-start prompt processing throughput; (4) set --parallel 1 to prevent slot fragmentation that would defeat cache reuse. |
| Act | Restarted container with new flags. First post-fix turn (cold cache): 38 s. Second turn (warm cache): 10 s. Third turn (still warm): 14 s. Tool call worked, with the model self-correcting from "date -u" (Unix syntax) to "Get-Date -UFormat" (PowerShell equivalent). Convergence reached. |

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p><strong>Final operational outcome</strong></p>
<p>After six OODA loops spanning approximately four hours of wall-clock time including model download, the stack achieved its target: agentic coding via Claude Code with a 35 B local model on a 6 GB GPU, post-warmup turn latency in the 5â€“15 second range, full tool-call compatibility, and stable thermal/memory operation. No hardware modifications. No cloud dependencies during inference. Fully reversible.</p></td>
</tr>
</tbody>
</table>

**5. Technical Challenges Catalog**

Every significant problem encountered during implementation is cataloged below, with its surface symptom, root cause, and applied resolution. This section is intended both as historical record and as an operational troubleshooting reference.

| **\#** | **Problem** | **Root Cause** | **Resolution** |
|----|----|----|----|
| 1 | **PATH not configured for Claude Code** | Claude Code installer placed binary in C:\Users\USER\\local\bin but did not modify the user's PATH environment variable. | Two-line PowerShell to append to user PATH and to current session: \[Environment\]::SetEnvironmentVariable("Path", currentPath + ";" + binPath, "User") then \$env:Path += ";" + binPath. |
| 2 | **WSL --install only installed platform, not Ubuntu** | On a fresh system, the first wsl --install -d Ubuntu-24.04 enables Windows features (VirtualMachinePlatform, WSL itself) and prompts a reboot. The distro itself is downloaded only on the second invocation after reboot. | After reboot, run wsl --install -d Ubuntu-24.04 a second time. This downloads Ubuntu and triggers first-time setup (username/password). |
| 3 | **Docker installer failed: "For security reasons C:\ProgramData\DockerDesktop must be owned by an elevated account"** | The first non-elevated launch of the installer created C:\ProgramData\DockerDesktop with the user's standard ownership. Subsequent elevated launches detected this and refused to proceed. | Run an elevated PowerShell, delete the orphan folder with Remove-Item -Recurse -Force, then run the installer with the elevated session inheriting admin rights. |
| 4 | **Disk space exhaustion mid-download** | Windows C: had only 8 GB free at session start. WSL VHDX hit the physical disk wall during the 21 GB GGUF download, causing EIO errors throughout the Linux VM. | Run wsl --shutdown to release the locked VHDX. User freed 60 GB on C: by deleting unneeded files in Downloads. Restart WSL; Hugging Face downloader resumed (partial file failed integrity check, restarted from zero). |
| 5 | **Sudo password prompt blocking from inside Claude Code's bash invocation** | Claude Code's bash tool runs commands non-interactively. sudo apt update prompts for password, hangs indefinitely. | Have user run the single sudo-requiring command manually in an Ubuntu terminal (Option A: open WSL terminal, paste command, type password once). This avoided granting NOPASSWD sudo for the rest of the install. |
| 6 | **Tool-call crash: undefined is not an object ('H.command')** | llama.cpp's native /v1/messages Anthropic shim does not produce tool-call output that matches Claude Code's parser expectations for Qwen3.6's specific tool-call format. | Introduce claude-code-router as a translation proxy between Claude Code and llama.cpp. Repoint settings.json at the router instead of directly at llama.cpp. |
| 7 | **First post-router response took 2 m 56 s** | Claude Code injects ~39 K tokens of system prompt + tool definitions per request. Without prompt caching, every turn re-processed the full prefix. | Add --cache-reuse 256 and --parallel 1 to llama-server. Move CLAUDE.md out of test working directory. Increase batch sizes to 4096/2048. |
| 8 | **Runaway token generation in Ollama (\<\|im_start\|\> repeated indefinitely)** | Unsloth's UD-Q4_K_XL GGUF metadata did not register the chat-template special tokens as stop tokens for Ollama's defaults. | Add explicit PARAMETER stop "\<\|im_start\|\>", PARAMETER stop "\<\|im_end\|\>", PARAMETER stop "\<\|endoftext\|\>" to the Modelfile. (Note: this fix was applied during the brief Ollama experiment; the final stack does not use Ollama.) |
| 9 | **Ollama 4.79 t/s vs llama.cpp 23 t/s on same hardware** | Ollama only offers whole-layer GPU offloading. On a 6 GB card with a 35 B MoE model, this forces most of the model to CPU. llama.cpp's --n-cpu-moe offers per-layer expert-vs-dense split. | Abandon Ollama path. Restore llama.cpp container and add claude-code-router for format translation. |
| 10 | **Docker WSL Integration silently disabled after a prior reboot** | Docker Desktop's WSL Integration toggle (per-distro) reset under some upgrade or restart conditions. Caused docker command to be unavailable inside Ubuntu. | Open Docker Desktop â†’ Settings â†’ Resources â†’ WSL Integration â†’ re-enable both the master switch and the Ubuntu-24.04 toggle. Apply & Restart. |
| 11 | **Auth conflict warning at Claude Code startup** | Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY were set; Claude Code wants exactly one. | Remove ANTHROPIC_API_KEY from settings.json env block via PSObject.Properties.Remove('ANTHROPIC_API_KEY'). |
| 12 | **Claude Code intercepting /think as a slash command** | Slash-prefixed messages at start of input are reserved for Claude Code's command system, never reach the model. | Use natural-language reasoning cues ("think step-by-step") in prompt body, or place /think mid-message after a leading character so Claude Code does not intercept it. |

**6. Performance Analysis**

**6.1 Final Measured Performance**

All numbers below are measured on the operational stack as configured (llama.cpp container with the final-tuned flags, ccr proxy, Claude Code on Windows, no concurrent workload). Measurements use llama-server's built-in timing metrics, sampled from container logs.

| **Metric** | **Value** | **Context** |
|----|----|----|
| **Generation throughput** | ~ 23 tokens/sec | Steady-state token output rate. Independently confirmed via direct API benchmark and via in-Claude-Code measurements. |
| **Prompt processing throughput (cold)** | ~ 600 tokens/sec | Rate at which new prompt tokens are processed when no cache hit is available. Approximately 2Ã— faster than default batch sizes. |
| **Prompt processing throughput (warm)** | effectively instant | When the prompt prefix matches a cached prefix, those tokens are skipped entirely. Only the new suffix is processed. |
| **First-turn latency (cold cache)** | 30â€“60 s | First request of a new session. ~39 K system+tools prompt processed at ~600 t/s, plus generation of the response itself. |
| **Subsequent-turn latency (warm cache)** | 5â€“15 s | Most of the prompt is cached. Only new user message + new tool results are processed; full response generation is the dominant cost. |
| **VRAM utilization (steady state)** | 5,354 / 6,144 MiB | 87% utilization. 790 MiB headroom for context expansion. |
| **System RAM utilization** | ~ 21 GB / 26 GB cap | Model weights mlock'd in WSL RAM. Headroom: 5 GB inside WSL plus 6 GB on Windows side. |
| **GPU peak temperature** | 71 Â°C | Under sustained inference load. Manufacturer spec: 90 Â°C throttle, 105 Â°C shutdown. Comfortable margin. |
| **Idle GPU temperature** | 33â€“35 Â°C | When no inference is running. |
| **Model file size on disk** | 21.4 GB | Single GGUF file in WSL filesystem. Hard-linked rather than copied during Ollama experiment. |

**6.2 Latency Decomposition Example**

A representative turn from the live system, broken down by component:

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p>USER MESSAGE: "Use the Bash tool to run: date -u"</p>
<p>TOTAL ELAPSED: 14 seconds</p>
<p>â”Œâ”€ Network: Windows â†’ ccr (3456) â”€â”€â”€â”€â”€â”€â”€â”€ &lt; 1 ms</p>
<p>â”‚</p>
<p>â”œâ”€ ccr: Anthropic â†’ OpenAI translation â”€ ~ 5 ms</p>
<p>â”‚</p>
<p>â”œâ”€ Network: ccr â†’ llama-server (8001) â”€â”€ &lt; 1 ms</p>
<p>â”‚</p>
<p>â”œâ”€ llama-server: prompt processing</p>
<p>â”‚ Cached prefix: 39,381 tokens (skipped)</p>
<p>â”‚ New suffix: 52 tokens (~ 0.1 s)</p>
<p>â”‚</p>
<p>â”œâ”€ Generation: ~ 60 tokens output</p>
<p>â”‚ At 23 t/s = ~ 2.6 s</p>
<p>â”‚ (Includes model writing the tool_call JSON)</p>
<p>â”‚</p>
<p>â”œâ”€ ccr: OpenAI â†’ Anthropic translation ~ 3 ms</p>
<p>â”‚</p>
<p>â”œâ”€ Claude Code: parse tool_use &lt; 1 ms</p>
<p>â”‚</p>
<p>â”œâ”€ Tool execution: PowerShell Get-Date ~ 200 ms</p>
<p>â”‚</p>
<p>â”œâ”€ Second roundtrip with tool result:</p>
<p>â”‚ Prompt: tool result (~100 tokens) ~ 0.2 s</p>
<p>â”‚ Generation: ~ 20-40 tokens ~ 1 s</p>
<p>â”‚</p>
<p>â””â”€ Final render in Claude Code &lt; 1 ms</p>
<p>â‰ˆ 4-5 s of pure model time Ã— 2 round trips</p>
<p>â‰ˆ 14 s wall-clock observed (matches the timing above)</p></td>
</tr>
</tbody>
</table>

**6.3 Comparison with Reference Hardware**

The reference benchmark is the YouTube video that inspired this project, which targeted the same Qwen3.6-35B-A3B model on a hardware floor described as deliberately worst-case: GTX 1060 6 GB (Pascal, 2016), Intel i3-8100 (4 cores, no hyperthreading, 2018), DDR4 RAM. Measured: 17 tokens/sec generation.

The hardware in this project is similar in VRAM but newer and more capable in CPU and memory subsystems:

| **Component** | **Reference (YouTube)** | **This Project** | **Effect** |
|----|----|----|----|
| **GPU** | GTX 1060 6 GB (Pascal) | RTX 3050 6 GB (Ampere) | Same VRAM. Newer architecture: ~2Ã— FP16 throughput, faster memory bandwidth. |
| **CPU** | i3-8100 4C/4T | Ryzen 7 8700F 8C/16T | 2Ã— core count, modern architecture. Faster expert routing during MoE inference. |
| **RAM** | DDR4 (speed unspecified) | DDR5 (8000F â†’ typically DDR5-5600+) | Approximately 2Ã— memory bandwidth. Reduces PCIe-RAM transfer time for expert fetches. |
| **Storage** | Not specified | NVMe SSD | Faster initial model load. No effect on steady-state inference. |
| **Generation speed** | 17 t/s | ~ 23 t/s | +35%, attributable to the cumulative effect of CPU/RAM upgrades. Reference was video-floor; this is moderate-floor. |

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p><strong>On the Reference number being a floor</strong></p>
<p>The 17 t/s figure was deliberately produced on "worst case" 8-year-old hardware to demonstrate the lower bound of the technique. Hardware from this decade â€” even consumer-tier â€” outperforms it. The 23 t/s in this project is a moderate-floor, not a ceiling. An 8 GB Ampere card or a 12 GB midrange card would easily clear 30 t/s with the same flags.</p></td>
</tr>
</tbody>
</table>

**7. Configuration Reference**

**7.1 Final Docker Run Command**

The exact command launching the llama.cpp container:

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p>docker run -d --name qwen36-server \</p>
<p>--gpus all \</p>
<p>--cap-add IPC_LOCK \</p>
<p>--ulimit memlock=-1:-1 \</p>
<p>--restart unless-stopped \</p>
<p>-p 127.0.0.1:8001:8001 \</p>
<p>-v "$HOME/models/qwen36:/models:ro" \</p>
<p>ghcr.io/ggml-org/llama.cpp:server-cuda \</p>
<p>--model /models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \</p>
<p>--alias qwen3.6-35b \</p>
<p>--host 0.0.0.0 --port 8001 \</p>
<p>--jinja \</p>
<p>-ngl 60 \</p>
<p>--n-cpu-moe 38 \</p>
<p>-fa on \</p>
<p>-ctk q8_0 -ctv q8_0 \</p>
<p>-c 65536 \</p>
<p>--no-mmap \</p>
<p>--mlock \</p>
<p>-t 8 -tb 16 \</p>
<p>-b 4096 -ub 2048 \</p>
<p>--parallel 1 \</p>
<p>--cache-reuse 256 \</p>
<p>--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0 \</p>
<p>--presence-penalty 1.5 \</p>
<p>--chat-template-kwargs '{"enable_thinking":false}'</p></td>
</tr>
</tbody>
</table>

**7.2 Claude Code settings.json**

Located at C:\Users\USER\\claude\settings.json. Final form:

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p>{</p>
<p>"autoUpdatesChannel": "latest",</p>
<p>"theme": "dark",</p>
<p>"claudeCodeAttributionHeader": false,</p>
<p>"hasCompletedOnboarding": true,</p>
<p>"primaryApiKey": "sk-no-key-required",</p>
<p>"model": "qwen3.6-35b",</p>
<p>"env": {</p>
<p>"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456",</p>
<p>"ANTHROPIC_AUTH_TOKEN": "sk-no-key-required",</p>
<p>"ANTHROPIC_MODEL": "qwen3.6-35b",</p>
<p>"ANTHROPIC_SMALL_FAST_MODEL": "qwen3.6-35b",</p>
<p>"API_TIMEOUT_MS": "600000",</p>
<p>"CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8192",</p>
<p>"CLAUDE_CODE_ATTRIBUTION_HEADER": "0"</p>
<p>}</p>
<p>}</p></td>
</tr>
</tbody>
</table>

**7.3 ccr Configuration**

Located at ~/.claude-code-router/config.json (inside WSL):

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p>{</p>
<p>"LOG": false,</p>
<p>"OPENAI_API_KEY": "sk-no-key-required",</p>
<p>"OPENAI_BASE_URL": "",</p>
<p>"OPENAI_MODEL": "",</p>
<p>"Providers": [{</p>
<p>"name": "llamacpp",</p>
<p>"api_base_url": "http://127.0.0.1:8001/v1/chat/completions",</p>
<p>"api_key": "sk-no-key-required",</p>
<p>"models": ["qwen3.6-35b"],</p>
<p>"transformer": { "use": ["openai"] }</p>
<p>}],</p>
<p>"Router": {</p>
<p>"default": "llamacpp,qwen3.6-35b",</p>
<p>"background": "llamacpp,qwen3.6-35b",</p>
<p>"think": "llamacpp,qwen3.6-35b",</p>
<p>"longContext": "llamacpp,qwen3.6-35b"</p>
<p>}</p>
<p>}</p></td>
</tr>
</tbody>
</table>

**7.4 .wslconfig**

Located at C:\Users\USER\\wslconfig:

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p>[wsl2]</p>
<p>memory=26GB</p>
<p>processors=8</p>
<p>swap=8GB</p>
<p>localhostForwarding=true</p></td>
</tr>
</tbody>
</table>

**8. Operational Guide**

**8.1 Daily Use**

After installation, daily use is simple. Both the Docker container (--restart unless-stopped) and the ccr router (launched with nohup) survive WSL restarts â€” opening any WSL terminal triggers WSL boot, which auto-starts both services. To begin coding:

1.  Open PowerShell.

2.  cd to any project directory on Windows.

3.  Run claude. The first message of each session takes 30â€“60 s (cold cache); subsequent messages 5â€“15 s.

**8.2 Health Checks**

If anything appears wrong, the following commands validate each layer in turn. Run inside an Ubuntu (WSL) terminal:

| **Check** | **Command** | **Healthy Output** |
|----|----|----|
| Docker daemon reachable | docker ps | Lists qwen36-server with status "Up X minutes" |
| llama-server alive | curl -s http://localhost:8001/health | {"status":"ok"} |
| ccr router alive | curl -s http://127.0.0.1:3456/ | {"message":"LLMs API","version":"1.0.51"} |
| GPU still attached | nvidia-smi | Shows RTX 3050 with non-zero memory.used |
| Container logs (recent) | docker logs --tail 30 qwen36-server | Recent prompt eval / eval timings |

**8.3 Restart Procedures**

To restart only the inference engine without disturbing other services:

|                              |
|------------------------------|
| docker restart qwen36-server |

To restart only the router:

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p>pkill -f 'ccr start' 2&gt;/dev/null</p>
<p>nohup ccr start &gt; ~/ccr.log 2&gt;&amp;1 &amp;</p></td>
</tr>
</tbody>
</table>

To restart everything from scratch:

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p># In PowerShell (Windows):</p>
<p>wsl --shutdown</p>
<p># Then open Ubuntu, services auto-start because of --restart unless-stopped</p>
<p># and the systemd-managed WSL bootstrap</p></td>
</tr>
</tbody>
</table>

**8.4 Mode Switching: Local vs. Cloud Claude**

To temporarily switch back to Anthropic's hosted Claude (using your normal Claude Pro/Max subscription), edit %USERPROFILE%\\claude\settings.json and either delete or rename the env block. The simplest reversible toggle, in PowerShell:

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p># Switch to CLOUD Claude (saves env to .env.local-backup):</p>
<p>$f='$env:USERPROFILE\.claude\settings.json'</p>
<p>$j=Get-Content $f -Raw | ConvertFrom-Json</p>
<p>if ($j.env) { $j | Add-Member -NotePropertyName 'env-local-backup' -NotePropertyValue $j.env -Force</p>
<p>$j.PSObject.Properties.Remove('env') }</p>
<p>$j | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 $f</p>
<p># Switch BACK to local Qwen:</p>
<p>$j=Get-Content $f -Raw | ConvertFrom-Json</p>
<p>if ($j.'env-local-backup') {</p>
<p>$j | Add-Member -NotePropertyName 'env' -NotePropertyValue $j.'env-local-backup' -Force</p>
<p>$j.PSObject.Properties.Remove('env-local-backup')</p>
<p>}</p>
<p>$j | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 $f</p></td>
</tr>
</tbody>
</table>

**8.5 Reasoning Mode Toggle**

Default: thinking off (set at server startup via --chat-template-kwargs '{"enable_thinking":false}'). Per-message overrides:

- Force thinking ON for one message: include "think step-by-step" or "reason carefully" in the prompt body. Do NOT use a leading slash command (Claude Code intercepts it).

- To make thinking the default permanently: restart the container with enable_thinking:true. Then per-message OFF override is "answer briefly without thinking" or appending /no_think mid-message.

**8.6 Tear-Down (Complete Removal)**

If the entire stack ever needs to be removed, the procedure is:

<table>
<colgroup>
<col style="width: 100%" />
</colgroup>
<tbody>
<tr>
<td><p># 1. Stop and remove the container (Ubuntu):</p>
<p>docker stop qwen36-server</p>
<p>docker rm qwen36-server</p>
<p>docker rmi ghcr.io/ggml-org/llama.cpp:server-cuda</p>
<p># 2. Stop the router (Ubuntu):</p>
<p>pkill -f 'ccr start'</p>
<p># 3. Revert Claude Code settings (PowerShell):</p>
<p>$f='$env:USERPROFILE\.claude\settings.json'</p>
<p>$j=Get-Content $f -Raw | ConvertFrom-Json</p>
<p>$j.PSObject.Properties.Remove('env')</p>
<p>$j.PSObject.Properties.Remove('claudeCodeAttributionHeader')</p>
<p>$j | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 $f</p>
<p># 4. (Optional) Unregister WSL distro entirely (irreversible â€” wipes Linux):</p>
<p># In PowerShell: wsl --unregister Ubuntu-24.04</p>
<p># 5. (Optional) Uninstall Docker Desktop via Add/Remove Programs</p></td>
</tr>
</tbody>
</table>

**9. Limitations & Future Improvements**

**9.1 Known Limitations**

- Single-user, single-session. The ccr proxy and llama-server are configured for one concurrent caller. A second simultaneous Claude Code session would queue behind the first. For typical solo coding this is fine; for shared use, --parallel â‰¥ 2 plus removing --cache-reuse 256 would be required, at the cost of dramatically reduced cache hit rates.

- Model weights are static. Updating the model (e.g., to Qwen3.7 or a better-suited successor) requires: stop container, download new GGUF, update --model path, restart. There is no hot-swap.

- Tool-call format is OpenAI-via-router, not native Anthropic. Some advanced Claude Code features that depend on Anthropic-specific tool semantics (parallel tool calls, fine-grained tool-result streaming) may not behave identically. Basic agent loops, file ops, and shell execution work as confirmed.

- Context limit: 64 K. Sufficient for most coding sessions but tighter than cloud Claude's 200 K. Pushing to 128 K is feasible by reducing --n-cpu-moe to 36, at the cost of moving more experts to GPU and approaching VRAM ceiling.

- First-turn latency. Cold-cache 30â€“60 s response on session start is the structural cost of processing a 39 K-token system prompt at 600 t/s. Improvements possible via larger batch sizes (more VRAM dependent) or aggressive system prompt trimming (Claude Code feature, not available).

- WSL VHDX dynamic growth never shrinks. Once expanded by writes, the underlying VHDX file does not auto-compact. Manual compaction is possible via diskpart but disruptive.

- Reasoning mode is on/off at server level, with imperfect per-message override. Natural-language reasoning cues work most of the time but are not deterministic switches.

**9.2 Plausible Future Improvements**

- TurboQuant KV cache integration. Currently using -ctk q8_0 -ctv q8_0 (8-bit, lossless). When PR \#21089 lands in mainline llama.cpp, swapping to -ctk turbo4 -ctv turbo3 frees ~3â€“4 GB equivalent of context-window headroom.

- Speculative decoding via DFlash or block-diffusion drafters. Standard speculative decoding with a small dense drafter does not work for MoE models (per benchmarks on RTX 3090). Newer block-diffusion drafters specifically designed for MoE may eventually offer 1.5â€“2Ã— speedup.

- Auto-restart unification via systemd unit for ccr. Currently ccr is launched with nohup; a proper systemd service would make it more robust.

- Health check endpoint aggregation. A small wrapper that returns the union of Docker, llama-server, and ccr health states would simplify monitoring.

- Per-project CLAUDE.md templates. The autonomous-installer CLAUDE.md is heavyweight; conventional per-project memory files should be small and conversational.

- Successor model evaluation. As open-weight models continue improving, the 35 B class may be supplanted within months by smaller models with comparable agentic-coding ability. The stack architecture (Docker container + ccr proxy + Claude Code wiring) is model-agnostic; only the GGUF file and a few flags change.

**9.3 Closing Note**

This document captures a snapshot of a working configuration as of May 2026. The components evolve quickly: llama.cpp ships changes weekly, ccr's transformer set expands, Claude Code adds and removes features per release. The architecture (host client + WSL proxy + containerized engine + GPU passthrough) should remain stable; the specific flags and versions will not. Periodic re-evaluation is appropriate, particularly when major Claude Code or llama.cpp releases land.

The implementation succeeded for one specific reason worth noting: the willingness to abandon initial architectural assumptions when evidence contradicted them. The original design â€” llama.cpp's native Anthropic shim, no router â€” was elegant and would have worked for many models. It did not work for Qwen3.6's tool-call format. Recognizing that and pivoting to add the router was the difference between a working stack and a stuck one. Boyd's principle held: faster OODA loops win.

