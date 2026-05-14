#!/bin/bash
# Reads ALB DNS names from cluster and updates Cloudflare DNS + generates ingress
# Usage: ./scripts/update-dns-and-ingress.sh [dev|prod]
set -euo pipefail

ENV="${1:-dev}"
REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CERT_ARN=$(aws acm list-certificates \
  --region "${REGION}" \
  --query "CertificateSummaryList[?DomainName=='praty.dev'].CertificateArn" \
  --output text)
DOMAIN="praty.dev"

echo "==> Environment : ${ENV}"
echo "==> Region      : ${REGION}"
echo "==> Certificate : ${CERT_ARN}"

# Get ALB DNS names from cluster
APP_ALB=$(kubectl get ingress petclinic-ingress \
  -n petclinic-${ENV} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

MONITORING_ALB=$(kubectl get ingress grafana-ingress \
  -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

echo "==> App ALB        : ${APP_ALB}"
echo "==> Monitoring ALB : ${MONITORING_ALB}"

# Generate ingress manifest with real values
cat > ~/petclinic-infra/monitoring/monitoring-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: ${CERT_ARN}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/group.name: petclinic-monitoring
spec:
  ingressClassName: alb
  rules:
    - host: grafana-${ENV}.${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: ${CERT_ARN}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/group.name: petclinic-monitoring
    alb.ingress.kubernetes.io/backend-protocol: HTTPS
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTPS
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
spec:
  ingressClassName: alb
  rules:
    - host: argocd-${ENV}.${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
EOF

echo "==> Generated monitoring-ingress.yaml"

# Update Cloudflare DNS via Terraform
cd ~/petclinic-infra/terraform/environments/${ENV}

# Write tfvars additions to a temp file
cat > /tmp/dns-update.auto.tfvars << EOF
alb_dns_name            = "${APP_ALB}"
monitoring_alb_dns_name = "${MONITORING_ALB}"
EOF

echo "==> Updating DNS records..."
terraform apply -auto-approve \
  -var="alb_dns_name=${APP_ALB}" \
  -var="monitoring_alb_dns_name=${MONITORING_ALB}"

echo "✅ Done!"
