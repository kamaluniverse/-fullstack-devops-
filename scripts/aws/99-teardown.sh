#!/usr/bin/env bash
# 99-teardown.sh — destroy everything created by the provisioning scripts.
#
#   ./scripts/aws/99-teardown.sh
#
# Deletes instances, EIPs, NAT gateway, IGW, subnets, route tables, VPC,
# security groups, the instance profile/role and the ECR repositories.
# MongoDB data on EBS is deleted with the instance: take a backup first if you
# need it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

confirm() {
  read -r -p "This will DELETE the ${PROJECT} AWS resources. Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || { echo "aborted"; exit 1; }
}
confirm

log "Terminating instances"
IDS=()
for name in "${PROJECT}-app" "${PROJECT}-mongo" "${PROJECT}-jenkins"; do
  id="$(find_instance "$name")"
  [[ -n "$id" ]] && IDS+=("$id")
done
if [[ ${#IDS[@]} -gt 0 ]]; then
  awsq ec2 terminate-instances --instance-ids "${IDS[@]}" >/dev/null
  awsq ec2 wait instance-terminated --instance-ids "${IDS[@]}"
fi

log "Releasing Elastic IPs"
for name in "${PROJECT}-nat-eip" "${PROJECT}-app-eip" "${PROJECT}-jenkins-eip"; do
  alloc="$(awsq ec2 describe-addresses --filters "Name=tag:Name,Values=${name}" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null | grep -v '^None$' || true)"
  [[ -n "$alloc" ]] && awsq ec2 release-address --allocation-id "$alloc" || true
done

log "Deleting NAT gateway"
NAT_ID="$(awsq ec2 describe-nat-gateways --filter "Name=tag:Name,Values=${PROJECT}-nat" \
  --query 'NatGateways[?State!=`deleted`][0].NatGatewayId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -n "$NAT_ID" ]]; then
  awsq ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" >/dev/null
  echo "Waiting for NAT gateway deletion..."
  for _ in $(seq 1 60); do
    state="$(awsq ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" --query 'NatGateways[0].State' --output text)"
    [[ "$state" == "deleted" ]] && break
    sleep 5
  done
fi

log "Deleting security groups"
for sg in "${PROJECT}-app-sg" "${PROJECT}-jenkins-sg" "${PROJECT}-mongo-sg"; do
  id="$(find_sg "$sg" 2>/dev/null || true)"
  [[ -n "$id" ]] && awsq ec2 delete-security-group --group-id "$id" >/dev/null || true
done

log "Deleting subnets, route tables, IGW, VPC"
for name in "${PROJECT}-public-a" "${PROJECT}-private-a"; do
  id="$(find_subnet "$name")"
  [[ -n "$id" ]] && awsq ec2 delete-subnet --subnet-id "$id" >/dev/null || true
done
for name in "${PROJECT}-public-rt" "${PROJECT}-private-rt"; do
  id="$(awsq ec2 describe-route-tables --filters "Name=tag:Name,Values=${name}" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null | grep -v '^None$' || true)"
  if [[ -n "$id" ]]; then
    # Disassociate before deleting
    awsq ec2 describe-route-tables --route-table-ids "$id" \
      --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text \
      | tr '\t' '\n' | while read -r assoc; do
          [[ -n "$assoc" && "$assoc" != "None" ]] && awsq ec2 disassociate-route-table --association-id "$assoc" >/dev/null || true
        done
    awsq ec2 delete-route-table --route-table-id "$id" >/dev/null || true
  fi
done
IGW_ID="${IGW_ID:-$(awsq ec2 describe-internet-gateways --filters "Name=tag:Name,Values=${PROJECT}-igw" \
  --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null | grep -v '^None$' || true)}"
if [[ -n "$IGW_ID" ]]; then
  awsq ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
  awsq ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" >/dev/null 2>&1 || true
fi
VPC_ID="${VPC_ID:-$(find_vpc)}"
[[ -n "$VPC_ID" ]] && awsq ec2 delete-vpc --vpc-id "$VPC_ID" >/dev/null || true

log "Deleting IAM role/profile and ECR repositories"
awsq iam remove-role-from-instance-profile --instance-profile-name "${PROJECT}-ec2-profile" --role-name "${PROJECT}-ec2-role" >/dev/null 2>&1 || true
awsq iam delete-instance-profile --instance-profile-name "${PROJECT}-ec2-profile" >/dev/null 2>&1 || true
for policy in arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
              arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore; do
  awsq iam detach-role-policy --role-name "${PROJECT}-ec2-role" --policy-arn "$policy" >/dev/null 2>&1 || true
done
awsq iam delete-role --role-name "${PROJECT}-ec2-role" >/dev/null 2>&1 || true
for repo in "${PROJECT}/backend" "${PROJECT}/frontend"; do
  awsq ecr delete-repository --repository-name "$repo" --force >/dev/null 2>&1 || true
done

rm -f "$OUTPUT_FILE"
warn "Teardown complete. EBS volumes marked DeleteOnTermination were removed with the instances."
