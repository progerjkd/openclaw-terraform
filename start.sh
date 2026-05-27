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
  # Spot: scale fleet to 1 — launches a new instance, then reattach EBS
  echo "Spot Fleet: $SPOT_FLEET_ID"

  current=$(aws ec2 describe-spot-fleet-requests \
    --spot-fleet-request-ids "$SPOT_FLEET_ID" \
    --region "$REGION" \
    --query 'SpotFleetRequestConfigs[0].SpotFleetRequestConfig.TargetCapacity' \
    --output text)

  INSTANCE_ID=""

  if [[ "$current" != "0" ]]; then
    echo ""
    echo "Fleet target capacity is already $current."
    # Look up running instance so we can show the IP below
    INSTANCE_ID=$(aws ec2 describe-spot-fleet-instances \
      --spot-fleet-request-id "$SPOT_FLEET_ID" \
      --region "$REGION" \
      --query 'ActiveInstances[0].InstanceId' \
      --output text 2>/dev/null || echo "")
    [[ "$INSTANCE_ID" == "None" ]] && INSTANCE_ID=""
  else
    echo ""
    echo "Scaling fleet to 1..."
    aws ec2 modify-spot-fleet-request \
      --spot-fleet-request-id "$SPOT_FLEET_ID" \
      --target-capacity 1 \
      --region "$REGION"

    echo "Waiting for spot instance to launch (30-120s)..."
    INSTANCE_ID=""
    for i in $(seq 1 60); do
      INSTANCE_ID=$(aws ec2 describe-spot-fleet-instances \
        --spot-fleet-request-id "$SPOT_FLEET_ID" \
        --region "$REGION" \
        --query 'ActiveInstances[0].InstanceId' \
        --output text 2>/dev/null || echo "None")
      if [[ "$INSTANCE_ID" != "None" && -n "$INSTANCE_ID" ]]; then
        echo "Instance launched: $INSTANCE_ID"
        break
      fi
      INSTANCE_ID=""
      echo "  Still pending... ($((i * 5))s)"
      sleep 5
    done

    if [[ -z "$INSTANCE_ID" ]]; then
      echo "Timed out waiting for spot instance. Run './attach-volume.sh' manually once it appears."
      exit 1
    fi

    echo "Waiting for instance to be running..."
    aws ec2 wait instance-running \
      --instance-ids "$INSTANCE_ID" \
      --region "$REGION"
  fi

  echo ""
  echo "Attaching EBS data volume..."
  "$SCRIPT_DIR/attach-volume.sh"

  echo ""
  echo "OpenClaw is running!"

  if [[ -n "$INSTANCE_ID" ]]; then
    ip=$(aws ec2 describe-instances \
      --instance-ids "$INSTANCE_ID" \
      --region "$REGION" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' \
      --output text)
    echo "Public IP:   $ip"

    # Show version once bootstrap is ready (instance may still be initialising; skip if not yet up)
    echo "Waiting for OpenClaw to start (up to 2 min)..."
    _ver=""
    for _i in $(seq 1 24); do
      _ver=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ubuntu@"$ip" \
        "docker inspect --format '{{.Config.Image}}' \$(docker ps -q --filter name=openclaw 2>/dev/null) 2>/dev/null | grep -o '[^:]*$'" \
        2>/dev/null || true)
      [[ -n "$_ver" ]] && break
      sleep 5
    done
    [[ -n "$_ver" ]] && echo "Version:     $_ver" || echo "Version:     (still starting — run ./status.sh to check)"

    echo ""
    echo "SSH tunnel:  ssh -fN -L 18789:localhost:18789 ubuntu@$ip"
    echo "Control UI:  http://localhost:18789/"
  fi

else
  # On-demand: start the instance directly
  INSTANCE_ID=$("$TERRAFORM" output -raw instance_id 2>/dev/null) || {
    echo "Error: could not read instance_id from terraform output."
    exit 1
  }

  state=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)

  echo "Instance: $INSTANCE_ID"
  echo "State:    $state"

  if [[ "$state" == "running" ]]; then
    ip=$(aws ec2 describe-instances \
      --instance-ids "$INSTANCE_ID" \
      --region "$REGION" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' \
      --output text)
    echo "Public IP: $ip"
    echo ""
    echo "Instance is already running."
    echo ""
    echo "SSH tunnel:  ssh -fN -L 18789:localhost:18789 ubuntu@$ip"
    echo "Control UI:  http://localhost:18789/"
    exit 0
  fi

  if [[ "$state" != "stopped" ]]; then
    echo ""
    echo "Instance is in state '$state'. Can only start from 'stopped'."
    exit 1
  fi

  echo ""
  echo "Starting instance..."
  aws ec2 start-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --output text > /dev/null

  echo "Waiting for instance to start..."
  aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

  ip=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

  echo ""
  echo "Instance is running!"
  echo "Public IP: $ip"
  echo ""
  echo "SSH tunnel:  ssh -fN -L 18789:localhost:18789 ubuntu@$ip"
  echo "Control UI:  http://localhost:18789/"
fi
