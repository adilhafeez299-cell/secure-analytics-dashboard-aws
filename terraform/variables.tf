variable "region" {
  description = "AWS region. London keeps data in the UK."
  type        = string
  default     = "eu-west-2"
}

variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "pharma-dash"
}

variable "allowed_cidrs" {
  description = "Only these IP ranges can reach the load balancer. Use your own public IP as x.x.x.x/32."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "Give at least one CIDR, and never 0.0.0.0/0: this app must not be open to the internet."
  }
}

variable "alert_email" {
  description = "Email address for CloudWatch alarms. Confirm the subscription email AWS sends."
  type        = string
}

variable "entra_tenant_id" {
  description = "Directory (tenant) ID of YOUR OWN test Entra tenant. Never an employer or client tenant."
  type        = string
}

variable "entra_client_id" {
  description = "Application (client) ID of the Entra app registration."
  type        = string
}

variable "image_tag" {
  description = "Container image tag to run. Tags are immutable: a new release needs a new tag."
  type        = string
  default     = "v2"
}

variable "instance_type" {
  description = "EC2 size. t3.small is plenty for a demo."
  type        = string
  default     = "t3.small"
}

variable "session_timeout_seconds" {
  description = "How long a login lasts before the user must sign in again. ALB default is 7 days; sensitive data deserves less."
  type        = number
  default     = 3600
}
