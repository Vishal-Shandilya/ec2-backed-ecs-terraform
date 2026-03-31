# ═══════════════════════════════════════════════════════════════
# DATA SOURCES  (pre-existing resources referenced by variable)
# ═══════════════════════════════════════════════════════════════

data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_subnets" "private" {
  filter {
    name   = "subnet-id"
    values = var.private_subnet_ids
  }
}

data "aws_ami" "ecs_optimized" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-ecs-hvm-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# data "aws_ssm_parameter" "secrets" {
#   # Iterate only over provided secret ARNs to build an ARN list for IAM
#   for_each = var.ssm_secret_arns
#   name     = each.value  # value is the full ARN; SSM data source accepts ARNs
#   # We only reference this for ARN extraction — the VALUE never touches TF state
#   # because we use `secrets` block in the task definition (fetched at container start)
#   with_decryption = false
# }

# ═══════════════════════════════════════════════════════════════
# IAM — EC2 Instance Role (ECS Agent)
# ═══════════════════════════════════════════════════════════════

resource "aws_iam_role" "ecs_instance_role" {
  name               = "${var.project_name}-ecs-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Managed policy required for ECS agent to register instances
resource "aws_iam_role_policy_attachment" "ecs_instance_core" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# SSM Session Manager — enables shell access without bastion or SSH keys
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${var.project_name}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance_role.name
}

# ═══════════════════════════════════════════════════════════════
# IAM — ECS Task Execution Role
# Allows ECS to pull images and inject SSM secrets at launch time
# ═══════════════════════════════════════════════════════════════

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${var.project_name}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_core" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Least-privilege: only the specific SSM parameters this service needs
resource "aws_iam_role_policy" "ssm_read" {
  count = length(var.ssm_secret_arns) > 0 ? 1 : 0
  name  = "${var.project_name}-ssm-read"
  role  = aws_iam_role.ecs_task_execution_role.id

  policy = data.aws_iam_policy_document.ssm_read.json
}

data "aws_iam_policy_document" "ssm_read" {
  statement {
    sid    = "SSMGetParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    # Scope to only the ARNs declared in variables — not a wildcard
    resources = values(var.ssm_secret_arns)
  }

  statement {
    sid    = "KMSDecryptForSSM"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
    ]
    # Restrict to the customer-managed key(s) that encrypt these parameters
    # In production: replace with the actual KMS key ARN(s)
    resources = ["arn:aws:kms:*:*:key/*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

# ═══════════════════════════════════════════════════════════════
# IAM — ECS Task Role (runtime identity of the container)
# Least-privilege: no permissions by default — add only what the app needs
# ═══════════════════════════════════════════════════════════════

resource "aws_iam_role" "ecs_task_role" {
  name               = "${var.project_name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  # Production note: attach only the policies the application actually needs.
  # nginx:latest needs no AWS API access, so no extra policies are attached here.
}

# ═══════════════════════════════════════════════════════════════
# CLOUDWATCH LOG GROUP
# ═══════════════════════════════════════════════════════════════

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_name}-${var.environment}"
  retention_in_days = 30
}

# ═══════════════════════════════════════════════════════════════
# ECS CLUSTER
# ═══════════════════════════════════════════════════════════════

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"  # Enables Container Insights (CloudWatch metrics + logs)
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = [aws_ecs_capacity_provider.asg.name]

  # Default strategy used when a service doesn't specify its own
  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.asg.name
    weight            = 1
    base              = 1
  }
}

# ═══════════════════════════════════════════════════════════════
# ECS CAPACITY PROVIDER  (bridges ASG ↔ ECS managed scaling)
# ═══════════════════════════════════════════════════════════════

resource "aws_ecs_capacity_provider" "asg" {
  name = "${var.project_name}-asg-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs.arn

    # MANAGED_TERMINATION_PROTECTION prevents the ASG from terminating an
    # instance that still has running tasks, avoiding mid-flight task loss.
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 80   # Keep cluster at ~80% utilisation (leaves headroom for bursts)
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 5    # Cap how fast the ASG can grow in one step
      instance_warmup_period    = 120  # Seconds before a new instance is counted toward capacity
    }
  }

  # IMPORTANT: The capacity provider must be destroyed before the ASG.
  # Terraform handles this via implicit dependency on aws_autoscaling_group.ecs.
}

