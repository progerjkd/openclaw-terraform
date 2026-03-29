#!/usr/bin/env bash
set -euo pipefail

# AWS_PROFILE is read from environment: export AWS_PROFILE=your-profile
REGION="us-east-1"

# Get instance ID (works for both spot and on-demand)
INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null) || {
  echo "Error: could not read instance_id from terraform output."
  echo "Run this script from the openclaw-terraform directory."
  exit 1
}

# Check if using spot fleet
SPOT_FLEET_ID=$(terraform output -raw spot_fleet_id 2>/dev/null || echo "")

if [[ "$INSTANCE_ID" == "pending" ]]; then
  echo "Spot fleet: $SPOT_FLEET_ID"
  echo "Status:     Pending (waiting for spot capacity)"
  echo ""
  echo "Spot instances may take 30-60 seconds to launch."
  echo "Run this script again in a moment."
  exit 0
fi

# Get instance info
info=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress,LaunchTime,InstanceType,InstanceLifecycle]' \
  --output text)

state=$(echo "$info" | awk '{print $1}')
ip=$(echo "$info" | awk '{print $2}')
launch=$(echo "$info" | awk '{print $3}')
instance_type=$(echo "$info" | awk '{print $4}')
lifecycle=$(echo "$info" | awk '{print $5}')

echo "Instance:  $INSTANCE_ID"
echo "Type:      $instance_type${lifecycle:+ ($lifecycle)}"
echo "State:     $state"

if [[ -n "$SPOT_FLEET_ID" ]]; then
  echo "Spot Fleet: $SPOT_FLEET_ID"
fi

if [[ "$state" == "running" && "$ip" != "None" ]]; then
  echo "Public IP: $ip"
  echo "Launched:  $launch"
  echo ""
  echo "SSH tunnel:  ssh -fN -L 18789:localhost:18789 ubuntu@$ip"
  echo "Control UI:  http://localhost:18789/"
elif [[ "$state" == "stopped" ]]; then
  echo ""
  echo "Instance is stopped. Run ./start.sh to start it."
else
  echo "Public IP: ${ip:-n/a}"
fi
