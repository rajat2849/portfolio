#!/usr/bin/env bash
# =============================================================================
# F5 NGINX Gateway Fabric - Hub & Spoke POC Deployment Script
# =============================================================================
# Architecture:
#   Internet → Hub Public ALB → Target Group (IP type)
#           → [VPC Peering] → NGF Internal NLB (Spoke)
#           → F5 NGINX Gateway Fabric pods (EKS private subnet)
#           → App pods
#
# Usage:
#   ./deploy.sh             # full deploy
#   ./deploy.sh destroy     # tear down everything
# =============================================================================

set -euo pipefail

# =============================================================================
# CHANGE THESE FOR EACH ENVIRONMENT
# =============================================================================
REGION="us-east-1"
PROJECT="ngf-poc"                    # used as tag prefix

HUB_VPC_CIDR="10.0.0.0/16"
HUB_PUBLIC_SUBNET_CIDR="10.0.1.0/24"
HUB_PUBLIC_SUBNET_B_CIDR="10.0.3.0/24"   # ALB needs 2 AZs
HUB_PRIVATE_SUBNET_CIDR="10.0.2.0/24"
HUB_AZ_A="us-east-1a"
HUB_AZ_B="us-east-1b"

SPOKE_VPC_CIDR="10.1.0.0/16"
SPOKE_PUBLIC_SUBNET_CIDR="10.1.1.0/24"   # NAT GW only
SPOKE_PRIVATE_SUBNET_A_CIDR="10.1.2.0/24"
SPOKE_PRIVATE_SUBNET_B_CIDR="10.1.3.0/24"
SPOKE_AZ_A="us-east-1a"
SPOKE_AZ_B="us-east-1b"

EKS_CLUSTER_NAME="ngf-poc-cluster"
EKS_VERSION="1.31"
EKS_NODE_TYPE="t3.medium"
EKS_NODE_COUNT=2

# IAM role ARN to grant EKS console access (your SSO admin role - no path prefix)
# Find with: aws iam list-roles --query 'Roles[?contains(RoleName,`Administrator`)].Arn'
CONSOLE_ADMIN_ROLE_ARN="arn:aws:iam::ACCOUNT_ID:role/AWSReservedSSO_AWSAdministratorAccess_XXXXXXXXXXXXXXXX"

# =============================================================================
# HELPERS
# =============================================================================
log()  { echo "$(date '+%H:%M:%S') [INFO] $*"; }
fail() { echo "$(date '+%H:%M:%S') [ERROR] $*" >&2; exit 1; }

tag() {
  # tag KEY VALUE - returns tag-specifications string for create commands
  echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=${PROJECT}}]"
}

wait_nat() {
  log "Waiting for NAT Gateway $1..."
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$1" --region "$REGION"
}

