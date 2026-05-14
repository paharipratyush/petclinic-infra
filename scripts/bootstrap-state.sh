#!/bin/bash
# Bootstrap Terraform remote state backend
#
# Creates:
#   - S3 bucket:      petclinic-terraform-state-{account-id}-{region}
#   - DynamoDB table: petclinic-terraform-locks
#   - config/backend-dev.hcl   (gitignored, used by terraform init)
#   - config/backend-prod.hcl  (gitignored, used by terraform init)
#
# Usage:
#   ./scripts/bootstrap-state.sh
#   ./scripts/bootstrap-state.sh --region us-west-2
#
# Anyone with an AWS account can run this — no hardcoded values anywhere.
# Prerequisites: aws cli configured with sufficient IAM permissions

set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────────────
REGION="${AWS_DEFAULT_REGION:-ap-south-1}"

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --region) REGION="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── derive everything from account id + region ────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="petclinic-terraform-state-${ACCOUNT_ID}-${REGION}"
TABLE_NAME="petclinic-terraform-locks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"

echo "=================================================="
echo " Terraform State Backend Bootstrap"
echo "=================================================="
echo " Region  : ${REGION}"
echo " Account : ${ACCOUNT_ID}"
echo " Bucket  : ${BUCKET_NAME}"
echo " Table   : ${TABLE_NAME}"
echo "=================================================="

# ── S3 bucket ─────────────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "[SKIP] S3 bucket already exists: ${BUCKET_NAME}"
else
  echo "[CREATE] S3 bucket: ${BUCKET_NAME}"
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
fi

echo "[SET] Versioning..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

echo "[SET] Encryption..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

echo "[SET] Block public access..."
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# ── DynamoDB table ─────────────────────────────────────────────────────────────
if aws dynamodb describe-table \
     --table-name "${TABLE_NAME}" \
     --region "${REGION}" 2>/dev/null | grep -q "ACTIVE\|CREATING"; then
  echo "[SKIP] DynamoDB table already exists: ${TABLE_NAME}"
else
  echo "[CREATE] DynamoDB table: ${TABLE_NAME}"
  aws dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" > /dev/null

  echo "[WAIT] Waiting for table to become active..."
  aws dynamodb wait table-exists \
    --table-name "${TABLE_NAME}" \
    --region "${REGION}"
fi

# ── Generate backend config files (gitignored) ─────────────────────────────────
echo "[GENERATE] Creating config/ directory and backend .hcl files..."
mkdir -p "${CONFIG_DIR}"

cat > "${CONFIG_DIR}/backend-dev.hcl" << EOF
bucket       = "${BUCKET_NAME}"
key          = "petclinic/dev/terraform.tfstate"
region       = "${REGION}"
use_lockfile = true
encrypt      = true
EOF

cat > "${CONFIG_DIR}/backend-prod.hcl" << EOF
bucket       = "${BUCKET_NAME}"
key          = "petclinic/prod/terraform.tfstate"
region       = "${REGION}"
use_lockfile = true
encrypt      = true
EOF

echo ""
echo "✅ Bootstrap complete!"
echo ""
echo "Generated files (gitignored):"
echo "  ${CONFIG_DIR}/backend-dev.hcl"
echo "  ${CONFIG_DIR}/backend-prod.hcl"
echo ""
echo "Next steps:"
echo ""
echo "  # Initialize dev:"
echo "  cd terraform/environments/dev"
echo "  terraform init -backend-config=../../config/backend-dev.hcl"
echo ""
echo "  # Initialize prod:"
echo "  cd terraform/environments/prod"
echo "  terraform init -backend-config=../../config/backend-prod.hcl"
