# AWS Infrastructure Setup — Assignment 2

This document walks through everything I set up on AWS for this assignment. All five steps are complete and the resources are live in the **us-east-1 (N. Virginia)** region under the **MontyIIT** account.

---

## Step 1 — Creating an IAM Role

**Role name:** `EC2-ReadOnly-Role`

The first thing I did was head over to **IAM → Roles → Create role** and set up a role that my EC2 instance could use. I chose **AWS Service → EC2** as the trusted entity, which means only EC2 instances can assume this role.

I attached three policies to it:

- **`AmazonS3ReadOnlyAccess`** — lets the EC2 instance read from S3 buckets, but not write anything
- **`CloudWatchAgentServerPolicy`** — allows the instance to push metrics and logs to CloudWatch
- **`AmazonSSMManagedInstanceCore`** — enables Systems Manager access so I don't need to open SSH at all

**Role ARN:** `arn:aws:iam::783330586370:instance-profile/EC2-ReadOnly-Role`


![alt text](image.png)
---

## Step 2 — Setting Up a Security Group

**Name:** `web-app-sg` | **ID:** `sg-07dc43887d2d72637`

Next, I created a security group under **EC2 → Security Groups** to control what traffic is allowed in and out of the instance. I kept it pretty minimal — only the ports that are actually needed:

| Type  | Port | Source                  | Why                          |
|-------|------|-------------------------|------------------------------|
| SSH   | 22   | My IP (205.254.163.5/32) | So only I can SSH in         |
| HTTP  | 80   | 0.0.0.0/0               | Anyone can reach the web app |
| HTTPS | 443  | 0.0.0.0/0               | Secure access for everyone   |

Restricting SSH to just my IP is a simple but important security step — no need to leave that open to the world.


![alt text](image-1.png)
---

## Step 3 — Launching the EC2 Instance

**Name:** `web-app-vm` | **Instance ID:** `i-01db3707448940ea5`

With the role and security group ready, I launched an EC2 instance from **EC2 → Launch Instances**. Here's what I went with:

- **AMI:** Amazon Linux 2023 (`ami-0f3caa1cf4417e51b`)
- **Instance type:** `t2.micro` — 1 vCPU, 1 GiB RAM, and it's Free Tier eligible
- **Key pair:** `my-ec2-keypair` (RSA, .pem format)
- **Security group:** `web-app-sg` (the one I just created)
- **Storage:** 20 GiB gp3
- **IAM Role:** `EC2-ReadOnly-Role` attached so it can access S3, CloudWatch, and SSM

![alt text](image-2.png)
---

## Step 4 — Creating a Launch Template

**Name:** `web-app-launch-template` | **ID:** `lt-0d76cf328bc05d526`

A launch template makes it easy to spin up new instances consistently — especially useful for auto scaling. I created the initial template through the Console, then updated it to **Version 3** using [CloudShell](https://us-east-1.console.aws.amazon.com/cloudshell/home?region=us-east-1) so the latest AMI was set as the default.

The template captures all the same settings as the instance above:

- **AMI:** `ami-0f3caa1cf4417e51b` (Amazon Linux 2023)
- **Instance type:** `t2.micro`
- **Key pair:** `my-ec2-keypair`
- **Security group:** `sg-07dc43887d2d72637`
- **IAM profile:** `EC2-ReadOnly-Role`

Here's the CLI command I ran in CloudShell to create the new template version:

```bash
aws ec2 create-launch-template-version \
  --launch-template-id lt-0d76cf328bc05d526 \
  --source-version 1 \
  --launch-template-data '{"ImageId":"ami-0f3caa1cf4417e51b"}' \
  --region us-east-1
```
![alt text](image-3.png)
---

## Step 5 — Auto Scaling Group with CPU-Based Scaling

**Name:** `web-app-asg`

The final step was setting up an [Auto Scaling Group](https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#AutoScalingGroups:) so the infrastructure can handle varying load automatically without manual intervention.

**Group settings:**

| Setting            | Value                              |
|--------------------|------------------------------------|
| Min instances      | 1                                  |
| Desired instances  | 2                                  |
| Max instances      | 5                                  |
| Availability Zones | us-east-1a, us-east-1b, us-east-1c |
| Health check       | EC2 (300s grace period)            |

I also created a **Target Tracking scaling policy** called `scale-out-cpu`. The idea is simple — if average CPU across the group climbs to **70%**, AWS automatically adds more instances. When the load drops back down, it removes them. No manual scaling needed.

A few details on the policy:
- Scale-in is enabled, so instances are cleaned up when they're no longer needed
- New instances get a **300-second warm-up** before they're counted in scaling decisions
- AWS automatically created two CloudWatch alarms: one to trigger scale-out (AlarmHigh) and one for scale-in (AlarmLow)
![alt text](image-4.png)
---

## Summary

Here's a quick overview of everything that was created:

| Resource         | Name                      | ID / ARN                                  |
|------------------|---------------------------|-------------------------------------------|
| IAM Role         | `EC2-ReadOnly-Role`        | arn:aws:iam::783330586370:...             |
| Security Group   | `web-app-sg`               | sg-07dc43887d2d72637                      |
| EC2 Instance     | `web-app-vm`               | i-01db3707448940ea5                       |
| Launch Template  | `web-app-launch-template`  | lt-0d76cf328bc05d526 (v3)                 |
| Auto Scaling Group | `web-app-asg`            | Min: 1 / Desired: 2 / Max: 5             |
| Scaling Policy   | `scale-out-cpu`            | Target tracking at 70% average CPU       |

Everything is up and running in **us-east-1 (N. Virginia)** on the **MontyIIT** account.
