#!/usr/bin/env bash
# Script to capture logs from all logging pipeline components
# Run this on the WORKING cluster to collect baseline logs for comparison

set -e

OUTPUT_DIR="${1:-./logging-pipeline-logs}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR}/${TIMESTAMP}"

mkdir -p "$OUTPUT_DIR"

echo "=============================================="
echo "Capturing logs from all logging pipeline components"
echo "Output directory: $OUTPUT_DIR"
echo "=============================================="

# Function to safely capture logs
capture_logs() {
    local name="$1"
    local cmd="$2"
    local output_file="$OUTPUT_DIR/$name"
    
    echo -e "\n>>> Capturing: $name"
    echo "Command: $cmd"
    if eval "$cmd" > "$output_file" 2>&1; then
        echo "✓ Saved to: $output_file"
    else
        echo "✗ Failed (check $output_file for details)"
    fi
}

# Function to safely get resource yaml
capture_yaml() {
    local name="$1"
    local cmd="$2"
    local output_file="$OUTPUT_DIR/$name"
    
    echo -e "\n>>> Capturing YAML: $name"
    if eval "$cmd" > "$output_file" 2>&1; then
        echo "✓ Saved to: $output_file"
    else
        echo "✗ Failed (check $output_file for details)"
    fi
}

echo ""
echo "=============================================="
echo "STEP 1: Cluster Info"
echo "=============================================="
capture_logs "00-cluster-version.txt" "oc get clusterversion version -o yaml"
capture_logs "00-nodes.txt" "oc get nodes -o wide"

echo ""
echo "=============================================="
echo "STEP 2: MinIO (Storage Backend)"
echo "=============================================="
capture_logs "01-minio-pods.txt" "oc get pods -n minio -o wide"
capture_logs "01-minio-pod-logs.txt" "oc logs -n minio minio-0 --tail=200"
capture_logs "01-minio-service.txt" "oc get svc -n minio -o yaml"
capture_logs "01-minio-route.txt" "oc get route -n minio -o yaml"
capture_logs "01-minio-statefulset.txt" "oc get statefulset -n minio -o yaml"

echo ""
echo "=============================================="
echo "STEP 3: Loki Operator (openshift-operators-redhat)"
echo "=============================================="
capture_logs "02-loki-operator-pods.txt" "oc get pods -n openshift-operators-redhat -o wide"
capture_logs "02-loki-operator-subscription.txt" "oc get subscription loki-operator -n openshift-operators-redhat -o yaml"
capture_logs "02-loki-operator-csv.txt" "oc get csv -n openshift-operators-redhat -o wide"
capture_logs "02-loki-operator-logs.txt" "oc logs -n openshift-operators-redhat -l name=loki-operator-controller-manager --tail=500"

echo ""
echo "=============================================="
echo "STEP 4: LokiStack Components (openshift-logging)"
echo "=============================================="
capture_yaml "03-lokistack.yaml" "oc get lokistack logging-loki -n openshift-logging -o yaml"
capture_logs "03-lokistack-pods.txt" "oc get pods -n openshift-logging -l app.kubernetes.io/instance=logging-loki -o wide"
capture_logs "03-lokistack-services.txt" "oc get svc -n openshift-logging -l app.kubernetes.io/instance=logging-loki -o wide"

# Capture logs from each LokiStack component
for component in distributor ingester querier query-frontend compactor gateway index-gateway ruler; do
    capture_logs "03-lokistack-${component}-logs.txt" "oc logs -n openshift-logging -l app.kubernetes.io/component=${component} --tail=200 --all-containers 2>/dev/null || echo 'Component not found'"
done

# LokiStack secret (redacted)
echo -e "\n>>> Capturing LokiStack MinIO secret (keys only)"
oc get secret logging-loki-minio -n openshift-logging -o jsonpath='{.data}' | jq 'keys' > "$OUTPUT_DIR/03-lokistack-secret-keys.txt" 2>/dev/null || echo "Secret not found" > "$OUTPUT_DIR/03-lokistack-secret-keys.txt"

echo ""
echo "=============================================="
echo "STEP 5: OpenShift Logging Operator"
echo "=============================================="
capture_logs "04-logging-operator-pods.txt" "oc get pods -n openshift-logging -l name=cluster-logging-operator -o wide"
capture_logs "04-logging-operator-subscription.txt" "oc get subscription cluster-logging -n openshift-logging -o yaml"
capture_logs "04-logging-operator-csv.txt" "oc get csv -n openshift-logging -o wide"
capture_logs "04-logging-operator-logs.txt" "oc logs -n openshift-logging -l name=cluster-logging-operator --tail=500"

echo ""
echo "=============================================="
echo "STEP 6: ClusterLogForwarder"
echo "=============================================="
capture_yaml "05-clusterlogforwarder.yaml" "oc get clusterlogforwarder collector -n openshift-logging -o yaml"
capture_logs "05-clusterlogforwarder-status.txt" "oc get clusterlogforwarder collector -n openshift-logging -o jsonpath='{.status}' | jq ."

