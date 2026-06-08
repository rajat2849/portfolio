# F5 NGINX Gateway Fabric — Hub & Spoke POC

## What this project is
POC for migrating from NGINX Ingress Controller (deprecated) to **F5 NGINX Gateway Fabric (NGF)** on AWS EKS.
This POC validates the architecture before applying to production.

## Architecture
```
Internet
    │
    ▼
Public ALB (Hub VPC - public subnet)
    │ HTTP listener
    ▼
Target Group (IP type)
  └─ Target: private IP of NGF internal NLB in Spoke VPC
    │
    │ [VPC Peering: 10.0.0.0/16 ↔ 10.1.0.0/16]
    ▼
F5 NGF Internal NLB (Spoke VPC - private)
    │
    ▼
F5 NGINX Gateway Fabric pods (EKS - private subnet)
    │
    ▼
App pods (nginx welcome page)
```

**Key design rule:** Nothing public in Spoke VPC. All EKS nodes, NGF pods, and the NLB are in private subnets.

## Key difference from NGINX Ingress Controller
| Old (Ingress Controller) | New (NGF) |
|---|---|
| `Ingress` resource | `Gateway` + `HTTPRoute` resources |
| `kubernetes.io/ingress.class` annotation | `GatewayClass` named `nginx` |
| Watches Ingress objects | Implements Kubernetes Gateway API |

## Current POC state (us-east-1)
| Resource | ID / Value |
|---|---|
| Hub VPC | `vpc-0cba881b8739d7bc1` |
| Spoke VPC | `vpc-06f53ce6172e7f029` |
| VPC Peering | `pcx-0de6625081df6f47d` |
| EKS Cluster | `ngf-poc-cluster` (k8s 1.31, 2x t3.medium) |
| NGF Internal NLB | `10.1.2.190` (us-east-1a private) |
| Hub Public ALB | `hub-public-alb-514045176.us-east-1.elb.amazonaws.com` |
| Target Group | `ngf-poc-tg` (IP type, AvailabilityZone=all) |
| AWS Account | `279867550269` |

## How to deploy fresh (new account or region)
```bash
cd ngf-poc/
# 1. Edit variables at the top of deploy.sh (REGION, CIDRs, CONSOLE_ADMIN_ROLE_ARN)
# 2. Run
chmod +x deploy.sh
./deploy.sh

# To tear down everything
./deploy.sh destroy
```

## CONSOLE_ADMIN_ROLE_ARN — how to find it
The EKS console needs this role added to aws-auth to show Kubernetes resources.
```bash
aws iam list-roles --query 'Roles[?contains(RoleName,`Administrator`)].Arn' --output table
```
⚠️  Use the ARN **without** the path prefix. EKS strips the path when matching.
- Wrong: `arn:aws:iam::ID:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AWSAdministratorAccess_XXX`
- Right:  `arn:aws:iam::ID:role/AWSReservedSSO_AWSAdministratorAccess_XXX`

## Subnet tags required for internal NLB
Spoke private subnets **must** have this tag or EKS won't know where to place the NLB:
```
kubernetes.io/role/internal-elb = 1
```

## NGF Helm chart — key insight
The data plane service annotations live under `nginx.service`, **not** `service`.
The `service.*` values control the controller's webhook (ClusterIP port 443) — not the NGINX load balancer.
Service type and annotations for the NGINX data plane are set via:
```bash
--set nginx.service.type=LoadBalancer
--set-json 'nginx.service.patches=[{"type":"JSONPatch","value":[...annotations...]}]'
```

## NGF creates its NLB only when a Gateway resource exists
Installing the Helm chart alone won't create an NLB. The NLB is provisioned when you apply a
`Gateway` resource referencing GatewayClass `nginx`. Delete the Gateway → NLB is deleted too.

## Cross-VPC Target Group registration
When registering the NGF NLB IP in the Hub VPC target group, you must use `AvailabilityZone=all`
because the IP is outside the Hub VPC:
```bash
aws elbv2 register-targets --target-group-arn $TG_ARN \
  --targets Id=10.1.2.190,Port=80,AvailabilityZone=all
```

## To apply to production
1. Copy `deploy.sh` to the prod context
2. Change variables: `REGION`, `PROJECT`, VPC CIDRs (must not overlap with existing VPCs),
   `EKS_CLUSTER_NAME`, `EKS_NODE_TYPE`, `CONSOLE_ADMIN_ROLE_ARN`
3. Swap the nginx test app for real workloads — keep the same `Gateway` + `HTTPRoute` pattern
4. For production: enable multi-AZ nodes, set proper `minSize`/`maxSize`, add ACM cert + HTTPS listener

## Files
- `deploy.sh` — full deploy + destroy script, parameterized at the top
- `CLAUDE.md` — this file (architecture context for Claude sessions)
