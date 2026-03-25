# ADDENDUM.md — Production Stress Test Scenarios

---

## Scenario 1 — Spot Failure During Deployment

**Situation:** A deployment is in progress. 60% of Spot instances are simultaneously reclaimed by AWS.

### Step-by-Step Walkthrough

**T=0 — Reclamation notices arrive**

AWS sends a 2-minute Spot interruption notification to the affected instances. The ECS agent (via `ECS_ENABLE_SPOT_INSTANCE_DRAINING=true`) immediately transitions those instances to `DRAINING` status.

**T=0 to T+2 min — Task drain**

- ECS stops routing new tasks to draining instances.
- The ALB deregisters tasks on draining instances; `deregistration_delay` (30 s) allows in-flight requests to complete.
- During the deployment, new-revision tasks were already launching on healthy instances.

**Effect on running tasks:**  
Tasks on healthy On-Demand and surviving Spot instances continue serving traffic. Tasks on reclaimed instances drain and terminate within ~30 seconds.

**Effect on pending tasks:**  
The deployment's new tasks that were pending on the reclaimed instances are rescheduled on surviving capacity. If insufficient capacity exists, they enter `PENDING`.

**Capacity provider response:**  
`CapacityProviderReservation` spikes above `target_capacity` (80%). Managed Scaling sends a `SetDesiredCapacity` to the ASG. The ASG requests new Spot instances (capacity-optimized pool selection reduces recurrence probability). If the Spot market is constrained, the ASG falls back to On-Demand per the `on_demand_base_capacity` guarantee.

**Effect on ALB / end users:**  
- The On-Demand baseline (2+ instances) ensures a minimum number of healthy tasks remain registered with the ALB throughout.
- `deployment_minimum_healthy_percent = 100` means ECS would not have removed old healthy tasks unless replacements were confirmed healthy — so the pre-deployment task count is still partially serving.
- Users may see slightly higher latency (fewer backends) for 2–4 minutes; no 5xx errors if On-Demand baseline holds.

**Why no downtime:**  
The On-Demand baseline is immune to Spot reclamation. Combined with task draining (not instant kill) and ALB health-check gating, traffic always has a healthy target.

**Where does new capacity come from?**  
ASG Managed Scaling provisions new instances. Capacity-optimized Spot allocation targets a different pool; if unavailable, On-Demand instances fulfil the `on_demand_base_capacity` floor.

---

## Scenario 2 — Secrets Break at Runtime

**Situation:** The `ssm:GetParameter` permission is removed from the task execution role while the service is running.

### What Breaks

- **New task launches fail.** When ECS starts a replacement task (due to scale-out or node failure), the ECS agent calls SSM to resolve `secrets` block ARNs. Without permission, the API returns `AccessDeniedException`. The task transitions to `STOPPED` with reason: `CannotPullContainerError` or `ResourceInitializationError`.
- **Existing tasks are unaffected.** Secrets are injected at launch into process environment — they are not re-fetched at runtime. Running containers continue serving traffic normally.
- **Logs.** CloudWatch will show `ResourceInitializationError: unable to pull secrets or registry auth` in ECS service events. The stopped task's `stoppedReason` field contains the exact SSM error.

### Detection

1. ECS service event: task stopped with `ResourceInitializationError`.
2. CloudWatch Alarm: `RunningTaskCount` drops below minimum if enough failures accumulate.
3. CloudWatch Alarm: `UnHealthyHostCount` > 0 if running tasks also fail for unrelated reasons.
4. The deployment circuit breaker fires if this occurs during a deploy — it rolls back to the previous task definition revision (which had the same IAM issue, but the rollback at least stops the bleeding and pages the on-call engineer).

### Recovery

1. **Restore the IAM policy** (`aws_iam_role_policy.ssm_read`) via Terraform apply or console.
2. **Force a new deployment** (`aws ecs update-service --force-new-deployment`) to relaunch failed tasks.
3. Confirm `RunningTaskCount` returns to desired.

### Why Secrets Never Leak

