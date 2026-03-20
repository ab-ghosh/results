#!/usr/bin/env bash
# HUB cluster setup script for spoke log forwarding
#
# This script:
#   1. Creates a route to expose the LokiStack gateway externally
#   2. Creates a ServiceAccount for spoke clusters to authenticate
#   3. Grants log-writer permissions to the ServiceAccount
#   4. Generates a long-lived token (1 year) for spoke clusters
#
# Run this on the HUB cluster before running setup-spoke-simple.sh on spoke clusters.
#
# Prerequisites:
#   - LokiStack must be installed and running on the HUB cluster
#   - You must be logged in as cluster-admin
#
set -euo pipefail

NAMESPACE="openshift-logging"
SA_NAME="spoke-collector"

echo "==> Checking for existing Loki route"

# Prefer the existing 'logging-loki' route (reencrypt) if it exists
# Otherwise create a new passthrough route
if oc get route logging-loki -n ${NAMESPACE} &>/dev/null; then
    ROUTE_NAME="logging-loki"
    echo "Using existing route: ${ROUTE_NAME}"
else
    ROUTE_NAME="loki-gateway"
    echo "Creating passthrough route: ${ROUTE_NAME}"
    # Use 'passthrough' - Loki gateway serves HTTPS on port 8080
    oc create route passthrough ${ROUTE_NAME} \
  --service=logging-loki-gateway-http \
  --port=8080 \
  -n ${NAMESPACE} 2>/dev/null || echo "Route already exists"
fi

echo "==> Fetching Loki gateway host"

HUB_LOKI_HOST=$(oc get route ${ROUTE_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.host}')
echo "HUB_LOKI_HOST=https://${HUB_LOKI_HOST}"

echo
echo "==> Creating ServiceAccount for log ingestion"

oc create sa ${SA_NAME} -n ${NAMESPACE} 2>/dev/null || echo "ServiceAccount already exists"

echo "==> Granting log-writer permissions"

oc adm policy add-cluster-role-to-user logging-collector-logs-writer \
  system:serviceaccount:${NAMESPACE}:${SA_NAME} 2>/dev/null || true

echo
echo "==> Generating token for ServiceAccount (valid for 1 year)"

HUB_LOKI_TOKEN=$(oc create token ${SA_NAME} -n ${NAMESPACE} --duration=8760h)

echo
echo "=============================================="
echo "Use these on the SPOKE cluster:"
echo "=============================================="
echo "export HUB_LOKI_HOST=\"https://${HUB_LOKI_HOST}\""
echo "export HUB_LOKI_TOKEN=\"${HUB_LOKI_TOKEN}\""
echo "=============================================="

echo
echo "==> Testing connectivity"
if curl -sk "https://${HUB_LOKI_HOST}/" | grep -q "paths"; then
    echo "✓ Loki gateway is reachable"
else
    echo "WARNING: Could not verify Loki gateway connectivity"
    echo "Test manually: curl -k https://${HUB_LOKI_HOST}/"
fi

echo
echo "==> Next Steps:"
echo "1. Copy the export commands above"
echo "2. Switch to your SPOKE cluster: oc config use-context <spoke-context>"
echo "3. Paste the export commands to set the environment variables"
echo "4. Run: ./setup-spoke-simple.sh"

echo
echo "Done."