# private-vllm-aws

Run a private coding-model endpoint on AWS with CloudFormation: one GPU EC2 instance running [vLLM in Docker](#why-vllm). Connect from your laptop through an AWS Systems Manager (SSM) port-forwarding tunnel. The instance has no public IP and no inbound rules.

The defaults serve gpt-oss-20b on a g5.xlarge Spot instance in us-west-2, using `vllm/vllm-openai:v0.30.0`. You can [switch models](docs/switching-models.md) without replacing the instance; larger models need a g6e.xlarge.

Expect noticeably weaker results than hosted Claude on multi-step tasks, especially with small models like the default.

## What it costs

Stopping the instance doesn't stop all charges: the NAT gateway, root volume and API key secret bill as long as their stacks exist.

For pauses of more than a few weeks, tear down both stacks with `scripts/teardown.sh`.

| Item                                | Rate             | Bills when                                     |
| ----------------------------------- | ---------------- | ---------------------------------------------- |
| g5.xlarge Spot                      | about $0.49/hour | the instance is running                        |
| g6e.xlarge On-Demand, if you switch | about $1.86/hour | the instance is running                        |
| NAT gateway and Elastic IP          | about $37/month  | the network stack exists (standalone VPC only) |
| 200 GB gp3 root volume, 500 MB/s    | about $31/month  | the compute stack exists                       |
| API key secret (Secrets Manager)    | $0.40/month      | the compute stack exists                       |

Downloads through the NAT cost $0.045/GB (about $0.60 for gpt-oss-20b's weights), plus $0.01/GB from another AZ. Rates are for us-west-2 as of September 2026.

## Docs

- [Deployment](docs/deployment.md): start here. GPU quota (many accounts start with none), then deploying into a new or existing VPC.
- [Switching models](docs/switching-models.md): changing the model
- [Network](docs/network.md): moving to another AZ
- [Updating the compute stack](docs/updating-compute.md): other changes
- [Claude Code](docs/claude-code.md): using the endpoint from the Claude Code CLI

## Daily use

Once it's deployed, look up the instance ID:

```bash
INSTANCE_ID=$(aws cloudformation describe-stacks --region us-west-2 --stack-name vllm-compute \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
```

1. Start the instance. The model is ready about 3 minutes later. On Spot, a start right after a stop fails for a few minutes; see [Spot behavior](#spot-behavior).

   ```bash
   aws ec2 start-instances --region us-west-2 --instance-ids $INSTANCE_ID
   ```

2. Open the tunnel in a second terminal and leave it running: `scripts/connect.sh`.
3. Set up the alias in [Claude Code](docs/claude-code.md#run-it), then run `claude-local` from your project directory.
4. When you're done, close the tunnel and stop the instance:

   ```bash
   aws ec2 stop-instances --region us-west-2 --instance-ids $INSTANCE_ID
   ```

## Spot behavior

`PurchaseOption` in `compute.yaml` defaults to `spot`: g5.xlarge Spot cost about half of On-Demand in September 2026. g6e.xlarge Spot cost the same as On-Demand then, so use `ondemand` for it. Changing `PurchaseOption` [replaces the instance](docs/updating-compute.md). The trade-offs of Spot:

- **EC2 can stop the instance at any time** when it needs the capacity back, with two minutes' notice. Any request in progress fails, and your client has to retry once the instance is back.
- **EC2 restarts the instance on its own** when capacity returns, even if you're away, and it bills while it runs. If you've been interrupted, check whether it's running (`scripts/connect.sh` reports its state), and stop it if you're done.
- **A start can fail** if no Spot capacity is available at that moment. Right after a stop, it also fails with `IncorrectSpotRequestState` until the Spot request catches up, which took about 4.5 minutes in September 2026.
- **The Spot request expires on 2027-12-31** (`ValidUntil` in `compute.yaml`). After that you can no longer stop and start the instance. Change the date if you need longer, which replaces the instance.
- **A stopped Spot instance can't change instance type.** Changing `InstanceType` through a stack update replaces the instance instead.

## Security notes

- **No inbound access.** The instance has no public IP, its security group allows no inbound traffic, and vLLM listens only on the instance's localhost. The only way in is an SSM session, which IAM controls and CloudTrail logs.
- **The API key covers only some paths.** It protects `/v1`, `/v2`, and `/inference`. Other vLLM endpoints, including `/invocations` (which also runs inference), don't check it.
- **The API key is in Secrets Manager.** The stack generates it, and vLLM reads it at startup. Anyone with `secretsmanager:GetSecretValue` on it can read it (AWS's ReadOnlyAccess policy doesn't grant that), as can root or Docker users on the instance.
- **Close the tunnel when you're done.** While it's open, any program on your laptop can reach `localhost:8000`, including the endpoints the key doesn't cover.
- **Logs stay on the instance.** vLLM logs to the systemd journal on the root volume, which is deleted when the instance is replaced or torn down.

## Why vLLM

The model runs in [vLLM](https://docs.vllm.ai), using the official `vllm/vllm-openai` Docker image. It provides:

- **Many requests at once on one GPU.** vLLM batches concurrent requests against one copy of the model, whether they come from several people or one Claude Code session running several at once.
- **The APIs the clients need.** It serves the Anthropic Messages API for Claude Code and the Responses API for Codex, with a tool-call parser for each model family.
- **Official checkpoints.** Many open models publish FP8, MXFP4, or NVFP4 weights that vLLM loads straight from Hugging Face, with no conversion.
- **A path to ECS.** [ECS Managed Instances](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ManagedInstances.html) runs containers, so the same pinned image and startup flags carry over to a shared service.

For one person trying out models on a single machine, [Ollama](https://ollama.com) is a simpler setup.
