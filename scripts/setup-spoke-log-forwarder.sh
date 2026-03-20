#!/usr/bin/env bash
# Script to set up OpenShift Logging + ClusterLogForwarder on a SPOKE cluster
# This forwards logs to a REMOTE LokiStack on the HUB cluster
#
# Required Environment Variables:
#   HUB_LOKI_HOST  - The URL of the hub cluster's Loki gateway
#                    Example: https://logging-loki-gateway-openshift-logging.apps.hub-cluster.example.com
#   HUB_LOKI_TOKEN - Bearer token for authenticating to the hub LokiStack
#
# Optional Environment Variables:
#   CHANNEL        - Operator channel (auto-detected if not set)
#   SKIP_TLS_VERIFY - Set to "true" to skip TLS verification (for testing)
#
# Usage:
#   export HUB_LOKI_HOST="https://logging-loki-gateway-openshift-logging.apps.hub.example.com"
#   export HUB_LOKI_TOKEN="eyJhbGc..."
#   ./setup-spoke-log-forwarder.sh
#
# To get HUB_LOKI_TOKEN from the hub cluster:
#   oc create sa spoke-log-writer -n openshift-logging
#   oc adm policy add-cluster-role-to-user logging-collector-logs-writer system:serviceaccount:openshift-logging:spoke-log-writer
#   oc create token spoke-log-writer -n openshift-logging --duration=8760h

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

# Validate required environment variables
if [ -z "$HUB_LOKI_HOST" ]; then
    echo "ERROR: HUB_LOKI_HOST environment variable is required"
    echo ""
    echo "Example:"
    echo "  export HUB_LOKI_HOST=\"https://logging-loki-gateway-openshift-logging.apps.hub.example.com\""
    echo ""
    echo "To get the Loki Gateway URL from the hub cluster, run on hub:"
    echo "  oc get route -n openshift-logging -l app.kubernetes.io/component=lokistack-gateway -o jsonpath='https://{.items[0].spec.host}'"
    exit 1
fi

if [ -z "$HUB_LOKI_TOKEN" ]; then
    echo "ERROR: HUB_LOKI_TOKEN environment variable is required"
    echo ""
    echo "To create a token on the hub cluster, run on hub:"
    echo "  oc create sa spoke-log-writer -n openshift-logging"
    echo "  oc adm policy add-cluster-role-to-user logging-collector-logs-writer system:serviceaccount:openshift-logging:spoke-log-writer"
    echo "  oc create token spoke-log-writer -n openshift-logging --duration=8760h"
    exit 1
fi

# Auto-detect channel based on cluster version
VERSION=$(oc get clusterversion version -o go-template='{{.status.desired.version}}')

if [ -z "$CHANNEL" ]; then
    if [[ $VERSION =~ ^4\.15.*$ ]]; then
        CHANNEL="stable-6.1"
    elif [[ $VERSION =~ ^(4\.16|4\.17).*$ ]]; then
        CHANNEL="stable-6.2"
    else
        CHANNEL="stable-6.3"
    fi
fi

# TLS skip verify setting
SKIP_TLS_VERIFY="${SKIP_TLS_VERIFY:-false}"

echo "=============================================="
echo "Setting up Spoke Cluster Log Forwarding"
echo "=============================================="
echo "Cluster Version: $VERSION"
echo "Operator Channel: $CHANNEL"
echo "Hub Loki Host: $HUB_LOKI_HOST"
echo "Skip TLS Verify: $SKIP_TLS_VERIFY"
echo "=============================================="

# Step 1: Install Loki Operator (required for CRDs even without local LokiStack)
echo -e "\nInstalling Loki operator (for CRDs)"
OPERATOR_NAMESPACE=openshift-operators-redhat
oc create namespace $OPERATOR_NAMESPACE 2>/dev/null || true

oc get operatorgroup -n $OPERATOR_NAMESPACE 2>/dev/null | grep -q $OPERATOR_NAMESPACE || cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: $OPERATOR_NAMESPACE-
  namespace: $OPERATOR_NAMESPACE
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: $OPERATOR_NAMESPACE
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: loki-operator
  channel: $CHANNEL
EOF

oc label ns $OPERATOR_NAMESPACE openshift.io/cluster-monitoring=true --overwrite

echo "Check if Loki operator pod is ready"
for i in {1..150}; do
    pods="$(oc get pods -n ${OPERATOR_NAMESPACE} --no-headers -l name=loki-operator-controller-manager 2>/dev/null | grep loki | wc -l)"
    if [[ "${pods}" -ge 1 ]]; then
        echo -e "\nWaiting for Loki operator pod"
        oc wait --for=condition=Ready -n ${OPERATOR_NAMESPACE} -l name=loki-operator-controller-manager pod --timeout=5m
        retval=$?
        if [[ "${retval}" -gt 0 ]]; then exit "${retval}"; else break; fi
    fi
    if [[ "${i}" -eq 150 ]]; then
        echo "Timeout: pod was not created."
        exit 2
    fi
    echo -n "."
    sleep 2
done

# Step 2: Install OpenShift Logging Operator
echo -e "\nInstalling OpenShift Logging operator"
OPERATOR_NAMESPACE=openshift-logging
oc create namespace $OPERATOR_NAMESPACE 2>/dev/null || true

