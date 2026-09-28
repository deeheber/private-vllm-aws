# Deployment

Before deploying, read [Security notes](../README.md#security-notes) for what keeps the endpoint private, and [Spot behavior](../README.md#spot-behavior) if you plan to use Spot.

## Before you start

- **GPU quota.** Check your quota for G instances in your region, since many accounts start with 0 vCPUs. You need 8 in the quota for your purchase option: "All G and VT Spot Instance Requests" (L-3819A6DF) for the default Spot, or "Running On-Demand G and VT instances" (L-DB2E81BA) for On-Demand. If it's lower, request an increase and wait for approval. One xlarge instance uses 4, but an update that replaces the instance runs the old and new ones together for a few minutes.
- **AWS credentials.** The CLI needs credentials that can manage CloudFormation, EC2, IAM, Systems Manager, and Secrets Manager, such as an admin profile. If you use named profiles, set `AWS_PROFILE`.
- **Region.** Everything defaults to us-west-2. For another region, set `AWS_REGION` before running the scripts, and change `us-west-2` everywhere it appears in the commands in these docs.

Tools on your laptop:

| Tool | Used for | macOS | Linux |
|---|---|---|---|
| AWS CLI v2 | everything | `brew install awscli` | [install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Session Manager plugin | `scripts/connect.sh` | `brew install --cask session-manager-plugin` | [install guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) |
| `jq` | the scripts and setup commands | `brew install jq` | your package manager, e.g. `apt install jq` |
| `python3` | `scripts/deploy.sh`, to check `ExtraVllmArgs` | included (macOS asks to install the command line tools the first time) | usually included |
| `curl` | step 3 below and `scripts/claude-local.sh` | included | usually included |

The scripts need bash, so on Windows everything runs in [WSL](https://learn.microsoft.com/windows/wsl/install):

1. In PowerShell as administrator, run `wsl --install`, then restart. This installs Ubuntu.
2. Open the Ubuntu terminal and install the tools from the Linux column.
3. Set up AWS credentials inside WSL with `aws configure` or `aws configure sso`. WSL doesn't read the credentials in your Windows home directory.
4. Clone this repo inside WSL and run every command in this guide from the Ubuntu terminal.

## Choose a deploy path

- **Standalone VPC:** deploy both stacks. `network.yaml` creates a VPC with one NAT gateway and private subnets in up to four AZs, so the instance can move between AZs; see [Network](network.md). Use this path if you don't already have a VPC with private subnets.
- **Existing VPC:** deploy only `compute.yaml`, into a private subnet that already has outbound HTTPS through a NAT or transit gateway.

Each stack's template and parameter files are in `stacks/network/` and `stacks/compute/`. The scripts to deploy, connect, and tear down are in `scripts/`. Run all commands from the repo root.

## 1. Create your parameter files

| File | Committed | Contents |
|---|---|---|
| `stacks/network/network-params.example.json` | yes | template for the network parameters |
| `stacks/network/network-params.json` | no, gitignored | your AZs for the standalone VPC |
| `stacks/compute/compute-params.example.json` | yes | template for the compute parameters |
| `stacks/compute/compute-params.json` | no, gitignored | your compute parameters: VPC, subnet, AMI, and model profile |

### Compute parameters

Create `compute-params.json` with the current Deep Learning AMI:

```bash
AMI=$(aws ssm get-parameter --region us-west-2 \
  --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id \
  --query Parameter.Value --output text)
jq --arg a "$AMI" 'map(if .ParameterKey=="ImageId" then .ParameterValue=$a else . end)' \
  stacks/compute/compute-params.example.json > stacks/compute/compute-params.json
```

The AMI stays pinned to that ID until you change it. See [Updating the compute stack](updating-compute.md).

The file also holds the model profile, which defaults to gpt-oss-20b. See [Switching models](switching-models.md).

Secrets Manager generates the API key; the scripts read it automatically.

### Availability Zone

Pick an AZ that offers your instance type, since not every AZ offers every type. List the AZs that offer it:

```bash
aws ec2 describe-instance-type-offerings --region us-west-2 \
  --location-type availability-zone-id \
  --filters Name=instance-type,Values=g5.xlarge \
  --query "InstanceTypeOfferings[].Location" --output text
```

On Spot, also check placement scores. They rate each AZ from 1 to 10 for how likely a Spot request is to succeed, and they say nothing about On-Demand. List at least three instance types, or EC2 returns a low score:

```bash
aws ec2 get-spot-placement-scores --region us-west-2 \
  --instance-types g5.xlarge g5.2xlarge g5.4xlarge --target-capacity 1 \
  --single-availability-zone --region-names us-west-2 \
  --query "SpotPlacementScores[].[AvailabilityZoneId,Score]" --output table
```

Both commands list AZ IDs (like `usw2-az1`), but the templates need AZ names (like `us-west-2a`). The mapping differs between accounts, so look up the name for the ID you chose. For the standalone VPC, write it to `network-params.json` as the AZ for the NAT and first private subnet:

```bash
ZONE_ID=usw2-az1   # the AZ ID you chose
AZ=$(aws ec2 describe-availability-zones --region us-west-2 --zone-ids "$ZONE_ID" \
  --query "AvailabilityZones[0].ZoneName" --output text)
jq --arg az "$AZ" 'map(if .ParameterKey=="AvailabilityZone" then .ParameterValue=$az else . end)' \
  stacks/network/network-params.example.json > stacks/network/network-params.json
```

To move the instance to another AZ later, set `PrivateSubnetAz2`, `PrivateSubnetAz3`, and `PrivateSubnetAz4` in `network-params.json` to other AZ names that offer the instance type. See [Network](network.md).

## 2a. Deploy: standalone VPC

```bash
scripts/deploy.sh all
```

This deploys the network stack, copies its VPC and subnet IDs into `compute-params.json`, then deploys the compute stack. `scripts/deploy.sh network` and `scripts/deploy.sh compute` run one stack at a time.

## 2b. Deploy: existing VPC

In `compute-params.json`, set `VpcId` to your VPC and `SubnetId` to a private subnet in your chosen AZ. The subnet needs outbound HTTPS for the SSM agent, the image pull, and the model download. Then deploy only the compute stack:

```bash
scripts/deploy.sh compute
```

## 3. Check that it works

The first boot pulls the vLLM image and downloads the model weights (about 14 GB for gpt-oss-20b). Expect about 10 minutes before the model answers (about 20 if you set `RootVolumeThroughput` to 125).

1. **The model has loaded.** Run `scripts/connect.sh shell`, then `sudo journalctl -u vllm -f` on the instance, and wait for `Application startup complete`. The journal also shows errors from reading the model profile or API key. If the session fails with `TargetNotConnected`, the SSM agent hasn't registered yet; wait a minute and retry.
2. **The endpoint answers.** Run `scripts/connect.sh` in its own terminal to open the tunnel to port 8000, then run the commands below, with your `ServedModelName` as `"model"`. If 8000 is taken on your laptop, pass another local port, like `scripts/connect.sh 9000`, and use it in the commands.

   ```bash
   curl -i localhost:8000/health

   SECRET=$(aws cloudformation describe-stacks --region us-west-2 --stack-name vllm-compute \
     --query "Stacks[0].Outputs[?OutputKey=='ApiKeySecretArn'].OutputValue" --output text)
   KEY=$(aws secretsmanager get-secret-value --region us-west-2 --secret-id "$SECRET" \
     --query SecretString --output text)
   curl -s localhost:8000/v1/messages \
     -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
     -d '{"model":"gpt-oss-20b","max_tokens":256,"messages":[{"role":"user","content":"Reply with OK."}]}'
   ```

`/health` only shows that the server has started. Neither check covers streaming or tool calls.

## 4. Connect a client

For Claude Code, see [Claude Code](claude-code.md). Codex setup is coming later.

## After deploying

### Stop and start

The commands are in [Daily use](../README.md#daily-use). The model reloads on every start, using the model profile deployed at that time, so expect a few minutes after the instance shows `running`. On Spot, a start can fail; see [Spot behavior](../README.md#spot-behavior).

### Updating the stack

To change the model, see [Switching models](switching-models.md); it doesn't replace the instance. For other parameters or a newer AMI, see [Updating the compute stack](updating-compute.md).

### Teardown

```bash
scripts/teardown.sh
```

After you confirm, it cancels the Spot request if there is one, deletes the compute stack (including the model profile and the API key secret), then deletes the network stack if there is one. It finishes by warning you about any Spot request still open in the region.
