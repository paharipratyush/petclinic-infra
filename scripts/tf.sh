#!/bin/bash
# ============================================================
# tf.sh — Terraform wrapper that handles backend config paths
#
# Usage:
#   ./scripts/tf.sh dev init
#   ./scripts/tf.sh dev validate
#   ./scripts/tf.sh dev plan
#   ./scripts/tf.sh dev apply
#   ./scripts/tf.sh prod plan
# ============================================================

set -euo pipefail

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
    # Run pre-apply-check BEFORE planning so imports are in state
    echo "Running pre-apply checks..."
    "${SCRIPT_DIR}/pre-apply-check.sh" "${ENV}"
    echo ""
    terraform plan -out="${REPO_ROOT}/plan.out"
    echo ""
    echo "Plan saved to: ${REPO_ROOT}/plan.out"
    echo "Apply with:    ./scripts/tf.sh ${ENV} apply"
    ;;
  apply)
    if [ -f "${REPO_ROOT}/plan.out" ]; then
      # Verify plan.out is not stale (older than 30 minutes)
      PLAN_AGE=$(( $(date +%s) - $(stat -c %Y "${REPO_ROOT}/plan.out" 2>/dev/null || echo 0) ))
      if [ "${PLAN_AGE}" -gt 1800 ]; then
        echo "⚠️  Saved plan is older than 30 minutes — regenerating..."
        rm -f "${REPO_ROOT}/plan.out"
        "${SCRIPT_DIR}/pre-apply-check.sh" "${ENV}"
        terraform plan -out="${REPO_ROOT}/plan.out"
      fi
      terraform apply "${REPO_ROOT}/plan.out"
      rm -f "${REPO_ROOT}/plan.out"
    else
      # No saved plan — run pre-apply-check then fresh plan+apply
      echo "No saved plan found — running pre-apply checks and fresh plan..."
      "${SCRIPT_DIR}/pre-apply-check.sh" "${ENV}"
      terraform plan -out="${REPO_ROOT}/plan.out"
      terraform apply "${REPO_ROOT}/plan.out"
      rm -f "${REPO_ROOT}/plan.out"
    fi
    ;;
  destroy)
    echo "⚠️  WARNING: This will destroy ALL infrastructure for ${ENV}!"
    echo "Run pre-destroy cleanup first: ./scripts/pre-destroy.sh --env ${ENV}"
    echo ""
    read -r -p "Type 'yes' to confirm: " CONFIRM
    if [ "${CONFIRM}" = "yes" ]; then
      terraform destroy
    else
      echo "Destroy cancelled."
      exit 1
    fi
    ;;
  *)
    terraform "${CMD}"
    ;;
esac
