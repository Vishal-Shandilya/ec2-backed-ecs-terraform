# Production ECS on EC2 — Terraform

Zero-downtime ECS service on EC2 with Spot/On-Demand mixed capacity, SSM secrets, ALB, and managed scaling.

---

## How to Run

### Prerequisites

- Terraform >= 1.5.0
- AWS credentials configured (`aws configure` or environment variables)
- Pre-existing VPC with:
  - Private subnets (multi-AZ) with NAT Gateway egress
  - Public subnets (multi-AZ) for the ALB
  - Security group for the ALB (ingress 80/443 from 0.0.0.0/0)
  - Security group for ECS instances (ingress on ephemeral ports 32768-60999 from ALB SG only)

### 1. Clone and initialise

```bash
git clone <repo-url>
cd terraform
terraform init
```

### 2. Create a `terraform.tfvars` file

```hcl
# terraform.tfvars — safe to commit (no secret values)
aws_region    = "us-east-1"
project_name  = "myapp"
environment   = "production"

vpc_id                         = "vpc-0abc123"
private_subnet_ids             = ["subnet-0aaa", "subnet-0bbb", "subnet-0ccc"]
public_subnet_ids              = ["subnet-0ddd", "subnet-0eee", "subnet-0fff"]
alb_security_group_id          = "sg-0alb111"
ecs_instance_security_group_id = "sg-0ecs222"

# SSM parameter ARNs (not values) — parameters must be pre-created
ssm_secret_arns = {
  "DB_PASSWORD" = "arn:aws:ssm:us-east-1:123456789012:parameter/myapp/production/db_password"
  "API_KEY"     = "arn:aws:ssm:us-east-1:123456789012:parameter/myapp/production/api_key"
}

# Optional: supply ACM cert ARN to enable HTTPS
# alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abc-123"
```

**Never put secret values in `terraform.tfvars` or any file tracked by git.**

### 3. Pre-create SSM parameters (outside Terraform)

```bash
aws ssm put-parameter \
  --name "/myapp/production/db_password" \
  --type "SecureString" \
  --value "your-actual-secret" \
  --key-id "alias/aws/ssm"

aws ssm put-parameter \
  --name "/myapp/production/api_key" \
  --type "SecureString" \
  --value "your-actual-key" \
  --key-id "alias/aws/ssm"
```

### 4. Plan and apply

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

### 5. Verify

```bash
# Get ALB DNS
terraform output alb_dns_name

# Check ECS service
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name)
```

---

## Architecture Overview

```
Internet
    │
    ▼
 [ALB]  (public subnets, HTTPS terminated here)
    │
    ▼
 [ECS Service]  (bridge mode, dynamic port mapping)
    │
    ├── Task 1 (AZ-a) ─── On-Demand instance
    ├── Task 2 (AZ-b) ─── On-Demand instance
    ├── Task 3 (AZ-a) ─── Spot instance
    └── Task 4 (AZ-b) ─── Spot instance
            │
            ▼
   SSM Parameter Store  (secrets injected at launch)
```

**Capacity layers:**
- `on_demand_base_capacity = 2` — guaranteed baseline, immune to Spot reclamation
- Additional capacity is Spot (capacity-optimized allocation strategy)
- ECS Capacity Provider bridges ASG scaling with task scheduling

---

## Assumptions

| Assumption | Detail |
|---|---|
| VPC exists | Module uses `vpc_id`, `private_subnet_ids`, `public_subnet_ids` as data sources |
| NAT Gateway exists | Private subnets have outbound internet (ECR image pull, SSM, CloudWatch) |
| Security groups exist | Caller provides ALB SG and ECS instance SG IDs |
| SSM parameters pre-exist | Terraform references ARNs only; never creates or reads secret values |
| ACM certificate optional | HTTP-only if `alb_certificate_arn` is empty |
| Single-region deployment | Multi-region would require additional Route 53 + replication design |
| No existing ECS cluster | Terraform creates a new cluster; adapt if importing an existing one |

---

## Shortcuts Taken

1. **ALB access logging disabled** — S3 bucket for access logs not provisioned. In production, enable this for audit and forensics.
2. **Remote state not configured** — `backend "s3"` block is commented out. Local state is used for demonstration. Production deployments must use remote state with DynamoDB locking.
3. **No WAF** — production internet-facing ALBs should have an AWS WAF WebACL attached.
4. **KMS key management** — the `ssm_read` IAM policy uses a wildcard on KMS key ARN with a `kms:ViaService` condition. In production, specify the exact CMK ARN(s).
5. **No Route 53 / ACM provisioning** — certificate ARN is passed in as a variable; DNS configuration is outside scope.

---

## Time Spent

- Phase 1 (Infrastructure): ~90 minutes
- Phase 2 (ADDENDUM stress test): ~50 minutes
- DESIGN.md + README.md: ~30 minutes
- **Total: ~2h 50m**

---

## AI / Tools Used

- Claude (Anthropic) — used to re-write the files and to draft ADDENDUM scenario prose. All architectural decisions, failure mode analysis, and Terraform logic were authored independently.
- AWS documentation — ECS capacity provider managed scaling, Spot interruption draining, ALB health check timing.

---

## What I Would Do Next (with more time)

1. **Modularise** — extract `ecs_service`, `asg_capacity_provider`, and `alb` into reusable child modules with clean interfaces, enabling multi-service clusters.
2. **Blue/Green deployment** — migrate `deployment_controller` from `ECS` (rolling) to `CODE_DEPLOY` for instant traffic cutover and instant rollback at the routing layer rather than the task scheduler.
3. **Automated secret rotation** — Lambda-backed SSM rotation with zero-downtime task relaunch orchestration.
4. **Load testing pipeline** — Load test in CI that validates autoscaling triggers before promotion to production.
