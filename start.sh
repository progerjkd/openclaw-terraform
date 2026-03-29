#!/usr/bin/env bash
set -euo pipefail

# AWS_PROFILE is read from environment: export AWS_PROFILE=your-profile
REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SPOT_FLEET_ID=$(terraform output -raw spot_fleet_id 2>/dev/null || echo "")

if [[ -n "$SPOT_FLEET_ID" ]]; then
  # Spot: scale fleet to 1 — launches a new instance, then reattach EBS
  echo "Spot Fleet: $SPOT_FLEET_ID"

  current=$(aws ec2 describe-spot-fleet-requests \
    --spot-fleet-request-ids "$SPOT_FLEET_ID" \
    --region "$REGION" \
    --query 'SpotFleetRequestConfigs[0].SpotFleetRequestConfig.TargetCapacity' \
    --output text)

  if [[ "$current" != "0" ]]; then
    echo ""
    echo "Fleet target capacity is already $current."
    # Still fall through to attach-volume in case it needs reattachment
  else
    echo ""
    echo "Scaling fleet to 1..."
    aws ec2 modify-spot-fleet-request \
      --spot-fleet-request-id "$SPOT_FLEET_ID" \
      --target-capacity 1 \
      --region "$REGION"

    echo "Waiting for spot instance to launch (30-60s)..."
    for i in $(seq 1 30); do
      terraform refresh -no-color > /dev/null 2>&1
      INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null || echo "pending")
      if [[ "$INSTANCE_ID" != "pending" ]]; then
        echo "Instance launched: $INSTANCE_ID"
        break
      fi
      echo "  Still pending... ($((i * 5))s)"
      sleep 5
    done

    INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null || echo "pending")
    if [[ "$INSTANCE_ID" == "pending" ]]; then
      echo "Timed out waiting for spot instance. Run 'terraform refresh' and './attach-volume.sh' manually."
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

  ip=$(aws ec2 describe-instances \
    --instance-ids "$(terraform output -raw instance_id)" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

  echo ""
  echo "OpenClaw is running!"
  echo "Public IP:   $ip"
  echo ""
  echo "SSH tunnel:  ssh -fN -L 18789:localhost:18789 ubuntu@$ip"
  echo "Control UI:  http://localhost:18789/"

else
  # On-demand: start the instance directly
  INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null) || {
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
