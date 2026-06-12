variable "aws_region" {
  description = "AWS region to deploy the Authentik IdP lab into."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment tag (e.g., lab, dev, eval)."
  type        = string
  default     = "lab"
}

variable "owner_tag" {
  description = "Owner tag — e.g., your email handle."
  type        = string
  default     = "AuthentikOwner"
}

variable "vpc_cidr" {
  description = "CIDR block for the Authentik VPC."
  type        = string
  default     = "10.50.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet hosting the EC2."
  type        = string
  default     = "10.50.1.0/24"
}

variable "instance_type" {
  description = "EC2 instance type. t3.medium is the minimum I'd recommend; Authentik worker + Postgres on the same box benefits from 2 vCPU + 4 GB RAM."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_gb" {
  description = "Root EBS volume size in GB."
  type        = number
  default     = 30
}

variable "allowed_admin_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach 80/443 on the IdP. For an eval where AWS
    Identity Center needs to fetch SAML metadata, leave this as ["0.0.0.0/0"]
    or you'll have to allow AWS service IP ranges explicitly. You can tighten
    this for the admin UI later by adding a separate path-based rule in front.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "authentik_image_tag" {
  description = <<-EOT
    Authentik container image tag, pinned for reproducibility. Authentik
    publishes year.month releases roughly monthly.
    Check the current stable release before deploying:
      https://github.com/goauthentik/authentik/releases
    or:
      curl -s https://api.github.com/repos/goauthentik/authentik/releases/latest | jq -r .tag_name
    Then set authentik_image_tag in terraform.tfvars accordingly.
  EOT
  type        = string
  default     = "2025.10"
}

variable "authentik_hostname_override" {
  description = <<-EOT
    Optional explicit hostname. If empty, the cloud-init computes
    <eip-with-dashes>.sslip.io automatically. Override when you eventually
    move to your own domain.
  EOT
  type        = string
  default     = ""
}

variable "enable_vpc_flow_logs" {
  description = "Send VPC flow logs to CloudWatch for detection telemetry. ~$0.50-$2/mo for a quiet lab."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention for VPC flow log CloudWatch group."
  type        = number
  default     = 30
}

variable "enable_detailed_monitoring" {
  description = "EC2 detailed (1-minute) CloudWatch metrics. Costs ~$2.10/mo. Set false to drop to default 5-min metrics."
  type        = bool
  default     = true
}
