output "zone_id" {
  description = "Route 53 hosted zone ID"
  value       = data.aws_route53_zone.main.zone_id
}

output "zone_name" {
  description = "Route 53 hosted zone name"
  value       = data.aws_route53_zone.main.name
}

output "certificate_arn" {
  description = "ACM wildcard certificate ARN"
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
}

output "name_servers" {
  description = "Route 53 name servers for the hosted zone"
  value       = data.aws_route53_zone.main.name_servers
}
