output "role_arn" {
  value = aws_iam_role.github_actions.arn
}
output "role_name" {
  value = aws_iam_role.github_actions.name
}
