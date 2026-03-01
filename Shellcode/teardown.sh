#!/bin/bash
# teardown.sh
# Written by MontyIIT — use this to nuke everything deploy.sh created.
#
# I learned the hard way that order matters here. If you try to delete
# the security group before the instances are gone, AWS just throws an
# error and you're left cleaning up manually. So this goes ASG first,
# then the template, then the instance, and so on down the chain.
#
# It'll ask you to type "yes" before touching anything — I added that
# after accidentally running a teardown on the wrong account once.
#
# Usage: chmod +x teardown.sh && ./teardown.sh

set -e
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[done] $1${NC}"; }
warn()   { echo -e "${YELLOW}[warn] $1${NC}"; }
skip()   { echo -e "${YELLOW}[skip] $1 — doesn't exist, moving on.${NC}"; }
header() {
  echo -e "\n${BLUE}--- $1 ---${NC}"
}

# these need to match exactly what deploy.sh used, otherwise the
# describe calls come back empty and everything gets skipped silently
REGION="us-east-1"
VM_NAME="web-app-vm"
SG_NAME="web-app-sg"
IAM_ROLE_NAME="EC2-ReadOnly-Role"
LAUNCH_TEMPLATE_NAME="web-app-launch-template"
ASG_NAME="web-app-asg"
KEY_PAIR_NAME="my-ec2-keypair"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text --region "$REGION" 2>/dev/null)

# give the user one last chance to bail out
echo ""
echo -e "${RED}╔════════════════════════════════════╗${NC}"
echo -e "${RED}║  heads up — this cannot be undone  ║${NC}"
echo -e "${RED}╚════════════════════════════════════╝${NC}"
echo ""
echo "  About to delete everything in $REGION:"
echo "    - Auto Scaling Group : $ASG_NAME"
echo "    - Launch Template    : $LAUNCH_TEMPLATE_NAME"
echo "    - EC2 Instance       : $VM_NAME"
echo "    - Security Group     : $SG_NAME"
echo "    - IAM Role           : $IAM_ROLE_NAME"
echo "    - Key Pair           : $KEY_PAIR_NAME"
echo ""
read -r -p "  Type 'yes' to continue (anything else cancels): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo ""
  warn "Cancelled. Nothing touched."
  exit 0
fi
echo ""

# step 1 — kill the ASG first
# it holds references to the launch template and has live instances,
# so if we don't remove it first everything else will fail with
# "resource is in use" errors
header "Auto Scaling Group"

ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query "AutoScalingGroups[0].AutoScalingGroupName" \
  --output text --region "$REGION" 2>/dev/null)

if [ "$ASG_EXISTS" != "None" ] && [ -n "$ASG_EXISTS" ]; then
  aws autoscaling delete-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --force-delete \
    --region "$REGION"
  log "ASG gone — the instances it was managing will terminate on their own"
  log "Giving them 30 seconds to shut down before we continue..."
  sleep 30
else
  skip "ASG '$ASG_NAME'"
fi

# step 2 — launch template
header "Launch Template"

LT_ID=$(aws ec2 describe-launch-templates \
  --filters "Name=launch-template-name,Values=$LAUNCH_TEMPLATE_NAME" \
  --query "LaunchTemplates[0].LaunchTemplateId" \
  --output text --region "$REGION" 2>/dev/null)

if [ "$LT_ID" != "None" ] && [ -n "$LT_ID" ]; then
  aws ec2 delete-launch-template \
    --launch-template-id "$LT_ID" \
    --region "$REGION" >/dev/null
  log "Launch template deleted ($LT_ID)"
else
  skip "Launch template '$LAUNCH_TEMPLATE_NAME'"
fi

# step 3 — the standalone instance we launched manually
# this is separate from the ASG-managed ones
header "EC2 Instance ($VM_NAME)"

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$VM_NAME" \
            "Name=instance-state-name,Values=running,pending,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text --region "$REGION" 2>/dev/null)

if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
  aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" >/dev/null
  log "Termination request sent for $INSTANCE_ID, waiting for it to finish..."
  aws ec2 wait instance-terminated \
    --instance-ids "$INSTANCE_ID" --region "$REGION"
  log "Instance is gone."
else
  skip "EC2 instance '$VM_NAME'"
fi

# step 4 — security group
# this is why we waited for the instance to fully terminate above;
# AWS won't let you delete an SG that's still attached to something
header "Security Group"

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text --region "$REGION" 2>/dev/null)

if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
  aws ec2 delete-security-group \
    --group-id "$SG_ID" --region "$REGION"
  log "Security group deleted ($SG_ID)"
else
  skip "Security group '$SG_NAME'"
fi

# step 5 — IAM cleanup
# AWS requires you to detach all policies before you can delete the role,
# and remove the role from the instance profile before deleting that too.
# a bit annoying but it's just the way IAM works.
header "IAM Role"

if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then

  ATTACHED=$(aws iam list-attached-role-policies \
    --role-name "$IAM_ROLE_NAME" \
    --query "AttachedPolicies[*].PolicyArn" \
    --output text)

  for ARN in $ATTACHED; do
    aws iam detach-role-policy \
      --role-name "$IAM_ROLE_NAME" \
      --policy-arn "$ARN"
    log "  detached $ARN"
  done

  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$IAM_ROLE_NAME" \
    --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1 || true

  aws iam delete-instance-profile \
    --instance-profile-name "$IAM_ROLE_NAME" >/dev/null 2>&1 || true

  aws iam delete-role --role-name "$IAM_ROLE_NAME"
  log "IAM role '$IAM_ROLE_NAME' deleted"
else
  skip "IAM role '$IAM_ROLE_NAME'"
fi

# step 6 — key pair
# note: we only delete the key from AWS here.
# the .pem file on your machine stays put — I'd rather leave it
# and let you delete it manually than accidentally nuke it.
header "Key Pair"

if aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" \
    --region "$REGION" >/dev/null 2>&1; then
  aws ec2 delete-key-pair \
    --key-name "$KEY_PAIR_NAME" --region "$REGION"
  log "Key pair removed from AWS"
  warn "Your local '${KEY_PAIR_NAME}.pem' file is still on disk — delete it yourself when you're ready"
else
  skip "Key pair '$KEY_PAIR_NAME'"
fi

echo ""
echo -e "${GREEN}all done — account should be clean now.${NC}"
echo ""
