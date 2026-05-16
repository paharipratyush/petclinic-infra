# DNS Provider Guide

This project supports two DNS management approaches depending on where your
domain is registered. Choose the one that applies to you.

---

## Option A: Cloudflare (default in this repo)

**Use this if:** Your domain is registered with Cloudflare, or you have added
your domain to Cloudflare (even if registered elsewhere) and Cloudflare
controls your nameservers.

### What's already configured
- `terraform/modules/dns/main.tf` uses `cloudflare_record` resources
- `terraform/modules/dns/versions.tf` declares `cloudflare/cloudflare` provider
- `terraform/environments/dev/versions.tf` declares `cloudflare/cloudflare`
- `terraform/environments/dev/providers.tf` configures the Cloudflare provider

### What you need
1. Cloudflare Zone ID — Dashboard → your domain → Overview → right sidebar
2. Cloudflare API Token — Profile → API Tokens → Create Token →
   "Edit zone DNS" template → Specific zone → your domain

### What to add to terraform.tfvars
```hcl
cloudflare_zone_id   = "your-zone-id-here"
cloudflare_api_token = "your-api-token-here"
```

### Subdomains created automatically
| Subdomain | Purpose |
|-----------|---------|
| `petclinic-dev.your-domain.com` | Application (dev) |
| `grafana-dev.your-domain.com` | Grafana (dev) |
| `argocd-dev.your-domain.com` | ArgoCD (dev) |
| `admin-dev.your-domain.com` | Spring Boot Admin (dev) |
| `zipkin-dev.your-domain.com` | Zipkin distributed tracing (dev) |
| `petclinic.your-domain.com` | Application (prod) |
| `grafana.your-domain.com` | Grafana (prod) |
| `argocd.your-domain.com` | ArgoCD (prod) |
| `admin.your-domain.com` | Spring Boot Admin (prod) |
| `zipkin.your-domain.com` | Zipkin distributed tracing (prod) |

---

## Option B: Route 53 (mentor's original approach)

**Use this if:** Your domain is registered directly through AWS Route 53,
OR you have transferred your domain's nameservers to Route 53.

### Step 1: Point your domain's nameservers to Route 53

Get your Route 53 nameservers:
```bash
aws route53 get-hosted-zone \
  --id <your-zone-id> \
  --query 'DelegationSet.NameServers'
```

Then update nameservers at your registrar:
- **GoDaddy:** My Domains → DNS → Nameservers → Custom
- **Namecheap:** Domain List → Manage → Nameservers → Custom DNS
- **Google Domains:** DNS → Use custom name servers

For Cloudflare registered domains: Cloudflare free plan does NOT allow
changing nameservers. Use Option A instead.

### Step 2: Replace dns module files

Replace `terraform/modules/dns/versions.tf` with:
```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

Replace `terraform/modules/dns/main.tf` with:
```hcl
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

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

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ALB DNS records (added after ALB is created)
resource "aws_route53_record" "app" {
  count = var.alb_dns_name != "" ? 1 : 0

  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.environment == "prod" ? "petclinic" : "petclinic-dev"
  type    = "CNAME"
  ttl     = 60
  records = [var.alb_dns_name]
}

resource "aws_route53_record" "grafana" {
  count = var.alb_dns_name != "" ? 1 : 0

  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.environment == "prod" ? "grafana" : "grafana-dev"
  type    = "CNAME"
  ttl     = 60
  records = [var.alb_dns_name]
}

resource "aws_route53_record" "argocd" {
  count = var.alb_dns_name != "" ? 1 : 0

  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.environment == "prod" ? "argocd" : "argocd-dev"
  type    = "CNAME"
  ttl     = 60
  records = [var.alb_dns_name]
}

resource "aws_route53_record" "admin" {
  count = var.alb_dns_name != "" ? 1 : 0

  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.environment == "prod" ? "admin" : "admin-dev"
  type    = "CNAME"
  ttl     = 60
  records = [var.alb_dns_name]
}
```

### Step 3: Remove Cloudflare from versions.tf

In `terraform/environments/dev/versions.tf` and `prod/versions.tf`,
remove the cloudflare provider block:
```hcl
# Remove this block:
cloudflare = {
  source  = "cloudflare/cloudflare"
  version = "~> 4.0"
}
```

### Step 4: Remove Cloudflare from providers.tf

In `terraform/environments/dev/providers.tf` and `prod/providers.tf`,
remove:
```hcl
# Remove this block:
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```

### Step 5: Remove Cloudflare variables from variables.tf and terraform.tfvars

Remove `cloudflare_zone_id` and `cloudflare_api_token` from both files.

### Step 6: Update dns module call in main.tf

Remove `cloudflare_zone_id` from the dns module call:
```hcl
module "dns" {
  source      = "../../modules/dns"
  project     = var.project
  environment = var.environment
  domain_name = var.domain_name
}
```

### Step 7: Reinitialize and apply
```bash
rm .terraform.lock.hcl
terraform init -backend-config=../../../config/backend-dev.hcl
terraform apply -auto-approve
```
