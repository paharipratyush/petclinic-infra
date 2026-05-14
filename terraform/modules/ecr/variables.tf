variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
}

variable "service_names" {
  description = "List of microservice names to create ECR repos for"
  type        = list(string)
  default = [
    "config-server",
    "discovery-server",
    "api-gateway",
    "customers-service",
    "visits-service",
    "vets-service",
    "genai-service",
    "admin-server"
  ]
}

variable "image_tag_mutability" {
  description = "Tag mutability: MUTABLE for dev, IMMUTABLE for prod"
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "Must be MUTABLE or IMMUTABLE."
  }
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
