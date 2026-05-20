#!/bin/bash
# ============================================================
# tf.sh — Terraform wrapper with phased apply for prod
#
# Usage:
#   ./scripts/tf.sh dev init
#   ./scripts/tf.sh dev plan
#   ./scripts/tf.sh dev apply
#   ./scripts/tf.sh prod apply
# ============================================================
set -euo pipefail

# Disable pager for non-interactive execution
export TF_IN_AUTOMATION=1
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-}"
CMD="${2:-}"

if [ -z "${ENV}" ] || [ -z "${CMD}" ]; then
  echo "Usage: ./scripts/tf.sh <dev|prod> <init|validate|plan|apply|destroy>"
  exit 1
fi

if [[ "${ENV}" != "dev" && "${ENV}" != "prod" ]]; then
  echo "ERROR: environment must be 'dev' or 'prod'"
  exit 1
fi

TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"
BACKEND_CONFIG="${REPO_ROOT}/config/backend-${ENV}.hcl"

if [ ! -d "${TF_DIR}" ]; then
  echo "ERROR: Directory not found: ${TF_DIR}"
  exit 1
fi

echo "=============================================="
echo " Terraform: ${CMD} — environment: ${ENV}"
echo " Directory: ${TF_DIR}"
echo "=============================================="
echo ""

cd "${TF_DIR}"

case "${CMD}" in
  init)
    if [ ! -f "${BACKEND_CONFIG}" ]; then
      echo "ERROR: Backend config not found: ${BACKEND_CONFIG}"
      echo "Run first: ./scripts/bootstrap-state.sh"
      exit 1
    fi
    terraform init -backend-config="${BACKEND_CONFIG}"
    ;;

  validate)
    terraform validate
    ;;

  plan)
    echo "Running pre-apply checks..."
    "${SCRIPT_DIR}/pre-apply-check.sh" "${ENV}"
    echo ""
    terraform plan -out="${REPO_ROOT}/plan.out"
    echo ""
    echo "Plan saved to: ${REPO_ROOT}/plan.out"
    echo "Apply with:    ./scripts/tf.sh ${ENV} apply"
    ;;

  apply)
    # ── Run pre-apply checks (imports, secret creation) ────────────────────
    echo "Running pre-apply checks..."
    "${SCRIPT_DIR}/pre-apply-check.sh" "${ENV}"
    echo ""

    if [ "${ENV}" = "prod" ]; then
      # ── Prod: Phased apply ───────────────────────────────────────────────
      # Phase 1: Apply all modules EXCEPT dns
      # Reason: dns module has for_each on aws_acm_certificate.domain_validation_options
      # which is unknown until the cert is created. Terraform cannot plan this
      # on a fresh state. Applying everything else first creates the cert,
      # then phase 2 can apply dns successfully.
      echo "=============================================="
      echo " Prod apply — Phase 1/2: Infrastructure"
      echo " (DNS module applied separately in Phase 2)"
      echo "=============================================="
      terraform apply \
        -target=module.vpc \
        -target=module.eks \
        -target=module.ecr \
        -target=module.rds \
        -target=module.secrets \
        -target=module.github_oidc \
        -target=module.karpenter \
        -target=aws_security_group_rule.karpenter_to_managed_node \
        -target=aws_security_group_rule.managed_node_to_karpenter \
        -auto-approve

      echo ""
      echo "=============================================="
      echo " Prod apply — Phase 2/2: DNS"
      echo "=============================================="

      # Re-run pre-apply-check to import Cloudflare record now that cert exists
      "${SCRIPT_DIR}/pre-apply-check.sh" "${ENV}"

      terraform apply \
        -target=module.dns \
        -auto-approve

      echo ""
      echo "=============================================="
      echo " Prod apply — Final: Catch any remaining"
      echo "=============================================="
      terraform apply -auto-approve

    else
      # ── Dev: Standard single apply ───────────────────────────────────────
      if [ -f "${REPO_ROOT}/plan.out" ]; then
        PLAN_AGE=$(( $(date +%s) - $(stat -c %Y "${REPO_ROOT}/plan.out" \
          2>/dev/null || echo 0) ))
        if [ "${PLAN_AGE}" -gt 1800 ]; then
          echo "⚠️  Saved plan is older than 30 minutes — regenerating..."
          rm -f "${REPO_ROOT}/plan.out"
          terraform plan -out="${REPO_ROOT}/plan.out"
        fi
        terraform apply "${REPO_ROOT}/plan.out"
        rm -f "${REPO_ROOT}/plan.out"
      else
        terraform plan -out="${REPO_ROOT}/plan.out"
        terraform apply "${REPO_ROOT}/plan.out"
        rm -f "${REPO_ROOT}/plan.out"
      fi
    fi
    ;;

  destroy)
    echo "⚠️  WARNING: This will destroy ALL infrastructure for ${ENV}!"
    echo "Run pre-destroy cleanup first: ./scripts/pre-destroy.sh --env ${ENV}"
    echo ""
    read -r -p "Type 'yes' to confirm: " CONFIRM
    if [ "${CONFIRM}" = "yes" ]; then
      TF_IN_AUTOMATION=1 terraform destroy -auto-approve
    else
      echo "Destroy cancelled."
      exit 1
    fi
    ;;

  *)
    terraform "${CMD}"
    ;;
esac
