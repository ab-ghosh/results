#!/usr/bin/env bash
# Simplified script for SPOKE cluster - forwards logs to HUB LokiStack
# Does NOT require Loki Operator on spoke (uses type: loki, not lokiStack)
#
# Prerequisites:
#   1. Run setup-route.sh on the HUB cluster first to get HUB_LOKI_HOST and HUB_LOKI_TOKEN
#   2. Ensure the HUB cluster has LokiStack running with the logging-collector-logs-writer role
#
# Required Environment Variables:
#   HUB_LOKI_HOST  - The URL of the hub cluster's Loki gateway (must include https://)
#   HUB_LOKI_TOKEN - Bearer token for authenticating to the hub LokiStack
#
# Usage:
#   export HUB_LOKI_HOST="https://logging-loki-openshift-logging.apps.hub.example.com"
#   export HUB_LOKI_TOKEN="eyJhbGc..."
#   ./setup-spoke-simple.sh
#
# Key Notes:
#   - Authentication block must be nested INSIDE the loki: section (not at output level)
#   - Collector SA needs RBAC to read the hub-loki-token secret
#   - Logs from 'default', 'kube-*', and 'openshift-*' namespaces are EXCLUDED by default
#   - Run PipelineRuns in custom namespaces (e.g., 'tekton-test') for logs to be collected

set -e

# Validate required environment variables
if [ -z "$HUB_LOKI_HOST" ]; then
    echo "ERROR: HUB_LOKI_HOST environment variable is required"
    exit 1
fi

if [ -z "$HUB_LOKI_TOKEN" ]; then
    echo "ERROR: HUB_LOKI_TOKEN environment variable is required"
    exit 1
fi

# Auto-detect channel
VERSION=$(oc get clusterversion version -o go-template='{{.status.desired.version}}')
if [[ $VERSION =~ ^4\.15.*$ ]]; then
    CHANNEL="stable-6.1"
elif [[ $VERSION =~ ^(4\.16|4\.17).*$ ]]; then
    CHANNEL="stable-6.2"
else
    CHANNEL="stable-6.3"
fi

echo "=============================================="
echo "Setting up Spoke Cluster Log Forwarding"
echo "=============================================="
echo "Cluster Version: $VERSION"
echo "Operator Channel: $CHANNEL"
echo "Hub Loki Host: $HUB_LOKI_HOST"
echo "=============================================="

# Step 1: Install OpenShift Logging Operator ONLY (no Loki Operator needed)
echo -e "\nInstalling OpenShift Logging operator"
oc create namespace openshift-logging 2>/dev/null || true

oc get operatorgroup -n openshift-logging 2>/dev/null | grep -q openshift-logging || cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-logging
  namespace: openshift-logging
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: cluster-logging
  channel: $CHANNEL
EOF

oc label ns openshift-logging openshift.io/cluster-monitoring=true --overwrite

echo "Waiting for Logging operator..."
for i in {1..150}; do
    pods=$(oc get pods -n openshift-logging --no-headers -l name=cluster-logging-operator 2>/dev/null | grep -c logging-operator || true)
    if [[ "${pods:-0}" -ge 1 ]]; then
        oc wait --for=condition=Ready -n openshift-logging -l name=cluster-logging-operator pod --timeout=5m
        break
    fi
    if [[ "${i}" -eq 150 ]]; then
        echo "Timeout: operator pod was not created."
        exit 2
    fi
    echo -n "."
    sleep 2
done
echo " Done"

# Step 2: Create secret with hub Loki token
echo -e "\nCreating secret for hub LokiStack authentication"
oc create secret generic hub-loki-token -n openshift-logging \
    --from-literal=token="${HUB_LOKI_TOKEN}" \
    --dry-run=client -o yaml | oc apply -f -

