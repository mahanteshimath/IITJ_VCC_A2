#!/bin/bash

# ============================================================
#  AWS Assignment Cleanup Script
#  Assignment: EC2 Web App with Auto Scaling
#  Author: MontyIIT
#  Date: March 01, 2026
#  Region: us-east-1
# ============================================================

set -e

REGION="us-east-1"
ASG_NAME="web-app-asg"
INSTANCE_ID="i-01db3707448940ea5"
LAUNCH_TEMPLATE_ID="lt-0d76cf328bc05d526"
IAM_ROLE_NAME="EC2-ReadOnly-Role"
SECURITY_GROUP_ID="sg-07dc43887d2d72637"

echo ""
echo "============================================================"
echo " AWS Assignment Resource Cleanup"
echo "============================================================"
echo ""

# ------------------------------------------------------------
# STEP 1: Delete Auto Scaling Group (force-delete terminates
#         any instances managed by the ASG automatically)
# ------------------------------------------------------------
echo "[1/5] Deleting Auto Scaling Group: $ASG_NAME ..."
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" \
  --force-delete \
  --region "$REGION" && echo "      -> ASG deleted successfully."
echo ""

# ------------------------------------------------------------
# STEP 2: Terminate standalone EC2 Instance
# ------------------------------------------------------------
echo "[2/5] Terminating EC2 Instance: $INSTANCE_ID ..."
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'TerminatingInstances[0].CurrentState.Name' \
  --output text && echo "      -> Instance termination initiated."
echo ""

# ------------------------------------------------------------
# STEP 3: Delete Launch Template
# ------------------------------------------------------------
echo "[3/5] Deleting Launch Template: $LAUNCH_TEMPLATE_ID ..."
aws ec2 delete-launch-template \
  --launch-template-id "$LAUNCH_TEMPLATE_ID" \
  --region "$REGION" \
  --query 'LaunchTemplate.LaunchTemplateName' \
  --output text && echo "      -> Launch template deleted successfully."
echo ""

# ------------------------------------------------------------
# STEP 4: Clean up IAM Role
#   4a. Detach all managed policies
#   4b. Remove role from instance profile
#   4c. Delete instance profile
#   4d. Delete the role
# ------------------------------------------------------------
echo "[4/5] Cleaning up IAM Role: $IAM_ROLE_NAME ..."

echo "      Detaching policies..."
aws iam detach-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam detach-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam detach-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
echo "      -> All policies detached."

echo "      Removing role from instance profile..."
aws iam remove-role-from-instance-profile \
  --instance-profile-name "$IAM_ROLE_NAME" \
  --role-name "$IAM_ROLE_NAME"
echo "      -> Role removed from instance profile."

echo "      Deleting instance profile..."
aws iam delete-instance-profile \
  --instance-profile-name "$IAM_ROLE_NAME"
echo "      -> Instance profile deleted."

echo "      Deleting IAM role..."
aws iam delete-role \
  --role-name "$IAM_ROLE_NAME" && echo "      -> IAM role deleted successfully."
echo ""

# ------------------------------------------------------------
# STEP 5: Delete Security Group
#   NOTE: Must wait for EC2 instance to fully terminate first,
#         otherwise AWS will reject deletion (instance still
#         holds a reference to the security group).
# ------------------------------------------------------------
echo "[5/5] Waiting for EC2 instance to fully terminate..."
aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" && echo "      -> Instance fully terminated."

echo "      Deleting Security Group: $SECURITY_GROUP_ID ..."
aws ec2 delete-security-group \
  --group-id "$SECURITY_GROUP_ID" \
  --region "$REGION" && echo "      -> Security group deleted successfully."
echo ""

# ------------------------------------------------------------
# DONE
# ------------------------------------------------------------
echo "============================================================"
echo " All AWS resources cleaned up successfully!"
echo " Zero active resources. No further charges will accrue."
echo "============================================================"
echo ""
