# Switching models

The model profile is stored in an SSM parameter, not in the instance's launch template. A service on the instance reads it each time it starts vLLM, at boot and when you run `scripts/switch-model.sh`. Switching models restarts only the vLLM container; the instance keeps running and keeps its ID.

## Switch

1. Edit the profile values in `compute-params.json` (see [The profile](#the-profile) and [Example profiles](#example-profiles)).
2. Run `scripts/deploy.sh compute`. The change set updates only the `ModelProfile` parameter, and the script doesn't ask about replacing the instance. If it does ask, something other than the profile changed; answer `n` and check the file.
3. Run `scripts/switch-model.sh`. It restarts vLLM, then lists what's running and cached (see [Cached models and disk space](#cached-models-and-disk-space)).

The restart returns right away, but the model isn't ready until it has loaded, which includes downloading its weights the first time you use it. To watch, run `scripts/connect.sh shell`, then `sudo journalctl -u vllm -f`, and wait for `Application startup complete`.

If the instance is stopped, skip step 3. It loads the deployed profile the next time it starts.

## The profile

These values in `stacks/compute/compute-params.json` make up the profile:

| Parameter | What it sets |
|---|---|
| `VllmTag` | The `vllm/vllm-openai` image tag. |
| `ModelId` | The Hugging Face model to serve. |
| `ServedModelName` | The name clients use. It can't contain `/`. |
| `ToolCallParser` | vLLM's `--tool-call-parser` for this model family. |
| `MaxModelLen` | The context window, `--max-model-len`. |
| `ExtraVllmArgs` | Any other `vllm serve` flags, split like a shell command line. Can be empty. |

`scripts/claude-local.sh` asks the running server for the model name and context window, so it follows a switch with no changes.

## If the new model doesn't start

`journalctl` shows the error, such as an unknown flag, a model that doesn't fit in GPU memory, or a context window larger than the KV cache holds. After three quick failures in 10 minutes, the service stops retrying and `switch-model.sh list` shows it as `failed`. A model that fails only after a long download can keep retrying.

Put the previous profile back, or fix the value, and run steps 2 and 3 again. `switch-model.sh` clears the failed state before it restarts.

`scripts/deploy.sh` rejects an `ExtraVllmArgs` value with unmatched quotes before it deploys anything.

## Cached models and disk space

Weights stay on the root volume under `/opt/hf-cache`, so switching back to a model you've used is fast. `scripts/switch-model.sh list` shows each cached model's size, marks the one running, and lists vLLM images and free space, without restarting anything.

When free space drops under 40 GB, it prints the commands to free space. To remove a cached model that isn't running:

```bash
scripts/switch-model.sh remove openai/gpt-oss-20b
```

A model's directory holds only links; its files are in a shared `/opt/hf-cache/hub/blobs/` store, so deleting the directory alone frees nothing. `remove` deletes the model's files except any another cached model also uses, then the directory. To remove an old vLLM image, run `scripts/connect.sh shell`, then `sudo docker image rm vllm/vllm-openai:<tag>`.

## Example profiles

With vLLM v0.30.0. The first two are for a g5.xlarge (A10G, 24 GB); the others need a g6e.xlarge (L40S, 48 GB). Changing `InstanceType` replaces the instance; the other rows are the profile.

| Parameter | gpt-oss-20b (default, tested) | Qwen3.5-9B, FP8 build (tested) | Devstral Small 2 24B (untested) | Muse Glimmer 30B, FP8 build (untested) |
|---|---|---|---|---|
| Developer, license | OpenAI, Apache 2.0 | Qwen (Alibaba), Apache 2.0 | Mistral, Apache 2.0 | Meta, Apache 2.0 plus Meta's usage policy |
| `InstanceType` | `g5.xlarge` | `g5.xlarge` | `g6e.xlarge` | `g6e.xlarge` |
| `ModelId` | `openai/gpt-oss-20b` | `RedHatAI/Qwen3.5-9B-FP8-dynamic` | `mistralai/Devstral-Small-2-24B-Instruct-2512` | `RedHatAI/Muse-Glimmer-30B-FP8-block` |
| `ServedModelName` | `gpt-oss-20b` | `qwen3.5-9b` | `devstral-small-2` | `muse-glimmer-30b` |
| `ToolCallParser` | `openai` | `qwen3_coder` | `mistral` | `muse_glimmer` |
| `MaxModelLen` | `65536` | `65536` | `131072` | `131072` |
| `ExtraVllmArgs` | (empty) | `--reasoning-parser qwen3 --language-model-only` | `--kv-cache-dtype fp8 --language-model-only` | `--reasoning-parser muse_glimmer --language-model-only` |

`--language-model-only` turns off image input, so no GPU memory is held for it.

- **gpt-oss-20b:** in vLLM v0.30.0 its tool calls sometimes fail, with chat-format tokens attached to tool names, as in `Bash<|channel|>commentary` (vLLM issues [#51977](https://github.com/vllm-project/vllm/issues/51977), [#32587](https://github.com/vllm-project/vllm/issues/32587)).
- **Devstral and Glimmer:** the context windows are estimated from the model configs, not measured. Devstral should need the fp8 KV cache to fit 131,072 tokens next to its 26 GB of weights; without it, try about 90,000. If vLLM reports at startup that the KV cache is too small, lower `MaxModelLen`.
