# Updating the compute stack

Every value in `compute-params.json` feeds the instance or its launch template, so changing any of them replaces the instance. So does pulling a new version of `compute.yaml` that changes the launch template.

A replacement means:

- **Downtime.** The new instance pulls the vLLM image and downloads the weights again (about 14 GB for gpt-oss-20b), so expect several minutes.
- **A new instance ID.** `scripts/connect.sh` looks it up each time, but re-run the lookup for any commands you keep around.
- **On Spot, cancelling the Spot request first.** `deploy.sh` does this for you; see [Why the Spot request gets cancelled](#why-the-spot-request-gets-cancelled).

Batch changes into one update where you can, for example a new AMI and a new vLLM tag together, so the instance is replaced once.

## Steps

1. Edit the values in `stacks/compute/compute-params.json`.
2. Run `scripts/deploy.sh compute`. It asks before replacing the instance and handles the Spot request.
3. Run the checks in [Check that it works](../README.md#3-check-that-it-works).

If the update fails and rolls back, fix the cause and run the script again. The old instance can no longer be stopped once its Spot request is cancelled.

## Updating vLLM

`VllmTag` pins the `vllm/vllm-openai` image. To upgrade, set it to a newer tag from the [vLLM releases](https://github.com/vllm-project/vllm/releases). Before deploying, check the release notes for:

- **The CUDA version of the default image.** If it needs a newer NVIDIA driver than your AMI has, update the AMI in the same deploy (see below).
- **Breaking changes to the flags** that `compute.yaml` passes in its user data, such as `--tool-call-parser` or `--enable-auto-tool-choice`.

## Updating the AMI

`ImageId` is pinned, so the host OS and NVIDIA driver change only when you change it. To move to the latest Deep Learning AMI, look up its ID:

```bash
aws ssm get-parameter --region us-west-2 \
  --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id \
  --query Parameter.Value --output text
```

If it matches `ImageId` in `compute-params.json`, you're current. Otherwise, check the [release notes](https://docs.aws.amazon.com/dlami/latest/devguide/aws-deep-learning-x86-base-gpu-ami-ubuntu-22-04.html) for the driver version. vLLM's default CUDA 13 images need driver R580 or newer. Then set the new ID as `ImageId` and follow the steps above.

A good time to update is when a new vLLM release needs a newer driver, or every month or two for security fixes.

## Faster replacements

A new instance spends a while extracting the vLLM image, limited by the root volume's default 125 MB/s. In September 2026, with vLLM v0.30.0 on g5.xlarge, that took about 10 minutes of a 22-minute first boot. Before a stretch of replacing updates, like swapping models, set `RootVolumeThroughput` to 500 in `compute-params.json`. At September 2026 us-west-2 prices, that costs about $15 a month and should cut first boot by roughly 7 minutes. Stop/start only gets about a minute faster.

Changing it replaces the instance, so raise it in the same update as the first swap and set it back to 125 with the last one.

## Why the Spot request gets cancelled

A Spot instance comes from a persistent Spot request, which EC2 keeps fulfilling until you cancel it. If CloudFormation terminates the instance while the request is still open, EC2 can launch another one that the stack doesn't track. `deploy.sh` and `teardown.sh` cancel the request before replacing or deleting the instance.

If the instance is stopped when the request is cancelled, EC2 terminates it right away. That's expected, since it's being replaced or deleted anyway.

If you change or delete the stack outside the scripts, cancel the request yourself first: EC2 console, Spot Requests, select the request, Actions, Cancel request.
