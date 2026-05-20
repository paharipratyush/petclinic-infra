#!/bin/bash
# ==========================================================
# pre-apply-check.sh — Run BEFORE terraform apply
#
# Fully automated — handles ALL pre-existing resource conflicts
# so any person can deploy from scratch without manual steps.
#
# Handles:
#   1. Alertmanager email secret — creates if missing
#   2. GitHub OIDC Provider — shared between dev and prod
#   3. EKS Access Entry — auto-created by bootstrap, needs import
#   4. Prod shared IAM resources — role and policy created by dev
#   5. Cloudflare ACM validation record — creates or imports
# ==========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-dev}"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"

echo "=============================================="
echo " Pre-Apply Check — environment: ${ENV}"
echo "=============================================="

cd "${TF_DIR}"

REGION=$(grep "^aws_region" "${TF_DIR}/terraform.tfvars" \
  | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null \
  || echo "ap-south-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ── Check 0: Alertmanager email secret ───────────────────────────────────────
# Creates the secret if it doesn't exist — required by setup-cluster.sh.
# Fully automated — no manual aws secretsmanager create-secret needed.
echo ""
echo "[0/5] Checking Alertmanager email secret..."

AM_SECRET_ID="petclinic/${ENV}/alertmanager-email"
AM_EXISTS=$(aws secretsmanager describe-secret \
  --secret-id "${AM_SECRET_ID}" \
  --region "${REGION}" \
  --query "Name" --output text 2>/dev/null || echo "")

if [ -n "${AM_EXISTS}" ]; then
  echo "  ✅ Alertmanager secret exists: ${AM_SECRET_ID}"
else
  # Read email config from tfvars if present, else use defaults
  AM_EMAIL=$(grep "^alertmanager_email" "${TF_DIR}/terraform.tfvars" \
    | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null || echo "")
  AM_PASSWORD=$(grep "^alertmanager_app_password" "${TF_DIR}/terraform.tfvars" \
    | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null || echo "")

  if [ -n "${AM_EMAIL}" ] && [ -n "${AM_PASSWORD}" ]; then
    aws secretsmanager create-secret \
      --name "${AM_SECRET_ID}" \
      --description "Alertmanager Gmail credentials for ${ENV}" \
      --secret-string "{\"email\":\"${AM_EMAIL}\",\"app_password\":\"${AM_PASSWORD}\"}" \
      --region "${REGION}" &>/dev/null
    echo "  ✅ Created alertmanager secret from tfvars: ${AM_SECRET_ID}"
  else
    echo "  ⚠️  Alertmanager secret missing and no tfvars config found."
    echo "      Add to ${TF_DIR}/terraform.tfvars:"
    echo "      alertmanager_email        = \"your@gmail.com\""
    echo "      alertmanager_app_password = \"xxxx xxxx xxxx xxxx\""
    echo "      Or create manually:"
    echo "      aws secretsmanager create-secret \\"
    echo "        --name ${AM_SECRET_ID} \\"
    echo "        --secret-string '{\"email\":\"your@gmail.com\",\"app_password\":\"xxxx xxxx xxxx xxxx\"}' \\"
    echo "        --region ${REGION}"
    echo "  ⚠️  Continuing without alertmanager email config"
  fi
fi

# ── Check 1: GitHub OIDC Provider ────────────────────────────────────────────
echo ""
echo "[1/5] Checking GitHub OIDC Provider..."

CREATE_OIDC=$(grep "create_oidc_provider" "${TF_DIR}/main.tf" \
  2>/dev/null | grep -v "^#" | grep "false" || echo "")

if [ -n "${CREATE_OIDC}" ]; then
  echo "  ✅ create_oidc_provider = false — OIDC shared from dev, skipping"
else
  OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
  OIDC_EXISTS=$(aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "${OIDC_ARN}" \
    --query "Url" --output text 2>/dev/null || echo "")

  if [ -n "${OIDC_EXISTS}" ]; then
    IN_STATE=$(terraform state list 2>/dev/null | \
      grep "github_oidc.aws_iam_openid_connect_provider" || echo "")
    if [ -z "${IN_STATE}" ]; then
      echo "  ⚠️  GitHub OIDC provider exists but not in state — importing..."
      terraform import \
        'module.github_oidc.aws_iam_openid_connect_provider.github[0]' \
        "${OIDC_ARN}"
      echo "  ✅ Imported GitHub OIDC provider"
    else
      echo "  ✅ GitHub OIDC provider in state — no action needed"
    fi
  else
    echo "  ✅ GitHub OIDC provider does not exist — will be created"
  fi
fi

# ── Check 2: EKS Access Entry ─────────────────────────────────────────────────
echo ""
echo "[2/5] Checking EKS Access Entry..."

CLUSTER_NAME="petclinic-${ENV}"
IAM_USER=$(aws sts get-caller-identity --query Arn --output text | sed 's|.*/||')

CLUSTER_EXISTS=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --query "cluster.status" \
  --output text 2>/dev/null || echo "")

