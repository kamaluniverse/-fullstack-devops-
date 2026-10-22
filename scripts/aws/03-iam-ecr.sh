#!/usr/bin/env bash
# 03-iam-ecr.sh — EC2 instance role (ECR pull + SSM) and private ECR repos.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text)"
ROLE_NAME="${PROJECT}-ec2-role"
PROFILE_NAME="${PROJECT}-ec2-profile"

log "IAM role $ROLE_NAME"
if ! awsq iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  TRUST_FILE="$(mktemp)"
  cat > "$TRUST_FILE" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "ec2.amazonaws.com" }, "Action": "sts:AssumeRole" }
  ]
}
JSON
  awsq iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://${TRUST_FILE}" \
    --tags "Key=Project,Value=${PROJECT}" >/dev/null
  rm -f "$TRUST_FILE"
fi

for policy in arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
              arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore; do
  awsq iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy"
done

log "Instance profile $PROFILE_NAME"
if ! awsq iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  awsq iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
  awsq iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
  # Instance profiles need a moment to propagate before EC2 can use them.
  sleep 10
fi

set_output ROLE_NAME "$ROLE_NAME"
set_output INSTANCE_PROFILE_NAME "$PROFILE_NAME"
set_output ACCOUNT_ID "$ACCOUNT_ID"

log "ECR repositories"
ensure_repo() {
  local name="$1"
  if ! awsq ecr describe-repositories --repository-names "$name" >/dev/null 2>&1; then
    awsq ecr create-repository --repository-name "$name" \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 >/dev/null
  fi
}
ensure_repo "${PROJECT}/backend"
ensure_repo "${PROJECT}/frontend"

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
set_output ECR_REGISTRY "$ECR_REGISTRY"
set_output ECR_REPO_PREFIX "$PROJECT"

log "IAM + ECR ready"
printf 'Role=%s\nInstanceProfile=%s\nECR=%s\n' "$ROLE_NAME" "$PROFILE_NAME" "$ECR_REGISTRY"
