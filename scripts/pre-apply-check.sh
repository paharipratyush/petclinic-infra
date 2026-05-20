#!/bin/bash
# ==========================================================
# pre-apply-check.sh — Run BEFORE terraform apply
#
# Fully automated — handles ALL pre-existing resource conflicts
# so any person can deploy from scratch without manual steps.
#
# Handles:
#   0. Alertmanager email secret — creates if missing
#   1. GitHub OIDC Provider — shared between dev and prod
#   2. EKS Access Entry — auto-created by bootstrap, needs import
#   3. Prod shared IAM resources — role and policy created by dev
#   4. Cloudflare ACM validation record — imports or creates for
#      BOTH dev and prod (same CNAME, shared across environments)
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

# Read Cloudflare credentials once — used in multiple checks
ZONE_ID=$(grep "^cloudflare_zone_id" "${TF_DIR}/terraform.tfvars" \
  | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null || echo "")
CF_TOKEN=$(grep "^cloudflare_api_token" "${TF_DIR}/terraform.tfvars" \
  | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null || echo "")
DOMAIN=$(grep "^domain_name" "${TF_DIR}/terraform.tfvars" \
  | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null || echo "")

# ── Check 0: Alertmanager email secret ───────────────────────────────────────
# Creates the secret if missing — required by setup-cluster.sh Step 9.
# Reads credentials from terraform.tfvars (alertmanager_email,
# alertmanager_app_password) — never committed to Git since tfvars
# is gitignored. Fully automated — no manual aws secretsmanager needed.
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
# GitHub Actions IAM role and ECR policy have no env suffix — they are
# shared across dev and prod. Dev creates them on first apply. Prod must
# import them to avoid duplicate creation errors.
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

# ── Check 4: Cloudflare ACM validation record ────────────────────────────────
# The ACM wildcard cert for *.domain always generates the same validation
# CNAME name regardless of which environment creates the cert. This means:
#   - Dev creates the Cloudflare CNAME on first apply
#   - Prod's dns module tries to create the same CNAME → conflict
#   - On re-deploy after destroy, CNAME may not exist → needs re-import
# Fix: check if CNAME exists in Cloudflare for BOTH environments.
#   - If exists and not in state → import it
#   - If not exists and cert exists → create it in Cloudflare + import
#   - If not exists and cert not exists → let terraform create it
echo ""
echo "[4/5] Checking Cloudflare ACM validation record..."

if [ -z "${ZONE_ID}" ] || [ -z "${CF_TOKEN}" ] || [ -z "${DOMAIN}" ]; then
  echo "  ⚠️  Missing Cloudflare credentials in tfvars — skipping"