if [ -n "${CLUSTER_EXISTS}" ]; then
  ACCESS_ENTRY=$(aws eks list-access-entries \
    --cluster-name "${CLUSTER_NAME}" \
    --region "${REGION}" \
    --query "accessEntries[?contains(@,'${IAM_USER}')]" \
    --output text 2>/dev/null || echo "")
  if [ -n "${ACCESS_ENTRY}" ]; then
    IN_STATE=$(terraform state list 2>/dev/null | \
      grep "eks.aws_eks_access_entry.admin" || echo "")
    if [ -z "${IN_STATE}" ]; then
      echo "  ⚠️  EKS access entry exists but not in state — importing..."
      terraform import \
        'module.eks.aws_eks_access_entry.admin[0]' \
        "${CLUSTER_NAME}:${ACCESS_ENTRY}"
      echo "  ✅ Imported EKS access entry"
    else
      echo "  ✅ EKS access entry in state — no action needed"
    fi
  else
    echo "  ✅ No conflicting EKS access entry found"
  fi
else
  echo "  ✅ Cluster does not exist — will be created fresh"
fi

# ── Check 3: Prod shared IAM resources ───────────────────────────────────────
echo ""
echo "[3/5] Checking shared IAM resources (prod only)..."

if [ "${ENV}" = "prod" ]; then
  ROLE_EXISTS=$(aws iam get-role \
    --role-name "petclinic-github-actions-role" \
    --query "Role.RoleName" \
    --output text 2>/dev/null || echo "")

  if [ -n "${ROLE_EXISTS}" ]; then
    IN_STATE=$(terraform state list 2>/dev/null | \
      grep "github_oidc.aws_iam_role.github_actions" || echo "")
    if [ -z "${IN_STATE}" ]; then
      echo "  ⚠️  IAM role exists — importing..."
      terraform import \
        'module.github_oidc.aws_iam_role.github_actions' \
        'petclinic-github-actions-role'
      echo "  ✅ Imported GitHub Actions IAM role"
    else
      echo "  ✅ GitHub Actions IAM role in state — no action needed"
    fi
  else
    echo "  ✅ GitHub Actions IAM role does not exist — will be created"
  fi

  POLICY_ARN=$(aws iam list-policies \
    --query "Policies[?PolicyName=='petclinic-github-actions-ecr-policy'].Arn" \
    --output text 2>/dev/null || echo "")

  if [ -n "${POLICY_ARN}" ] && [ "${POLICY_ARN}" != "None" ]; then
    IN_STATE=$(terraform state list 2>/dev/null | \
      grep "github_oidc.aws_iam_policy.github_actions_ecr" || echo "")
    if [ -z "${IN_STATE}" ]; then
      echo "  ⚠️  IAM policy exists — importing..."
      terraform import \
        'module.github_oidc.aws_iam_policy.github_actions_ecr' \
        "${POLICY_ARN}"
      echo "  ✅ Imported GitHub Actions IAM policy"
    else
      echo "  ✅ GitHub Actions IAM policy in state — no action needed"
    fi
  else
    echo "  ✅ GitHub Actions IAM policy does not exist — will be created"
  fi
else
  echo "  ✅ Dev environment — shared IAM resources will be created"
fi

# ── Check 4: Cloudflare ACM validation record (prod only) ────────────────────
# The ACM wildcard cert for *.domain.com always generates the same validation
# CNAME regardless of which environment creates it. Dev creates it first.
# For prod we must either import the existing record or create it if missing.
# This is fully automated — no manual Cloudflare steps needed.
echo ""
echo "[4/5] Checking Cloudflare ACM validation record (prod only)..."

