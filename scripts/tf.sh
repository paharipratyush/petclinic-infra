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
#
# This script always runs from the correct directory and uses
# the correct backend config path — no path confusion possible.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-}"
CMD="${2:-}"

if [ -z "${ENV}" ] || [ -z "${CMD}" ]; then
  echo "Usage: ./scripts/tf.sh <dev|prod> <init|validate|plan|apply|destroy>"
  echo ""
  echo "Examples:"
  echo "  ./scripts/tf.sh dev init"
  echo "  ./scripts/tf.sh dev plan"
  echo "  ./scripts/tf.sh prod validate"
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
    terraform plan -out="${REPO_ROOT}/plan.out"
    echo ""
    echo "Plan saved to: ${REPO_ROOT}/plan.out"
    echo "Apply with:    ./scripts/tf.sh ${ENV} apply"
    ;;
  apply)
    if [ -f "${REPO_ROOT}/plan.out" ]; then
      terraform apply "${REPO_ROOT}/plan.out"
      rm -f "${REPO_ROOT}/plan.out"
    else
      echo "ERROR: No saved plan found at ${REPO_ROOT}/plan.out"
      echo "Run first: ./scripts/tf.sh ${ENV} plan"
      exit 1
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
    # Pass through any other terraform command directly
    terraform "${CMD}"
    ;;
esac
