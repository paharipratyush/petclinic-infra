#!/bin/bash
# ==========================================================
# pre-apply-check.sh — Run BEFORE terraform apply
# Checks for and imports pre-existing resources that would
# cause Terraform to fail with conflict errors.
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

# ── Check 1: GitHub OIDC Provider ────────────────────────────────────────────
echo ""
echo "[1/2] Checking GitHub OIDC Provider..."
OIDC_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):oidc-provider/token.actions.githubusercontent.com"
OIDC_EXISTS=$(aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "${OIDC_ARN}" \
  --query "Url" --output text 2>/dev/null || echo "")

if [ -n "${OIDC_EXISTS}" ]; then
  # Check if already in state
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

# ── Check 2: EKS Access Entry (only if cluster exists) ────────────────────────
echo ""
echo "[2/2] Checking EKS Access Entry..."
CLUSTER_NAME="${PROJECT:-petclinic}-${ENV}"
REGION=$(grep "^aws_region" "${TF_DIR}/terraform.tfvars" \
  | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' 2>/dev/null \
  || echo "ap-south-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IAM_USER=$(aws sts get-caller-identity --query Arn --output text | \
  sed 's|.*/||')

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

echo ""
echo "=============================================="
echo " Pre-apply check complete! Safe to apply:"
echo "   ./scripts/tf.sh ${ENV} apply"
echo "=============================================="
