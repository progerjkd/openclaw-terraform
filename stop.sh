#!/usr/bin/env bash
set -euo pipefail

# AWS_PROFILE is read from environment: export AWS_PROFILE=your-profile
REGION="us-east-1"

SPOT_FLEET_ID=$(terraform output -raw spot_fleet_id 2>/dev/null || echo "")

if [[ -n "$SPOT_FLEET_ID" ]]; then
  # Spot: scale fleet to 0 — terminates the instance, EBS data volume is preserved
  INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null || echo "pending")

  echo "Spot Fleet: $SPOT_FLEET_ID"
  [[ "$INSTANCE_ID" != "pending" ]] && echo "Instance:   $INSTANCE_ID"
  echo ""

  # Check current target capacity
  current=$(aws ec2 describe-spot-fleet-requests \
    --spot-fleet-request-ids "$SPOT_FLEET_ID" \
    --region "$REGION" \
    --query 'SpotFleetRequestConfigs[0].SpotFleetRequestConfig.TargetCapacity' \
    --output text)

  if [[ "$current" == "0" ]]; then
    echo "Fleet is already at capacity 0. Nothing to stop."
    exit 0
  fi

  read -rp "Scale fleet to 0 (terminates instance, EBS data preserved)? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    echo "Cancelled."
    exit 0
  fi

  echo ""
  echo "Scaling fleet to 0..."
  aws ec2 modify-spot-fleet-request \
    --spot-fleet-request-id "$SPOT_FLEET_ID" \
    --target-capacity 0 \
    --region "$REGION"

  if [[ "$INSTANCE_ID" != "pending" ]]; then
    echo "Waiting for instance to terminate..."
    aws ec2 wait instance-terminated \
      --instance-ids "$INSTANCE_ID" \
      --region "$REGION"
  fi

  echo "Fleet stopped. EBS data volume is preserved."

else
  # On-demand: stop the instance directly
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

  if [[ "$state" != "running" ]]; then
    echo ""
    echo "Instance is not running (state: $state). Nothing to stop."
    exit 0
  fi

  echo ""
  read -rp "Stop this instance? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    echo "Cancelled."
    exit 0
  fi

  echo ""
  echo "Stopping instance..."
  aws ec2 stop-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --output text > /dev/null

  echo "Waiting for instance to stop..."
  aws ec2 wait instance-stopped \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

  echo "Instance stopped."
fi
