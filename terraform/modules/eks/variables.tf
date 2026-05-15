variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for EKS cluster and node group"
  type        = list(string)
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID"
  type        = string
}

variable "node_sg_id" {
  description = "EKS node security group ID"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "EC2 instance types for node group (ARM64/Graviton)"
  type        = list(string)
  default     = ["t4g.medium"]
}

variable "node_ami_type" {
  description = "AMI type for nodes — AL2_ARM_64 for Graviton (t4g) instances"
  type        = string
  default     = "AL2_ARM_64"
}

variable "node_min_size" {
  description = "Minimum node count"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count"
  type        = number
  default     = 6
}

variable "node_desired_size" {
  description = "Desired node count"
  type        = number
  default     = 3
}

variable "node_disk_size" {
  description = "Node disk size in GB"
  type        = number
  default     = 20
}

variable "iam_admin_username" {
  description = "IAM username to grant EKS cluster admin access. Leave empty to skip."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

variable "rds_sg_id" {
  description = "RDS security group ID — EKS managed node SG gets MySQL access to this"
  type        = string
  default     = ""
}

variable "alb_sg_id" {
  description = "ALB security group ID — allows ALB to reach pods"
  type        = string
  default     = ""
}
