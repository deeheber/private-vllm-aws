# Claude Code

The Claude Code CLI can use the vLLM endpoint in place of Anthropic's hosted models. Expect noticeably weaker results than hosted Claude on multi-step tasks, especially with small models. Anthropic doesn't support routing Claude Code to non-Claude models, so a Claude Code update can break this setup.

## Before you start

- The stack is deployed and the model has loaded. See [Deployment](deployment.md).
- The [Claude Code CLI](https://code.claude.com/docs/en/setup) is installed.
- AWS credentials for the account are set up, as for deploying. The script uses them to read the API key.
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

The script reads the API key from the stack's Secrets Manager secret, and the model name and context window from the running server's `/v1/models`. After you [switch models](switching-models.md), the next session follows automatically. Plain `claude` keeps using your normal login.

In the session, `/status` should show the `http://localhost:<port>` base URL, an auth token, and the served model name.

## What the script sets

| Variable | Why |
|---|---|
| `ANTHROPIC_BASE_URL` | Sends requests to the tunnel instead of Anthropic. |
| `ANTHROPIC_AUTH_TOKEN` | The vLLM API key, sent as a bearer token. It takes precedence over a saved claude.ai login. `ANTHROPIC_API_KEY` sends a different header and fails. |
| `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` | Every model choice, including background tasks like session titles, resolves to the served model. |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Claude Code assumes a 200K window for model names it doesn't recognize. This must match the server's `--max-model-len`, or Claude Code never compacts and the server rejects long prompts. |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | Caps replies at 8,192 tokens. Claude Code reserves room for the reply out of the window, so a smaller cap leaves more for the conversation. |
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

- **Context is smaller.** The default profile serves 65,536 tokens, so long sessions compact sooner than on hosted models. With the script's settings, the system prompt, tools and skills take about 15K and the autocompact buffer about 21K, leaving about 29K for the conversation. Each MCP server takes more; two AWS servers took 6.7K. These were measured with gpt-oss-20b in September 2026; check `/context` for yours.
- **No web search.** WebSearch is a tool Anthropic runs on its own servers, so it isn't available through vLLM.
- **claude.ai connectors don't load.** Connectors that come with a claude.ai login (such as Slack or Google Drive) are disabled while the auth token is set.
- **CLI only.** The VS Code extension would need the script's variables in its own environment (untested). Claude Desktop ignores `ANTHROPIC_BASE_URL`, and cloud sessions always use your subscription.
