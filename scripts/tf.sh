#!/bin/bash
# ============================================================
# tf.sh — Terraform wrapper
#
# Usage:
#   ./scripts/tf.sh dev init
#   ./scripts/tf.sh dev validate
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
    # ── Run pre-apply checks ───────────────────────────────────────────────
    # Creates alertmanager secret, imports pre-existing shared resources
    # (IAM role/policy, Cloudflare CNAME) so terraform doesn't fail on
    # resource conflicts. Fully automated — no manual steps needed.
    echo "Running pre-apply checks..."
    "${SCRIPT_DIR}/pre-apply-check.sh" "${ENV}"
    echo ""

    # ── Single apply for both dev and prod ────────────────────────────────
    # The dns, ecr, and vpc modules previously used for_each/count with
    # values unknown at plan time. This caused plan failures on fresh state.
    # Fixed by using static keys in terraform/modules/{dns,ecr,vpc}/main.tf:
    #   - dns:  static key "*.{domain}" instead of dynamic cert options
    #   - ecr:  toset(var.service_names) instead of aws_ecr_repository ref
    #   - vpc:  length(var.public_subnet_cidrs) instead of length(aws_subnet)
    # Now a single plan+apply works correctly for both environments.
    terraform plan -out="${REPO_ROOT}/plan.out"
    terraform apply "${REPO_ROOT}/plan.out"
    rm -f "${REPO_ROOT}/plan.out"
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
