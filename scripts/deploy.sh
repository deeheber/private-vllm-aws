#!/usr/bin/env bash
# Deploy the vLLM stacks. Usage: scripts/deploy.sh network|compute|all
set -euo pipefail
cd "$(dirname "$0")/.."

REGION="${AWS_REGION:-us-west-2}"
NETWORK_STACK=vllm-network
COMPUTE_STACK=vllm-compute
NETWORK_TEMPLATE=stacks/network/network.yaml
NETWORK_PARAMS=stacks/network/network-params.json
COMPUTE_TEMPLATE=stacks/compute/compute.yaml
COMPUTE_PARAMS=stacks/compute/compute-params.json

usage() {
  echo "Usage: $0 network|compute|all" >&2
  exit 1
}

stack_exists() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" >/dev/null 2>&1
}

stack_output() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

cancel_spot_request() {
  local instance_id sir
  instance_id=$(stack_output "$COMPUTE_STACK" InstanceId)
  sir=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$instance_id" \
    --query "Reservations[0].Instances[0].SpotInstanceRequestId" --output text 2>/dev/null) || sir=None
  if [[ -z "$sir" || "$sir" == "None" ]]; then
    echo "No Spot request to cancel."
    return
  fi
  aws ec2 cancel-spot-instance-requests --region "$REGION" --spot-instance-request-ids "$sir" >/dev/null
  echo "Cancelled Spot request $sir."
}

deploy_network() {
  aws cloudformation deploy --region "$REGION" \
    --stack-name "$NETWORK_STACK" \
    --template-file "$NETWORK_TEMPLATE" \
    --parameter-overrides file://"$NETWORK_PARAMS" \
    --no-fail-on-empty-changeset

  (
    umask 077
    jq --arg v "$(stack_output "$NETWORK_STACK" VpcId)" \
       --arg s "$(stack_output "$NETWORK_STACK" PrivateSubnetId)" \
      'map(if .ParameterKey=="VpcId" then .ParameterValue=$v
           elif .ParameterKey=="SubnetId" then .ParameterValue=$s else . end)' \
      "$COMPUTE_PARAMS" > "$COMPUTE_PARAMS.tmp"
    mv "$COMPUTE_PARAMS.tmp" "$COMPUTE_PARAMS"
  )
  echo "Wrote VpcId and SubnetId to $COMPUTE_PARAMS."
}

deploy_compute() {
  if grep -q '"SET_' "$COMPUTE_PARAMS" || grep -q '"ParameterValue": ""' "$COMPUTE_PARAMS"; then
    echo "$COMPUTE_PARAMS still has placeholder or empty values. See docs/deployment.md step 1." >&2
    exit 1
  fi

  local status
  status=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$COMPUTE_STACK" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null) || status=NONE
  if [[ "$status" == "ROLLBACK_COMPLETE" ]]; then
    echo "The first deploy of $COMPUTE_STACK failed and rolled back. Run scripts/teardown.sh (it also deletes the network stack, if any), fix the cause, then run this again." >&2
    exit 1
  fi

  if [[ "$status" == "NONE" ]]; then
    aws cloudformation deploy --region "$REGION" \
      --stack-name "$COMPUTE_STACK" \
      --template-file "$COMPUTE_TEMPLATE" \
      --parameter-overrides file://"$COMPUTE_PARAMS" \
      --capabilities CAPABILITY_IAM
    return
  fi

  # A change set shows whether the instance gets replaced. On Spot, the Spot request
  # must be cancelled first or EC2 launches an extra instance outside the stack.
  local change_set
  change_set="deploy-$(date +%Y%m%d%H%M%S)"
  aws cloudformation create-change-set --region "$REGION" \
    --stack-name "$COMPUTE_STACK" \
    --change-set-name "$change_set" \
    --template-body file://"$COMPUTE_TEMPLATE" \
    --parameters file://"$COMPUTE_PARAMS" \
    --capabilities CAPABILITY_IAM >/dev/null

  if ! aws cloudformation wait change-set-create-complete --region "$REGION" \
      --stack-name "$COMPUTE_STACK" --change-set-name "$change_set" 2>/dev/null; then
    local reason
    reason=$(aws cloudformation describe-change-set --region "$REGION" \
      --stack-name "$COMPUTE_STACK" --change-set-name "$change_set" \
      --query StatusReason --output text)
    aws cloudformation delete-change-set --region "$REGION" \
      --stack-name "$COMPUTE_STACK" --change-set-name "$change_set"
    if [[ "$reason" == *"didn't contain changes"* || "$reason" == *"No updates"* ]]; then
      echo "No changes to deploy."
      return
    fi
    echo "Change set failed: $reason" >&2
    exit 1
  fi

  local replacement
  replacement=$(aws cloudformation describe-change-set --region "$REGION" \
    --stack-name "$COMPUTE_STACK" --change-set-name "$change_set" \
    --query "Changes[?ResourceChange.LogicalResourceId=='Instance'].ResourceChange.Replacement" \
    --output text)

  if [[ "$replacement" == "True" || "$replacement" == "Conditional" ]]; then
    echo "This update replaces the instance: the weights download again and the instance ID changes."
    read -r -p "Continue? [y/N] " answer
    if [[ "$answer" != "y" ]]; then
      aws cloudformation delete-change-set --region "$REGION" \
        --stack-name "$COMPUTE_STACK" --change-set-name "$change_set"
      echo "Cancelled. Nothing changed."
      exit 1
    fi
    cancel_spot_request
  fi

  aws cloudformation execute-change-set --region "$REGION" \
    --stack-name "$COMPUTE_STACK" --change-set-name "$change_set"
  echo "Updating $COMPUTE_STACK..."
  if ! aws cloudformation wait stack-update-complete --region "$REGION" --stack-name "$COMPUTE_STACK"; then
    echo "Update failed. Fix the cause and run this again; see docs/updating-compute.md." >&2
    exit 1
  fi
  echo "Updated $COMPUTE_STACK."

  if [[ "$replacement" == "True" || "$replacement" == "Conditional" ]]; then
    echo "Open Spot requests (expect only the new instance's):"
    aws ec2 describe-spot-instance-requests --region "$REGION" \
      --filters Name=state,Values=open,active,disabled \
      --query "SpotInstanceRequests[].{id:SpotInstanceRequestId,state:State,instance:InstanceId}" \
      --output table
  fi
}

require_file() {
  [[ -f "$1" ]] || { echo "Missing $1. See docs/deployment.md step 1." >&2; exit 1; }
}

case "${1:-}" in network|compute|all) require_file "$COMPUTE_PARAMS" ;; esac
case "${1:-}" in network|all) require_file "$NETWORK_PARAMS" ;; esac

case "${1:-}" in
  network) deploy_network ;;
  compute) deploy_compute ;;
  all) deploy_network; deploy_compute ;;
  *) usage ;;
esac
