variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
}

variable "openai_api_key" {
  description = "OpenAI API key for the GenAI service (leave empty to use demo key)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
