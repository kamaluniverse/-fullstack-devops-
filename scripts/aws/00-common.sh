#!/usr/bin/env bash
# Shared helpers for the ProShop AWS provisioning scripts.
# Source this file from the numbered scripts; do not execute it directly.
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
AWS="${AWS_CLI:-aws}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${PROJECT:-proshop}"
ADMIN_CIDR="${ADMIN_CIDR:-54.81.38.205/32}"
OUTPUT_FILE="${OUTPUT_FILE:-$ROOT_DIR/infra/aws-outputs.env}"

mkdir -p "$(dirname "$OUTPUT_FILE")"
touch "$OUTPUT_FILE"
# shellcheck disable=SC1090
source "$OUTPUT_FILE"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

set_output() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  grep -v "^${key}=" "$OUTPUT_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$OUTPUT_FILE"
  export "${key}=${value}"
}

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "$name is not set. Run the earlier provisioning scripts first."
  fi
}

awsq() { "$AWS" "$@" --region "$AWS_REGION"; }

# Look up the single VPC tagged with ${PROJECT}-vpc (empty if none).
find_vpc() {
  awsq ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT}-vpc" "Name=state,Values=available" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep -v '^None$' || true
}

# Look up a subnet by Name tag.
find_subnet() {
  awsq ec2 describe-subnets \
    --filters "Name=tag:Name,Values=$1" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null | grep -v '^None$' || true
}

# Look up a security group by Name tag inside the project VPC.
find_sg() {
  local name="$1"
  require VPC_ID
  awsq ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${name}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true
}

# Look up a running/pending instance by Name tag.
find_instance() {
  awsq ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=pending,running,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null | grep -v '^None$' || true
}