# ═══════════════════════════════════════════════════════════════
# LAUNCH TEMPLATE  (EC2 instance configuration for the ASG)
# ═══════════════════════════════════════════════════════════════

resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.project_name}-ecs-"
  image_id      = data.aws_ami.ecs_optimized.id
  # instance_type is NOT set here — the ASG Mixed Instance Policy handles it
  ebs_optimized = true

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  # No public IP — instances live in private subnets with NAT egress
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.ecs_instance_security_group_id]
    delete_on_termination       = true
  }

  # User data registers the instance into the correct ECS cluster and
  # enables Spot interruption draining so tasks are gracefully relocated
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euxo pipefail
    cat >> /etc/ecs/ecs.config <<EOL
    ECS_CLUSTER=${aws_ecs_cluster.main.name}
    ECS_ENABLE_SPOT_INSTANCE_DRAINING=true
    ECS_CONTAINER_STOP_TIMEOUT=30s
    ECS_ENGINE_TASK_CLEANUP_WAIT_DURATION=1h
    EOL
  EOF
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    # IMDSv2 (session-oriented) protects against SSRF credential theft
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # Enforce IMDSv2
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true  # Detailed (1-minute) CloudWatch metrics
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ═══════════════════════════════════════════════════════════════
# AUTO SCALING GROUP  (Mixed Instances: On-Demand base + Spot overflow)
# ═══════════════════════════════════════════════════════════════

resource "aws_autoscaling_group" "ecs" {
  name_prefix               = "${var.project_name}-ecs-"
  max_size                  = var.asg_max_size
  min_size                  = var.asg_min_size
  desired_capacity          = var.asg_desired_capacity
  vpc_zone_identifier       = var.private_subnet_ids
  health_check_type         = "EC2"
  health_check_grace_period = 300

  # ECS Capacity Provider uses managed termination protection — the ASG
  # must not terminate instances independently during scale-in.
  # The capacity provider removes protection only after task draining completes.
  protect_from_scale_in = true

  mixed_instances_policy {
    instances_distribution {
      # on_demand_base_capacity: guaranteed On-Demand minimum (e.g. 2 instances)
      on_demand_base_capacity = var.on_demand_base_capacity

      # Above the base, what % is On-Demand vs Spot?
      # 0 = all additional capacity is Spot (maximises savings)
      on_demand_percentage_above_base_capacity = var.on_demand_percentage_above_base

      # Spot allocation across pools — capacity-optimized picks the pool with
      # most available capacity, reducing interruption probability
      spot_allocation_strategy = "capacity-optimized"

      # Spot interruption fallback: how many Spot pools to draw from
      spot_instance_pools = 0  # N/A when using capacity-optimized strategy
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.ecs.id
        version            = "$Latest"
      }

      # Override instance types — ASG picks the best available across these
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  # Spread tasks across AZs before considering other factors
  dynamic "tag" {
    for_each = {
      Name        = "${var.project_name}-ecs-node"
      Environment = var.environment
      Project     = var.project_name
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # Allow Terraform to update the ASG without recreating it
  lifecycle {
    create_before_destroy = true
    # Prevent Terraform from overriding desired_capacity that ECS manages
    ignore_changes = [desired_capacity, tag]
  }
}

# ═══════════════════════════════════════════════════════════════
# APPLICATION LOAD BALANCER
# ═══════════════════════════════════════════════════════════════

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false  # Internet-facing; change to true for internal services
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  # Access logs bucket — recommended for production audit trail
  # access_logs {
  #   bucket  = "your-alb-access-log-bucket"
  #   prefix  = var.project_name
  #   enabled = true
  # }

  drop_invalid_header_fields = true  # Security hardening

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# Target Group — ALB routes traffic to this group; ECS registers/deregisters tasks
resource "aws_lb_target_group" "app" {
  name                 = "${var.project_name}-tg"
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay  # Drain time before task kill

  health_check {
    enabled             = true
    path                = var.health_check_path
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
    interval            = var.health_check_interval
    timeout             = 10
    matcher             = "200-299"
    protocol            = "HTTP"
  }

  stickiness {
    type    = "lb_cookie"
    enabled = false  # Disabled — stateless service; enable for session-sticky apps
  }

  tags = {
    Name = "${var.project_name}-tg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# HTTP listener — redirects to HTTPS if certificate is provided, otherwise serves directly
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = var.alb_certificate_arn != "" ? "redirect" : "forward"

    dynamic "redirect" {
      for_each = var.alb_certificate_arn != "" ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "forward" {
      for_each = var.alb_certificate_arn == "" ? [1] : []
      content {
        target_group {
          arn = aws_lb_target_group.app.arn
        }
      }
    }
  }
}

# HTTPS listener — created only if a certificate ARN is supplied
resource "aws_lb_listener" "https" {
  count             = var.alb_certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.alb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ═══════════════════════════════════════════════════════════════
# ECS TASK DEFINITION
# ═══════════════════════════════════════════════════════════════

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project_name}-${var.environment}"
  network_mode             = "bridge"  # EC2 launch type; awsvpc is for Fargate
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  cpu                      = var.task_cpu
  memory                   = var.task_memory

  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-app"
      image     = "nginx:latest"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = 0       # Dynamic host port — required for bridge mode + multiple tasks per instance
          protocol      = "tcp"
        }
      ]

      # Secrets are fetched at container start by the ECS agent (execution role).
      # Values are injected as environment variables and NEVER stored in TF state.
      secrets = [
        for name, arn in var.ssm_secret_arns : {
          name      = name
          valueFrom = arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      # Resource guardrails — prevent a runaway container from starving neighbours
      cpu    = var.task_cpu
      memory = var.task_memory

      # Health check at container level (in addition to ALB health check)
      healthCheck = {
        command     = ["CMD", "curl", "-f", "http://localhost:${var.container_port}/"]
        interval    = 30
        timeout     = 10
        retries     = 3
        startPeriod = 60
      }

      # Graceful shutdown: allow nginx to finish in-flight requests
      stopTimeout = 30
    }
  ])

  tags = {
    Name = "${var.project_name}-task-def"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ═══════════════════════════════════════════════════════════════
# ECS SERVICE
# ═══════════════════════════════════════════════════════════════

resource "aws_ecs_service" "app" {
  name                               = "${var.project_name}-${var.environment}"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.app.arn
  desired_count                      = var.service_desired_count
  health_check_grace_period_seconds  = var.health_check_grace_period_seconds

  # ZERO-DOWNTIME DEPLOYMENT SETTINGS:
  # minimum_healthy_percent = 100 means ECS never kills old tasks until new ones are healthy
  # maximum_percent = 200 means ECS can run 2× desired tasks transiently during rollout
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  # Use the capacity provider instead of a fixed launch type
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.asg.name
    weight            = 1
    base              = 1  # At least 1 task must be placed via this provider
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "${var.project_name}-app"
    container_port   = var.container_port
  }

  # Spread tasks across AZs first, then across instances within each AZ
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  # Circuit-breaker: auto-rolls back if a deployment fails health checks
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"  # Rolling update (not Blue/Green or external)
  }

  # Prevent Terraform from resetting desired_count that autoscaling manages
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.ecs_task_execution_core,
  ]
}

