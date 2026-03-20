#!/usr/bin/env bash
# Script to set up OpenShift Logging + ClusterLogForwarder on Cluster B
# This forwards logs to an EXTERNAL LokiStack on Cluster A
#
# Usage: ./02-setup-remote-log-forwarder.sh <LOKI_GATEWAY_URL> [CHANNEL]
#
# Example:
#   ./02-setup-remote-log-forwarder.sh https://logging-loki-gateway-openshift-logging.apps.cluster-a.example.com stable-6.2
#
# Prerequisites on Cluster A (destination):
#   1. LokiStack must be accessible externally (via Route or LoadBalancer)
#   2. You need a bearer token with write permissions to Loki

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

# Parameters
LOKI_GATEWAY_URL="${1:-}"
CHANNEL="${2:-}"

if [ -z "$LOKI_GATEWAY_URL" ]; then
    echo "Usage: $0 <LOKI_GATEWAY_URL> [CHANNEL]"
    echo ""
    echo "Example:"
    echo "  $0 https://logging-loki-gateway-openshift-logging.apps.cluster-a.example.com stable-6.2"
    echo ""
    echo "To get the Loki Gateway URL from Cluster A, run:"
    echo "  oc get route -n openshift-logging -l app.kubernetes.io/component=lokistack-gateway -o jsonpath='{.items[0].spec.host}'"
    exit 1
fi

# Auto-detect channel based on cluster version if not provided
if [ -z "$CHANNEL" ]; then
    VERSION=$(oc get clusterversion version -o go-template='{{.status.desired.version}}' 2>/dev/null || echo "4.16")
    if [[ $VERSION =~ ^4\.15.*$ ]]; then
        CHANNEL="stable-6.1"
    elif [[ $VERSION =~ ^(4\.16|4\.17).*$ ]]; then
        CHANNEL="stable-6.2"
    else
        CHANNEL="stable-6.3"
    fi
    echo "Auto-detected channel: $CHANNEL (based on cluster version $VERSION)"
fi

echo "=============================================="
echo "Setting up Remote Log Forwarding"
echo "=============================================="
echo "Loki Gateway URL: $LOKI_GATEWAY_URL"
echo "Operator Channel: $CHANNEL"
echo "=============================================="

# Step 1: Install Loki Operator (required for CRDs even if not using local LokiStack)
echo -e "\n>>> Step 1: Installing Loki Operator"
LOKI_OPERATOR_NAMESPACE=openshift-operators-redhat
oc create namespace $LOKI_OPERATOR_NAMESPACE 2>/dev/null || true

oc get operatorgroup -n $LOKI_OPERATOR_NAMESPACE 2>/dev/null | grep -q $LOKI_OPERATOR_NAMESPACE || cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: $LOKI_OPERATOR_NAMESPACE-
  namespace: $LOKI_OPERATOR_NAMESPACE
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: $LOKI_OPERATOR_NAMESPACE
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: loki-operator
  channel: $CHANNEL
EOF

oc label ns $LOKI_OPERATOR_NAMESPACE openshift.io/cluster-monitoring=true --overwrite

echo "Waiting for Loki operator..."
for i in {1..150}; do
    pods=$(oc get pods -n ${LOKI_OPERATOR_NAMESPACE} --no-headers -l name=loki-operator-controller-manager 2>/dev/null | grep -c loki || echo 0)
    if [[ "${pods}" -ge 1 ]]; then
        oc wait --for=condition=Ready -n ${LOKI_OPERATOR_NAMESPACE} -l name=loki-operator-controller-manager pod --timeout=5m
        break
    fi
    echo -n "."
    sleep 2
done
echo " Done"

# Step 2: Install OpenShift Logging Operator
echo -e "\n>>> Step 2: Installing OpenShift Logging Operator"
LOGGING_OPERATOR_NAMESPACE=openshift-logging
oc create namespace $LOGGING_OPERATOR_NAMESPACE 2>/dev/null || true

oc get operatorgroup -n $LOGGING_OPERATOR_NAMESPACE 2>/dev/null | grep -q $LOGGING_OPERATOR_NAMESPACE || cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: $LOGGING_OPERATOR_NAMESPACE-
  namespace: $LOGGING_OPERATOR_NAMESPACE
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: $LOGGING_OPERATOR_NAMESPACE
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: cluster-logging
  channel: $CHANNEL
