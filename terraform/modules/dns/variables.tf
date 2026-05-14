variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
}

variable "domain_name" {
  description = "Root domain name - must exist as Route 53 hosted zone"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