else
  IN_STATE=$(terraform state list 2>/dev/null | \
    grep 'dns.cloudflare_record.acm_validation' || echo "")

  if [ -n "${IN_STATE}" ]; then
    echo "  ✅ Cloudflare ACM validation record in state — no action needed"
  else
    # Check if CNAME exists in Cloudflare
    CF_RESPONSE=$(curl -s -X GET \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=CNAME&per_page=100" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" 2>/dev/null || echo "{}")

    CF_RECORD_ID=$(echo "${CF_RESPONSE}" | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    for r in data.get('result', []):
        name = r.get('name', '')
        if '_acm-challenge' in name or name.startswith('_'):
            print(r['id'])
            break
except:
    pass
" 2>/dev/null || echo "")

    if [ -n "${CF_RECORD_ID}" ]; then
      # Record exists in Cloudflare — import into state
      echo "  ⚠️  Cloudflare ACM validation record exists — importing..."
      terraform import \
        "module.dns.cloudflare_record.acm_validation[\"*.${DOMAIN}\"]" \
        "${ZONE_ID}/${CF_RECORD_ID}" 2>/dev/null && \
        echo "  ✅ Imported Cloudflare ACM validation record" || \
        echo "  ⚠️  Import failed — terraform will handle during apply"
    else
      # Record does not exist — check if ACM cert already exists
      # Use S3 state to avoid terraform CLI hang
      STATE_FILE="/tmp/tfstate-${ENV}.json"
      if [ ! -f "${STATE_FILE}" ]; then
        BACKEND_CONFIG="${REPO_ROOT}/config/backend-${ENV}.hcl"
        S3_BUCKET=$(grep "^bucket" "${BACKEND_CONFIG}" \
          | sed 's/.*=\s*//' | tr -d '"' | tr -d ' ' 2>/dev/null || echo "")
        S3_KEY=$(grep "^key" "${BACKEND_CONFIG}" \
          | sed 's/.*=\s*//' | tr -d '"' | tr -d ' ' 2>/dev/null || echo "")
        if [ -n "${S3_BUCKET}" ] && [ -n "${S3_KEY}" ]; then
          aws s3 cp "s3://${S3_BUCKET}/${S3_KEY}" "${STATE_FILE}" \
            --region "${REGION}" --quiet 2>/dev/null || true
        fi
      fi

      CERT_ARN=""
      if [ -f "${STATE_FILE}" ]; then
        CERT_ARN=$(python3 -c "
import json
with open('${STATE_FILE}') as f:
    state = json.load(f)
print(state.get('outputs',{}).get('certificate_arn',{}).get('value',''))
" 2>/dev/null || echo "")
      fi

      if [ -n "${CERT_ARN}" ]; then
        # ACM cert exists — get validation CNAME details and create in Cloudflare
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
        import sys
        print('', file=sys.stderr)
        print('', end='')
except:
    print('', end='')
" 2>/dev/null || echo "")

          if [ -n "${NEW_ID}" ]; then
            terraform import \
              "module.dns.cloudflare_record.acm_validation[\"*.${DOMAIN}\"]" \
              "${ZONE_ID}/${NEW_ID}" 2>/dev/null && \
              echo "  ✅ Created and imported Cloudflare ACM validation record" || \
              echo "  ⚠️  Created record but import failed"
          else
            echo "  ⚠️  Could not create Cloudflare record — may conflict"
          fi
        else
          echo "  ⚠️  Could not get ACM cert validation details"
        fi
      else
        echo "  ✅ No existing cert or CNAME — terraform will create fresh"
      fi
    fi
  fi
fi

# ── Check 5: Delete old IAM policy versions ───────────────────────────────────
# AWS limits IAM policies to 5 versions. When tf.sh applies changes to the
# ECR policy (e.g. adding dev+prod repos), it creates a new version. After
# 5 versions, further updates fail. Auto-delete non-default old versions.
echo ""
echo "[5/5] Cleaning up old IAM policy versions..."

POLICY_ARN_CHECK=$(aws iam list-policies \
  --query "Policies[?PolicyName=='petclinic-github-actions-ecr-policy'].Arn" \
  --output text 2>/dev/null || echo "")

if [ -n "${POLICY_ARN_CHECK}" ] && [ "${POLICY_ARN_CHECK}" != "None" ]; then
  DEFAULT_VERSION=$(aws iam get-policy \
    --policy-arn "${POLICY_ARN_CHECK}" \
    --query "Policy.DefaultVersionId" \
    --output text 2>/dev/null || echo "v1")

  OLD_VERSIONS=$(aws iam list-policy-versions \
    --policy-arn "${POLICY_ARN_CHECK}" \
    --query "Versions[?IsDefaultVersion==\`false\`].VersionId" \
    --output text 2>/dev/null || echo "")

  if [ -n "${OLD_VERSIONS}" ]; then
    for VERSION in ${OLD_VERSIONS}; do
      aws iam delete-policy-version \
        --policy-arn "${POLICY_ARN_CHECK}" \
        --version-id "${VERSION}" 2>/dev/null && \
        echo "  ✅ Deleted old policy version: ${VERSION}" || true
    done
  else
    echo "  ✅ No old policy versions to clean up"
  fi
else
  echo "  ✅ Policy does not exist yet — will be created"
fi

echo ""
echo "=============================================="
echo " Pre-apply check complete! Safe to apply:"
echo "   ./scripts/tf.sh ${ENV} apply"
echo "=============================================="
