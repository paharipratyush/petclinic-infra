output "zone_id" {
  description = "Route 53 hosted zone ID"
  value       = data.aws_route53_zone.main.zone_id
}

output "certificate_arn" {
  description = "ACM wildcard certificate ARN"
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
}
