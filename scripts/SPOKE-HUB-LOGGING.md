# Spoke-to-Hub Log Forwarding

This guide explains how to set up log forwarding from a **SPOKE** OpenShift cluster to a **HUB** cluster's LokiStack.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            SPOKE CLUSTER                                     │
│                                                                              │
│  ┌─────────────┐     ┌─────────────────┐     ┌──────────────────────────┐   │
│  │ Tekton Pods │ ──► │ Collector Pods  │ ──► │ ClusterLogForwarder      │   │
│  │ (logs)      │     │ (Vector)        │     │ (type: loki)             │   │
│  └─────────────┘     └─────────────────┘     └────────────┬─────────────┘   │
│                                                           │                  │
└───────────────────────────────────────────────────────────┼──────────────────┘
                                                            │ HTTPS + Bearer Token
                                                            ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│                            HUB CLUSTER                                        │
│                                                                               │
│  ┌─────────────────┐     ┌─────────────────┐     ┌──────────────────────┐    │
│  │ Route           │ ──► │ Loki Gateway    │ ──► │ LokiStack            │    │
│  │ (passthrough)   │     │ (auth + routing)│     │ (storage in MinIO)   │    │
│  └─────────────────┘     └─────────────────┘     └──────────────────────┘    │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### HUB Cluster
- LokiStack installed and running
- MinIO or S3-compatible storage configured
- Cluster admin access

### SPOKE Cluster
- OpenShift 4.15+ 
- Tekton Pipelines installed
- Cluster admin access

## Setup Steps

### Step 1: Setup HUB Cluster

Run on the **HUB** cluster:

```bash
./scripts/setup-route.sh
```

This will output:
```
export HUB_LOKI_HOST="https://logging-loki-openshift-logging.apps.hub.example.com"
export HUB_LOKI_TOKEN="eyJhbGc..."
```

**Copy these export commands for use on the SPOKE cluster.**

### Step 2: Setup SPOKE Cluster

Run on the **SPOKE** cluster:

```bash
# Set environment variables from HUB setup
export HUB_LOKI_HOST="https://logging-loki-openshift-logging.apps.hub.example.com"
export HUB_LOKI_TOKEN="eyJhbGc..."

# Run setup
./scripts/setup-spoke-simple.sh
```

## Testing the Setup

### Important: Namespace Exclusions

Logs from these namespaces are **EXCLUDED** by default:
- `default`
- `kube-*`
- `openshift-*`

**Always run PipelineRuns in custom namespaces** (e.g., `tekton-test`).

### Step 1: Create Test Namespace

```bash
oc create namespace test
```

### Step 2: Run Test PipelineRun

```bash
cat <<EOF | oc create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: test-spoke-hub-
  namespace: test
spec:
  pipelineSpec:
    tasks:
    - name: hello
      taskSpec:
        steps:
        - name: say-hello
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          script: |
            #!/bin/bash
            for i in 1 2 3 4 5; do
              echo "SPOKE-TO-HUB TEST \$i - \$(date)"
              sleep 1
            done
EOF
```

### Step 3: Verify Logs Were Sent (SPOKE)

Wait ~20 seconds for logs to be collected, then check collector metrics:

```bash
oc exec -n openshift-logging $(oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o jsonpath='{.items[0].metadata.name}') -- \
  curl -sk https://127.0.0.1:24231/metrics | grep "sent.*output_hub_loki"
```

Expected output should show non-zero sent events:
```
vector_component_sent_events_total{...output_hub_loki...} 7
vector_component_sent_bytes_total{...output_hub_loki...} 2768
```

### Step 4: Query Logs on HUB

On the **HUB** cluster:

```bash
curl -k -H "Authorization: Bearer $(oc whoami -t)" \
  "${HUB_LOKI_HOST}/api/logs/v1/application/loki/api/v1/query_range" \
  --data-urlencode 'query={kubernetes_namespace_name="tekton-test"}' \
  --data-urlencode 'limit=10' | jq '.data.result[].values[][1]' | head -5
```