- Secrets are never written to Terraform state (task definition `secrets` block stores ARNs only).
- The removed policy doesn't expose any secret value — it merely breaks resolution.
- Environment variables in running containers exist only in the container process memory; they are not accessible from the host without `docker inspect` (which requires instance access gated by IAM/SSM Session Manager).

---

## Scenario 3 — Pending Task Deadlock

**Situation:** Service desired count = 10. Cluster can accommodate 6. 4 tasks are PENDING.

### What Triggers Capacity Increase

The ECS Capacity Provider continuously evaluates `CapacityProviderReservation`:

```
CapacityProviderReservation = (tasks_needing_capacity / current_capacity) * 100
```

With 10 desired tasks and capacity for only 6, `CapacityProviderReservation` exceeds the `target_capacity` threshold (80%). This metric is emitted to CloudWatch; Managed Scaling reads it and calls `SetDesiredCapacity` on the ASG.

### Why It Doesn't Deadlock

The key invariant is that ECS Managed Scaling is **decoupled** from the service scheduler:

1. The 4 PENDING tasks sit in the ECS scheduler queue.
2. Managed Scaling independently monitors reservation and increases the ASG.
3. New EC2 instances take ~90–120 seconds to: launch → bootstrap user-data → ECS agent registration → cluster join.
4. `instance_warmup_period = 120` prevents new instances from being counted in capacity metrics until they're actually ready, avoiding premature "capacity satisfied" signals.
5. Once instances join, the scheduler places the pending tasks — no manual intervention required.

**Deadlock conditions that are explicitly prevented:**

- **Managed termination protection** prevents ASG from removing an instance that has running tasks (which would create a circular dependency).
- **`protect_from_scale_in = true`** on the ASG prevents EC2 Auto Scaling from independently shrinking capacity while ECS Managed Scaling is trying to grow it.

---

## Scenario 4 — Deployment Safety

**When do new tasks start?**  
When ECS updates the service, it immediately begins launching replacement tasks (up to `maximum_percent = 200` of desired). New tasks start in parallel with old tasks running.

**When do old tasks stop receiving traffic?**  
Only after a replacement task passes ALB health checks (`healthy_threshold = 2` consecutive 200-level responses, 30 s apart). The ALB then deregisters the old task. ALB honours `deregistration_delay = 30 s` — no new requests are routed, but open connections complete.

**When are old tasks killed?**  
After deregistration delay completes, ECS sends `SIGTERM` to the container. The container has `stopTimeout = 30 s` to shut down gracefully. ECS sends `SIGKILL` if still running after the timeout.

**What if new tasks fail health checks?**  
- ECS will not deregister old tasks (min healthy percent = 100 ensures old tasks keep running).
- The deployment circuit breaker counts consecutive failed task launches.
- After the failure threshold is crossed, ECS automatically rolls back to the previous task definition.
- Rollback follows the same zero-downtime sequence in reverse.
- CloudWatch alarm on `UnHealthyHostCount` and ECS service events both fire.

---

## Scenario 5 — TLS, Trust Boundary, Identity

**Where is TLS terminated?**  
At the ALB. The ALB listener uses ACM certificate (if `alb_certificate_arn` is set) with policy `ELBSecurityPolicy-TLS13-1-2-2021-06`. Traffic between the ALB and ECS instances travels over a private VPC network (never public internet); HTTP is acceptable here because:
- The path is VPC-internal only.
- Adding end-to-end TLS to ECS bridge-mode containers requires certificate management on every instance, adding operational complexity for marginal security benefit inside a private subnet.

For higher-assurance workloads (PCI, HIPAA), HTTPS on the target group is achievable using a self-signed cert or ACM Private CA.

**What AWS identity does the container run as?**  
The container's AWS SDK/CLI calls are signed as `ecs_task_role` (`${project_name}-ecs-task-role`). This role has **zero permissions by default** for the nginx demo. In production, attach only the minimum policies the application requires (e.g., `s3:GetObject` for specific buckets).

The EC2 instance itself runs as `ecs_instance_role`, but the container cannot access instance credentials because IMDSv2 hop limit is set to 1 (only the host can reach IMDS; containers cannot).

