#!/bin/bash
# ============================================================
# update-dns-and-ingress.sh — Wire ALB hostnames to Cloudflare DNS
#
# Run this AFTER all ingresses are created and ALBs are provisioned:
#   1. Gets ALB hostnames from kubectl
#   2. Updates terraform.tfvars with ALB hostnames
#   3. Reads domain from terraform.tfvars
#   4. Runs terraform apply to create Cloudflare CNAME records
#   5. Prints the live URLs
#
# Usage:
#   ./scripts/update-dns-and-ingress.sh          # defaults to dev
#   ./scripts/update-dns-and-ingress.sh dev
#   ./scripts/update-dns-and-ingress.sh prod
#
# Prerequisites:
#   - kubectl configured (aws eks update-kubeconfig)
#   - terraform.tfvars exists in terraform/environments/{env}/
#   - App ingress and monitoring ingress are both created
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-dev}"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"
TFVARS="${TF_DIR}/terraform.tfvars"

echo "=============================================="
echo " update-dns-and-ingress.sh — env: ${ENV}"
echo "=============================================="

# ── Verify tfvars exists ──────────────────────────────────────────────────────
if [ ! -f "${TFVARS}" ]; then
  echo "   ❌ ERROR: ${TFVARS} not found."
  echo "   Copy terraform.tfvars.example to terraform.tfvars and fill in your values."
  exit 1
fi

# ── Read domain from tfvars ───────────────────────────────────────────────────
DOMAIN=$(grep "^domain_name" "${TFVARS}" | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ')
if [ -z "${DOMAIN}" ]; then
  echo "   ⚠️  WARNING: domain_name not found in ${TFVARS} — URLs will be incomplete"
  DOMAIN="your-domain.com"
fi
echo " Domain: ${DOMAIN}"

# ── Wait for and get App ALB hostname ────────────────────────────────────────
echo ""
echo "[1/3] Getting App ALB hostname (petclinic-${ENV} ingress)..."
echo "      Waiting up to 5 minutes for ALB to be provisioned..."

APP_ALB=""
for i in $(seq 1 30); do
  APP_ALB=$(kubectl get ingress petclinic-ingress -n "petclinic-${ENV}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "${APP_ALB}" ]; then
    echo "   ✅ App ALB: ${APP_ALB}"
    break
  fi
  echo "   Attempt ${i}/30 — ALB not ready yet, waiting 10s..."
  sleep 10
done

if [ -z "${APP_ALB}" ]; then
  echo "   ❌ ERROR: App ALB hostname not found after 5 minutes."
  echo "   Make sure the ingress is applied: kubectl apply -f k8s/overlays/${ENV}/ingress.yaml"
  exit 1
fi

# ── Wait for and get Monitoring ALB hostname ──────────────────────────────────
echo ""
echo "[2/3] Getting Monitoring ALB hostname (grafana ingress)..."

MONITORING_ALB=""
for i in $(seq 1 30); do
  MONITORING_ALB=$(kubectl get ingress grafana-ingress -n monitoring \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "${MONITORING_ALB}" ]; then
    echo "   ✅ Monitoring ALB: ${MONITORING_ALB}"
    break
  fi
  echo "   Attempt ${i}/30 — ALB not ready yet, waiting 10s..."
  sleep 10
done

if [ -z "${MONITORING_ALB}" ]; then
  echo "   ⚠️  WARNING: Monitoring ALB hostname not found."
  echo "   Continuing with empty monitoring_alb_dns_name."
  echo "   Apply monitoring ingress first, then re-run this script."
fi

# ── Update terraform.tfvars ───────────────────────────────────────────────────
echo ""
echo "[3/3] Updating terraform.tfvars..."

sed -i "s|^alb_dns_name.*=.*|alb_dns_name            = \"${APP_ALB}\"|" "${TFVARS}"
echo "   ✅ Updated alb_dns_name = ${APP_ALB}"

if [ -n "${MONITORING_ALB}" ]; then
  sed -i "s|^monitoring_alb_dns_name.*=.*|monitoring_alb_dns_name = \"${MONITORING_ALB}\"|" "${TFVARS}"
  echo "   ✅ Updated monitoring_alb_dns_name = ${MONITORING_ALB}"
fi

# ── Run terraform apply ───────────────────────────────────────────────────────
echo ""
echo "Running terraform apply to create Cloudflare CNAME records..."
echo ""

cd "${TF_DIR}"
terraform apply \
  -target=module.dns.cloudflare_record.app \
  -target=module.dns.cloudflare_record.grafana \
  -target=module.dns.cloudflare_record.argocd \
  -target=module.dns.cloudflare_record.admin \
  -target=module.dns.cloudflare_record.zipkin \
  -auto-approve

# ── Print live URLs ───────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " DNS records created! Your live URLs:"
echo "=============================================="
if [ "${ENV}" = "prod" ]; then
  echo "   https://petclinic.${DOMAIN}"
  echo "   https://grafana.${DOMAIN}"
  echo "   https://argocd.${DOMAIN}"
  echo "   https://admin.${DOMAIN}"
  echo "   https://zipkin.${DOMAIN}"
else
  echo "   https://petclinic-dev.${DOMAIN}"
  echo "   https://grafana-dev.${DOMAIN}"
  echo "   https://argocd-dev.${DOMAIN}"
  echo "   https://admin-dev.${DOMAIN}"
  echo "   https://zipkin-dev.${DOMAIN}"
fi
echo ""
echo " DNS propagation may take 1-5 minutes."
echo "=============================================="
