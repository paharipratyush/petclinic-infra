variable "project"              { type = string }
variable "environment"          { type = string }
variable "aws_region"           { type = string }
variable "github_org"           { type = string }
variable "app_repo"             { type = string }

variable "create_oidc_provider" {
  description = "Set true for the FIRST environment that applies (dev). Set false for subsequent environments (prod) — they reference the existing provider via data source."
  type        = bool
  default     = true
}
