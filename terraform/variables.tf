# ─────────────────────────────────────────────
# General
# ─────────────────────────────────────────────
variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short identifier used as a name prefix for all resources"
  type        = string
  default     = "myapp"
}

variable "environment" {
  description = "Deployment environment (e.g. production, staging)"
  type        = string
  default     = "production"
}

# ─────────────────────────────────────────────
# Networking  (pre-existing VPC assumed)
# ─────────────────────────────────────────────
variable "vpc_id" {
  description = "ID of the pre-existing VPC"
  type        = string
  # default     = "vpc-0fd43e21b7f3be66d"
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs (multi-AZ) for ECS instances and tasks"
  type        = list(string)
  # default = [ "subnet-0e76ebe267d4091c6", "subnet-070bc589db7a29525" ]
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs (multi-AZ) for the ALB"
  type        = list(string)
  # default = [ "subnet-02989b692e44129c6", "subnet-056ccf674d91cfda4" ]
}

variable "alb_security_group_id" {
  description = "Security group ID for the ALB (allows 80/443 from internet)"
  type        = string
  # default     = "sg-0a09aa1eeb0de220e"
}

variable "ecs_instance_security_group_id" {
  description = "Security group ID for ECS EC2 instances (allows traffic from ALB SG only)"
  type        = string
  # default     = "sg-03c0ab33c3eb2e70b"
}

# ─────────────────────────────────────────────
# Compute / ASG
# ─────────────────────────────────────────────
variable "instance_types" {
  description = "Ordered list of instance types for the Mixed Instance Policy"
  type        = list(string)
  default     =  [ "t2.micro", "t3.micro" ] # [ "m6g.large", "m7g.large" ]
}

variable "on_demand_base_capacity" {
  description = "Number of On-Demand instances that form the guaranteed baseline"
  type        = number
  default     = 2
}

variable "on_demand_percentage_above_base" {
  description = "Percentage of instances above the base that should be On-Demand (0 = all Spot)"
  type        = number
  default     = 0
}

variable "asg_min_size" {
  description = "Minimum number of EC2 instances in the ASG"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of EC2 instances in the ASG"
  type        = number
  default     = 10
}

variable "asg_desired_capacity" {
  description = "Initial desired capacity of the ASG"
  type        = number
  default     = 2
}

# ─────────────────────────────────────────────
# ECS Service
# ─────────────────────────────────────────────
variable "service_desired_count" {
  description = "Desired number of running ECS tasks"
  type        = number
  default     = 4
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 80
}

variable "task_cpu" {
  description = "CPU units reserved per task (1024 = 1 vCPU)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Memory (MiB) reserved per task"
  type        = number
  default     = 512
}


variable "alarm_sns_topic_arn" {
  description = "Alarm ARN"
  type        = string
}

variable "deployment_minimum_healthy_percent" {
  description = "Minimum percentage of tasks that must remain healthy during a deployment"
  type        = number
  default     = 100
}

variable "deployment_maximum_percent" {
  description = "Maximum percentage of desired task count that can run during a deployment"
  type        = number
  default     = 200
}

variable "health_check_grace_period_seconds" {
  description = "Seconds ECS waits before starting health checks on new tasks"
  type        = number
  default     = 60
}

# ─────────────────────────────────────────────
# ALB / Health Check
# ─────────────────────────────────────────────
variable "alb_certificate_arn" {
  description = "ARN of the ACM certificate for HTTPS termination on the ALB"
  type        = string
  default     = ""  # If empty, only HTTP listener is created
}

variable "health_check_path" {
  description = "Path the ALB uses for target health checks"
  type        = string
  default     = "/"
}

variable "health_check_healthy_threshold" {
  description = "Number of consecutive successes before a target is considered healthy"
  type        = number
  default     = 2
}

variable "health_check_unhealthy_threshold" {
  description = "Number of consecutive failures before a target is considered unhealthy"
  type        = number
  default     = 3
}

variable "health_check_interval" {
  description = "Seconds between health check requests"
  type        = number
  default     = 30
}

variable "deregistration_delay" {
  description = "Seconds ALB drains connections before deregistering a target"
  type        = number
  default     = 30
}

# ─────────────────────────────────────────────
# Secrets (SSM Parameter Store)
# ─────────────────────────────────────────────
variable "ssm_secret_arns" {
  description = <<-EOT
    Map of environment-variable name → SSM Parameter ARN.
    Parameters must be pre-created (Terraform never writes secret values).
    Example:
      { "DB_PASSWORD" = "arn:aws:ssm:us-east-1:123456789012:parameter/myapp/production/db_password" }
  EOT
  type        = map(string)
  default     = {}
}

# ─────────────────────────────────────────────
# Autoscaling (Service-level)
# ─────────────────────────────────────────────
variable "scale_out_cpu_threshold" {
  description = "Average service CPU % that triggers scale-out"
  type        = number
  default     = 70
}

variable "scale_in_cpu_threshold" {
  description = "Average service CPU % that triggers scale-in"
  type        = number
  default     = 30
}

variable "autoscaling_min_capacity" {
  description = "Minimum number of ECS tasks (service autoscaling)"
  type        = number
  default     = 2
}

variable "autoscaling_max_capacity" {
  description = "Maximum number of ECS tasks (service autoscaling)"
  type        = number
  default     = 20
}
