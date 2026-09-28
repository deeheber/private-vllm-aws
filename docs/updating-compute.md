# Updating the compute stack

What an update does depends on which values in `compute-params.json` change:

- **The model profile** (`VllmTag`, `ModelId`, `ServedModelName`, `ToolCallParser`, `MaxModelLen`, `ExtraVllmArgs`) lives in an SSM parameter. Changing it doesn't touch the instance. See [Switching models](switching-models.md).
- **Everything else** (`InstanceType`, `PurchaseOption`, `ImageId`, `RootVolumeThroughput`, the VPC and subnet) feeds the instance or its launch template, so changing it replaces the instance. So does pulling a new version of `compute.yaml` that changes the launch template. To move to another AZ, see [Network](network.md#switching-azs).

A replacement means:

- **Downtime.** The new instance pulls the vLLM image and downloads the weights again (about 14 GB for gpt-oss-20b), so expect about 10 minutes, or about 20 with `RootVolumeThroughput` at 125.
- **A new instance ID.** `scripts/connect.sh` looks it up each time, but re-run the `INSTANCE_ID=` lookup in [Stop and start](deployment.md#stop-and-start) for any commands you keep around.
- **On Spot, cancelling the Spot request first.** `deploy.sh` does this for you; see [Why the Spot request gets cancelled](#why-the-spot-request-gets-cancelled).

Batch replacing changes into one update where you can, for example a new AMI and a new instance type together, so the instance is replaced once.

## Steps

1. Edit the values in `stacks/compute/compute-params.json`.
2. Run `scripts/deploy.sh compute`. It asks before replacing the instance and handles the Spot request. If only the model profile changed, it says to run `scripts/switch-model.sh`.
3. Run the checks in [Check that it works](deployment.md#3-check-that-it-works).

If the update fails and rolls back, fix the cause and run the script again. The old instance can no longer be stopped once its Spot request is cancelled.

## Updating vLLM

`VllmTag` pins the `vllm/vllm-openai` image. To upgrade, deploy the new tag, then run `scripts/switch-model.sh`. The first start on a new tag pulls its image, which took about 15 minutes for v0.30.0. The old image stays on disk until you remove it; `scripts/switch-model.sh list` shows both.

Set it to a newer tag from the [vLLM releases](https://github.com/vllm-project/vllm/releases). Before deploying, check the release notes for:

- **The CUDA version of the default image.** If it needs a newer NVIDIA driver than your AMI has, update the AMI too (see below). That replaces the instance.
- **Breaking changes to the flags** in your profile, such as `--tool-call-parser` or anything in `ExtraVllmArgs`.

## Updating the AMI

`ImageId` is pinned, so the host OS and NVIDIA driver change only when you change it. To move to the latest Deep Learning AMI, look up its ID:

```bash
aws ssm get-parameter --region us-west-2 \
  --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id \
  --query Parameter.Value --output text
```

If it matches `ImageId` in `compute-params.json`, you're current. Otherwise, check the [release notes](https://docs.aws.amazon.com/dlami/latest/devguide/aws-deep-learning-x86-base-gpu-ami-ubuntu-22-04.html) for the driver version. vLLM's default CUDA 13 images need driver R580 or newer. Then set the new ID as `ImageId` and follow the steps above.

A good time to update is when a new vLLM release needs a newer driver, or every month or two for security fixes.

## Rotating the API key

To replace the key with a new random one:

```bash
SECRET=$(aws cloudformation describe-stacks --region us-west-2 --stack-name vllm-compute \
  --query "Stacks[0].Outputs[?OutputKey=='ApiKeySecretArn'].OutputValue" --output text)
aws secretsmanager put-secret-value --region us-west-2 --secret-id "$SECRET" \
  --secret-string "$(aws secretsmanager get-random-password --region us-west-2 \
    --password-length 64 --exclude-punctuation --query RandomPassword --output text)"
scripts/switch-model.sh
```

vLLM reads the key when it starts, so the restart is what makes the new key take effect. `scripts/claude-local.sh` reads the key each time it runs.

## Why the Spot request gets cancelled

A Spot instance comes from a persistent Spot request, which EC2 keeps fulfilling until you cancel it. If CloudFormation terminates the instance while the request is still open, EC2 can launch another one that the stack doesn't track. `deploy.sh` and `teardown.sh` cancel the request before replacing or deleting the instance.

If the instance is stopped when the request is cancelled, EC2 terminates it within a few minutes (about 2.5 in September 2026). That's expected, since it's being replaced or deleted anyway.

If you change or delete the stack outside the scripts, cancel the request yourself first: EC2 console, Spot Requests, select the request, Actions, Cancel request.
