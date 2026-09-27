# private-vllm-aws

CloudFormation for a private, self-hosted LLM endpoint on AWS: one GPU EC2 instance running vLLM in Docker, reached from your laptop through an SSM port-forwarding tunnel. The instance has no public IP and no inbound rules.

The defaults serve gpt-oss-20b on a g5.xlarge Spot instance in us-west-2, using `vllm/vllm-openai:v0.30.0`.

## What it costs

| Item | Rate | Bills when |
|---|---|---|
| g5.xlarge Spot | about $0.48/hour | the instance is running |
| NAT gateway and Elastic IP | about $37/month | the network stack exists, even with the instance stopped |
| 150 GB gp3 root volume | about $12/month | the compute stack exists |

Rates are for us-west-2 as of September 2026. For pauses of more than a few weeks, tear down both stacks.

## Spot behavior

The instance defaults to Spot, which costs about half as much as On-Demand. The trade-offs:

- **EC2 can stop the instance at any time** when it needs the capacity back, with two minutes' notice. Any request in progress fails, and your client has to retry once the instance is back.
- **EC2 restarts the instance on its own** when capacity returns, even if you're away, and it bills while it runs. Check for a running instance if you've been interrupted, and stop it if you're done.
- **A start can fail** if no Spot capacity is available at that moment.
- **The Spot request expires on 2027-12-31** (`ValidUntil` in `compute.yaml`). After that you can no longer stop and start the instance. Change the date if you need longer.
- **A stopped Spot instance can't change instance type.** Changing `InstanceType` through a stack update replaces the instance instead.

For predictable availability, set `PurchaseOption` to `ondemand` in `compute-params.json` and [update the stack](docs/updating-compute.md). That update replaces the instance.

## Before you start

- **GPU quota.** New accounts usually have 0 vCPUs for G instances. Request 8 for "Running On-Demand G and VT instances" (L-DB2E81BA) and "All G and VT Spot Instance Requests" (L-3819A6DF) in your region, and wait for approval. One xlarge instance uses 4, but an update that replaces the instance runs the old and new ones together for a few minutes.
- **AWS credentials.** The CLI needs credentials that can manage CloudFormation, EC2, IAM, and Systems Manager, such as an admin profile. If you use named profiles, set `AWS_PROFILE`.
- **Region.** Everything defaults to us-west-2. For another region, set `AWS_REGION` before running the scripts, and change `--region` in the commands below.

Tools on your laptop:

| Tool | Used for | Install on macOS |
|---|---|---|
| AWS CLI v2 | everything | `brew install awscli` |
| Session Manager plugin | `scripts/connect.sh` | `brew install --cask session-manager-plugin` |
| `jq` | the scripts and setup commands | `brew install jq` |
| `openssl`, `curl` | the API key and the step 3 checks | included with macOS |

On Linux or Windows, see the install guides for the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

## Choose a deploy path

- **Standalone VPC:** deploy both stacks. `network.yaml` creates a single-AZ VPC with a public subnet for a NAT gateway and a private subnet for the instance. Use this path if you don't already have a VPC with private subnets.
- **Existing VPC:** deploy only `compute.yaml`, into a private subnet that already has outbound HTTPS through a NAT or transit gateway.

Each stack's template and parameter files are in `stacks/network/` and `stacks/compute/`. The scripts to deploy, connect, and tear down are in `scripts/`. Run all commands from the repo root.

## 1. Create your parameter files

| File | Committed | Contents |
|---|---|---|
| `stacks/network/network-params.example.json` | yes | template for the network parameters |
| `stacks/network/network-params.json` | no, gitignored | your AZ for the standalone VPC |
| `stacks/compute/compute-params.example.json` | yes | template for the compute parameters |
| `stacks/compute/compute-params.json` | no, gitignored | your compute parameters, including the API key |

Create `compute-params.json` with a new random API key and the current Deep Learning AMI:

