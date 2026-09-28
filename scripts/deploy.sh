#!/usr/bin/env bash
# Deploy the vLLM stacks. Usage: scripts/deploy.sh network|compute|all
#        scripts/deploy.sh use-az <az>   point compute-params.json at the private subnet in <az>
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
  echo "Usage: $0 network|compute|all | $0 use-az <az>" >&2
  exit 1
}

stack_exists() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" >/dev/null 2>&1
}

stack_output() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

compute_param() {
  jq -r --arg k "$1" '.[] | select(.ParameterKey==$k).ParameterValue' "$COMPUTE_PARAMS"
}

set_compute_param() {
  (
    umask 077
    jq --arg k "$1" --arg v "$2" 'map(if .ParameterKey==$k then .ParameterValue=$v else . end)' \
      "$COMPUTE_PARAMS" > "$COMPUTE_PARAMS.tmp"
    mv "$COMPUTE_PARAMS.tmp" "$COMPUTE_PARAMS"
  )
}

# The network stack's private subnet IDs, one per line.
network_private_subnets() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$NETWORK_STACK" \
    --query "Stacks[0].Outputs[?starts_with(OutputKey, 'PrivateSubnet')].OutputValue" --output text | tr '\t' '\n'
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
  local state
  state=$(aws ec2 describe-spot-instance-requests --region "$REGION" --spot-instance-request-ids "$sir" \
    --query "SpotInstanceRequests[0].State" --output text 2>/dev/null) || state=unknown
  # Skip only a request that's known to be finished; if unsure, cancel anyway.
  if [[ "$state" == cancelled || "$state" == closed || "$state" == failed ]]; then
    echo "Spot request $sir is already $state."
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

  set_compute_param VpcId "$(stack_output "$NETWORK_STACK" VpcId)"
  # Keep a subnet chosen with use-az; otherwise use the first private subnet.
  if network_private_subnets | grep -qx -- "$(compute_param SubnetId)"; then
    echo "Wrote VpcId to $COMPUTE_PARAMS and kept SubnetId $(compute_param SubnetId)."
  else
    set_compute_param SubnetId "$(stack_output "$NETWORK_STACK" PrivateSubnetId)"
    echo "Wrote VpcId and SubnetId to $COMPUTE_PARAMS."
  fi
}

use_az() {
  local az=$1 network_vpc subnets matches
  if ! stack_exists "$NETWORK_STACK"; then
    echo "Stack $NETWORK_STACK not found in $REGION. With your own VPC, set SubnetId in $COMPUTE_PARAMS by hand." >&2
    exit 1
  fi
  network_vpc=$(stack_output "$NETWORK_STACK" VpcId)
  if [[ "$(compute_param VpcId)" != "$network_vpc" ]]; then
    echo "VpcId in $COMPUTE_PARAMS isn't $NETWORK_STACK's VPC ($network_vpc). Run scripts/deploy.sh network first, or set SubnetId by hand." >&2
    exit 1
  fi
  subnets=$(network_private_subnets | tr '\n' ' ')
  matches=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids $subnets \
    --filters Name=availability-zone,Values="$az" --query "Subnets[].SubnetId" --output text)
  case $(wc -w <<<"$matches" | tr -d ' ') in
    1) ;;
    0)
      echo "$NETWORK_STACK has no private subnet in $az. Its private subnets are in:" >&2
      aws ec2 describe-subnets --region "$REGION" --subnet-ids $subnets \
        --query "Subnets[].AvailabilityZone" --output text | tr '\t' '\n' | sort | sed 's/^/  /' >&2
      echo "Add one with PrivateSubnetAz2-4 in $NETWORK_PARAMS; see docs/network.md." >&2
      exit 1 ;;
    *)
      echo "$NETWORK_STACK has more than one private subnet in $az ($(tr '\t' ' ' <<<"$matches")). Give each PrivateSubnetAz a different AZ." >&2
      exit 1 ;;
  esac
  set_compute_param SubnetId "$matches"
  echo "Set SubnetId to $matches ($az). Run scripts/deploy.sh compute; it replaces the instance."
}

deploy_compute() {
  if jq -e 'any(.[]; .ParameterKey != "ExtraVllmArgs"
                and ((.ParameterValue | startswith("SET_")) or .ParameterValue == ""))' \
      "$COMPUTE_PARAMS" >/dev/null; then
    echo "$COMPUTE_PARAMS still has placeholder or empty values. See docs/deployment.md step 1." >&2
    exit 1
  fi

  # Catch bad quoting here rather than when the instance starts vLLM.
  command -v python3 >/dev/null || { echo "python3 is needed to check ExtraVllmArgs." >&2; exit 1; }
  local extra_args
  extra_args=$(jq -r '.[] | select(.ParameterKey=="ExtraVllmArgs").ParameterValue' "$COMPUTE_PARAMS")
  if ! python3 -c 'import shlex, sys; shlex.split(sys.argv[1])' "$extra_args" 2>/dev/null; then
    echo "ExtraVllmArgs in $COMPUTE_PARAMS doesn't split like a shell command line (check its quotes): $extra_args" >&2
    exit 1
  fi

  local status
  status=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$COMPUTE_STACK" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null) || status=NONE
  if [[ "$status" == "ROLLBACK_COMPLETE" ]]; then
    echo "The first deploy of $COMPUTE_STACK failed and rolled back. Delete just that stack, fix the cause (for no capacity, pick another AZ with scripts/deploy.sh use-az), then run this again:" >&2
    echo "  aws cloudformation delete-stack --region $REGION --stack-name $COMPUTE_STACK" >&2
    echo "  aws cloudformation wait stack-delete-complete --region $REGION --stack-name $COMPUTE_STACK" >&2
    exit 1
  fi

  if [[ "$status" == "NONE" ]]; then
    aws cloudformation deploy --region "$REGION" \
      --stack-name "$COMPUTE_STACK" \
      --template-file "$COMPUTE_TEMPLATE" \
      --parameter-overrides file://"$COMPUTE_PARAMS" \
      --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND
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
    --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND >/dev/null

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
  local profile_changed
  profile_changed=$(aws cloudformation describe-change-set --region "$REGION" \
    --stack-name "$COMPUTE_STACK" --change-set-name "$change_set" \
    --query "length(Changes[?ResourceChange.LogicalResourceId=='ModelProfile'])" \
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

  if [[ "$profile_changed" != "0" && "$replacement" != "True" && "$replacement" != "Conditional" ]]; then
    echo "The model profile changed. Run scripts/switch-model.sh to load it."
  fi

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

case "${1:-}" in network|compute|all|use-az) require_file "$COMPUTE_PARAMS" ;; esac
case "${1:-}" in network|all) require_file "$NETWORK_PARAMS" ;; esac

case "${1:-}" in
  network) deploy_network ;;
  compute) deploy_compute ;;
  all) deploy_network; deploy_compute ;;
  use-az) [[ -n "${2:-}" ]] || usage; use_az "$2" ;;
  *) usage ;;
esac