oc get operatorgroup -n $OPERATOR_NAMESPACE 2>/dev/null | grep -q $OPERATOR_NAMESPACE || cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: $OPERATOR_NAMESPACE-
  namespace: $OPERATOR_NAMESPACE
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: $OPERATOR_NAMESPACE
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: cluster-logging
  channel: $CHANNEL
EOF

oc label ns $OPERATOR_NAMESPACE openshift.io/cluster-monitoring=true --overwrite

echo "Check if OpenShift Logging operator pod is ready"
for i in {1..150}; do
    pods="$(oc get pods -n ${OPERATOR_NAMESPACE} --no-headers -l name=cluster-logging-operator 2>/dev/null | grep logging-operator | wc -l)"
    if [[ "${pods}" -ge 1 ]]; then
        echo -e "\nWaiting for Logging operator pod"
        oc wait --for=condition=Ready -n ${OPERATOR_NAMESPACE} -l name=cluster-logging-operator pod --timeout=5m
        retval=$?
        if [[ "${retval}" -gt 0 ]]; then exit "${retval}"; else break; fi
    fi
    if [[ "${i}" -eq 150 ]]; then
        echo "Timeout: pod was not created."
        exit 2
    fi
    echo -n "."
    sleep 2
done

# Step 3: Create secret with hub Loki token
echo -e "\nCreating secret for hub LokiStack authentication"
oc create secret generic hub-loki-token -n openshift-logging \
    --from-literal=token="${HUB_LOKI_TOKEN}" \
    --dry-run=client -o yaml | oc apply -f -

# Step 4: Create service account and configure roles
echo -e "\nCreating collector service account and configuring roles"
oc create sa collector -n openshift-logging 2>/dev/null || true
oc adm policy add-cluster-role-to-user logging-collector-logs-writer system:serviceaccount:openshift-logging:collector 2>/dev/null || true
oc adm policy add-cluster-role-to-user collect-application-logs system:serviceaccount:openshift-logging:collector 2>/dev/null || true
oc adm policy add-cluster-role-to-user collect-audit-logs system:serviceaccount:openshift-logging:collector 2>/dev/null || true
oc adm policy add-cluster-role-to-user collect-infrastructure-logs system:serviceaccount:openshift-logging:collector 2>/dev/null || true

# Step 5: Create ClusterLogForwarder
echo -e "\nCreating ClusterLogForwarder to forward logs to hub LokiStack"

if [ "$SKIP_TLS_VERIFY" = "true" ]; then
    # ClusterLogForwarder with insecureSkipVerify
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
  - name: hub-lokistack
    type: lokiStack
    url: "${HUB_LOKI_HOST}"
    lokiStack:
      labelKeys:
        application:
          ignoreGlobal: true
          labelKeys:
          - log_type
          - kubernetes.namespace_name
          - openshift_cluster_id
      authentication:
        token:
          secret:
            name: hub-loki-token
            key: token
    tls:
      insecureSkipVerify: true
  pipelines:
  - inputRefs:
    - only-tekton
    name: forward-to-hub
    outputRefs:
    - hub-lokistack
  serviceAccount:
    name: collector
EOF
else
    # ClusterLogForwarder with proper TLS (you may need to add CA cert)
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
  - name: hub-lokistack
    type: lokiStack
    url: "${HUB_LOKI_HOST}"
    lokiStack:
      labelKeys:
        application:
          ignoreGlobal: true
          labelKeys:
          - log_type
          - kubernetes.namespace_name
          - openshift_cluster_id
      authentication:
        token:
          secret:
            name: hub-loki-token
            key: token
    tls:
      insecureSkipVerify: false
  pipelines:
  - inputRefs:
    - only-tekton
    name: forward-to-hub
    outputRefs:
    - hub-lokistack
  serviceAccount:
    name: collector
EOF
fi

echo ""
echo "=============================================="
echo "Setup Complete!"
echo "=============================================="
echo ""

# Wait for collector pods
echo "Waiting for collector pods to start..."
sleep 15

echo -e "\nCollector Pod Status:"
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o wide

echo -e "\nClusterLogForwarder Status:"
oc get clusterlogforwarder collector -n openshift-logging -o jsonpath='{.status.conditions}' 2>/dev/null | jq . || \
    oc get clusterlogforwarder collector -n openshift-logging -o yaml | grep -A 20 "status:"

echo ""
echo "=============================================="
echo "Troubleshooting Commands"
echo "=============================================="
echo ""
echo "Check ClusterLogForwarder status:"
echo "  oc get clusterlogforwarder collector -n openshift-logging -o yaml"
echo ""
echo "Check collector pod logs for errors:"
echo "  oc logs -n openshift-logging -l app.kubernetes.io/component=collector --tail=100"
echo ""
echo "Test connectivity to hub Loki:"
echo "  oc run curl-test --rm -it --restart=Never --image=curlimages/curl -- \\"
echo "    curl -v -k -H \"Authorization: Bearer \$HUB_LOKI_TOKEN\" ${HUB_LOKI_HOST}/ready"
echo ""
echo "If TLS errors occur, set SKIP_TLS_VERIFY=true and re-run, or add the hub's CA cert."