# =============================================================================
# DEPLOY
# =============================================================================
deploy() {

# ---------------- HUB VPC ----------------
log "Creating Hub VPC..."
HUB_VPC=$(aws ec2 create-vpc --cidr-block "$HUB_VPC_CIDR" --region "$REGION" \
  --tag-specifications "$(tag vpc hub-vpc)" \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "$HUB_VPC" --enable-dns-hostnames --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$HUB_VPC" --enable-dns-support   --region "$REGION"

HUB_PUB_SN=$(aws ec2 create-subnet --vpc-id "$HUB_VPC" \
  --cidr-block "$HUB_PUBLIC_SUBNET_CIDR" --availability-zone "$HUB_AZ_A" --region "$REGION" \
  --tag-specifications "$(tag subnet hub-public-1a)" --query 'Subnet.SubnetId' --output text)

HUB_PUB_SN_B=$(aws ec2 create-subnet --vpc-id "$HUB_VPC" \
  --cidr-block "$HUB_PUBLIC_SUBNET_B_CIDR" --availability-zone "$HUB_AZ_B" --region "$REGION" \
  --tag-specifications "$(tag subnet hub-public-1b)" --query 'Subnet.SubnetId' --output text)

HUB_PRIV_SN=$(aws ec2 create-subnet --vpc-id "$HUB_VPC" \
  --cidr-block "$HUB_PRIVATE_SUBNET_CIDR" --availability-zone "$HUB_AZ_A" --region "$REGION" \
  --tag-specifications "$(tag subnet hub-private-1a)" --query 'Subnet.SubnetId' --output text)

HUB_IGW=$(aws ec2 create-internet-gateway --region "$REGION" \
  --tag-specifications "$(tag internet-gateway hub-igw)" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$HUB_IGW" --vpc-id "$HUB_VPC" --region "$REGION"

HUB_EIP=$(aws ec2 allocate-address --domain vpc --region "$REGION" \
  --tag-specifications "$(tag elastic-ip hub-nat-eip)" --query 'AllocationId' --output text)
HUB_NAT=$(aws ec2 create-nat-gateway --subnet-id "$HUB_PUB_SN" \
  --allocation-id "$HUB_EIP" --region "$REGION" \
  --query 'NatGateway.NatGatewayId' --output text)
aws ec2 create-tags --resources "$HUB_NAT" \
  --tags Key=Name,Value=hub-nat Key=Project,Value="$PROJECT" --region "$REGION"
wait_nat "$HUB_NAT"

HUB_PUB_RT=$(aws ec2 create-route-table --vpc-id "$HUB_VPC" --region "$REGION" \
  --tag-specifications "$(tag route-table hub-public-rt)" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$HUB_PUB_RT" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$HUB_IGW" --region "$REGION" >/dev/null
aws ec2 associate-route-table --route-table-id "$HUB_PUB_RT" \
  --subnet-id "$HUB_PUB_SN" --region "$REGION" >/dev/null
aws ec2 associate-route-table --route-table-id "$HUB_PUB_RT" \
  --subnet-id "$HUB_PUB_SN_B" --region "$REGION" >/dev/null

HUB_PRIV_RT=$(aws ec2 create-route-table --vpc-id "$HUB_VPC" --region "$REGION" \
  --tag-specifications "$(tag route-table hub-private-rt)" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$HUB_PRIV_RT" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$HUB_NAT" --region "$REGION" >/dev/null
aws ec2 associate-route-table --route-table-id "$HUB_PRIV_RT" \
  --subnet-id "$HUB_PRIV_SN" --region "$REGION" >/dev/null
log "Hub VPC done: $HUB_VPC"

# ---------------- SPOKE VPC ----------------
log "Creating Spoke VPC..."
SPOKE_VPC=$(aws ec2 create-vpc --cidr-block "$SPOKE_VPC_CIDR" --region "$REGION" \
  --tag-specifications "$(tag vpc spoke-vpc)" \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "$SPOKE_VPC" --enable-dns-hostnames --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$SPOKE_VPC" --enable-dns-support   --region "$REGION"

SPOKE_PUB_SN=$(aws ec2 create-subnet --vpc-id "$SPOKE_VPC" \
  --cidr-block "$SPOKE_PUBLIC_SUBNET_CIDR" --availability-zone "$SPOKE_AZ_A" --region "$REGION" \
  --tag-specifications "$(tag subnet spoke-public-1a)" --query 'Subnet.SubnetId' --output text)

SPOKE_PRIV_SN_A=$(aws ec2 create-subnet --vpc-id "$SPOKE_VPC" \
  --cidr-block "$SPOKE_PRIVATE_SUBNET_A_CIDR" --availability-zone "$SPOKE_AZ_A" --region "$REGION" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=spoke-private-1a},{Key=Project,Value=${PROJECT}},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
  --query 'Subnet.SubnetId' --output text)

SPOKE_PRIV_SN_B=$(aws ec2 create-subnet --vpc-id "$SPOKE_VPC" \
  --cidr-block "$SPOKE_PRIVATE_SUBNET_B_CIDR" --availability-zone "$SPOKE_AZ_B" --region "$REGION" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=spoke-private-1b},{Key=Project,Value=${PROJECT}},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
  --query 'Subnet.SubnetId' --output text)

SPOKE_IGW=$(aws ec2 create-internet-gateway --region "$REGION" \
  --tag-specifications "$(tag internet-gateway spoke-igw)" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$SPOKE_IGW" --vpc-id "$SPOKE_VPC" --region "$REGION"

SPOKE_EIP=$(aws ec2 allocate-address --domain vpc --region "$REGION" \
  --tag-specifications "$(tag elastic-ip spoke-nat-eip)" --query 'AllocationId' --output text)
SPOKE_NAT=$(aws ec2 create-nat-gateway --subnet-id "$SPOKE_PUB_SN" \
  --allocation-id "$SPOKE_EIP" --region "$REGION" \
  --query 'NatGateway.NatGatewayId' --output text)
aws ec2 create-tags --resources "$SPOKE_NAT" \
  --tags Key=Name,Value=spoke-nat Key=Project,Value="$PROJECT" --region "$REGION"
wait_nat "$SPOKE_NAT"

SPOKE_PUB_RT=$(aws ec2 create-route-table --vpc-id "$SPOKE_VPC" --region "$REGION" \
  --tag-specifications "$(tag route-table spoke-public-rt)" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$SPOKE_PUB_RT" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$SPOKE_IGW" --region "$REGION" >/dev/null
aws ec2 associate-route-table --route-table-id "$SPOKE_PUB_RT" \
  --subnet-id "$SPOKE_PUB_SN" --region "$REGION" >/dev/null

SPOKE_PRIV_RT=$(aws ec2 create-route-table --vpc-id "$SPOKE_VPC" --region "$REGION" \
  --tag-specifications "$(tag route-table spoke-private-rt)" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$SPOKE_PRIV_RT" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$SPOKE_NAT" --region "$REGION" >/dev/null
aws ec2 associate-route-table --route-table-id "$SPOKE_PRIV_RT" \
  --subnet-id "$SPOKE_PRIV_SN_A" --region "$REGION" >/dev/null
aws ec2 associate-route-table --route-table-id "$SPOKE_PRIV_RT" \
  --subnet-id "$SPOKE_PRIV_SN_B" --region "$REGION" >/dev/null
log "Spoke VPC done: $SPOKE_VPC"

# ---------------- VPC PEERING ----------------
log "Creating VPC Peering..."
PEERING=$(aws ec2 create-vpc-peering-connection \
  --vpc-id "$HUB_VPC" --peer-vpc-id "$SPOKE_VPC" --region "$REGION" \
  --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)
aws ec2 create-tags --resources "$PEERING" \
  --tags Key=Name,Value=hub-spoke-peering Key=Project,Value="$PROJECT" --region "$REGION"
aws ec2 accept-vpc-peering-connection \
  --vpc-peering-connection-id "$PEERING" --region "$REGION" >/dev/null

aws ec2 create-route --route-table-id "$HUB_PUB_RT" \
  --destination-cidr-block "$SPOKE_VPC_CIDR" \
  --vpc-peering-connection-id "$PEERING" --region "$REGION" >/dev/null
aws ec2 create-route --route-table-id "$HUB_PRIV_RT" \
  --destination-cidr-block "$SPOKE_VPC_CIDR" \
  --vpc-peering-connection-id "$PEERING" --region "$REGION" >/dev/null
aws ec2 create-route --route-table-id "$SPOKE_PRIV_RT" \
  --destination-cidr-block "$HUB_VPC_CIDR" \
  --vpc-peering-connection-id "$PEERING" --region "$REGION" >/dev/null
log "VPC Peering done: $PEERING"

# ---------------- EKS IAM ROLES ----------------
log "Creating EKS IAM roles..."
cat > /tmp/eks-cluster-trust.json <<'TRUST'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
TRUST
cat > /tmp/eks-node-trust.json <<'TRUST'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
TRUST

EKS_CLUSTER_ROLE=$(aws iam create-role \
  --role-name "${PROJECT}-eks-cluster-role" \
  --assume-role-policy-document file:///tmp/eks-cluster-trust.json \
  --query 'Role.Arn' --output text)
aws iam attach-role-policy --role-name "${PROJECT}-eks-cluster-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

EKS_NODE_ROLE=$(aws iam create-role \
  --role-name "${PROJECT}-eks-node-role" \
  --assume-role-policy-document file:///tmp/eks-node-trust.json \
  --query 'Role.Arn' --output text)
aws iam attach-role-policy --role-name "${PROJECT}-eks-node-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name "${PROJECT}-eks-node-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam attach-role-policy --role-name "${PROJECT}-eks-node-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

# ---------------- EKS CLUSTER ----------------
log "Creating EKS cluster (takes ~10-15 min)..."
aws eks create-cluster \
  --name "$EKS_CLUSTER_NAME" --region "$REGION" \
  --kubernetes-version "$EKS_VERSION" \
  --role-arn "$EKS_CLUSTER_ROLE" \
  --resources-vpc-config \
    subnetIds="${SPOKE_PRIV_SN_A},${SPOKE_PRIV_SN_B}",\
endpointPublicAccess=true,endpointPrivateAccess=true >/dev/null

aws eks wait cluster-active --name "$EKS_CLUSTER_NAME" --region "$REGION"
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$REGION"
log "EKS cluster active"

# ---------------- NODE GROUP ----------------
log "Creating node group (takes ~5 min)..."
aws eks create-nodegroup \
  --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "${PROJECT}-nodes" \
  --region "$REGION" --node-role "$EKS_NODE_ROLE" \
  --subnets "$SPOKE_PRIV_SN_A" \
  --instance-types "$EKS_NODE_TYPE" \
  --scaling-config minSize=2,maxSize=3,desiredSize="$EKS_NODE_COUNT" \
  --ami-type AL2_x86_64 --capacity-type ON_DEMAND >/dev/null

aws eks wait nodegroup-active \
  --cluster-name "$EKS_CLUSTER_NAME" \
  --nodegroup-name "${PROJECT}-nodes" --region "$REGION"
log "Node group active: $(kubectl get nodes --no-headers | wc -l) nodes ready"

# ---------------- AWS-AUTH (CONSOLE ACCESS) ----------------
log "Configuring aws-auth for console access..."
kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${EKS_NODE_ROLE}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
      - system:bootstrappers
      - system:nodes
    - rolearn: ${CONSOLE_ADMIN_ROLE_ARN}
      username: admin
      groups:
      - system:masters
YAML

# ---------------- F5 NGF ----------------
log "Installing Gateway API CRDs..."
kubectl apply -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

log "Installing F5 NGINX Gateway Fabric..."
helm upgrade --install ngf \
  oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --namespace nginx-gateway --create-namespace \
  --set nginx.service.type=LoadBalancer \
  --set nginx.service.externalTrafficPolicy=Cluster \
  --set-json 'nginx.service.patches=[{"type":"JSONPatch","value":[{"op":"add","path":"/metadata/annotations","value":{"service.beta.kubernetes.io/aws-load-balancer-internal":"true","service.beta.kubernetes.io/aws-load-balancer-scheme":"internal","service.beta.kubernetes.io/aws-load-balancer-type":"nlb"}}]}]' \
  --wait --timeout 3m

# ---------------- NGINX TEST APP + GATEWAY ----------------
log "Deploying nginx test app, Gateway, and HTTPRoute..."
kubectl apply -f - <<'YAML'
---
apiVersion: v1
kind: Namespace
metadata:
  name: nginx-app
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-app
  namespace: nginx-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-app
  template:
    metadata:
      labels:
        app: nginx-app
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-app-svc
  namespace: nginx-app
spec:
  selector:
    app: nginx-app
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: nginx-gateway
  namespace: nginx-app
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx-app-route
  namespace: nginx-app
spec:
  parentRefs:
  - name: nginx-gateway
    namespace: nginx-app
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: nginx-app-svc
      port: 80
YAML

log "Waiting for NGF NLB to become available..."
NLB_ARN=""
for i in $(seq 1 30); do
  NLB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query 'LoadBalancers[?Scheme==`internal` && Type==`network`].LoadBalancerArn' \
    --output text 2>/dev/null | head -1)
  [[ -n "$NLB_ARN" ]] && break
  sleep 10
done
[[ -z "$NLB_ARN" ]] && fail "NGF NLB not found after 5 minutes"

aws elbv2 wait load-balancer-available --load-balancer-arns "$NLB_ARN" --region "$REGION"
log "NGF NLB active"

NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$NLB_ARN" \
  --region "$REGION" --query 'LoadBalancers[0].DNSName' --output text)

# Get private IP via ENI (resolves faster than DNS in new deployments)
NGF_NLB_IP=$(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=description,Values=*${NLB_ARN##*/loadbalancer/net/}*" \
  --query 'NetworkInterfaces[?AvailabilityZone==`'"$SPOKE_AZ_A"'`].PrivateIpAddress' \
  --output text | head -1)

# Wait for DNS to resolve if ENI lookup failed
if [[ -z "$NGF_NLB_IP" ]]; then
  for i in $(seq 1 12); do
    NGF_NLB_IP=$(dig +short "$NLB_DNS" | grep "^10\." | head -1)
    [[ -n "$NGF_NLB_IP" ]] && break
    sleep 10
  done
fi
[[ -z "$NGF_NLB_IP" ]] && fail "Could not resolve NGF NLB IP"
log "NGF NLB IP: $NGF_NLB_IP"

# ---------------- HUB ALB + TARGET GROUP ----------------
log "Creating Hub ALB security group..."
HUB_ALB_SG=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-hub-alb-sg" \
  --description "Hub public ALB security group" \
  --vpc-id "$HUB_VPC" --region "$REGION" \
  --query 'GroupId' --output text)
aws ec2 create-tags --resources "$HUB_ALB_SG" \
  --tags Key=Name,Value="${PROJECT}-hub-alb-sg" Key=Project,Value="$PROJECT" --region "$REGION"
aws ec2 authorize-security-group-ingress \
  --group-id "$HUB_ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null

log "Creating Hub Target Group..."
TG_ARN=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg" \
  --protocol HTTP --port 80 \
  --vpc-id "$HUB_VPC" --target-type ip \
  --health-check-protocol HTTP --health-check-path / \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 register-targets --target-group-arn "$TG_ARN" --region "$REGION" \
  --targets "Id=${NGF_NLB_IP},Port=80,AvailabilityZone=all"

log "Creating Hub Public ALB..."
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "${PROJECT}-hub-alb" \
  --subnets "$HUB_PUB_SN" "$HUB_PUB_SN_B" \
  --security-groups "$HUB_ALB_SG" \
  --scheme internet-facing --type application --ip-address-type ipv4 \
  --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
  --region "$REGION" >/dev/null

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --region "$REGION" --query 'LoadBalancers[0].DNSName' --output text)

log "============================================"
log "DEPLOYMENT COMPLETE"
log "============================================"
log "Hub ALB (public):  http://${ALB_DNS}"
log "NGF NLB IP (private): ${NGF_NLB_IP}"
log "EKS cluster: ${EKS_CLUSTER_NAME} (${REGION})"
log "Hub VPC:   ${HUB_VPC}"
log "Spoke VPC: ${SPOKE_VPC}"
log "VPC Peering: ${PEERING}"
log "============================================"

} # end deploy()

# =============================================================================
# DESTROY - tears down all resources created by this script
# =============================================================================
destroy() {
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  log "Starting teardown in account $ACCOUNT_ID region $REGION project $PROJECT"

  # ALB + listeners + TG
  for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName,\`${PROJECT}\`)].LoadBalancerArn" \
    --output text); do
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION"
    log "Deleted LB: $arn"
  done
  aws elbv2 wait load-balancers-deleted \
    --load-balancer-arns "$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?contains(LoadBalancerName,\`${PROJECT}\`)].LoadBalancerArn" \
      --output text)" --region "$REGION" 2>/dev/null || true

  for arn in $(aws elbv2 describe-target-groups --region "$REGION" \
    --query "TargetGroups[?contains(TargetGroupName,\`${PROJECT}\`)].TargetGroupArn" \
    --output text); do
    aws elbv2 delete-target-group --target-group-arn "$arn" --region "$REGION"
    log "Deleted TG: $arn"
  done

  # Helm uninstall (NGF creates the internal NLB - must delete first)
  helm uninstall ngf -n nginx-gateway 2>/dev/null || true
  kubectl delete namespace nginx-app nginx-gateway 2>/dev/null || true
  sleep 30  # allow NLB deletion to propagate

  # EKS node group + cluster
  aws eks delete-nodegroup --cluster-name "$EKS_CLUSTER_NAME" \
    --nodegroup-name "${PROJECT}-nodes" --region "$REGION" 2>/dev/null || true
  aws eks wait nodegroup-deleted --cluster-name "$EKS_CLUSTER_NAME" \
    --nodegroup-name "${PROJECT}-nodes" --region "$REGION" 2>/dev/null || true
  aws eks delete-cluster --name "$EKS_CLUSTER_NAME" --region "$REGION" 2>/dev/null || true
  aws eks wait cluster-deleted --name "$EKS_CLUSTER_NAME" --region "$REGION" 2>/dev/null || true
  log "EKS deleted"

  # IAM roles
  for role in "${PROJECT}-eks-cluster-role" "${PROJECT}-eks-node-role"; do
    for policy in $(aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$policy"
    done
    aws iam delete-role --role-name "$role" 2>/dev/null || true
    log "Deleted IAM role: $role"
  done

  # VPC Peering
  for pcx in $(aws ec2 describe-vpc-peering-connections --region "$REGION" \
    --filters "Name=tag:Project,Values=${PROJECT}" \
    --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text); do
    aws ec2 delete-vpc-peering-connection \
      --vpc-peering-connection-id "$pcx" --region "$REGION"
    log "Deleted peering: $pcx"
  done

  # NAT GWs + EIPs
  for vpc_name in hub spoke; do
    NAT=$(aws ec2 describe-nat-gateways --region "$REGION" \
      --filter "Name=tag:Name,Values=${vpc_name}-nat" "Name=state,Values=available" \
      --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)
    if [[ "$NAT" != "None" && -n "$NAT" ]]; then
      aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" --region "$REGION" >/dev/null
      log "Deleting NAT GW: $NAT"
    fi
  done

  log "Waiting for NAT GWs to delete (~60s)..."
  sleep 60

  for alloc in $(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:Project,Values=${PROJECT}" \
    --query 'Addresses[*].AllocationId' --output text); do
    aws ec2 release-address --allocation-id "$alloc" --region "$REGION" 2>/dev/null || true
    log "Released EIP: $alloc"
  done

  # Security Groups
  for sg in $(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:Project,Values=${PROJECT}" \
    --query 'SecurityGroups[*].GroupId' --output text); do
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || true
  done

  # VPCs (subnets, route tables, IGWs, then VPC)
  for vpc in $(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Project,Values=${PROJECT}" \
    --query 'Vpcs[*].VpcId' --output text); do

    for sn in $(aws ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=${vpc}" \
      --query 'Subnets[*].SubnetId' --output text); do
      aws ec2 delete-subnet --subnet-id "$sn" --region "$REGION" 2>/dev/null || true
    done

    for rt in $(aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=vpc-id,Values=${vpc}" \
      --query 'RouteTables[?Associations[?Main==`false`]].RouteTableId' --output text); do
      aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" 2>/dev/null || true
    done

    for igw in $(aws ec2 describe-internet-gateways --region "$REGION" \
      --filters "Name=attachment.vpc-id,Values=${vpc}" \
      --query 'InternetGateways[*].InternetGatewayId' --output text); do
      aws ec2 detach-internet-gateway --internet-gateway-id "$igw" \
        --vpc-id "$vpc" --region "$REGION"
      aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION"
    done

    aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" 2>/dev/null || true
    log "Deleted VPC: $vpc"
  done

  log "Teardown complete."
}

# =============================================================================
# ENTRYPOINT
# =============================================================================
case "${1:-deploy}" in
  deploy)  deploy  ;;
  destroy) destroy ;;
  *) echo "Usage: $0 [deploy|destroy]" && exit 1 ;;
esac