# Step 3: Create service account and roles
echo -e "\nCreating collector service account"
oc create sa collector -n openshift-logging 2>/dev/null || true
oc adm policy add-cluster-role-to-user collect-application-logs system:serviceaccount:openshift-logging:collector 2>/dev/null || true
oc adm policy add-cluster-role-to-user collect-infrastructure-logs system:serviceaccount:openshift-logging:collector 2>/dev/null || true
oc adm policy add-cluster-role-to-user collect-audit-logs system:serviceaccount:openshift-logging:collector 2>/dev/null || true

# Step 4: Create Role and RoleBinding for collector to read the secret
echo -e "\nGranting collector access to hub-loki-token secret"
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: hub-loki-token-reader
  namespace: openshift-logging
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["hub-loki-token"]
  verbs: ["get", "list", "watch"]
EOF

cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: collector-hub-loki-token-reader
  namespace: openshift-logging
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: hub-loki-token-reader
subjects:
- kind: ServiceAccount
  name: collector
  namespace: openshift-logging
EOF

# Step 5: Create ClusterLogForwarder with type: loki (NOT lokiStack)
# NOTE: authentication must be nested INSIDE the loki: block
echo -e "\nCreating ClusterLogForwarder"
cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
spec:
  serviceAccount:
    name: collector
  inputs:
  - name: only-tekton
    type: application
    application:
      selector:
        matchExpressions:
        - key: app.kubernetes.io/managed-by
          operator: In
          values: ["tekton-pipelines", "pipelinesascode.tekton.dev"]
  outputs:
  - name: hub-loki
    type: loki
    loki:
      url: "${HUB_LOKI_HOST}/api/logs/v1/application"
      labelKeys:
      - kubernetes.namespace_name
      - kubernetes.pod_name
      - kubernetes.container_name
      - log_type
      authentication:
        token:
          from: secret
          secret:
            name: hub-loki-token
            key: token
    tls:
      insecureSkipVerify: true
  pipelines:
  - name: forward-to-hub
    inputRefs:
    - only-tekton
    outputRefs:
    - hub-loki
EOF

echo ""
echo "=============================================="
echo "Setup Complete!"
echo "=============================================="

echo -e "\nWaiting for collector pods to start..."
sleep 15

echo -e "\nCollector Pod Status:"
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o wide

echo -e "\nClusterLogForwarder Status:"
oc get clusterlogforwarder collector -n openshift-logging -o jsonpath='{.status.conditions}' 2>/dev/null | jq . || \
    oc get clusterlogforwarder collector -n openshift-logging -o yaml | grep -A 20 "status:"

echo -e "\nVerifying authentication is configured in Vector:"
oc get configmap collector-config -n openshift-logging -o jsonpath='{.data.vector\.toml}' 2>/dev/null | grep -A 3 "\[sinks.output_hub_loki.auth\]" || \
    echo "WARNING: Auth section not found in Vector config!"

echo -e "\nVerifying secret is mounted:"
oc get daemonset collector -n openshift-logging -o yaml 2>/dev/null | grep -q "hub-loki-token" && \
    echo "✓ hub-loki-token secret is mounted" || \
    echo "WARNING: hub-loki-token secret not mounted!"

echo ""
echo "=============================================="
echo "IMPORTANT: Namespace Exclusions"
echo "=============================================="
echo "Logs from these namespaces are EXCLUDED by default:"
echo "  - default"
echo "  - kube-*"
echo "  - openshift-*"
echo ""
echo "Run PipelineRuns in custom namespaces (e.g., 'tekton-test') for logs to be collected!"
echo ""
echo "=============================================="
echo "Next Steps"
echo "=============================================="
echo ""
echo "See SPOKE-HUB-LOGGING.md for testing and troubleshooting instructions."
echo ""
echo "Quick test:"
echo "  1. oc create namespace tekton-test"
echo "  2. Create a PipelineRun in tekton-test namespace"
echo "  3. Check collector metrics: oc exec -n openshift-logging \$(oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o jsonpath='{.items[0].metadata.name}') -- curl -sk https://127.0.0.1:24231/metrics | grep sent.*hub_loki"
echo "  4. Query logs on HUB cluster"
