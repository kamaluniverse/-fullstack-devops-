#!/usr/bin/env bash
# 05-jenkins-iam.sh — give the Jenkins host its own least-privilege role.
#
# The Jenkins instance needs to push images to ECR (the app/mongo hosts only
# need read access). Keeping a separate role avoids granting push to hosts that
# never build images.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"
require JENKINS_INSTANCE_ID
require ECR_REGISTRY

ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text)"
ROLE_NAME="${PROJECT}-jenkins-role"
PROFILE_NAME="${PROJECT}-jenkins-profile"

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

awsq iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

REPO_BACKEND="arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/${PROJECT}/backend"
REPO_FRONTEND="arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/${PROJECT}/frontend"
POLICY_FILE="$(mktemp)"
cat > "$POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "PushProShopImages",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": ["${REPO_BACKEND}", "${REPO_FRONTEND}"]
    }
  ]
}
JSON
awsq iam put-role-policy --role-name "$ROLE_NAME" --policy-name "${PROJECT}-ecr-push" \
  --policy-document "file://${POLICY_FILE}" >/dev/null
rm -f "$POLICY_FILE"

log "Instance profile $PROFILE_NAME"
if ! awsq iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  awsq iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
  awsq iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
  sleep 10
fi

log "Attaching the Jenkins profile to ${JENKINS_INSTANCE_ID}"
ASSOC="$(awsq ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=${JENKINS_INSTANCE_ID}" \
  --query 'IamInstanceProfileAssociations[0].AssociationId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -n "$ASSOC" ]]; then
  awsq ec2 replace-iam-instance-profile-association --association-id "$ASSOC" \
    --iam-instance-profile "Name=${PROFILE_NAME}" >/dev/null
else
  awsq ec2 associate-iam-instance-profile --instance-id "$JENKINS_INSTANCE_ID" \
    --iam-instance-profile "Name=${PROFILE_NAME}" >/dev/null
fi

set_output JENKINS_ROLE_NAME "$ROLE_NAME"
set_output JENKINS_PROFILE_NAME "$PROFILE_NAME"

log "Jenkins IAM ready"
echo "Role: $ROLE_NAME (ECR push limited to ${PROJECT}/backend and ${PROJECT}/frontend)"
