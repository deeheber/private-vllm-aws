#!/usr/bin/env bash
# Run Claude Code against the vLLM endpoint through an open SSM tunnel.
# Usage: scripts/claude-local.sh [claude args...]
#        scripts/claude-local.sh --mcp-config servers.json   to load specific MCP servers
#        VLLM_LOCAL_PORT=9000 scripts/claude-local.sh   if the tunnel uses another local port
# Open the tunnel first with scripts/connect.sh. Works from any directory.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARAMS="$REPO_ROOT/stacks/compute/compute-params.json"
PORT="${VLLM_LOCAL_PORT:-8000}"
# Must match --max-model-len in stacks/compute/compute.yaml
MAX_CONTEXT_TOKENS=65536
MAX_OUTPUT_TOKENS=8192

if [[ ! -f "$PARAMS" ]]; then
  echo "$PARAMS not found. See docs/deployment.md." >&2
  exit 1
fi

param() { jq -r --arg k "$1" '.[] | select(.ParameterKey==$k).ParameterValue' "$PARAMS"; }
api_key=$(param ApiKey)
model=$(param ServedModelName)

if ! curl -sf -o /dev/null "localhost:$PORT/health"; then
  echo "vLLM isn't answering on localhost:$PORT. Open the tunnel with scripts/connect.sh" >&2
  echo "and wait for the model to load." >&2
  exit 1
fi

exec env \
  ANTHROPIC_BASE_URL="http://localhost:$PORT" \
  ANTHROPIC_AUTH_TOKEN="$api_key" \
  ANTHROPIC_MODEL="$model" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" \
  CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1 \
  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS="$MAX_CONTEXT_TOKENS" \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS="$MAX_OUTPUT_TOKENS" \
  claude --strict-mcp-config "$@"
