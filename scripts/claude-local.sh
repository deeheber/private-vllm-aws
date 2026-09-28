#!/usr/bin/env bash
# Run Claude Code against the vLLM endpoint through an open SSM tunnel.
# Usage: scripts/claude-local.sh [claude args...]
#        scripts/claude-local.sh --mcp-config servers.json   to load specific MCP servers
#        VLLM_LOCAL_PORT=9000 scripts/claude-local.sh   if the tunnel uses another local port
# Open the tunnel first with scripts/connect.sh. Works from any directory. Needs AWS
# credentials to read the API key from Secrets Manager.
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
COMPUTE_STACK=vllm-compute
PORT="${VLLM_LOCAL_PORT:-8000}"
MAX_OUTPUT_TOKENS=8192

if ! curl -sf --max-time 10 -o /dev/null "localhost:$PORT/health"; then
  echo "vLLM isn't answering on localhost:$PORT. Open the tunnel with scripts/connect.sh" >&2
  echo "and wait for the model to load." >&2
  exit 1
fi

secret_arn=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$COMPUTE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiKeySecretArn'].OutputValue" --output text 2>/dev/null) || secret_arn=""
if [[ -z "$secret_arn" || "$secret_arn" == "None" ]]; then
  echo "Couldn't find the API key secret in stack $COMPUTE_STACK ($REGION). Check your AWS credentials and that the stack is deployed." >&2
  exit 1
fi
api_key=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$secret_arn" \
  --query SecretString --output text) || {
  echo "Couldn't read the API key from Secrets Manager. Check your AWS credentials." >&2
  exit 1
}

# From the running server, so they match what it's serving.
models=$(curl -s --max-time 30 -w '\n%{http_code}' -H "Authorization: Bearer $api_key" \
  "localhost:$PORT/v1/models") || {
  echo "Lost the connection to localhost:$PORT while reading /v1/models. Check the tunnel (scripts/connect.sh)." >&2
  exit 1
}
status=${models##*$'\n'}
models=${models%$'\n'*}
if [[ "$status" == 401 ]]; then
  echo "vLLM rejected the API key. If you rotated it, run scripts/switch-model.sh so the server loads the new one." >&2
  exit 1
fi
model=$(jq -r '.data[0].id // empty' <<<"$models" 2>/dev/null) || model=""
max_context_tokens=$(jq -r '.data[0].max_model_len // empty' <<<"$models" 2>/dev/null) || max_context_tokens=""
if [[ "$status" != 200 || -z "$model" || ! "$max_context_tokens" =~ ^[1-9][0-9]*$ ]]; then
  echo "Unexpected response from localhost:$PORT/v1/models (HTTP $status):" >&2
  echo "$models" >&2
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
  CLAUDE_CODE_MAX_CONTEXT_TOKENS="$max_context_tokens" \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS="$MAX_OUTPUT_TOKENS" \
  claude --strict-mcp-config "$@"
