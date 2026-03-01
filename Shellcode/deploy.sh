#!/bin/bash
# deploy.sh — spins up the full infrastructure for this project
# MontyIIT | us-east-1 | written 2026-02-28
#
# runs through six steps in order:
#   1. IAM role with just enough permissions
#   2. key pair for SSH
#   3. security group (SSH locked to my IP, HTTP/HTTPS open)
#   4. baseline EC2 instance to sanity-check things
#   5. launch template so the ASG has something consistent to clone
#   6. auto scaling group with a CPU-based scaling policy
#
# each step checks if the resource already exists before creating it,
# so you can safely re-run this without it blowing up.
#
# usage: chmod +x deploy.sh && ./deploy.sh

set -e
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[done] $1${NC}"; }
warn()   { echo -e "${YELLOW}[warn] $1${NC}"; }
error()  { echo -e "${RED}[err]  $1${NC}"; exit 1; }
header() {
  echo -e "\n${BLUE}--- $1 ---${NC}"
}

# tweak these if you're deploying to a different account or just want
# different names — everything else flows from here
REGION="us-east-1"
ACCOUNT_ID="783330586370"
AMI_ID="ami-0f3caa1cf4417e51b"   # Amazon Linux 2023, us-east-1
INSTANCE_TYPE="t2.micro"          # free tier, good enough for this
KEY_PAIR_NAME="my-ec2-keypair"
VM_NAME="web-app-vm"
SG_NAME="web-app-sg"
SG_DESCRIPTION="Firewall for web application EC2 instances"
IAM_ROLE_NAME="EC2-ReadOnly-Role"
LAUNCH_TEMPLATE_NAME="web-app-launch-template"
ASG_NAME="web-app-asg"
ASG_MIN=1
ASG_MAX=5
ASG_DESIRED=2
CPU_TARGET=70.0   # add instances when avg CPU crosses 70%
VOLUME_SIZE=20    # GB

# pull the default VPC id rather than hard-coding it
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text --region "$REGION")

header "before we start"

# bail out early if the basics aren't in place
command -v aws >/dev/null 2>&1 || error "aws cli not found — install it first: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1 || \
  error "no aws credentials found — run 'aws configure' and try again"

CALLER=$(aws sts get-caller-identity --query 'Account' --output text)
log "account: $CALLER"
log "region:  $REGION"
log "vpc:     $VPC_ID"
echo ""

# step 1 — iam role
# the instance needs to be able to read from S3, push metrics to cloudwatch,
# and talk to SSM so we don't need to keep port 22 open all the time.
# keeping it read-only means even if someone gets in, they can't do much.
header "step 1: iam role ($IAM_ROLE_NAME)"

if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  warn "role already exists, skipping"
else
  # dump the trust policy to a temp file so we can pass it to the cli
  cat > /tmp/ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  aws iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
    --description "Least-privilege role for web app EC2 instances" \
    >/dev/null

  # only attaching what the instance actually needs — nothing more
  for POLICY_ARN in \
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess" \
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy" \
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"; do
    aws iam attach-role-policy \
      --role-name "$IAM_ROLE_NAME" \
      --policy-arn "$POLICY_ARN"
    log "  Attached: $POLICY_ARN"
  done

  # the role itself can't be assigned to an instance directly — you need
  # an instance profile wrapper. a bit redundant but that's how AWS works.
  aws iam create-instance-profile \
    --instance-profile-name "$IAM_ROLE_NAME" >/dev/null 2>&1 || true
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$IAM_ROLE_NAME" \
    --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1 || true

  log "role created"
  log "sleeping 10s — iam changes take a moment to propagate across regions"
  sleep 10
fi

IAM_PROFILE_ARN="arn:aws:iam::${ACCOUNT_ID}:instance-profile/${IAM_ROLE_NAME}"

# step 2 — key pair
# aws only lets you download the private key once, right at creation time.
# the .pem file lands in the current directory — don't lose it.
header "step 2: key pair ($KEY_PAIR_NAME)"

if aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" \
    --region "$REGION" >/dev/null 2>&1; then
  warn "key pair already exists, skipping"
else
  aws ec2 create-key-pair \
    --key-name "$KEY_PAIR_NAME" \
    --query 'KeyMaterial' \
    --output text \
    --region "$REGION" > "${KEY_PAIR_NAME}.pem"

  chmod 400 "${KEY_PAIR_NAME}.pem"
  log "saved as ${KEY_PAIR_NAME}.pem"
fi

# step 3 — security group
# SSH is locked to whatever IP you're on right now. HTTP/HTTPS are open
# since this is meant to be a public web server.
# if your IP changes, you'll need to update the SSH rule manually.
header "step 3: security group ($SG_NAME)"

# figure out current public IP so we can lock SSH to it
MY_IP=$(curl -s https://checkip.amazonaws.com)/32
log "locking SSH to $MY_IP"

# skip if it's already there
EXISTING_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text --region "$REGION" 2>/dev/null)

if [ "$EXISTING_SG" != "None" ] && [ -n "$EXISTING_SG" ]; then
  warn "security group already there ($EXISTING_SG), reusing it"
  SG_ID=$EXISTING_SG
else
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "$SG_DESCRIPTION" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' --output text)

  log "created: $SG_ID"

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" --protocol tcp --port 22 \
    --cidr "$MY_IP" --region "$REGION" >/dev/null
  log "  ssh  (22)  → $MY_IP only"

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" --protocol tcp --port 80 \
    --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
  log "  http (80)  → anywhere"

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" --protocol tcp --port 443 \
    --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
  log "  https(443) → anywhere"

  log "security group ready"
fi

