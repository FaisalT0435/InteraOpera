#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Gated canary rollout for meridian-slm
#
# Usage: bash eval/rollout.sh <VERSION>
# Example: bash eval/rollout.sh 1.1
#
# Expected outcomes (from ML team notes):
#   VERSION=1.1 → AUTO-PROMOTE  (quantized rebuild, passes all thresholds)
#   VERSION=2.0 → AUTO-ROLLBACK (fine-tune regression, fails accuracy + latency)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <VERSION>"
  echo "  Example: $0 1.1"
  exit 1
fi

NAMESPACE="meridian"
CANARY_NAME="model-server-canary"
STABLE_NAME="model-server"
IMAGE="meridian-slm:${VERSION}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8000}"
RAG_URL="${RAG_URL:-http://localhost:8080}"
EVAL_SET="eval/eval_set.jsonl"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
EVIDENCE_FILE="evidence/rollout-${VERSION}-${TIMESTAMP}.json"

mkdir -p evidence

echo "========================================================"
echo "  Gated rollout: meridian-slm:${VERSION}"
echo "  Timestamp: ${TIMESTAMP}"
echo "========================================================"

# ── Step 1: Verify image exists ───────────────────────────────────────────────
echo ""
echo "==> [1/5] Checking image meridian-slm:${VERSION}..."
if ! docker image inspect "meridian-slm:${VERSION}" > /dev/null 2>&1; then
  echo "ERROR: Image meridian-slm:${VERSION} not found locally."
  echo "       Run: docker build -t meridian-slm:${VERSION} --build-arg MODEL_VERSION=${VERSION} services/model-server/"
  exit 1
fi
echo "    Image found."

# Load into kind if not already loaded
echo "==> Loading image into kind cluster..."
kind load docker-image "meridian-slm:${VERSION}" --name meridian-cluster 2>/dev/null || true

# ── Step 2: Deploy canary ─────────────────────────────────────────────────────
echo ""
echo "==> [2/5] Deploying canary (meridian-slm:${VERSION})..."

# Create canary deployment via kubectl patch
cat <<EOF | kubectl apply -f - -n ${NAMESPACE}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CANARY_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: model-server
    track: canary
    version: "${VERSION}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: model-server
      track: canary
  template:
    metadata:
      labels:
        app: model-server
        track: canary
        version: "${VERSION}"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8001"
        prometheus.io/path: "/metrics"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: model-server
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: MODEL_VERSION
              value: "${VERSION}"
          ports:
            - containerPort: 8001
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8001
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8001
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
EOF

# Create a canary service so gate.py can target it directly
cat <<EOF | kubectl apply -f - -n ${NAMESPACE}
apiVersion: v1
kind: Service
metadata:
  name: model-server-canary
  namespace: ${NAMESPACE}
spec:
  selector:
    app: model-server
    track: canary
  ports:
    - port: 8001
      targetPort: 8001
  type: ClusterIP
EOF

echo "    Waiting for canary to be ready..."
kubectl wait --for=condition=ready pod -l app=model-server,track=canary \
  -n ${NAMESPACE} --timeout=120s

echo "    Canary is ready."

# ── Step 3: Port-forward canary for eval ─────────────────────────────────────
echo ""
echo "==> [3/5] Port-forwarding canary service for evaluation..."
kubectl port-forward svc/model-server-canary 18001:8001 -n ${NAMESPACE} &
PF_PID=$!
sleep 3  # Give port-forward time to establish

# Temporarily redirect gateway to canary for evaluation
# (In real canary: only 10% traffic — here we eval against canary directly)
CANARY_GATEWAY_URL="http://localhost:18001"
echo "    Canary accessible at ${CANARY_GATEWAY_URL}"

# ── Step 4: Run eval gate ─────────────────────────────────────────────────────
echo ""
echo "==> [4/5] Running evaluation gate against canary..."
echo "    Evaluating accuracy + p95 latency on direct and RAG paths..."

# For RAG path eval, use existing RAG API (points at stable model server)
# Gate evaluates canary direct path + RAG accuracy via stable path
set +e
python eval/gate.py \
  --gateway-url "http://localhost:18001" \
  --rag-url "${RAG_URL}" \
  --eval-set "${EVAL_SET}" \
  --version "${VERSION}" \
  --output "${EVIDENCE_FILE}"
GATE_EXIT=$?
set -e

# Kill port-forward
kill ${PF_PID} 2>/dev/null || true

# ── Step 5: Promote or rollback ───────────────────────────────────────────────
echo ""
echo "==> [5/5] Applying gate decision..."

if [[ ${GATE_EXIT} -eq 0 ]]; then
  # PROMOTE
  echo ""
  echo "✅ DECISION: PROMOTE"
  echo "   Updating stable deployment to meridian-slm:${VERSION}..."

  kubectl set image deployment/${STABLE_NAME} \
    model-server=${IMAGE} \
    -n ${NAMESPACE}

  kubectl set env deployment/${STABLE_NAME} \
    MODEL_VERSION="${VERSION}" \
    -n ${NAMESPACE}

  kubectl rollout status deployment/${STABLE_NAME} -n ${NAMESPACE} --timeout=120s

  echo "   Removing canary..."
  kubectl delete deployment ${CANARY_NAME} -n ${NAMESPACE} --ignore-not-found
  kubectl delete service model-server-canary -n ${NAMESPACE} --ignore-not-found

  echo ""
  echo "🎉 meridian-slm:${VERSION} is now serving 100% of traffic."

  # Update evidence with final decision
  python3 -c "
import json, sys
with open('${EVIDENCE_FILE}') as f:
    e = json.load(f)
e['rollout_decision'] = 'PROMOTE'
e['production_version'] = '${VERSION}'
with open('${EVIDENCE_FILE}', 'w') as f:
    json.dump(e, f, indent=2)
print('Evidence updated.')
"

else
  # ROLLBACK
  echo ""
  echo "❌ DECISION: ROLLBACK"
  echo "   Removing canary deployment — stable version unchanged."

  kubectl delete deployment ${CANARY_NAME} -n ${NAMESPACE} --ignore-not-found
  kubectl delete service model-server-canary -n ${NAMESPACE} --ignore-not-found

  # Update evidence with final decision
  python3 -c "
import json
with open('${EVIDENCE_FILE}') as f:
    e = json.load(f)
e['rollout_decision'] = 'ROLLBACK'
e['reason'] = 'Evaluation thresholds not met — see direct_path and rag_path for details'
with open('${EVIDENCE_FILE}', 'w') as f:
    json.dump(e, f, indent=2)
print('Evidence updated.')
"

  echo ""
  echo "⚠️  meridian-slm:${VERSION} did NOT reach production. Stable version continues serving."
fi

echo ""
echo "Evidence saved to: ${EVIDENCE_FILE}"
echo "========================================================"