if [ "${ENV}" = "prod" ]; then
  IN_STATE=$(terraform state list 2>/dev/null | \
    grep 'dns.cloudflare_record.acm_validation' || echo "")

  if [ -n "${IN_STATE}" ]; then
    echo "  ✅ Cloudflare ACM validation record in state — no action needed"
  else
    ZONE_ID=$(grep "^cloudflare_zone_id" "${TF_DIR}/terraform.tfvars" \
      | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null || echo "")
    CF_TOKEN=$(grep "^cloudflare_api_token" "${TF_DIR}/terraform.tfvars" \
      | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null || echo "")
    DOMAIN=$(grep "^domain_name" "${TF_DIR}/terraform.tfvars" \
      | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null || echo "")

    if [ -z "${ZONE_ID}" ] || [ -z "${CF_TOKEN}" ] || [ -z "${DOMAIN}" ]; then
      echo "  ⚠️  Missing Cloudflare credentials in tfvars — skipping"
    else
      # Find existing ACM validation CNAME in Cloudflare
      CF_RESPONSE=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=CNAME&per_page=100" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" 2>/dev/null || echo "{}")

      CF_RECORD_ID=$(echo "${CF_RESPONSE}" | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    for r in data.get('result', []):
        if '_acm-challenge' in r.get('name', '') or \
           r.get('name','').startswith('_'):
            print(r['id'])
            break
except:
    pass
" 2>/dev/null || echo "")

      if [ -n "${CF_RECORD_ID}" ]; then
        # Record exists — import it
        echo "  ⚠️  Cloudflare ACM validation record exists — importing..."
        terraform import \
          "module.dns.cloudflare_record.acm_validation[\"*.${DOMAIN}\"]" \
          "${ZONE_ID}/${CF_RECORD_ID}" 2>/dev/null && \
          echo "  ✅ Imported Cloudflare ACM validation record" || \
          echo "  ⚠️  Import failed — will attempt to handle during apply"
      else
        # Record does not exist — need to get ACM cert validation details
        # Check if prod ACM cert already exists in state
        CERT_ARN=$(terraform output -raw certificate_arn 2>/dev/null || echo "")
        if [ -n "${CERT_ARN}" ]; then
          # Get validation CNAME from existing cert
          CNAME_NAME=$(aws acm describe-certificate \
            --certificate-arn "${CERT_ARN}" \
            --region "${REGION}" \
            --query "Certificate.DomainValidationOptions[0].ResourceRecord.Name" \
            --output text 2>/dev/null | sed 's/\.$//' || echo "")
          CNAME_VALUE=$(aws acm describe-certificate \
            --certificate-arn "${CERT_ARN}" \
            --region "${REGION}" \
            --query "Certificate.DomainValidationOptions[0].ResourceRecord.Value" \
            --output text 2>/dev/null | sed 's/\.$//' || echo "")

          if [ -n "${CNAME_NAME}" ] && [ -n "${CNAME_VALUE}" ]; then
            echo "  ⚠️  Creating ACM validation CNAME in Cloudflare..."
            NEW_ID=$(curl -s -X POST \
              "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
              -H "Authorization: Bearer ${CF_TOKEN}" \
              -H "Content-Type: application/json" \
              --data "{
                \"type\": \"CNAME\",
                \"name\": \"${CNAME_NAME}\",
                \"content\": \"${CNAME_VALUE}\",
                \"ttl\": 60,
                \"proxied\": false
              }" | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    if data.get('success'):
        print(data['result']['id'])
    else:
        print('')
except:
    print('')
" 2>/dev/null || echo "")

            if [ -n "${NEW_ID}" ]; then
              terraform import \
                "module.dns.cloudflare_record.acm_validation[\"*.${DOMAIN}\"]" \
                "${ZONE_ID}/${NEW_ID}" 2>/dev/null && \
                echo "  ✅ Created and imported Cloudflare ACM validation record" || \
                echo "  ⚠️  Created record but import failed"
            else
              echo "  ⚠️  Could not create Cloudflare record — may already exist"
            fi
          fi
        else
          echo "  ✅ ACM cert not yet created — dns module will create record on first apply"
        fi
      fi
    fi
  fi
else
  echo "  ✅ Dev environment — Cloudflare record will be created fresh"
fi

echo ""
echo "=============================================="
echo " Pre-apply check complete!"
echo "=============================================="
