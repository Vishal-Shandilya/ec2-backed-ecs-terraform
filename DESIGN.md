# DESIGN.md — Production ECS on EC2 (Terraform)

## A. Zero-Downtime Deployments

### Deployment Settings

| Parameter | Value | Reasoning |
|---|---|---|
| `deployment_minimum_healthy_percent` | 100 | ECS may not kill any old task until the replacement is healthy |
| `deployment_maximum_percent` | 200 | ECS can surge to 2× desired task count during the rollout |
| `health_check_grace_period_seconds` | 60 | Prevents ALB failures from killing a task that is still starting |
| `deregistration_delay` | 30 s | ALB drains in-flight connections before the target is removed |

### Sequence of Events in a Rolling Deployment

```
1. Terraform updates task definition → new revision registered.
2. ECS scheduler launches N new tasks (up to max_percent ceiling).
3. New tasks register with the ALB target group.
4. ALB begins health-checking new tasks (path: /, expected 200).
5. Once a new task passes health_check_healthy_threshold consecutive checks,
   it enters InService state and starts receiving traffic.
6. ECS deregisters one old task from the ALB target group.
7. ALB honours deregistration_delay (30 s): no new requests sent to old task,
   existing connections allowed to complete.
8. After drain completes, ECS sends SIGTERM to the old task container.
9. Container gets stopTimeout (30 s) to finish gracefully; SIGKILL follows.
10. Repeat steps 2-9 until all tasks are on the new revision.
```

**What if new tasks fail health checks?**

The deployment circuit breaker (`deployment_circuit_breaker { enable = true, rollback = true }`) detects consecutive failed launches. After a configurable threshold, ECS automatically rolls back to the previous stable task definition. The old tasks are never drained because `minimum_healthy_percent = 100` kept them running throughout.

### Why No Downtime

- Old tasks remain in service and continue handling traffic until replacements are healthy.
- The ALB never routes traffic to an unhealthy new task.
- The 30-second drain window ensures no in-flight requests are interrupted.

---

## B. Secrets: SSM → Container Flow

### How Secrets Are Injected

```
SSM Parameter Store (encrypted with KMS)
        │
        │  ssm:GetParameters  (called by ECS agent at task launch)
        ▼
  ECS Task Execution Role  (aws_iam_role.ecs_task_execution_role)
        │
        │  injected as environment variables
        ▼
  Container runtime  (nginx process never calls SSM itself)
```

The task definition uses the `secrets` block (not `environment`):

```json
"secrets": [
  { "name": "DB_PASSWORD", "valueFrom": "arn:aws:ssm:...:parameter/myapp/prod/db_password" }
]
```

ECS resolves the ARN and injects the plaintext value at container start. The **value never touches the Terraform execution context** and therefore never appears in:

- `terraform.tfvars` (only ARNs are stored there)
- Any other repo file
- **Terraform state** — the state file contains the ARN reference, not the resolved value

### IAM Scoping

| Role | Purpose | SSM Access |
|---|---|---|
| `ecs_task_execution_role` | ECS agent reads secrets during task launch | `ssm:GetParameter` on explicit ARNs only |
| `ecs_task_role` | Runtime identity of the container process | None (nginx needs no AWS API access) |
| `ecs_instance_role` | EC2 instance / ECS agent registration | None |

The `ssm_read` inline policy lists each parameter ARN explicitly — no wildcards. Rotation of a secret requires no Terraform change; the next task launch picks up the new value automatically.

---

## C. Spot Strategy: Base vs Overflow

### Capacity Configuration

```
┌─────────────────────────────────────────────────────┐
│  ASG Mixed Instances Policy                          │
│                                                      │
│  On-Demand base:          2 instances (always warm)  │
│  Spot above base:         remainder (cost savings)   │
│  Spot allocation:         capacity-optimized         │
│  Instance pool:           m5.large, m5a.large,       │
│                           m4.large, m5d.large        │
└─────────────────────────────────────────────────────┘
```