EOF

oc label ns $LOGGING_OPERATOR_NAMESPACE openshift.io/cluster-monitoring=true --overwrite

echo "Waiting for Logging operator..."
for i in {1..150}; do
    pods=$(oc get pods -n ${LOGGING_OPERATOR_NAMESPACE} --no-headers -l name=cluster-logging-operator 2>/dev/null | grep -c logging-operator || echo 0)
    if [[ "${pods}" -ge 1 ]]; then
        oc wait --for=condition=Ready -n ${LOGGING_OPERATOR_NAMESPACE} -l name=cluster-logging-operator pod --timeout=5m
        break
    fi
    echo -n "."
    sleep 2
done
echo " Done"

# Step 3: Create Service Account for collector
echo -e "\n>>> Step 3: Creating collector service account and RBAC"
oc create sa collector -n openshift-logging 2>/dev/null || true
oc adm policy add-cluster-role-to-user logging-collector-logs-writer system:serviceaccount:openshift-logging:collector 2>/dev/null || true
oc adm policy add-cluster-role-to-user collect-application-logs system:serviceaccount:openshift-logging:collector 2>/dev/null || true
oc adm policy add-cluster-role-to-user collect-audit-logs system:serviceaccount:openshift-logging:collector 2>/dev/null || true
oc adm policy add-cluster-role-to-user collect-infrastructure-logs system:serviceaccount:openshift-logging:collector 2>/dev/null || true

# Step 4: Create secret for remote Loki authentication
echo -e "\n>>> Step 4: Creating authentication secret for remote Loki"
echo ""
echo "You need to provide a bearer token for authenticating to the remote LokiStack."
echo "To get a token from Cluster A, run this on Cluster A:"
echo ""
echo "  # Create a service account with write permissions"
echo "  oc create sa remote-log-writer -n openshift-logging"
echo "  oc adm policy add-cluster-role-to-user logging-collector-logs-writer system:serviceaccount:openshift-logging:remote-log-writer"
echo ""
echo "  # Get a long-lived token"
echo "  oc create token remote-log-writer -n openshift-logging --duration=8760h"
echo ""
read -p "Enter the bearer token from Cluster A (or press Enter to skip for now): " BEARER_TOKEN

if [ -n "$BEARER_TOKEN" ]; then
    oc create secret generic remote-loki-token -n openshift-logging \
        --from-literal=token="$BEARER_TOKEN" \
        --dry-run=client -o yaml | oc apply -f -
    echo "Secret 'remote-loki-token' created"
    USE_TOKEN_SECRET=true
else
    echo "Skipping token secret creation. You'll need to create it manually."
    USE_TOKEN_SECRET=false
fi

# Step 5: Get CA certificate from remote cluster (optional)
echo -e "\n>>> Step 5: TLS Certificate Configuration"
echo ""
echo "If the remote LokiStack uses a self-signed or internal CA, you need to provide the CA cert."
echo "To get the CA from Cluster A, run this on Cluster A:"
echo ""
echo "  oc get configmap openshift-service-ca.crt -n openshift-logging -o jsonpath='{.data.service-ca\\.crt}'"
echo ""
read -p "Paste the CA certificate (or press Enter to skip/use system CA): " CA_CERT

if [ -n "$CA_CERT" ]; then
    echo "$CA_CERT" | oc create configmap remote-loki-ca -n openshift-logging \
        --from-file=ca-bundle.crt=/dev/stdin \
        --dry-run=client -o yaml | oc apply -f -
    echo "ConfigMap 'remote-loki-ca' created"
    USE_CA_CONFIGMAP=true
else
    echo "Skipping CA configmap. Using system CA or insecure connection."
    USE_CA_CONFIGMAP=false
fi

# Step 6: Create ClusterLogForwarder
echo -e "\n>>> Step 6: Creating ClusterLogForwarder for remote Loki"

# Build the CLF based on what secrets/configmaps were created
if [ "$USE_TOKEN_SECRET" = true ] && [ "$USE_CA_CONFIGMAP" = true ]; then
    cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
