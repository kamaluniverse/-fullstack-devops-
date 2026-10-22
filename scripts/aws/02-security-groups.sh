#!/usr/bin/env bash
# 02-security-groups.sh — least-privilege security groups.
#
#   app-sg     : 80 from the internet, 22 from the admin IP only
#   jenkins-sg : 8080 + 22 from the admin IP only
#   mongo-sg   : 27017 (and 22 for admin tunnelling) from app-sg only
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"
require VPC_ID

ensure_sg() {
  local name="$1" desc="$2" id
  id="$(find_sg "$name")"
  if [[ -z "$id" ]]; then
    id="$(awsq ec2 create-security-group --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}}]" \
      --query 'GroupId' --output text)"
  fi
  printf '%s' "$id"
}

allow() {
  local sg="$1"; shift
  local out
  if out="$(awsq ec2 authorize-security-group-ingress --group-id "$sg" "$@" 2>&1)"; then
    return 0
  fi
  if grep -q 'InvalidPermission.Duplicate' <<<"$out"; then
    return 0
  fi
  echo "$out" >&2
  return 1
}

log "App security group"
APP_SG="$(ensure_sg "${PROJECT}-app-sg" "Public app host: HTTP + admin SSH")"
set_output APP_SG_ID "$APP_SG"
allow "$APP_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0
allow "$APP_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0
allow "$APP_SG" --protocol tcp --port 22 --cidr "$ADMIN_CIDR"

log "Jenkins security group"
JENKINS_SG="$(ensure_sg "${PROJECT}-jenkins-sg" "Jenkins host: admin-only web + SSH")"
set_output JENKINS_SG_ID "$JENKINS_SG"
allow "$JENKINS_SG" --protocol tcp --port 8080 --cidr "$ADMIN_CIDR"
allow "$JENKINS_SG" --protocol tcp --port 22 --cidr "$ADMIN_CIDR"

log "MongoDB security group"
MONGO_SG="$(ensure_sg "${PROJECT}-mongo-sg" "Private MongoDB: reachable only from the app SG")"
set_output MONGO_SG_ID "$MONGO_SG"
allow "$MONGO_SG" --protocol tcp --port 27017 --source-group "$APP_SG"
allow "$MONGO_SG" --protocol tcp --port 22 --source-group "$APP_SG"

# The CI server deploys over SSH; allow it explicitly instead of widening the
# admin CIDR rule.
allow "$APP_SG" --protocol tcp --port 22 --source-group "$JENKINS_SG"

log "Security groups ready"
printf 'APP_SG=%s\nJENKINS_SG=%s\nMONGO_SG=%s\n' "$APP_SG" "$JENKINS_SG" "$MONGO_SG"