## Verification Commands

### Check Collector Pods Are Running

```bash
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o wide
```

### Check ClusterLogForwarder Status

```bash
oc get clusterlogforwarder collector -n openshift-logging -o jsonpath='{.status.conditions}' | jq .
```

### Verify Authentication in Vector Config

```bash
oc get configmap collector-config -n openshift-logging -o jsonpath='{.data.vector\.toml}' | grep -A 3 "\[sinks.output_hub_loki.auth\]"
```

Expected output:
```toml
[sinks.output_hub_loki.auth]
strategy = "bearer"
token = "SECRET[kubernetes_secret.hub-loki-token/token]"
```

### Verify Secret Is Mounted

```bash
oc get daemonset collector -n openshift-logging -o yaml | grep -A 5 "hub-loki-token"
```

## Troubleshooting

### Problem: Authentication Not Configured in Vector

**Symptom:** No `[sinks.output_hub_loki.auth]` section in Vector config.

**Cause:** The `authentication:` block must be nested **inside** the `loki:` section, not at the output level.

**Fix:** Check ClusterLogForwarder YAML structure:
```yaml
outputs:
- name: hub-loki
  type: loki
  loki:
    url: "..."
    authentication:        # Must be INSIDE loki:
      token:
        from: secret
        secret:
          name: hub-loki-token
          key: token
```

### Problem: Secret Not Mounted

**Symptom:** `hub-loki-token` not found in collector volumes.

**Cause:** Collector ServiceAccount doesn't have permission to read the secret.

**Fix:** Create Role/RoleBinding:
```bash
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
---
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
```

### Problem: No Logs Collected

**Symptom:** Metrics show 0 received events.

**Cause:** Pods in excluded namespaces (`default`, `kube-*`, `openshift-*`).

**Fix:** Run PipelineRuns in custom namespaces:
```bash
oc create namespace tekton-test
# Run PipelineRun with namespace: tekton-test
```

### Problem: HTTP to HTTPS Error

**Symptom:** Gateway logs show `client sent an HTTP request to an HTTPS server`.

**Cause:** Wrong route type.

**Fix:** Use `passthrough` route for the Loki gateway:
```bash
oc create route passthrough loki-gateway \
  --service=logging-loki-gateway-http \
  --port=8080 \
  -n openshift-logging
```

### Problem: Permission Denied on HUB

**Symptom:** Gateway returns "You don't have permission to access this tenant".

**Cause:** Token doesn't have write permissions.

**Fix:** Grant `logging-collector-logs-writer` role on HUB:
```bash
oc adm policy add-cluster-role-to-user logging-collector-logs-writer \
  system:serviceaccount:openshift-logging:spoke-collector
```

## Debug Commands

### Check Collector Logs

```bash
oc logs -n openshift-logging -l app.kubernetes.io/component=collector --tail=50
```

### Check All Hub-Loki Metrics

```bash
oc exec -n openshift-logging $(oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o jsonpath='{.items[0].metadata.name}') -- \
  curl -sk https://127.0.0.1:24231/metrics | grep hub_loki
```

### Check HUB Gateway Logs

On **HUB** cluster:
```bash
oc logs -n openshift-logging -l app.kubernetes.io/component=lokistack-gateway --tail=50
```

### Check Full Vector Configuration

```bash
oc get configmap collector-config -n openshift-logging -o jsonpath='{.data.vector\.toml}'
```

## Key Configuration Details

### ClusterLogForwarder Structure

```yaml
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
      authentication:              # MUST be inside loki: block
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
```

### Vector Configuration Generated

The ClusterLogForwarder generates this Vector sink configuration:

```toml
[sinks.output_hub_loki]
type = "loki"
endpoint = "https://..."
...

[sinks.output_hub_loki.auth]
strategy = "bearer"
token = "SECRET[kubernetes_secret.hub-loki-token/token]"

[sinks.output_hub_loki.tls]
verify_certificate = false
verify_hostname = false
```