`capacity-optimized` Spot allocation selects the instance pool AWS currently has the most capacity for. This directly reduces interruption probability compared to `lowest-price`.

### Spot Interruption Behaviour

1. AWS issues a 2-minute interruption notice.
2. EC2 Spot interruption notification reaches the instance metadata endpoint.
3. `ECS_ENABLE_SPOT_INSTANCE_DRAINING=true` (in user data) causes the ECS agent to immediately set the instance to `DRAINING`.
4. ECS stops placing new tasks on the draining instance.
5. Existing tasks receive SIGTERM; connections drain per `deregistration_delay`.
6. ECS Managed Scaling detects the reduction in capacity and requests new instances from the ASG.
7. New Spot (or On-Demand fallback) instances register and tasks are rescheduled.

**Why users stay online:** The On-Demand baseline guarantees that at least 2 instances always exist regardless of Spot availability. The `minimum_healthy_percent = 100` policy means ECS will not remove running tasks unless enough healthy replacements exist. The worst case is a brief period of higher latency (fewer tasks) not an outage.

---

## D. Scaling: Service CPU → Cluster Capacity → Pending Tasks

### Two-Layer Scaling Architecture

```
Layer 1 — Service (task count)
  CPUUtilization > 70%  →  +2 tasks  (60s cooldown)
  CPUUtilization < 30%  →  -1 task   (300s cooldown)

Layer 2 — Cluster (instance count)
  ECS Capacity Provider: target_capacity = 80%
  When pending tasks → CapacityProviderReservation rises above 80%
  → Managed Scaling increases ASG desired_capacity
  → New EC2 instances launch and join cluster
  → Pending tasks are placed
```

### Why Pending Tasks Don't Deadlock

The ECS capacity provider is the bridge between "ECS wants more tasks" and "ASG provides more instances":

1. Service scaling raises desired task count from 6 → 10.
2. 4 tasks enter `PENDING` state (no available capacity).
3. `CapacityProviderReservation` metric exceeds `target_capacity` (80%).
4. Managed Scaling signals the ASG to increase `desired_capacity`.
5. New instances bootstrap (~2 min), register with the cluster.
6. ECS places the pending tasks; they start and pass health checks.

The `minimum_scaling_step_size = 1` and `maximum_scaling_step_size = 5` prevent over-provisioning while ensuring responsiveness.

---

## E. Operations: Top 5 Monitors and What Pages at 3 AM

### Monitors

| # | Metric | Threshold | Severity | Why It Matters |
|---|---|---|---|---|
| 1 | `UnHealthyHostCount` (ALB) | > 0 | **PAGE** | A target failing health checks means real traffic is being dropped |
| 2 | `RunningTaskCount` < `min_capacity` | (alarm) | **PAGE** | Service is below safe operating capacity |
| 3 | `HTTPCode_ELB_5XX_Count` | > 50/min | **PAGE** | Application errors reaching end users |
| 4 | `CPUUtilization` (service) | > 85% sustained | Warn | Pre-scale signal; escalates if autoscaling lags |
| 5 | `MemoryUtilization` (service) | > 90% | Warn | OOM risk; tasks may be killed silently |

### What Pages at 3 AM (HIGH severity only)

- **Unhealthy targets > 0** — something is broken and real users are affected.
- **Running tasks < minimum** — the service is understaffed; SLA at risk.
- **ALB 5xx > threshold** — application is returning errors.

CPU/memory warnings are lower-severity and can wait for business hours unless they sustain or escalate.

### Recommended Additional Instrumentation

- CloudWatch Container Insights (enabled) provides per-task memory/CPU without custom agents.
- ALB access logging to S3 for post-incident forensics.
- ECS Service Events streamed to CloudWatch Logs for deployment timeline reconstruction.
- AWS Health events forwarded to SNS for Spot interruption advance notice.
