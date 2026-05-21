#!/bin/bash
# ==========================================================
# seed-prod-data.sh — One-time prod RDS data seed
#
# Run ONCE after fresh prod cluster deploy to seed test data.
# Spring Boot's DB init scripts create the schema AND seed data.
# Prod uses SPRING_SQL_INIT_MODE=never to prevent re-seeding on
# every restart — but needs 'always' once on fresh RDS.
#
# Usage:
#   ./scripts/seed-prod-data.sh
# ==========================================================
set -euo pipefail

echo "=============================================="
echo " Seeding prod RDS with test data"
echo " (one-time operation on fresh database)"
echo "=============================================="

# Enable init mode temporarily
echo "[1/3] Enabling DB init mode..."
for SVC in customers-service visits-service vets-service; do
  kubectl set env deployment/${SVC} \
    -n petclinic-prod \
    SPRING_SQL_INIT_MODE=always 2>/dev/null
  echo "  ✅ ${SVC}: init mode = always"
done

echo "[2/3] Waiting for pods to restart and seed data (90s)..."
sleep 90

kubectl get pods -n petclinic-prod | \
  grep -E "customers|visits|vets"

echo "[3/3] Restoring init mode to never..."
for SVC in customers-service visits-service vets-service; do
  kubectl set env deployment/${SVC} \
    -n petclinic-prod \
    SPRING_SQL_INIT_MODE=never 2>/dev/null
  echo "  ✅ ${SVC}: init mode = never"
done

echo ""
echo "✅ Prod data seeded successfully"
echo "   Open https://petclinic.praty.dev to verify"
echo "=============================================="
