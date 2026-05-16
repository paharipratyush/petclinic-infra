variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name used in resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "availability_zones" {
  description = "Availability zones to use"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "eks_cluster_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "EC2 instance types for EKS node group (ARM64/Graviton)"
  type        = list(string)
  default     = ["t4g.medium"]
}

variable "node_min_size" {
  description = "Minimum number of nodes in the node group"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of nodes in the node group"
  type        = number
  default     = 6
}

variable "node_desired_size" {
  description = "Desired number of nodes in the node group"
  type        = number
  default     = 3
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "domain_name" {
  description = "Root domain name managed in Cloudflare"
  type        = string
  default     = "praty.dev"
}

variable "iam_admin_username" {
  description = "IAM username that gets EKS cluster admin access"
  type        = string
  default     = ""
}

variable "openai_api_key" {
  description = "OpenAI API key for the GenAI service. Leave empty for demo mode."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for the domain (from Cloudflare dashboard)"
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit permissions"
  type        = string
  sensitive   = true
}

variable "alb_dns_name" {
  description = "App ALB DNS name — filled by scripts/update-dns-and-ingress.sh after deploy"
  type        = string
  default     = ""
}

variable "monitoring_alb_dns_name" {
  description = "Monitoring ALB DNS name — filled by scripts/update-dns-and-ingress.sh after deploy"
  type        = string
  default     = ""
}

variable "github_org" {
  description = "GitHub organization or username that owns the repos"
  type        = string
  default     = ""
}

variable "infra_repo" {
  description = "GitHub repository name for the infra repo"
  type        = string
  default     = "petclinic-infra"
}

variable "app_repo" {
  description = "GitHub repository name for the app repo"
  type        = string
  default     = "spring-petclinic-microservices"
}
