# private-vllm-aws

CloudFormation for a private, self-hosted LLM endpoint on AWS, for coding clients like Claude Code: one GPU EC2 instance running [vLLM in Docker](#model-server), reached from your laptop through an AWS Systems Manager (SSM) port-forwarding tunnel. The instance has no public IP and no inbound rules.

The defaults serve gpt-oss-20b on a g5.xlarge Spot instance in us-west-2, using `vllm/vllm-openai:v0.30.0`.

## What it costs

Stopping the instance doesn't stop all charges: the NAT gateway and root volume bill as long as their stacks exist.

For pauses of more than a few weeks, tear down both stacks with `scripts/teardown.sh`.

| Item                               | Rate             | Bills when                                     |
| ---------------------------------- | ---------------- | ---------------------------------------------- |
| g5.xlarge Spot                     | about $0.48/hour | the instance is running                        |
| g5.xlarge On-Demand, if you switch | about $1.01/hour | the instance is running                        |
| NAT gateway and Elastic IP         | about $37/month  | the network stack exists (standalone VPC only) |
| 150 GB gp3 root volume             | about $12/month  | the compute stack exists                       |

Each new instance also downloads the image and weights through the NAT gateway, at $0.045/GB, which comes to about $1. Rates are for us-west-2 as of September 2026.

## Deploying

First, check that your account has quota for GPU (G-family) instances in your region. Many accounts start with none, and approval can take a while.

There are two ways to deploy: a standalone VPC, which deploys both the network and compute stacks, or an existing VPC with private subnets, which deploys only the compute stack.

[Deployment](docs/deployment.md) has the step-by-step instructions, and [Updating the compute stack](docs/updating-compute.md) covers changes after that.

To use the endpoint from the Claude Code CLI, see [Claude Code](docs/claude-code.md).

## Spot behavior

The instance defaults to Spot, which costs about half as much as On-Demand. The trade-offs:

- **EC2 can stop the instance at any time** when it needs the capacity back, with two minutes' notice. Any request in progress fails, and your client has to retry once the instance is back.
- **EC2 restarts the instance on its own** when capacity returns, even if you're away, and it bills while it runs. If you've been interrupted, check whether it's running (`scripts/connect.sh` reports its state), and stop it if you're done.
- **A start can fail** if no Spot capacity is available at that moment.
- **The Spot request expires on 2027-12-31** (`ValidUntil` in `compute.yaml`). After that you can no longer stop and start the instance. Change the date if you need longer, which replaces the instance.
- **A stopped Spot instance can't change instance type.** Changing `InstanceType` through a stack update replaces the instance instead.

For predictable availability, set `PurchaseOption` to `ondemand` in `compute-params.json` and [update the stack](docs/updating-compute.md). That update replaces the instance.

## Security notes

- **No inbound access.** The instance has no public IP, its security group allows no inbound traffic, and vLLM listens only on the instance's localhost. The only way in is an SSM session, which IAM controls and CloudTrail logs.
- **The API key covers only some paths.** It protects `/v1`, `/v2`, and `/inference`. Other vLLM endpoints, including `/invocations` (which also runs inference), don't check it.
- **Close the tunnel when you're done.** While it's open, any program on your laptop can reach `localhost:8000`, including those endpoints.
- **The key is stored in the instance's startup script.** Anyone in the AWS account who can read launch templates or instance user data can see it. For a shared account, keep it in SSM Parameter Store as a SecureString and have the instance read it at boot.
- **Logs stay on the instance.** vLLM's logs go to Docker on the root volume, not CloudWatch, and are deleted when the instance is replaced or torn down.

## Model server

The model runs in [vLLM](https://docs.vllm.ai), using the official `vllm/vllm-openai` Docker image (chosen in September 2026). It provides:

- **Many requests at once on one GPU.** vLLM batches concurrent requests against one copy of the model, whether they come from several people or one Claude Code session running several at once.
- **The APIs the clients need.** It serves the Anthropic Messages API for Claude Code and the Responses API for Codex, with a tool-call parser for each model family.
- **Official checkpoints.** The candidate models publish FP8, MXFP4, and NVFP4 weights that vLLM loads straight from Hugging Face, with no conversion.
- **A path to ECS.** [ECS Managed Instances](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ManagedInstances.html) runs containers, so the same pinned image and startup flags carry over to a shared service.

For one person trying out models on a single machine, [Ollama](https://ollama.com) is a simpler setup.
