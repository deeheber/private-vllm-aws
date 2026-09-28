#!/usr/bin/env bash
# Look for On-Demand capacity for the InstanceType in compute-params.json by trying a
# capacity reservation in each AZ, stopping at the first success. A reservation bills
# until it ends or you cancel it, used or not.
# Usage: scripts/find-capacity.sh region [region...]
set -euo pipefail
cd "$(dirname "$0")/.."

COMPUTE_PARAMS=stacks/compute/compute-params.json

RESERVATION_HOURS=1   # enough to deploy right away; a running instance outlives it

regions=()
for arg in "$@"; do
  if [[ "$arg" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]]; then
    regions+=("$arg")
  fi
done

if [[ ${#regions[@]} -eq 0 ]]; then
  echo "Usage: $0 region [region...], for example: $0 us-west-2 us-east-1" >&2
  exit 2
fi
if [[ ! -f "$COMPUTE_PARAMS" ]]; then
  echo "Missing $COMPUTE_PARAMS. See docs/deployment.md step 1." >&2
  exit 2
fi
instance_type=$(jq -r '.[] | select(.ParameterKey=="InstanceType").ParameterValue' "$COMPUTE_PARAMS")
if [[ -z "$instance_type" ]]; then
  echo "No InstanceType in $COMPUTE_PARAMS." >&2
  exit 2
fi

# python3 because `date` arithmetic differs between macOS and Linux.
end=$(python3 - "$RESERVATION_HOURS" <<'PY'
import datetime, sys
end = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=int(sys.argv[1]))
print(end.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)

now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

echo "Probing for $instance_type in: ${regions[*]}."
echo "If an AZ has capacity, this creates a capacity reservation there. It bills at the"
echo "On-Demand rate for $instance_type until $end, or until you cancel it, used or not."
read -r -p "Continue? [y/N] " answer
if [[ "$answer" != "y" ]]; then
  echo "Cancelled."
  exit 1
fi

for region in "${regions[@]}"; do
  azs=$(aws ec2 describe-instance-type-offerings --region "$region" \
    --location-type availability-zone \
    --filters Name=instance-type,Values="$instance_type" \
    --query "InstanceTypeOfferings[].Location" --output text | tr '\t' '\n' | sort)
  if [[ -z "$azs" ]]; then
    echo "$(now)  $region  $instance_type isn't offered in this region"
    continue
  fi

  for az in $azs; do
    # open, not targeted: the stack's launch template doesn't reference a reservation.
    if output=$(aws ec2 create-capacity-reservation \
        --region "$region" \
        --availability-zone "$az" \
        --instance-type "$instance_type" \
        --instance-platform Linux/UNIX \
        --tenancy default \
        --instance-count 1 \
        --end-date-type limited \
        --end-date "$end" \
        --instance-match-criteria open \
        --query CapacityReservation.CapacityReservationId --output text 2>&1); then
      id=$output
      echo "$(now)  $az  capacity reserved: $id"
      echo
      echo "Reserved one $instance_type in $az until $end. It's billing now."
      echo "An On-Demand instance of that type in $az uses it automatically. Next:"
      # The other scripts use $AWS_REGION, or us-west-2 if it's unset.
      if [[ "$region" != "${AWS_REGION:-us-west-2}" ]]; then
        echo "  export AWS_REGION=$region"
      fi
      echo "  New network stack: set AvailabilityZone to $az in stacks/network/network-params.json,"
      echo "    then scripts/deploy.sh all"
      echo "  Existing network stack: scripts/deploy.sh use-az $az, then scripts/deploy.sh compute"
      echo "  PurchaseOption must be ondemand in $COMPUTE_PARAMS."
      echo "To cancel it instead:"
      echo "  aws ec2 cancel-capacity-reservation --region $region --capacity-reservation-id $id"
      exit 0
    fi

    # "An error occurred (InsufficientInstanceCapacity) when calling ..." -> the code
    code=$(sed -n 's/.*An error occurred (\([A-Za-z.]*\)).*/\1/p' <<<"$output" | head -1)
    echo "$(now)  $az  ${code:-$output}"

    # Moving on after an unclear failure, such as a lost response to a request that
    # did succeed, could create a second reservation.
    if [[ "$code" != InsufficientInstanceCapacity ]]; then
      echo "Stopped on an unexpected error. Check for a reservation before running again:" >&2
      echo "  aws ec2 describe-capacity-reservations --region $region --filters Name=state,Values=active" >&2
      exit 1
    fi
  done
done

echo
echo "No capacity for $instance_type in ${regions[*]}. Nothing was created; try again later."
exit 1