spec:
  inputs:
  - application:
      selector:
        matchExpressions:
        - key: app.kubernetes.io/managed-by
          operator: In
          values: ["tekton-pipelines", "pipelinesascode.tekton.dev"]
    name: only-tekton
    type: application
  managementState: Managed
  outputs:
  - name: remote-lokistack
    type: lokiStack
    lokiStack:
      target:
        name: logging-loki
        namespace: openshift-logging
      labelKeys:
        application:
          ignoreGlobal: true
          labelKeys:
          - log_type
          - kubernetes.namespace_name
          - openshift_cluster_id
          - kubernetes.labels.tekton_dev_taskRunUID
          - kubernetes.labels.tekton_dev_pipelineRunUID
          - kubernetes.container_name
          - kubernetes.pod_name
      authentication:
        token:
          secret:
            name: remote-loki-token
            key: token
    tls:
      ca:
        configMapName: remote-loki-ca
        key: ca-bundle.crt
    url: "${LOKI_GATEWAY_URL}"
  pipelines:
  - inputRefs:
    - only-tekton
    name: forward-to-remote-loki
    outputRefs:
    - remote-lokistack
  serviceAccount:
    name: collector
EOF
elif [ "$USE_TOKEN_SECRET" = true ]; then
    cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
spec:
  inputs:
  - application:
      selector:
        matchExpressions:
        - key: app.kubernetes.io/managed-by
          operator: In
          values: ["tekton-pipelines", "pipelinesascode.tekton.dev"]
    name: only-tekton
    type: application
  managementState: Managed
  outputs:
  - name: remote-lokistack
    type: lokiStack
    lokiStack:
      target:
        name: logging-loki
        namespace: openshift-logging
      labelKeys:
        application:
          ignoreGlobal: true
          labelKeys:
          - log_type
          - kubernetes.namespace_name
          - openshift_cluster_id
          - kubernetes.labels.tekton_dev_taskRunUID
          - kubernetes.labels.tekton_dev_pipelineRunUID
          - kubernetes.container_name
          - kubernetes.pod_name
      authentication:
        token:
          secret:
            name: remote-loki-token
            key: token
    tls:
      insecureSkipVerify: true
    url: "${LOKI_GATEWAY_URL}"
  pipelines:
  - inputRefs:
    - only-tekton
    name: forward-to-remote-loki
    outputRefs:
    - remote-lokistack
  serviceAccount:
    name: collector
EOF
else
    # No auth - using service account token (only works for local LokiStack)
    cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
spec:
  inputs:
  - application:
      selector:
        matchExpressions:
        - key: app.kubernetes.io/managed-by
          operator: In
          values: ["tekton-pipelines", "pipelinesascode.tekton.dev"]
    name: only-tekton
    type: application
  managementState: Managed
  outputs:
  - name: remote-lokistack
    type: lokiStack
    lokiStack:
      target:
        name: logging-loki
        namespace: openshift-logging
      labelKeys:
        application:
          ignoreGlobal: true
          labelKeys:
          - log_type
          - kubernetes.namespace_name
          - openshift_cluster_id
      authentication:
        token:
          from: serviceAccount
    tls:
      insecureSkipVerify: true
    url: "${LOKI_GATEWAY_URL}"
  pipelines:
  - inputRefs:
    - only-tekton
    name: forward-to-remote-loki
    outputRefs:
    - remote-lokistack
  serviceAccount:
    name: collector
EOF
fi

echo ""
echo "=============================================="
echo "Setup Complete!"
echo "=============================================="
echo ""
echo "Waiting for collector pods to start..."
sleep 10
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector

echo ""
echo "Check ClusterLogForwarder status:"
echo "  oc get clusterlogforwarder collector -n openshift-logging -o yaml"
echo ""
echo "Check collector logs for forwarding issues:"
echo "  oc logs -n openshift-logging -l app.kubernetes.io/component=collector --tail=100"
echo ""
echo "Common issues to check:"
echo "  1. Network connectivity to ${LOKI_GATEWAY_URL}"
echo "  2. TLS certificate validation (use insecureSkipVerify for testing)"
echo "  3. Bearer token permissions on the remote cluster"
echo "  4. Loki gateway route/ingress configuration on Cluster A"
echo ""
echo "To capture logs for debugging, run:"
echo "  ./01-capture-logging-pipeline-logs.sh ./cluster-b-logs"