echo ""
echo "=============================================="
echo "STEP 7: Log Collector Pods (Vector)"
echo "=============================================="
capture_logs "06-collector-pods.txt" "oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o wide"
capture_logs "06-collector-daemonset.txt" "oc get daemonset -n openshift-logging -l app.kubernetes.io/component=collector -o yaml"

# Get logs from collector pods on each node
echo -e "\n>>> Capturing collector pod logs from each node..."
COLLECTOR_PODS=$(oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
for pod in $COLLECTOR_PODS; do
    capture_logs "06-collector-${pod}-logs.txt" "oc logs -n openshift-logging ${pod} --tail=300"
done

# Vector config
capture_logs "06-collector-config.txt" "oc get configmap -n openshift-logging -l app.kubernetes.io/component=collector -o yaml"

echo ""
echo "=============================================="
echo "STEP 8: Service Account & RBAC"
echo "=============================================="
capture_logs "07-collector-sa.txt" "oc get sa collector -n openshift-logging -o yaml"
capture_logs "07-collector-clusterrolebindings.txt" "oc get clusterrolebindings -o wide | grep -E 'collector|logging'"

echo ""
echo "=============================================="
echo "STEP 9: Certificates & TLS"
echo "=============================================="
capture_logs "08-service-ca-configmap.txt" "oc get configmap openshift-service-ca.crt -n openshift-logging -o yaml 2>/dev/null || echo 'ConfigMap not found'"

echo ""
echo "=============================================="
echo "STEP 10: Test Log Query to Loki"
echo "=============================================="
# Try to query Loki directly
echo -e "\n>>> Testing Loki query endpoint..."
LOKI_ROUTE=$(oc get route -n openshift-logging -l app.kubernetes.io/component=lokistack-gateway -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
if [ -n "$LOKI_ROUTE" ]; then
    echo "Loki Gateway Route: $LOKI_ROUTE" > "$OUTPUT_DIR/09-loki-query-test.txt"
    # Try a simple query (this might need authentication)
    curl -s -k "https://${LOKI_ROUTE}/api/logs/v1/application/loki/api/v1/labels" >> "$OUTPUT_DIR/09-loki-query-test.txt" 2>&1 || echo "Query failed (may need auth)" >> "$OUTPUT_DIR/09-loki-query-test.txt"
else
    echo "No Loki gateway route found" > "$OUTPUT_DIR/09-loki-query-test.txt"
fi

echo ""
echo "=============================================="
echo "STEP 11: Events in openshift-logging namespace"
echo "=============================================="
capture_logs "10-events-openshift-logging.txt" "oc get events -n openshift-logging --sort-by='.lastTimestamp'"

echo ""
echo "=============================================="
echo "STEP 12: All resources in openshift-logging"
echo "=============================================="
capture_logs "11-all-resources-openshift-logging.txt" "oc get all -n openshift-logging -o wide"

echo ""
echo "=============================================="
echo "COMPLETE!"
echo "=============================================="
echo ""
echo "All logs captured to: $OUTPUT_DIR"
echo ""
echo "Key files to review:"
echo "  - 05-clusterlogforwarder.yaml      : CLF configuration"
echo "  - 05-clusterlogforwarder-status.txt: CLF status (check for errors)"
echo "  - 06-collector-*-logs.txt          : Vector collector logs (look for forwarding errors)"
echo "  - 03-lokistack-ingester-logs.txt   : Loki ingester (receiving logs)"
echo "  - 10-events-openshift-logging.txt  : Recent events"
echo ""

# Create summary
echo "Creating summary..."
{
    echo "=== LOGGING PIPELINE CAPTURE SUMMARY ==="
    echo "Timestamp: $TIMESTAMP"
    echo ""
    echo "=== Cluster Version ==="
    oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null
    echo ""
    echo ""
    echo "=== Pod Status ==="
    echo "MinIO:"
    oc get pods -n minio --no-headers 2>/dev/null | awk '{print "  " $1 ": " $3}'
    echo ""
    echo "Loki Operator:"
    oc get pods -n openshift-operators-redhat -l name=loki-operator-controller-manager --no-headers 2>/dev/null | awk '{print "  " $1 ": " $3}'
    echo ""
    echo "LokiStack:"
    oc get pods -n openshift-logging -l app.kubernetes.io/instance=logging-loki --no-headers 2>/dev/null | awk '{print "  " $1 ": " $3}'
    echo ""
    echo "Logging Operator:"
    oc get pods -n openshift-logging -l name=cluster-logging-operator --no-headers 2>/dev/null | awk '{print "  " $1 ": " $3}'
    echo ""
    echo "Collectors:"
    oc get pods -n openshift-logging -l app.kubernetes.io/component=collector --no-headers 2>/dev/null | awk '{print "  " $1 ": " $3}'
    echo ""
    echo "=== ClusterLogForwarder Status ==="
    oc get clusterlogforwarder collector -n openshift-logging -o jsonpath='{.status.conditions[*].type}' 2>/dev/null
    echo ""
} > "$OUTPUT_DIR/00-SUMMARY.txt"

echo "Summary saved to: $OUTPUT_DIR/00-SUMMARY.txt"
echo ""
echo "To compare with another cluster, run this script there and diff the outputs."


