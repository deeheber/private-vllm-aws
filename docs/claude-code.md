# Claude Code

The Claude Code CLI can use the vLLM endpoint in place of Anthropic's hosted models. Expect noticeably weaker results than hosted Claude on multi-step tasks, especially with small models. Anthropic doesn't support routing Claude Code to non-Claude models, so a Claude Code update can break this setup.

## Before you start

- The stack is deployed and the model has loaded. See [Deployment](deployment.md).
- The [Claude Code CLI](https://code.claude.com/docs/en/setup) is installed.
- The tunnel is open in its own terminal: `scripts/connect.sh`. Close it when you're done; while it's open, any program on your laptop can reach the endpoint. See [Security notes](../README.md#security-notes).

## Run it

```bash
scripts/claude-local.sh
```

This starts a normal interactive Claude Code session in your current directory, using the model on your instance. It passes its arguments through to `claude`, so `scripts/claude-local.sh -p "..."` runs a single prompt headless. If the tunnel uses another local port, set `VLLM_LOCAL_PORT`, like `VLLM_LOCAL_PORT=9000 scripts/claude-local.sh`.

To run it from anywhere as `claude-local`, add an alias to your shell profile:

```bash
alias claude-local=/path/to/private-vllm-aws/scripts/claude-local.sh
```

The script reads the API key and model name from `stacks/compute/compute-params.json` and sets environment variables only for the session it starts. Plain `claude` keeps using your normal login.

In the session, `/status` should show the `http://localhost:<port>` base URL, an auth token, and the served model name.

## What the script sets

| Variable | Why |
|---|---|
| `ANTHROPIC_BASE_URL` | Sends requests to the tunnel instead of Anthropic. |
| `ANTHROPIC_AUTH_TOKEN` | The vLLM API key, sent as a bearer token. It takes precedence over a saved claude.ai login. `ANTHROPIC_API_KEY` sends a different header and fails. |
| `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` | Every model choice, including background tasks like session titles, resolves to the served model. |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Claude Code assumes a 200K window for model names it doesn't recognize. This must match `--max-model-len` in `compute.yaml` (65,536), or Claude Code never compacts and the server rejects long prompts. If you change `--max-model-len`, change `MAX_CONTEXT_TOKENS` in the script to match. |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | Claude Code reserves room for the reply out of the window, so a smaller cap leaves more for the conversation (8,192). |
| `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING`, `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` | Stop Claude Code sending request fields vLLM doesn't accept. |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | Turns off telemetry and other requests to Anthropic that aren't needed. |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY` | Turns off auto memory, which is shared with your hosted sessions for the same repo (and all its git worktrees). A weaker model can save wrong lessons there that your normal sessions then load. CLAUDE.md files still load. |

## MCP servers

The script passes `--strict-mcp-config`, so local sessions load no MCP servers. Their tool definitions take space in a small context window; see [Limits](#limits). To load specific servers for a task, pass a config file:

```bash
scripts/claude-local.sh --mcp-config servers.json
```

The file uses the same `mcpServers` format as `.mcp.json`. Plain `claude` sessions still load all your MCP servers.

## Limits

- **Context is smaller.** At 65,536 tokens, long sessions compact sooner than on hosted models. Check `/context` to see where it goes. With the script's settings:
  - The system prompt, built-in tools, and skills take about 15K.
  - Claude Code holds back an autocompact buffer of about 13K plus the output cap, so about 21K.
  - That leaves about 29K for the conversation. Each MCP server takes more; two AWS servers took 6.7K.
- **No web search.** WebSearch is a tool Anthropic runs on its own servers, so it isn't available through vLLM.
- **gpt-oss tool calls sometimes fail.** In vLLM v0.30.0, gpt-oss's chat-format tokens can end up attached to tool names, as in `Bash<|channel|>commentary`, and Claude Code rejects those calls. See vLLM issues [#51977](https://github.com/vllm-project/vllm/issues/51977) and [#32587](https://github.com/vllm-project/vllm/issues/32587).
- **claude.ai connectors don't load.** Connectors that come with a claude.ai login (such as Slack or Google Drive) are disabled while the auth token is set.
- **CLI only.** The script sets its variables for the `claude` command it runs. The VS Code extension would need the same variables in its own environment (untested). Claude Desktop ignores `ANTHROPIC_BASE_URL`, and cloud sessions always use your subscription.
