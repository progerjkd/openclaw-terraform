#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="us-east-1"

# Load AWS_PROFILE from terraform.tfvars if not already set in environment
if [[ -z "${AWS_PROFILE:-}" && -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  _profile=$(grep -E '^\s*aws_profile\s*=' "$SCRIPT_DIR/terraform.tfvars" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')
  [[ -n "$_profile" ]] && export AWS_PROFILE="$_profile"
  unset _profile
fi

# Resolve terraform binary (handles cases where it is not on PATH)
TERRAFORM=$(command -v terraform 2>/dev/null || echo /opt/homebrew/bin/terraform)
if [[ ! -x "$TERRAFORM" ]]; then
  echo "Error: terraform not found. Install via: brew install terraform"
  exit 1
fi

SPOT_FLEET_ID=$("$TERRAFORM" output -raw spot_fleet_id 2>/dev/null || echo "")

if [[ -n "$SPOT_FLEET_ID" ]]; then
  echo "Spot Fleet: $SPOT_FLEET_ID"

  # Query fleet target capacity
  target=$(aws ec2 describe-spot-fleet-requests \
    --spot-fleet-request-ids "$SPOT_FLEET_ID" \
    --region "$REGION" \
    --query 'SpotFleetRequestConfigs[0].SpotFleetRequestConfig.TargetCapacity' \
    --output text)
  echo "Target capacity: $target"

  if [[ "$target" == "0" ]]; then
    echo "Status:    Stopped (fleet at 0). Run ./start.sh to start."
    exit 0
  fi

  # Query running instances directly from the fleet (no terraform refresh needed)
  INSTANCE_ID=$(aws ec2 describe-spot-fleet-instances \
    --spot-fleet-request-id "$SPOT_FLEET_ID" \
    --region "$REGION" \
    --query 'ActiveInstances[0].InstanceId' \
    --output text 2>/dev/null || echo "None")

  # Fallback: fleet API may lag behind actual launch; query by fleet tag directly
  if [[ "$INSTANCE_ID" == "None" || -z "$INSTANCE_ID" ]]; then
    INSTANCE_ID=$(aws ec2 describe-instances \
      --region "$REGION" \
      --filters \
        "Name=tag:aws:ec2spot:fleet-request-id,Values=$SPOT_FLEET_ID" \
        "Name=instance-state-name,Values=pending,running" \
      --query 'Reservations[0].Instances[0].InstanceId' \
      --output text 2>/dev/null || echo "None")
  fi

  if [[ "$INSTANCE_ID" == "None" || -z "$INSTANCE_ID" ]]; then
    echo "Status:    Pending (waiting for spot capacity)..."
    exit 0
  fi

  # Get instance info
  info=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress,LaunchTime,InstanceType]' \
    --output text)

  state=$(echo "$info" | awk '{print $1}')
  ip=$(echo "$info" | awk '{print $2}')
  launch=$(echo "$info" | awk '{print $3}')
  instance_type=$(echo "$info" | awk '{print $4}')

  echo "Instance:  $INSTANCE_ID ($instance_type, spot)"
  echo "State:     $state"

  # Check data volume attachment
  VOLUME_ID=$("$TERRAFORM" output -raw data_volume_id 2>/dev/null || echo "")
  if [[ -n "$VOLUME_ID" ]]; then
    vol_state=$(aws ec2 describe-volumes \
      --volume-ids "$VOLUME_ID" \
      --region "$REGION" \
      --query 'Volumes[0].Attachments[0].State' \
      --output text 2>/dev/null || echo "detached")
    echo "Data vol:  $VOLUME_ID ($vol_state)"
    if [[ "$vol_state" != "attached" ]]; then
      echo "           ⚠ Run ./attach-volume.sh to attach data volume!"
    fi
  fi

  if [[ "$state" == "running" && "$ip" != "None" ]]; then
    echo "Public IP: $ip"
    echo "Launched:  $launch"

    # Version info via SSH (non-blocking; skip if unreachable)
    _ver=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ubuntu@"$ip" \
      "docker inspect --format '{{.Config.Image}}' \$(docker ps -q --filter name=openclaw 2>/dev/null) 2>/dev/null | grep -o '[^:]*$'" \
      2>/dev/null || true)
    _upd=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ubuntu@"$ip" \
      "cat /opt/openclaw-data/config/update-check.json 2>/dev/null" \
      2>/dev/null || true)
    if [[ -n "$_ver" ]]; then
      echo "Running:   $_ver"
      _latest=$(echo "$_upd" | grep -o '"lastAvailableVersion"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' || true)
      if [[ -n "$_latest" ]]; then
        if [[ "$_latest" == "${_ver%%-*}" ]]; then
          echo "Latest:    $_latest  ✓ up to date"
        else
          echo "Latest:    $_latest  ⚠  run ./stop.sh && ./start.sh to update"
        fi
      fi
    fi

    echo ""
    echo "SSH:         ssh ubuntu@$ip"
    echo "SSH tunnel:  ssh -fN -L 18789:localhost:18789 ubuntu@$ip"
    echo "Control UI:  http://localhost:18789/"
  fi

else
  # On-demand path
  INSTANCE_ID=$("$TERRAFORM" output -raw instance_id 2>/dev/null) || {
    echo "Error: could not read instance_id from terraform output."
    exit 1
  }

  info=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress,LaunchTime,InstanceType]' \
    --output text)

  state=$(echo "$info" | awk '{print $1}')
  ip=$(echo "$info" | awk '{print $2}')
  launch=$(echo "$info" | awk '{print $3}')
  instance_type=$(echo "$info" | awk '{print $4}')

  echo "Instance:  $INSTANCE_ID ($instance_type, on-demand)"
  echo "State:     $state"

  if [[ "$state" == "running" && "$ip" != "None" ]]; then
    echo "Public IP: $ip"
    echo "Launched:  $launch"
    echo ""
    echo "SSH:         ssh ubuntu@$ip"
    echo "SSH tunnel:  ssh -fN -L 18789:localhost:18789 ubuntu@$ip"
    echo "Control UI:  http://localhost:18789/"
  elif [[ "$state" == "stopped" ]]; then
    echo ""
    echo "Instance is stopped. Run ./start.sh to start it."
  fi
fi
