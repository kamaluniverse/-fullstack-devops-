#!/usr/bin/env bash
# 04-instances.sh — key pair, three EC2 instances and stable public IPs.
#
#   app     -> public subnet  (Nginx entry point)
#   mongo   -> private subnet (no public IP, no internet ingress)
#   jenkins -> public subnet  (admin-only 8080)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"
require VPC_ID
require PUBLIC_SUBNET_ID
require PRIVATE_SUBNET_ID
require APP_SG_ID
require JENKINS_SG_ID
require MONGO_SG_ID
require INSTANCE_PROFILE_NAME

KEY_NAME="${KEY_NAME:-${PROJECT}-key}"
KEY_PATH="${KEY_PATH:-$ROOT_DIR/infra/${KEY_NAME}.pem}"
APP_INSTANCE_TYPE="${APP_INSTANCE_TYPE:-t3.small}"
MONGO_INSTANCE_TYPE="${MONGO_INSTANCE_TYPE:-t3.small}"
JENKINS_INSTANCE_TYPE="${JENKINS_INSTANCE_TYPE:-t3.small}"
VOLUME_SIZE="${VOLUME_SIZE:-20}"

log "Key pair $KEY_NAME"
if ! awsq ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  awsq ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$KEY_PATH"
  chmod 600 "$KEY_PATH"
  echo "Saved private key to $KEY_PATH (gitignored)"
else
  [[ -f "$KEY_PATH" ]] || warn "Key pair exists in AWS but $KEY_PATH is missing"
fi
set_output KEY_NAME "$KEY_NAME"
set_output KEY_PATH "$KEY_PATH"

log "Resolving Ubuntu 24.04 AMI"
AMI_ID="${AMI_ID:-$(awsq ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameter.Value' --output text)}"
set_output AMI_ID "$AMI_ID"

USERDATA_DIR="${USERDATA_DIR:-/tmp/opencode}"
mkdir -p "$USERDATA_DIR"

cat > "$USERDATA_DIR/userdata-app.sh" <<'EOF'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git unzip jq
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
systemctl enable --now docker
usermod -aG docker ubuntu
mkdir -p /opt/proshop && chown ubuntu:ubuntu /opt/proshop
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
EOF

cat > "$USERDATA_DIR/userdata-mongo.sh" <<'EOF'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
systemctl enable --now docker
usermod -aG docker ubuntu
mkdir -p /opt/proshop && chown ubuntu:ubuntu /opt/proshop
EOF

cat > "$USERDATA_DIR/userdata-jenkins.sh" <<'EOF'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Swap helps a 2 GB build agent survive image builds.
fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

apt-get update -y
apt-get install -y ca-certificates curl git unzip jq fontconfig openjdk-21-jre-headless

curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
systemctl enable --now docker
usermod -aG docker ubuntu

# The 2023 signing key expired in March 2026; use the current key.
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
  | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list
apt-get update -y
apt-get install -y jenkins
usermod -aG docker jenkins
systemctl enable --now jenkins
EOF

launch() {
  local name="$1" type="$2" subnet="$3" sg="$4" userdata="$5" public="$6"
  local existing
  existing="$(find_instance "$name")"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi

  local public_flag=(--no-associate-public-ip-address)
  [[ "$public" == "yes" ]] && public_flag=(--associate-public-ip-address)

  awsq ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$type" \
    --key-name "$KEY_NAME" \
    --subnet-id "$subnet" \
    --security-group-ids "$sg" \
    --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
    "${public_flag[@]}" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${VOLUME_SIZE},VolumeType=gp3,DeleteOnTermination=true}" \
    --user-data "file://${userdata}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}}]" \
    --query 'Instances[0].InstanceId' --output text
}

log "Launching app instance"
APP_INSTANCE_ID="$(launch "${PROJECT}-app" "$APP_INSTANCE_TYPE" "$PUBLIC_SUBNET_ID" "$APP_SG_ID" "$USERDATA_DIR/userdata-app.sh" yes)"
log "Launching mongo instance (private subnet)"
MONGO_INSTANCE_ID="$(launch "${PROJECT}-mongo" "$MONGO_INSTANCE_TYPE" "$PRIVATE_SUBNET_ID" "$MONGO_SG_ID" "$USERDATA_DIR/userdata-mongo.sh" no)"
log "Launching jenkins instance"
JENKINS_INSTANCE_ID="$(launch "${PROJECT}-jenkins" "$JENKINS_INSTANCE_TYPE" "$PUBLIC_SUBNET_ID" "$JENKINS_SG_ID" "$USERDATA_DIR/userdata-jenkins.sh" yes)"

set_output APP_INSTANCE_ID "$APP_INSTANCE_ID"
set_output MONGO_INSTANCE_ID "$MONGO_INSTANCE_ID"
set_output JENKINS_INSTANCE_ID "$JENKINS_INSTANCE_ID"

log "Waiting for instances to be running"
awsq ec2 wait instance-running --instance-ids "$APP_INSTANCE_ID" "$MONGO_INSTANCE_ID" "$JENKINS_INSTANCE_ID"

MONGO_PRIVATE_IP="$(awsq ec2 describe-instances --instance-ids "$MONGO_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
set_output MONGO_PRIVATE_IP "$MONGO_PRIVATE_IP"

allocate_eip() {
  local name="$1" instance="$2" alloc
  alloc="$(awsq ec2 describe-addresses --filters "Name=tag:Name,Values=${name}" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null | grep -v '^None$' || true)"
  if [[ -z "$alloc" ]]; then
    alloc="$(awsq ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${name}}]" \
      --query 'AllocationId' --output text)"
  fi
  awsq ec2 associate-address --instance-id "$instance" --allocation-id "$alloc" >/dev/null 2>&1 || true
  awsq ec2 describe-addresses --allocation-ids "$alloc" --query 'Addresses[0].PublicIp' --output text
}

log "Associating Elastic IPs"
APP_PUBLIC_IP="$(allocate_eip "${PROJECT}-app-eip" "$APP_INSTANCE_ID")"
JENKINS_PUBLIC_IP="$(allocate_eip "${PROJECT}-jenkins-eip" "$JENKINS_INSTANCE_ID")"
set_output APP_PUBLIC_IP "$APP_PUBLIC_IP"
set_output JENKINS_PUBLIC_IP "$JENKINS_PUBLIC_IP"

log "Instances ready"
cat <<EOF

  app      ${APP_INSTANCE_ID}  public ${APP_PUBLIC_IP}
  mongo    ${MONGO_INSTANCE_ID}  private ${MONGO_PRIVATE_IP}
  jenkins  ${JENKINS_INSTANCE_ID}  public ${JENKINS_PUBLIC_IP}

  SSH: ssh -i ${KEY_PATH} ubuntu@${APP_PUBLIC_IP}

  Wait ~2-3 minutes for user-data (Docker/Jenkins installation) to finish.
EOF
