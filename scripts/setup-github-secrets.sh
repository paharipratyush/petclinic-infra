#!/bin/bash
# ============================================================
# setup-github-secrets.sh — Configure GitHub secrets and
# variables for the CI/CD pipeline.
#
# Prerequisites:
#   - gh CLI installed and authenticated (gh auth login)
#   - AWS CLI configured with correct credentials
#   - Terraform state available (terraform output must work)
#
# Usage:
#   ./scripts/setup-github-secrets.sh
#
# What it does:
#   1. Reads AWS account ID and role ARN from Terraform output
#   2. Sets GitHub repository variables on the app repo
#   3. Sets GitHub repository secrets on the app repo
#   4. Prompts for PLATFORM_REPO_TOKEN (PAT) — cannot be automated
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_REPO="paharipratyush/spring-petclinic-microservices"
INFRA_REPO="paharipratyush/petclinic-infra"
REGION="ap-south-1"
TF_DIR="${REPO_ROOT}/terraform/environments/dev"

echo "=============================================="
echo " GitHub CI/CD Setup"
echo " App Repo  : ${APP_REPO}"
echo " Infra Repo: ${INFRA_REPO}"
echo " Region    : ${REGION}"
echo "=============================================="

# ── Step 1: Verify prerequisites ─────────────────────────────
echo ""
echo "[1/5] Checking prerequisites..."

if ! command -v gh &>/dev/null; then
  echo "❌ gh CLI not found. Install from: https://cli.github.com"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "❌ gh CLI not authenticated. Run: gh auth login"
  exit 1
fi
echo "  ✅ gh CLI authenticated"

if ! command -v aws &>/dev/null; then
  echo "❌ AWS CLI not found"
  exit 1
fi
echo "  ✅ AWS CLI available"

if ! command -v terraform &>/dev/null; then
  echo "❌ Terraform not found"
  exit 1
fi
echo "  ✅ Terraform available"

# ── Step 2: Get values from AWS and Terraform ─────────────────
echo ""
echo "[2/5] Reading AWS and Terraform values..."

ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text 2>/dev/null)
if [ -z "${ACCOUNT_ID}" ]; then
  echo "❌ Could not get AWS account ID. Check AWS credentials."
  exit 1
fi
echo "  ✅ AWS Account ID: ${ACCOUNT_ID}"

ROLE_ARN=$(cd "${TF_DIR}" && \
  terraform output -raw github_actions_role_arn 2>/dev/null || echo "")
if [ -z "${ROLE_ARN}" ]; then
  echo "  ⚠️  Could not get role ARN from Terraform output."
  echo "  Falling back to constructed ARN..."
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/petclinic-github-actions-role"
fi
echo "  ✅ GitHub Actions Role ARN: ${ROLE_ARN}"

# ── Step 3: Set GitHub repository variables ───────────────────
echo ""
echo "[3/5] Setting GitHub repository variables on app repo..."

gh variable set AWS_REGION \
  --body "${REGION}" \
  --repo "${APP_REPO}" \
  && echo "  ✅ AWS_REGION = ${REGION}"

gh variable set AWS_ACCOUNT_ID \
  --body "${ACCOUNT_ID}" \
  --repo "${APP_REPO}" \
  && echo "  ✅ AWS_ACCOUNT_ID = ${ACCOUNT_ID}"

gh variable set PLATFORM_REPO \
  --body "${INFRA_REPO}" \
  --repo "${APP_REPO}" \
  && echo "  ✅ PLATFORM_REPO = ${INFRA_REPO}"

# ── Step 4: Set GitHub repository secrets ────────────────────
echo ""
echo "[4/5] Setting GitHub repository secrets on app repo..."

gh secret set AWS_ROLE_ARN \
  --body "${ROLE_ARN}" \
  --repo "${APP_REPO}" \
  && echo "  ✅ AWS_ROLE_ARN set"

echo ""
echo "  ⚠️  PLATFORM_REPO_TOKEN requires manual setup:"
echo "     It must be a fine-grained PAT with Contents:write"
echo "     on ${INFRA_REPO}."
echo ""
echo "     Create at: https://github.com/settings/tokens?type=beta"
echo "     Scope: Repository → ${INFRA_REPO} → Contents: Read/Write"
echo ""
read -r -p "  Paste your PLATFORM_REPO_TOKEN now (or press Enter to skip): " PAT

if [ -n "${PAT}" ]; then
  echo "${PAT}" | gh secret set PLATFORM_REPO_TOKEN \
    --repo "${APP_REPO}" \
    && echo "  ✅ PLATFORM_REPO_TOKEN set on app repo"

  echo "${PAT}" | gh secret set PLATFORM_REPO_TOKEN \
    --repo "${INFRA_REPO}" \
    && echo "  ✅ PLATFORM_REPO_TOKEN set on infra repo"
else
  echo "  ⚠️  Skipped — set PLATFORM_REPO_TOKEN manually in GitHub UI"
fi

# ── Step 5: Verify ────────────────────────────────────────────
echo ""
echo "[5/5] Verifying configuration..."

echo ""
echo "  App repo variables:"
gh variable list --repo "${APP_REPO}" 2>/dev/null | \
  grep -E "AWS_REGION|AWS_ACCOUNT_ID|PLATFORM_REPO" | \
  awk '{print "    " $0}' || echo "    (could not list variables)"

echo ""
echo "  App repo secrets:"
gh secret list --repo "${APP_REPO}" 2>/dev/null | \
  grep -E "AWS_ROLE_ARN|PLATFORM_REPO_TOKEN" | \
  awk '{print "    " $0}' || echo "    (could not list secrets)"

echo ""
echo "=============================================="
echo " Setup Complete!"
echo "=============================================="
echo ""
echo " Summary:"
echo "   App repo  : https://github.com/${APP_REPO}/settings/secrets/actions"
echo "   Infra repo: https://github.com/${INFRA_REPO}/settings/secrets/actions"
echo ""
echo " Next steps:"
echo "   1. Verify secrets and variables in GitHub UI"
echo "   2. Push a code change to test the pipeline"
echo "   3. Watch: https://github.com/${APP_REPO}/actions"
echo "=============================================="
