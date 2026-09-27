#!/usr/bin/env bash
# Open an SSM session to the vLLM instance.
# Usage: scripts/connect.sh [local-port]   tunnel to vLLM, local port defaults to 8000
#        scripts/connect.sh shell          shell on the instance
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
COMPUTE_STACK=vllm-compute
REMOTE_PORT=8000

mode=tunnel
local_port=$REMOTE_PORT
case "${1:-}" in
  "") ;;
  shell) mode=shell ;;
  *[!0-9]*) echo "Usage: $0 [local-port] | $0 shell" >&2; exit 1 ;;
  *) local_port=$1 ;;
esac

instance_id=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$COMPUTE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text 2>/dev/null) || {
  echo "Stack $COMPUTE_STACK not found in $REGION. Deploy it first." >&2
  exit 1
}

state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$instance_id" \
  --query "Reservations[0].Instances[0].State.Name" --output text)
if [[ "$state" != "running" ]]; then
  echo "Instance $instance_id is $state. Start it with:" >&2
  echo "  aws ec2 start-instances --region $REGION --instance-ids $instance_id" >&2
  exit 1
fi

if [[ "$mode" == "shell" ]]; then
  exec aws ssm start-session --region "$REGION" --target "$instance_id"
fi

echo "Forwarding localhost:$local_port to port $REMOTE_PORT on $instance_id. Press Ctrl-C to close."
exec aws ssm start-session --region "$REGION" --target "$instance_id" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"$REMOTE_PORT\"],\"localPortNumber\":[\"$local_port\"]}"
