# Network

`stacks/network/network.yaml` creates a standalone VPC with one NAT gateway, in the AZ set by `AvailabilityZone`, and private subnets in up to four AZs. All the private subnets route outbound traffic through that one NAT. Skip this stack if you bring your own VPC.

## Switching AZs

A launch can fail because EC2 has no capacity for the instance type in the current AZ. To move the instance to another AZ, the network stack needs a private subnet there. If it doesn't have one, set one of `PrivateSubnetAz2`, `PrivateSubnetAz3`, or `PrivateSubnetAz4` in `network-params.json` to that AZ's name and run `scripts/deploy.sh network`. Then:

```bash
scripts/deploy.sh use-az us-west-2b
scripts/deploy.sh compute
```

`use-az` sets `SubnetId` in `compute-params.json` to the private subnet in that AZ. The deploy replaces the instance, as any AZ move must, because the root volume belongs to one AZ.

- `use-az` only moves the instance. The NAT stays in `AvailabilityZone`.
- Don't change or clear a `PrivateSubnetAz` value while the instance is in that subnet: the subnet would be replaced or deleted, and the update fails.

If a compute deploy fails on capacity:

- **An update** rolls back to `UPDATE_ROLLBACK_COMPLETE`. Wait for that state, then `use-az` another AZ and deploy again.
- **A first deploy** ends in `ROLLBACK_COMPLETE`. Delete only the compute stack, as `deploy.sh` explains, then retry.
- **`UPDATE_ROLLBACK_FAILED`** needs `aws cloudformation continue-update-rollback --stack-name vllm-compute` before anything else.

## Finding capacity

Larger GPU types can have no On-Demand capacity in any AZ of a region for days. Instead of retrying deploys, which take minutes each to fail, look for capacity with a capacity reservation:

```bash
scripts/find-capacity.sh us-west-2 us-east-1
```

It tries each AZ that offers the instance type in `compute-params.json` and stops at the first success. A failed attempt takes seconds and costs nothing. A successful one creates a reservation, which an On-Demand instance of that type in that AZ uses automatically.

- **A reservation bills from the moment it's created,** at the On-Demand rate, whether or not an instance uses it. It ends after an hour, enough to deploy right away; cancel it early if you don't deploy. Once it ends, a running instance keeps running, but a later stop and start needs capacity again.
- **Only On-Demand can use it.** Spot can't be reserved, so for Spot, check placement scores instead (see [Deployment](deployment.md#availability-zone)).
- **Before trying another region,** check its G quota there (see [Deployment](deployment.md#before-you-start)).

## One NAT gateway: the trade-off

One NAT gateway costs one hourly charge, about $33 a month plus its Elastic IP, however many AZs route through it. The costs of sharing it:

- **Cross-AZ traffic.** When the instance isn't in the NAT's AZ, outbound traffic pays about $0.01/GB each way between AZs, around $0.28 for gpt-oss-20b's 14 GB of weights.
- **Two AZs to depend on.** With the instance in us-west-2b and the NAT in us-west-2a, losing 2b loses the instance, and losing 2a loses outbound access, including SSM. This repo accepts that for the lower cost.

## Removing the single-AZ dependency

- **A NAT gateway per AZ.** The standard production layout: each AZ's private subnet routes through its own NAT, at one hourly charge per AZ.
- **A regional NAT gateway** (`AvailabilityMode: regional`). One NAT that spans AZs, with no public subnet or hand-allocated Elastic IPs.
  - It's billed per AZ it runs in, and expanding into a new AZ can take up to 60 minutes.
  - AWS's docs differ on what makes it run in an AZ: the [VPC User Guide](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html) says a network interface there, while the [CloudFormation reference](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-natgateway.html) says every AZ with a subnet. With subnets in four AZs, that difference could mean four hourly charges.
  - Untested here.