# ═══════════════════════════════════════════════════════════════
# SERVICE AUTO SCALING  (task-level, driven by CPU utilisation)
# ═══════════════════════════════════════════════════════════════

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.autoscaling_max_capacity
  min_capacity       = var.autoscaling_min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "scale" {
  name               = "${var.project_name}-scale"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_in_cooldown  = 300  # Wait 5 minutes before scaling in
    scale_out_cooldown = 60   # Wait 1 minute before scaling out
  }
  
}

# ═══════════════════════════════════════════════════════════════
# OPERATIONAL ALARMS  (production pages)
# ═══════════════════════════════════════════════════════════════

resource "aws_cloudwatch_metric_alarm" "alb_5xx_high" {
  alarm_name          = "${var.project_name}-alb-5xx-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 50
  treat_missing_data  = "notBreaching"
  alarm_description   = "ALB 5xx error rate elevated — check ECS tasks and application logs"
  alarm_actions       = [var.alarm_sns_topic_arn]
  
  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_host_count" {
  alarm_name          = "${var.project_name}-unhealthy-targets"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "One or more ALB targets are unhealthy — check ECS service events"
  alarm_actions       = [var.alarm_sns_topic_arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "running_task_count_low" {
  alarm_name          = "${var.project_name}-running-tasks-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = var.autoscaling_min_capacity
  alarm_description   = "Running task count below minimum — possible capacity exhaustion"
  alarm_actions       = [var.alarm_sns_topic_arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }
}