**What AWS resources can the container access?**  
None by default (task role has no policies). The execution role (`ecs_task_execution_role`) is used only during task startup for secrets resolution — the container process itself does not inherit it.

---

## Scenario 6 — Cost Floor (Zero Traffic for 12 Hours)

**What are you still paying for?**

| Resource | Cost Continues? | Reason |
|---|---|---|
| ALB (hourly rate) | Yes | ALB charges per hour regardless of traffic |
| ALB LCUs | Near zero | LCU charge scales with traffic; near zero at idle |
| On-Demand EC2 baseline (2× m5.large) | Yes | `asg_min_size = 2` keeps instances running |
| Spot EC2 (above baseline) | Service scales in | CPU alarms trigger scale-in after `autoscaling_min_capacity` |
| ECS tasks | Scales in | Service autoscaling reduces tasks to `autoscaling_min_capacity` |
| CloudWatch metrics/logs | Minimal | Per-metric and per-GB charges; negligible at idle |
| NAT Gateway | Yes (hourly) | Charges per hour + per-GB; idle still costs the hourly rate |

**What would you change to reduce cost without reducing safety?**

1. **Scheduled scaling:** If traffic patterns are predictable (e.g., business hours only), add scheduled scale-in at night and scale-out in the morning. The On-Demand baseline can drop to 1 overnight.
2. **Smaller instance types on baseline:** Replace `m5.large` On-Demand baseline with `t4g.medium` (Graviton, burstable) — 40–50% cheaper for steady-state low CPU.
3. **ALB idle cost:** Nothing to do without removing the ALB. For development/staging, consider a shared ALB with host-based routing.
4. **NAT Gateway:** Replace with VPC Gateway Endpoints for S3/DynamoDB (free) and Interface Endpoints for ECR/SSM/CloudWatch to eliminate NAT Gateway data charges for those services.
5. **Task count minimum:** If zero traffic is expected, `autoscaling_min_capacity = 1` (instead of 2) halves task costs at idle; the trade-off is slower scale-out on traffic spike.

---

## Scenario 7 — Failure Modes

### Failure 1: ECS Instance Fails Health Check and Is Terminated

**Detection:** EC2 Auto Scaling `EC2 Health Check` marks instance unhealthy. CloudWatch `StatusCheckFailed` alarm.  
**Blast radius:** Tasks on the failed instance are stopped. If the instance held 30% of task capacity, available capacity drops temporarily.  
**Mitigation:** ASG launches a replacement instance (managed termination protection prevents removal of healthy instances). ECS reschedules stopped tasks on surviving capacity. AZ spread placement ensures tasks are distributed; a single-instance failure affects only one AZ's share. The On-Demand baseline means at least 2 AZs are always represented.

### Failure 2: Bad Deployment — Application Crashes on Start

**Detection:** New tasks fail container health check → ECS marks them STOPPED → circuit breaker threshold crossed → ECS auto-rollback triggered → CloudWatch alarm on `RunningTaskCount` or ECS service event stream.  
**Blast radius:** Zero — `minimum_healthy_percent = 100` kept all old tasks running during the failed deployment attempt. Users were never routed to the crashing new tasks.  
**Mitigation:** Automatic rollback restores previous task definition. On-call alert fires. Engineer investigates `stoppedReason` in ECS console/CloudWatch Logs. Root cause fix deployed as a new revision.

### Failure 3: SSM KMS Key Disabled / Deleted

**Detection:** New task launches fail with `AccessDeniedException` from KMS during SSM `GetParameter`. ECS service events log `ResourceInitializationError`. `RunningTaskCount` alarm fires as tasks cannot be replaced.  
**Blast radius:** Running tasks are unaffected (secrets already in environment). New launches, replacements, and scale-out all fail until KMS key is restored.  
**Mitigation:** Re-enable the KMS key in AWS KMS console (key deletion has a mandatory 7–30 day pending window — this buys time). If deleted, restore from key material backup if CMK, or rotate to a new key. Update SSM parameters to use the new key ARN. Force a new deployment. For operational safety, the KMS key should have a deletion prevention policy (`aws_kms_key.enable_key_rotation = true` and `deletion_window_in_days = 30`).
