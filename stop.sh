#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="us-east-1"

# --yes / -y skips the confirmation prompt (used by CI)
AUTO_APPROVE=false
for arg in "$@"; do
  case $arg in --yes|-y) AUTO_APPROVE=true ;; esac
done

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
  # Spot: scale fleet to 0 — terminates the instance, EBS data volume is preserved
  INSTANCE_ID=$("$TERRAFORM" output -raw instance_id 2>/dev/null || echo "pending")

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

  if [[ "$AUTO_APPROVE" != "true" ]]; then
    read -rp "Scale fleet to 0 (terminates instance, EBS data preserved)? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
      echo "Cancelled."
      exit 0
    fi
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

  if [[ "$state" != "running" ]]; then
    echo ""
    echo "Instance is not running (state: $state). Nothing to stop."
    exit 0
  fi

  echo ""
  if [[ "$AUTO_APPROVE" != "true" ]]; then
    read -rp "Stop this instance? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
      echo "Cancelled."
      exit 0
    fi
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
