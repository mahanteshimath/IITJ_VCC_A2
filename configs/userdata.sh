#!/bin/bash
# ============================================================
# userdata.sh — EC2 Instance Bootstrap Script
#
# This runs automatically the very first time the instance
# boots. It installs a simple web server so you can verify
# the instance is reachable over HTTP straight away.
#
# You can also drop any app-specific setup steps in here —
# pulling from S3, configuring environment variables, etc.
# ============================================================

set -e
exec > >(tee /var/log/userdata.log | logger -t userdata -s 2>/dev/console) 2>&1

echo "=== Bootstrap started at $(date) ==="

# ── System update ─────────────────────────────────────────────
echo "--- Updating system packages..."
dnf update -y

# ── Install a lightweight web server ─────────────────────────
echo "--- Installing Nginx..."
dnf install -y nginx

# ── Write a simple health-check page ─────────────────────────
# CloudWatch and load balancer health checks hit port 80,
# so a minimal page is enough to confirm the instance is alive.
cat > /usr/share/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>web-app-vm — Running</title>
  <style>
    body { font-family: sans-serif; text-align: center; padding: 60px; background: #f4f6f9; }
    h1   { color: #2c7be5; }
    p    { color: #555; }
    code { background: #eee; padding: 2px 6px; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>✅ Instance is healthy</h1>
  <p>Host: <code id="host"></code></p>
  <p>Launched by the AutoScaling demo project on MontyIIT / us-east-1</p>
  <script>document.getElementById('host').textContent = location.hostname;</script>
</body>
</html>
EOF

# ── Start the web server and make it persist across reboots ──
echo "--- Enabling and starting Nginx..."
systemctl enable nginx
systemctl start nginx

# ── Install the CloudWatch agent ──────────────────────────────
# This agent ships CPU, memory, and disk metrics to CloudWatch
# so the Auto Scaling policy has accurate data to act on.
echo "--- Installing CloudWatch agent..."
dnf install -y amazon-cloudwatch-agent

# Minimal CloudWatch config: collect per-second CPU metrics
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
  "metrics": {
    "namespace": "WebAppDemo",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 60,
        "totalcpu": true
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["/"]
      }
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

echo "--- CloudWatch agent started."

# ── Tag the instance with the launch timestamp ────────────────
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

aws ec2 create-tags \
  --resources "$INSTANCE_ID" \
  --tags "Key=LaunchedAt,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --region "$REGION" || true   # non-critical, don't fail the boot if this errors

echo "=== Bootstrap complete at $(date) ==="
