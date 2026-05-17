output "openai_secret_arn" {
  description = "Secrets Manager ARN for OpenAI API key"
  value       = aws_secretsmanager_secret.openai.arn
}

output "grafana_secret_arn" {
  description = "Secrets Manager ARN for Grafana admin credentials"
  value       = aws_secretsmanager_secret.grafana.arn
}

output "eso_role_arn" {
  description = "IRSA role ARN for External Secrets Operator"
  value       = aws_iam_role.eso.arn
}
