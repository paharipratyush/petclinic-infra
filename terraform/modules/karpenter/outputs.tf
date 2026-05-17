output "karpenter_role_arn" {
  description = "Karpenter controller IRSA role ARN"
  value       = aws_iam_role.karpenter.arn
}

output "karpenter_queue_name" {
  description = "SQS interruption queue name"
  value       = aws_sqs_queue.interruption.name
}

output "karpenter_queue_url" {
  description = "SQS interruption queue URL"
  value       = aws_sqs_queue.interruption.url
}

output "karpenter_instance_profile_name" {
  description = "Instance profile name for Karpenter-launched nodes"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "karpenter_node_role_arn" {
  description = "IAM role ARN for Karpenter-launched nodes"
  value       = aws_iam_role.karpenter_node.arn
}
