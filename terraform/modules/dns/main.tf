# ── Look up existing hosted zone ──────────────────────────────────────────────
# The hosted zone must already exist (created when you registered the domain).
# We use a data source — we do NOT create a new hosted zone.
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# ── ACM Wildcard Certificate ──────────────────────────────────────────────────
# Wildcard covers: *.praty.dev
# This allows: petclinic.praty.dev, grafana.praty.dev, argocd.praty.dev, etc.
resource "aws_acm_certificate" "wildcard" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-wildcard-cert"
  })
}

# ── DNS validation records ────────────────────────────────────────────────────
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

# ── Wait for certificate validation ──────────────────────────────────────────
resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
