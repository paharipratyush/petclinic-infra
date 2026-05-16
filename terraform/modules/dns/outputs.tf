output "certificate_arn" {
  description = "ACM wildcard certificate ARN"
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
}

output "zone_id" {
  description = "Cloudflare zone ID (passed through for reference)"
  value       = var.cloudflare_zone_id
}
