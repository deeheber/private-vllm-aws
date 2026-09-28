#!/usr/bin/env bash
# Restart vLLM on the instance so it loads the current model profile, then list
# the cached models and free disk space. The instance keeps running.
# Usage: scripts/switch-model.sh        restart vLLM with the deployed profile
#        scripts/switch-model.sh list   only list what's running and cached
#        scripts/switch-model.sh remove <org>/<name>   delete a cached model that isn't running
# Deploy the profile first with scripts/deploy.sh compute.
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
COMPUTE_STACK=vllm-compute
FREE_GB_WARNING=40
DEADLINE_SECONDS=180

model=""
case "${1:-}" in
  "") mode=switch ;;
  list) mode=list ;;
  remove)
    mode=remove
    model=${2:-}
    [[ "$model" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "Usage: $0 remove <org>/<name>" >&2; exit 1; } ;;
  *) echo "Usage: $0 [list | remove <org>/<name>]" >&2; exit 1 ;;
esac

instance_id=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$COMPUTE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text 2>/dev/null) || {
  echo "Stack $COMPUTE_STACK not found in $REGION. Deploy it first." >&2
  exit 1
}

state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$instance_id" \
  --query "Reservations[0].Instances[0].State.Name" --output text)
if [[ "$state" != "running" ]]; then
  echo "Instance $instance_id is $state. It loads the current profile when it starts:" >&2
  echo "  aws ec2 start-instances --region $REGION --instance-ids $instance_id" >&2
  exit 1
fi

# Runs as root on the instance.
remote_script=$(cat <<EOF
MODE=$mode
MODEL=$model
FREE_GB_WARNING=$FREE_GB_WARNING
EOF
cat <<'EOF'
if [ "$MODE" = remove ]; then
  dir=/opt/hf-cache/hub/models--$(echo "$MODEL" | sed 's|/|--|g')
  [ -d "$dir" ] || { echo "$MODEL isn't cached." >&2; exit 1; }
  if [ "$(docker inspect vllm --format '{{index .Config.Cmd 0}}' 2>/dev/null)" = "$MODEL" ]; then
    echo "$MODEL is running. Switch to another model first." >&2
    exit 1
  fi
  # The files live in a shared blobs/ store. Keep any that another model also links to.
  keep=$(mktemp)
  for other in /opt/hf-cache/hub/models--*; do
    [ "$other" = "$dir" ] || find "$other" -type l -exec readlink -f {} +
  done | sort -u > "$keep"
  find "$dir" -type l -exec readlink -f {} + | sort -u | comm -23 - "$keep" | xargs -r rm -f
  rm -rf "$dir" "$keep"
  echo "Removed $MODEL."
  echo
fi

if [ "$MODE" = switch ]; then
  # Clears the start limit left by an earlier profile that failed.
  systemctl reset-failed vllm 2>/dev/null
  systemctl restart vllm || exit 1
  sleep 3
fi

service=$(systemctl is-active vllm)
echo "Service: $service"
if ! docker info >/dev/null 2>&1; then
  echo "Docker isn't responding on the instance. Check it with: sudo systemctl status docker" >&2
  exit 1
fi
current=""
if docker inspect vllm >/dev/null 2>&1; then
  echo "Running: $(docker inspect vllm --format '{{.Config.Image}} {{join .Config.Cmd " "}}')"
  current="models--$(docker inspect vllm --format '{{index .Config.Cmd 0}}' | sed 's|/|--|g')"
elif [ "$service" = active ] || [ "$service" = activating ]; then
  echo "Running: starting; container not created yet (reading the profile or pulling the image)"
else
  echo "Running: nothing"
fi

echo
echo "Cached models:"
found=0
for dir in /opt/hf-cache/hub/models--*; do
  [ -d "$dir" ] || continue
  found=1
  mark="  "
  [ "$(basename "$dir")" = "$current" ] && mark="* "
  # -L follows the symlinks into blobs/.
  echo "$mark$(du -shL "$dir" | cut -f1)  $(basename "$dir")"
done
[ "$found" = 1 ] || echo "  (none yet)"

echo
echo "vLLM images:"
docker images vllm/vllm-openai --format '  {{.Tag}}  {{.Size}}'

echo
df -h / | sed 's/^/  /'
free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
# Without a running container we can't tell which model is about to load, so
# don't suggest removals then.
if [ "$free_gb" -lt "$FREE_GB_WARNING" ] && [ -z "$current" ]; then
  echo
  echo "Under ${FREE_GB_WARNING} GB free. Run scripts/switch-model.sh list once the model is running to see what's safe to remove."
elif [ "$free_gb" -lt "$FREE_GB_WARNING" ]; then
  echo
  echo "Under ${FREE_GB_WARNING} GB free. To free space:"
  for dir in /opt/hf-cache/hub/models--*; do
    [ -d "$dir" ] && [ "$(basename "$dir")" != "$current" ] && \
      echo "  scripts/switch-model.sh remove $(basename "$dir" | sed 's/^models--//; s|--|/|')"
  done
  echo "  scripts/connect.sh shell, then: sudo docker image rm vllm/vllm-openai:<old tag>"
fi

if [ "$MODE" != remove ] && [ "$service" != active ] && [ "$service" != activating ]; then
  echo "vLLM is $service. See why with: sudo journalctl -u vllm -n 50" >&2
  exit 1
fi
EOF
)

command_id=$(aws ssm send-command --region "$REGION" --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript --comment "switch-model.sh $mode" \
  --parameters "$(jq -n --arg s "$remote_script" '{commands: [$s]}')" \
  --query Command.CommandId --output text)

if [[ "$mode" == switch ]]; then
  echo "Restarting vLLM on $instance_id..."
fi

# The invocation can take a moment to appear after send-command.
start=$SECONDS
while :; do
  if status=$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$command_id" --instance-id "$instance_id" \
      --query Status --output text 2>&1); then
    case "$status" in
      Pending|InProgress|Delayed) ;;
      *) break ;;
    esac
  elif [[ "$status" != *InvocationDoesNotExist* ]]; then
    echo "$status" >&2
    exit 1
  fi
  if (( SECONDS - start > DEADLINE_SECONDS )); then
    echo "No result after ${DEADLINE_SECONDS}s (status: $status). Check the command $command_id in the Systems Manager console." >&2
    exit 1
  fi
  sleep 2
done

aws ssm get-command-invocation --region "$REGION" \
  --command-id "$command_id" --instance-id "$instance_id" \
  --query StandardOutputContent --output text
stderr=$(aws ssm get-command-invocation --region "$REGION" \
  --command-id "$command_id" --instance-id "$instance_id" \
  --query StandardErrorContent --output text)
[[ -n "$stderr" && "$stderr" != "None" ]] && echo "$stderr" >&2

if [[ "$status" != Success ]]; then
  echo "The command on the instance ended with status $status." >&2
  exit 1
fi

if [[ "$mode" == switch ]]; then
  echo
  echo "Restart requested. The model isn't ready until it has downloaded and loaded;"
  echo "until then /health doesn't answer. To watch, run scripts/connect.sh shell, then:"
  echo "  sudo journalctl -u vllm -f"
fi
