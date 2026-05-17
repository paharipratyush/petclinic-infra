# ── ACM Wildcard Certificate ──────────────────────────────────────────────────
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

# ── ACM validation record in Cloudflare ──────────────────────────────────────
# ACM uses the IDENTICAL CNAME for both praty.dev and *.praty.dev validation.
# Creating two Cloudflare records with the same name/value causes:
#   "attempted to override existing record however didn't find an exact match"
# Fix: only create ONE record by filtering to the wildcard domain only.
# One CNAME is sufficient — ACM validates both domains from it.
resource "cloudflare_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options :
    dvo.domain_name => {
      name  = trimsuffix(dvo.resource_record_name, ".")
      value = trimsuffix(dvo.resource_record_value, ".")
      type  = dvo.resource_record_type
    }
    if dvo.domain_name == "*.${var.domain_name}"
  }

  zone_id         = var.cloudflare_zone_id
  name            = each.value.name
  content         = each.value.value
  type            = each.value.type
  ttl             = 60
  proxied         = false
  allow_overwrite = true
}

# ── Wait for ACM certificate validation ───────────────────────────────────────
# Cert is already ISSUED from previous apply — this completes immediately.
resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn = aws_acm_certificate.wildcard.arn
  depends_on      = [cloudflare_record.acm_validation]
}

# ── Application DNS records in Cloudflare ────────────────────────────────────
resource "cloudflare_record" "app" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.environment == "prod" ? "petclinic" : "petclinic-dev"
  content = var.alb_dns_name
  type    = "CNAME"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "grafana" {
  count   = var.monitoring_alb_dns_name != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.environment == "prod" ? "grafana" : "grafana-dev"
  content = var.monitoring_alb_dns_name
  type    = "CNAME"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "argocd" {
  count   = var.monitoring_alb_dns_name != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.environment == "prod" ? "argocd" : "argocd-dev"
  content = var.monitoring_alb_dns_name
  type    = "CNAME"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "admin" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.environment == "prod" ? "admin" : "admin-dev"
  content = var.alb_dns_name
  type    = "CNAME"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "zipkin" {
  count   = var.monitoring_alb_dns_name != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.environment == "prod" ? "zipkin" : "zipkin-dev"
  content = var.monitoring_alb_dns_name
  type    = "CNAME"
  ttl     = 1
  proxied = false
}
