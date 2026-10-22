#!/usr/bin/env bash
# 01-network.sh — VPC, public subnets, private subnet, IGW, NAT gateway, routes.
# Idempotent: re-running reuses existing resources.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
PUBLIC_CIDR="${PUBLIC_CIDR:-10.0.1.0/24}"
PRIVATE_CIDR="${PRIVATE_CIDR:-10.0.2.0/24}"
AZ="${AZ:-${AWS_REGION}a}"

log "VPC"
VPC_ID="$(find_vpc)"
if [[ -z "$VPC_ID" ]]; then
  VPC_ID="$(awsq ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT}-vpc},{Key=Project,Value=${PROJECT}}]" \
    --query 'Vpc.VpcId' --output text)"
  awsq ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
  awsq ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
fi
set_output VPC_ID "$VPC_ID"
echo "VPC_ID=$VPC_ID"

log "Internet gateway"
IGW_ID="$(awsq ec2 describe-internet-gateways \
  --filters "Name=tag:Name,Values=${PROJECT}-igw" \
  --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -z "$IGW_ID" ]]; then
  IGW_ID="$(awsq ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT}-igw}]" \
    --query 'InternetGateway.InternetGatewayId' --output text)"
  awsq ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi
set_output IGW_ID "$IGW_ID"

log "Subnets"
PUBLIC_SUBNET_ID="$(find_subnet "${PROJECT}-public-a")"
if [[ -z "$PUBLIC_SUBNET_ID" ]]; then
  PUBLIC_SUBNET_ID="$(awsq ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUBLIC_CIDR" \
    --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-public-a}]" \
    --query 'Subnet.SubnetId' --output text)"
  awsq ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET_ID" --map-public-ip-on-launch
fi
set_output PUBLIC_SUBNET_ID "$PUBLIC_SUBNET_ID"

PRIVATE_SUBNET_ID="$(find_subnet "${PROJECT}-private-a")"
if [[ -z "$PRIVATE_SUBNET_ID" ]]; then
  PRIVATE_SUBNET_ID="$(awsq ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIVATE_CIDR" \
    --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-private-a}]" \
    --query 'Subnet.SubnetId' --output text)"
fi
set_output PRIVATE_SUBNET_ID "$PRIVATE_SUBNET_ID"

log "Public route table"
PUBLIC_RT_ID="$(awsq ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=${PROJECT}-public-rt" \
  --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -z "$PUBLIC_RT_ID" ]]; then
  PUBLIC_RT_ID="$(awsq ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-public-rt}]" \
    --query 'RouteTable.RouteTableId' --output text)"
  awsq ec2 create-route --route-table-id "$PUBLIC_RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  awsq ec2 associate-route-table --route-table-id "$PUBLIC_RT_ID" --subnet-id "$PUBLIC_SUBNET_ID" >/dev/null
fi
set_output PUBLIC_RT_ID "$PUBLIC_RT_ID"

log "NAT gateway (for private subnet egress)"
NAT_EIP_ALLOC="$(awsq ec2 describe-addresses \
  --filters "Name=tag:Name,Values=${PROJECT}-nat-eip" \
  --query 'Addresses[0].AllocationId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -z "$NAT_EIP_ALLOC" ]]; then
  NAT_EIP_ALLOC="$(awsq ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-nat-eip}]" \
    --query 'AllocationId' --output text)"
fi
set_output NAT_EIP_ALLOC "$NAT_EIP_ALLOC"

NAT_GW_ID="$(awsq ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=${PROJECT}-nat" "Name=state,Values=available,pending" \
  --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -z "$NAT_GW_ID" ]]; then
  NAT_GW_ID="$(awsq ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET_ID" \
    --allocation-id "$NAT_EIP_ALLOC" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT}-nat}]" \
    --query 'NatGateway.NatGatewayId' --output text)"
fi
set_output NAT_GW_ID "$NAT_GW_ID"
echo "Waiting for NAT gateway to become available..."
awsq ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"

log "Private route table"
PRIVATE_RT_ID="$(awsq ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=${PROJECT}-private-rt" \
  --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -z "$PRIVATE_RT_ID" ]]; then
  PRIVATE_RT_ID="$(awsq ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-private-rt}]" \
    --query 'RouteTable.RouteTableId' --output text)"
  awsq ec2 create-route --route-table-id "$PRIVATE_RT_ID" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW_ID" >/dev/null
  awsq ec2 associate-route-table --route-table-id "$PRIVATE_RT_ID" --subnet-id "$PRIVATE_SUBNET_ID" >/dev/null
fi
set_output PRIVATE_RT_ID "$PRIVATE_RT_ID"

log "Network ready"
printf 'VPC=%s\nPublicSubnet=%s\nPrivateSubnet=%s\nNAT=%s\n' \
  "$VPC_ID" "$PUBLIC_SUBNET_ID" "$PRIVATE_SUBNET_ID" "$NAT_GW_ID"
