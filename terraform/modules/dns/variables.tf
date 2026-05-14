variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
}

variable "domain_name" {
  description = "Root domain name (e.g. praty.dev)"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for DNS record management"
  type        = string
}

variable "alb_dns_name" {
  description = "ALB DNS name to point subdomains at (provided after ALB is created)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags for AWS resources"
  type        = map(string)
  default     = {}
}

variable "monitoring_alb_dns_name" {
  description = "ALB DNS name for monitoring tools (Grafana, ArgoCD)"
  type        = string
  default     = ""
}
