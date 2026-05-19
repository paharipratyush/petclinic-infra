#!/bin/bash
# ==========================================================
# pre-apply-check.sh — Run BEFORE terraform apply
# Checks for and imports pre-existing resources that would
# cause Terraform to fail with conflict errors.
#
# Handles:
#   1. GitHub OIDC Provider — shared between dev and prod
#   2. EKS Access Entry — auto-created by bootstrap, needs import
#   3. Prod-specific shared IAM resources — role and policy
#      created by dev, reused by prod (same name, no env suffix)
#   4. Cloudflare ACM validation record — shared between dev/prod
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

# ── Check 1: GitHub OIDC Provider ────────────────────────────────────────────
echo ""
echo "[1/4] Checking GitHub OIDC Provider..."

# Prod sets create_oidc_provider = false — OIDC is shared from dev.
# Skip import attempt when create_oidc_provider = false.
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
echo "[2/4] Checking EKS Access Entry..."

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
# GitHub Actions IAM role and policy have no env suffix (petclinic-github-actions-role).
# Dev creates them. Prod must import them instead of trying to create duplicates.
echo ""
echo "[3/4] Checking shared IAM resources (prod only)..."

if [ "${ENV}" = "prod" ]; then
  # Check and import GitHub Actions IAM role
  ROLE_EXISTS=$(aws iam get-role \
    --role-name "petclinic-github-actions-role" \
    --query "Role.RoleName" \
    --output text 2>/dev/null || echo "")

  if [ -n "${ROLE_EXISTS}" ]; then
    IN_STATE=$(terraform state list 2>/dev/null | \
      grep "github_oidc.aws_iam_role.github_actions" || echo "")
    if [ -z "${IN_STATE}" ]; then
      echo "  ⚠️  IAM role petclinic-github-actions-role exists — importing..."
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

  # Check and import GitHub Actions IAM policy
  POLICY_ARN=$(aws iam list-policies \
    --query "Policies[?PolicyName=='petclinic-github-actions-ecr-policy'].Arn" \
    --output text 2>/dev/null || echo "")

  if [ -n "${POLICY_ARN}" ] && [ "${POLICY_ARN}" != "None" ]; then
    IN_STATE=$(terraform state list 2>/dev/null | \
      grep "github_oidc.aws_iam_policy.github_actions_ecr" || echo "")
    if [ -z "${IN_STATE}" ]; then
      echo "  ⚠️  IAM policy petclinic-github-actions-ecr-policy exists — importing..."
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
# Dev creates the ACM validation CNAME in Cloudflare for *.praty.dev.
# Prod creates a new ACM cert but the same validation CNAME already exists.
# Import the existing Cloudflare record so Terraform doesn't try to create a duplicate.
echo ""
echo "[4/4] Checking Cloudflare ACM validation record (prod only)..."

if [ "${ENV}" = "prod" ]; then
  IN_STATE=$(terraform state list 2>/dev/null | \
    grep 'dns.cloudflare_record.acm_validation' || echo "")

  if [ -z "${IN_STATE}" ]; then
    # Read Cloudflare credentials from tfvars
    ZONE_ID=$(grep "^cloudflare_zone_id" "${TF_DIR}/terraform.tfvars" \
      | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null || echo "")
    CF_TOKEN=$(grep "^cloudflare_api_token" "${TF_DIR}/terraform.tfvars" \
      | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null || echo "")

    if [ -n "${ZONE_ID}" ] && [ -n "${CF_TOKEN}" ]; then
      # Find the ACM validation CNAME record ID
      CF_RECORD_ID=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=CNAME" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        2>/dev/null | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    for r in data.get('result', []):
        if '_acm-challenge' in r.get('name', ''):
            print(r['id'])
            break
except:
    pass
" 2>/dev/null || echo "")

      if [ -n "${CF_RECORD_ID}" ]; then
        echo "  ⚠️  Cloudflare ACM validation record exists — importing..."
        terraform import \
          "module.dns.cloudflare_record.acm_validation[\"*.praty.dev\"]" \
          "${ZONE_ID}/${CF_RECORD_ID}"
        echo "  ✅ Imported Cloudflare ACM validation record"
      else
        echo "  ✅ No existing Cloudflare ACM validation record — will be created"
      fi
    else
      echo "  ⚠️  Could not read Cloudflare credentials — skipping import"
    fi
  else
    echo "  ✅ Cloudflare ACM validation record in state — no action needed"
  fi
else
  echo "  ✅ Dev environment — Cloudflare record will be created fresh"
fi

echo ""
echo "=============================================="
echo " Pre-apply check complete! Safe to apply:"
echo "   ./scripts/tf.sh ${ENV} apply"
echo "=============================================="