```bash
umask 077
AMI=$(aws ssm get-parameter --region us-west-2 \
  --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id \
  --query Parameter.Value --output text)
jq --arg k "$(openssl rand -hex 32)" --arg a "$AMI" \
  'map(if .ParameterKey=="ApiKey" then .ParameterValue=$k
       elif .ParameterKey=="ImageId" then .ParameterValue=$a else . end)' \
  stacks/compute/compute-params.example.json > stacks/compute/compute-params.json
```

The AMI stays pinned to that ID until you change it. See [Updating the compute stack](docs/updating-compute.md).

Next, pick an AZ. Spot placement scores rate each AZ from 1 to 10 for how likely a Spot request is to succeed. Check each instance type you plan to use, one at a time:

```bash
aws ec2 get-spot-placement-scores --region us-west-2 \
  --instance-types g5.xlarge --target-capacity 1 \
  --single-availability-zone --region-names us-west-2 \
  --query "SpotPlacementScores[].[AvailabilityZoneId,Score]" --output table
```

The scores list AZ IDs (like `usw2-az1`), but the templates need AZ names (like `us-west-2a`). The mapping differs between accounts, so look up the name for the ID you chose. For the standalone VPC, write it to `network-params.json`:

```bash
AZ=$(aws ec2 describe-availability-zones --region us-west-2 --zone-ids usw2-az1 \
  --query "AvailabilityZones[0].ZoneName" --output text)
jq --arg az "$AZ" 'map(.ParameterValue=$az)' \
  stacks/network/network-params.example.json > stacks/network/network-params.json
```

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

The first boot pulls the image and downloads the model weights (about 14 GB for gpt-oss-20b). Expect several minutes before the model answers.

1. **The model has loaded.** Run `scripts/connect.sh shell`, then `sudo docker logs -f vllm` on the instance. If the session fails with `TargetNotConnected`, the SSM agent hasn't registered yet; wait a minute and retry.
2. **The endpoint answers.** Run `scripts/connect.sh` in its own terminal to open the tunnel to port 8000, then run the commands below. If 8000 is taken on your laptop, pass another local port, like `scripts/connect.sh 9000`, and use it in the commands.

   ```bash
   curl -i localhost:8000/health

   KEY=$(jq -r '.[] | select(.ParameterKey=="ApiKey").ParameterValue' stacks/compute/compute-params.json)
   curl -s localhost:8000/v1/messages \
     -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
     -d '{"model":"gpt-oss-20b","max_tokens":256,"messages":[{"role":"user","content":"Reply with OK."}]}'
   ```

`/health` only shows that the server has started. Neither check covers streaming or tool calls; connecting a client such as Claude Code does.

The API key protects only paths under `/v1`, `/v2`, and `/inference`. Other vLLM endpoints, including `/invocations` (which also runs inference), don't check it. The server stays private because its port listens only on the instance's localhost, the security group allows no inbound traffic, and reaching it takes an SSM session that IAM controls. While your tunnel is open, any program on your laptop can reach `localhost:8000`, so close the tunnel when you're done.

## Stop and start

```bash
INSTANCE_ID=$(aws cloudformation describe-stacks --region us-west-2 --stack-name vllm-compute \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
aws ec2 stop-instances  --region us-west-2 --instance-ids $INSTANCE_ID
aws ec2 start-instances --region us-west-2 --instance-ids $INSTANCE_ID
```

The model reloads on every start, so expect a few minutes after the instance shows `running`. On Spot, a start succeeds only if capacity is available at that moment. If it fails, retry later or redeploy with `PurchaseOption` set to `ondemand`.

## Updating the stack

Edit `compute-params.json`, then run `scripts/deploy.sh compute`. Changing any value replaces the instance. The script asks before replacing it and cancels the Spot request first. [Updating the compute stack](docs/updating-compute.md) has the details, including how to move to a newer AMI.

## Teardown

```bash
scripts/teardown.sh
```

After you confirm, it cancels the Spot request, deletes the compute stack, then deletes the network stack if there is one. It finishes by warning you about any Spot request still open in the region.
