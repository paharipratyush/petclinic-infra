#!/bin/bash
# ============================================================
# smoke-test.sh — Validate all 8 Petclinic services are healthy
#
# Usage:
#   ./scripts/smoke-test.sh              # defaults to petclinic-dev
#   ./scripts/smoke-test.sh petclinic-dev
#   ./scripts/smoke-test.sh petclinic-prod
#
# Exit code: 0 = all passed, 1 = one or more failed
# ============================================================

set -euo pipefail

NAMESPACE="${1:-petclinic-dev}"
FAILED=0
PASSED=0

echo "=============================================="
echo " Smoke Test — namespace: ${NAMESPACE}"
echo "=============================================="

# ── Helper: check deployment ready ───────────────────────────────────────────
check_deployment() {
  local name="$1"
  local ready
  ready=$(kubectl get deployment "${name}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  local desired
  desired=$(kubectl get deployment "${name}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

  if [ "${ready}" = "${desired}" ] && [ "${ready}" != "0" ]; then
    echo "   ✅ ${name}: ${ready}/${desired} pods ready"
    PASSED=$((PASSED + 1))
  else
    echo "   ❌ ${name}: ${ready:-0}/${desired} pods ready"
    FAILED=$((FAILED + 1))
  fi
}

# ── Helper: check service health via kubectl exec ─────────────────────────────
check_health() {
  local service="$1"
  local port="$2"
  local path="${3:-/actuator/health}"

  local pod
  pod=$(kubectl get pod -n "${NAMESPACE}" -l "app.kubernetes.io/name=${service}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [ -z "${pod}" ]; then
    echo "   ❌ ${service}: no pod found"
    FAILED=$((FAILED + 1))
    return
  fi

  local status
  status=$(kubectl exec "${pod}" -n "${NAMESPACE}" -- \
    wget -qO- "http://localhost:${port}${path}" 2>/dev/null | \
    grep -o '"status":"[^"]*"' | head -1 || echo "")

  if echo "${status}" | grep -q "UP"; then
    echo "   ✅ ${service} health: UP"
    PASSED=$((PASSED + 1))
  else
    echo "   ❌ ${service} health: ${status:-no response}"
    FAILED=$((FAILED + 1))
  fi
}

# ── Check 1: All 8 deployments have desired replicas ready ───────────────────
echo ""
echo "[1/4] Checking deployment replica status..."
check_deployment "config-server"
check_deployment "discovery-server"
check_deployment "api-gateway"
check_deployment "customers-service"
check_deployment "visits-service"
check_deployment "vets-service"
check_deployment "genai-service"
check_deployment "admin-server"

# ── Check 2: Config Server health ────────────────────────────────────────────
echo ""
echo "[2/4] Checking Config Server health..."
check_health "config-server" "8888"

# ── Check 3: Discovery Server — all services registered ──────────────────────
echo ""
echo "[3/4] Checking Discovery Server (Eureka) registrations..."
POD=$(kubectl get pod -n "${NAMESPACE}" -l "app.kubernetes.io/name=discovery-server" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "${POD}" ]; then
  APPS=$(kubectl exec "${POD}" -n "${NAMESPACE}" -- \
    wget -qO- http://localhost:8761/eureka/apps 2>/dev/null | \
    grep -o '<application>.*</application>' | \
    grep -oP '(?<=<name>)[^<]+' || echo "")

  EXPECTED_SERVICES=("API-GATEWAY" "CUSTOMERS-SERVICE" "VISITS-SERVICE" "VETS-SERVICE" "GENAI-SERVICE" "ADMIN-SERVER")
  for SVC in "${EXPECTED_SERVICES[@]}"; do
    if echo "${APPS}" | grep -qi "${SVC}"; then
      echo "   ✅ ${SVC} registered in Eureka"
      PASSED=$((PASSED + 1))
    else
      echo "   ❌ ${SVC} NOT registered in Eureka"
      FAILED=$((FAILED + 1))
    fi
  done
else
  echo "   ❌ Discovery Server pod not found"
  FAILED=$((FAILED + 1))
fi

# ── Check 4: API Gateway health ───────────────────────────────────────────────
echo ""
echo "[4/4] Checking API Gateway health..."
check_health "api-gateway" "8080"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " Smoke Test Results"
echo "=============================================="
echo "   Passed: ${PASSED}"
echo "   Failed: ${FAILED}"
echo ""

if [ "${FAILED}" -eq 0 ]; then
  echo "   ✅ ALL CHECKS PASSED — ${NAMESPACE} is healthy!"
  exit 0
else
  echo "   ❌ ${FAILED} CHECKS FAILED"
  echo ""
  echo "   Troubleshooting:"
  echo "     kubectl get pods -n ${NAMESPACE}"
  echo "     kubectl describe pod <pod-name> -n ${NAMESPACE}"
  echo "     kubectl logs <pod-name> -n ${NAMESPACE} --previous"
  exit 1
fi
