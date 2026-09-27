#!/usr/bin/env bash
# Delete the vLLM stacks: cancel the Spot request, delete compute, then delete network.
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
NETWORK_STACK=vllm-network
COMPUTE_STACK=vllm-compute

stack_exists() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" >/dev/null 2>&1
}

read -r -p "Delete $COMPUTE_STACK and $NETWORK_STACK in $REGION? [y/N] " answer
[[ "$answer" == "y" ]] || { echo "Cancelled."; exit 1; }

if stack_exists "$COMPUTE_STACK"; then
  # Cancel first, or EC2 relaunches the instance after CloudFormation terminates it.
  instance_id=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$COMPUTE_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
  sir=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$instance_id" \
    --query "Reservations[0].Instances[0].SpotInstanceRequestId" --output text 2>/dev/null) || sir=None
  if [[ -n "$sir" && "$sir" != "None" ]]; then
    aws ec2 cancel-spot-instance-requests --region "$REGION" --spot-instance-request-ids "$sir" >/dev/null
    echo "Cancelled Spot request $sir."
  fi

  echo "Deleting $COMPUTE_STACK..."
  aws cloudformation delete-stack --region "$REGION" --stack-name "$COMPUTE_STACK"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$COMPUTE_STACK"
fi

if stack_exists "$NETWORK_STACK"; then
  echo "Deleting $NETWORK_STACK (the NAT gateway takes a few minutes)..."
  aws cloudformation delete-stack --region "$REGION" --stack-name "$NETWORK_STACK"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$NETWORK_STACK"
fi

# An uncancelled Spot request can launch an instance outside the stack.
leftover=$(aws ec2 describe-spot-instance-requests --region "$REGION" \
  --filters Name=state,Values=open,active,disabled \
  --query "SpotInstanceRequests[].[SpotInstanceRequestId,InstanceId]" --output text)
if [[ -n "$leftover" ]]; then
  echo "Warning: Spot requests are still open in $REGION (request, instance). Some may not be from this stack:" >&2
  echo "$leftover" >&2
  echo "Cancel them and terminate their instances in the EC2 console." >&2
  exit 1
fi
echo "Done. Both stacks are deleted."
