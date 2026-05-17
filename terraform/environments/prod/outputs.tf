output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN"
  value       = module.eks.oidc_provider_arn
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl"
  value       = module.eks.kubeconfig_command
}

output "ecr_registry_url" {
  description = "ECR registry base URL"
  value       = module.ecr.registry_url
}

output "ecr_repository_urls" {
  description = "All ECR repository URLs"
  value       = module.ecr.repository_urls
}

output "rds_endpoint" {
  description = "RDS endpoint"
  value       = module.rds.endpoint
}

output "rds_secret_arn" {
  description = "RDS credentials secret ARN"
  value       = module.rds.secret_arn
}

output "rds_jdbc_url" {
  description = "JDBC URL for Spring Boot services"
  value       = module.rds.jdbc_url
}

output "openai_secret_arn" {
  description = "OpenAI API key secret ARN"
  value       = module.secrets.openai_secret_arn
}

output "certificate_arn" {
  description = "ACM wildcard certificate ARN"
  value       = module.dns.certificate_arn
}

output "zone_id" {
  description = "Cloudflare zone ID"
  value       = module.dns.zone_id
}

output "eso_role_arn" {
  description = "ESO IRSA role ARN"
  value       = module.secrets.eso_role_arn
}

output "lb_controller_role_arn" {
  description = "ALB controller IRSA role ARN"
  value       = module.eks.lb_controller_role_arn
}

output "github_actions_role_arn" {
  value = module.github_oidc.role_arn
}

output "grafana_secret_arn" {
  description = "Grafana admin credentials secret ARN"
  value       = module.secrets.grafana_secret_arn
}

output "karpenter_role_arn" {
  description = "Karpenter controller IRSA role ARN"
  value       = module.karpenter.karpenter_role_arn
}

output "karpenter_queue_name" {
  description = "Karpenter SQS interruption queue name"
  value       = module.karpenter.karpenter_queue_name
}

output "karpenter_instance_profile_name" {
  description = "Karpenter node instance profile name"
  value       = module.karpenter.karpenter_instance_profile_name
}