# step 4 — ec2 instance
# this is just a single "seed" instance to make sure everything connects
# before we let the ASG start spinning up copies of it.
header "step 4: ec2 instance ($VM_NAME)"

EXISTING_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$VM_NAME" \
            "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text --region "$REGION" 2>/dev/null)

if [ "$EXISTING_INSTANCE" != "None" ] && [ -n "$EXISTING_INSTANCE" ]; then
  warn "instance already running ($EXISTING_INSTANCE), skipping"
  INSTANCE_ID=$EXISTING_INSTANCE
else
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_PAIR_NAME" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile Name="$IAM_ROLE_NAME" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\"}}]" \
    --user-data file://configs/userdata.sh \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=$VM_NAME},{Key=Environment,Value=Production},{Key=Project,Value=AutoScalingDemo}]" \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' \
    --output text)

  log "launched: $INSTANCE_ID — waiting for it to come up..."
  aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" --region "$REGION"
  log "instance is running"
fi

# step 5 — launch template
# this is what the ASG clones every time it needs a new instance.
# getting this right means all scaled-out instances are identical.
header "step 5: launch template ($LAUNCH_TEMPLATE_NAME)"

EXISTING_LT=$(aws ec2 describe-launch-templates \
  --filters "Name=launch-template-name,Values=$LAUNCH_TEMPLATE_NAME" \
  --query "LaunchTemplates[0].LaunchTemplateId" \
  --output text --region "$REGION" 2>/dev/null)

if [ "$EXISTING_LT" != "None" ] && [ -n "$EXISTING_LT" ]; then
  warn "template already exists ($EXISTING_LT), skipping"
  LT_ID=$EXISTING_LT
else
  USERDATA_B64=$(base64 -w0 configs/userdata.sh)

  LT_ID=$(aws ec2 create-launch-template \
    --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
    --version-description "v1 — initial production template" \
    --launch-template-data "{
      \"ImageId\": \"$AMI_ID\",
      \"InstanceType\": \"$INSTANCE_TYPE\",
      \"KeyName\": \"$KEY_PAIR_NAME\",
      \"SecurityGroupIds\": [\"$SG_ID\"],
      \"IamInstanceProfile\": { \"Name\": \"$IAM_ROLE_NAME\" },
      \"BlockDeviceMappings\": [{
        \"DeviceName\": \"/dev/xvda\",
        \"Ebs\": { \"VolumeSize\": $VOLUME_SIZE, \"VolumeType\": \"gp3\", \"DeleteOnTermination\": true }
      }],
      \"UserData\": \"$USERDATA_B64\",
      \"TagSpecifications\": [{
        \"ResourceType\": \"instance\",
        \"Tags\": [
          {\"Key\": \"Name\",        \"Value\": \"$ASG_NAME-instance\"},
          {\"Key\": \"Environment\", \"Value\": \"Production\"},
          {\"Key\": \"ManagedBy\",   \"Value\": \"AutoScaling\"}
        ]
      }]
    }" \
    --region "$REGION" \
    --query 'LaunchTemplate.LaunchTemplateId' \
    --output text)

  log "template created: $LT_ID"
fi

# step 6 — auto scaling group + scaling policy
# min=1 keeps at least one instance alive, desired=2 for some redundancy,
# max=5 so a spike doesn't rack up a huge bill.
# the target tracking policy handles the math — we just pick 70% as the target.
header "step 6: auto scaling group ($ASG_NAME)"

# spread across all default subnets so we get multi-AZ automatically
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=defaultForAz,Values=true" \
  --query "Subnets[*].SubnetId" \
  --output text --region "$REGION" | tr '\t' ',')

EXISTING_ASG=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query "AutoScalingGroups[0].AutoScalingGroupName" \
  --output text --region "$REGION" 2>/dev/null)

if [ "$EXISTING_ASG" != "None" ] && [ -n "$EXISTING_ASG" ]; then
  warn "asg already exists, skipping"
else
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateId=$LT_ID,Version=\$Latest" \
    --min-size "$ASG_MIN" \
    --max-size "$ASG_MAX" \
    --desired-capacity "$ASG_DESIRED" \
    --vpc-zone-identifier "$SUBNET_IDS" \
    --health-check-type EC2 \
    --health-check-grace-period 300 \
    --tags "Key=Name,Value=$ASG_NAME,PropagateAtLaunch=true" \
           "Key=Environment,Value=Production,PropagateAtLaunch=true" \
    --region "$REGION"

  log "asg created (min=$ASG_MIN / desired=$ASG_DESIRED / max=$ASG_MAX)"

  # wire up the scaling policy — target tracking means aws handles everything,
  # we just tell it what cpu % to aim for
  aws autoscaling put-scaling-policy \
    --auto-scaling-group-name "$ASG_NAME" \
    --policy-name "scale-out-cpu" \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration "{
      \"PredefinedMetricSpecification\": {
        \"PredefinedMetricType\": \"ASGAverageCPUUtilization\"
      },
      \"TargetValue\": $CPU_TARGET,
      \"DisableScaleIn\": false
    }" \
    --estimated-instance-warmup 300 \
    --region "$REGION" >/dev/null

  log "scaling policy attached — target ${CPU_TARGET}% avg cpu"
fi

echo ""
echo -e "${GREEN}all done.${NC}"
echo ""
echo "  iam role       : $IAM_ROLE_NAME"
echo "  security group : $SG_NAME ($SG_ID)"
echo "  ec2 instance   : $VM_NAME ($INSTANCE_ID)"
echo "  launch template: $LAUNCH_TEMPLATE_NAME ($LT_ID)"
echo "  asg            : $ASG_NAME"
echo "  region         : $REGION"
echo ""
echo "  to clean everything up: ./teardown.sh"
echo ""
