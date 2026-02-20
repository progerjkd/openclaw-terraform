#!/usr/bin/env bash
set -euo pipefail

REGION="us-east-1"
INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null) || {
  echo "Error: could not read instance_id from terraform output."
  echo "Run this script from the openclaw-terraform directory."
  exit 1
}

info=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress,LaunchTime]' \
  --output text)

state=$(echo "$info" | awk '{print $1}')
ip=$(echo "$info" | awk '{print $2}')
launch=$(echo "$info" | awk '{print $3}')

echo "Instance:  $INSTANCE_ID"
echo "State:     $state"

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
