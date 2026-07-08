.PHONY: up down build load deploy rollout inject-fault clear-fault load-test eval

CLUSTER_NAME := meridian-cluster
VERSION      ?= 1.1

# ─────────────────────────────────────────────────────────────────────────────
# Platform lifecycle
# ─────────────────────────────────────────────────────────────────────────────

## Bring up the entire platform from scratch (one command)
up:
	@echo "==> Building Docker images..."
	$(MAKE) build
	@echo "==> Provisioning kind cluster + Helm releases via Terraform..."
	cd infra && terraform init -input=false && terraform apply -auto-approve
	@echo "==> Creating namespace..."
	kubectl apply -f deploy/namespace.yaml
	@echo "==> Loading images into kind..."
	$(MAKE) load
	@echo "==> Deploying corpus ConfigMap..."
	kubectl create configmap corpus-files \
	  --from-file=corpus/ \
	  --namespace=meridian \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo "==> Deploying all services..."
	$(MAKE) deploy
	@echo "==> Waiting for pods to be ready..."
	kubectl wait --for=condition=ready pod -l app=qdrant      -n meridian --timeout=120s
	kubectl wait --for=condition=ready pod -l app=model-server -n meridian --timeout=120s
	kubectl wait --for=condition=ready pod -l app=gateway      -n meridian --timeout=120s
	kubectl wait --for=condition=ready pod -l app=rag-api      -n meridian --timeout=180s
	@echo ""
	@echo "✅ Platform is up!"
	@echo "   Gateway:      http://localhost:8000"
	@echo "   RAG API:      http://localhost:8080"
	@echo "   Grafana:      http://localhost:3000  (admin/admin)"
	@echo "   Prometheus:   http://localhost:9090"
	@echo "   Alertmanager: http://localhost:9093"

## Tear down everything
down:
	@echo "==> Destroying Terraform resources (kind cluster + Helm)..."
	cd infra && terraform destroy -auto-approve
	@echo "✅ Platform destroyed."

# ─────────────────────────────────────────────────────────────────────────────
# Build & load images
# ─────────────────────────────────────────────────────────────────────────────

build:
	docker build -t meridian-slm:1.0 --build-arg MODEL_VERSION=1.0 services/model-server/
	docker build -t meridian-slm:1.1 --build-arg MODEL_VERSION=1.1 services/model-server/
	docker build -t meridian-slm:2.0 --build-arg MODEL_VERSION=2.0 services/model-server/
	docker build -t meridian-gateway:latest services/gateway/
	docker build -t meridian-rag-api:latest services/rag-api/

load:
	kind load docker-image meridian-slm:1.0     --name $(CLUSTER_NAME)
	kind load docker-image meridian-slm:1.1     --name $(CLUSTER_NAME)
	kind load docker-image meridian-slm:2.0     --name $(CLUSTER_NAME)
	kind load docker-image meridian-gateway:latest --name $(CLUSTER_NAME)
	kind load docker-image meridian-rag-api:latest --name $(CLUSTER_NAME)

# ─────────────────────────────────────────────────────────────────────────────
# Deploy Kubernetes manifests
# ─────────────────────────────────────────────────────────────────────────────

deploy:
	kubectl apply -f deploy/qdrant/deployment.yaml
	kubectl apply -f deploy/model-server/deployment.yaml
	kubectl apply -f deploy/gateway/deployment.yaml
	kubectl apply -f deploy/rag-api/deployment.yaml
	kubectl apply -f deploy/observability/alertrules.yaml

# ─────────────────────────────────────────────────────────────────────────────
# Model rollout (gated canary)
# ─────────────────────────────────────────────────────────────────────────────

## Run gated canary rollout. Usage: make rollout VERSION=1.1
rollout:
	@echo "==> Starting gated rollout for meridian-slm:$(VERSION)..."
	bash eval/rollout.sh $(VERSION)

# ─────────────────────────────────────────────────────────────────────────────
# Observability demos
# ─────────────────────────────────────────────────────────────────────────────

## Inject fault — triggers HighErrorRate alert
inject-fault:
	@echo "==> Injecting fault: 50% error rate on model server..."
	kubectl exec -n meridian deployment/model-server -- \
	  wget -qO- --post-data='{"mode":"error","rate":0.5}' \
	  --header='Content-Type: application/json' \
	  http://localhost:8001/admin/fault
	@echo ""
	@echo "⚠️  Fault injected. Alert should fire within ~5 minutes."
	@echo "   Monitor: http://localhost:9093 (Alertmanager)"

## Clear injected fault
clear-fault:
	@echo "==> Clearing fault..."
	kubectl exec -n meridian deployment/model-server -- \
	  wget -qO- --post-data='{"mode":"off"}' \
	  --header='Content-Type: application/json' \
	  http://localhost:8001/admin/fault
	@echo "✅ Fault cleared. Alert should resolve within ~5 minutes."

## Run reference load test (8 concurrent clients, 60 seconds)
load-test:
	@echo "==> Running reference load test (concurrency=8, duration=60s)..."
	pip install httpx -q
	python loadgen/loadgen.py \
	  --url http://localhost:8000/v1/chat/completions \
	  --concurrency 8 \
	  --duration 60 \
	  | tee evidence/load-$(shell date +%Y%m%d-%H%M%S).json
	@echo "✅ Load test complete. Results saved to evidence/"

# ─────────────────────────────────────────────────────────────────────────────
# Evaluation
# ─────────────────────────────────────────────────────────────────────────────

## Run eval gate against live model server (direct path)
eval:
	@echo "==> Running eval against gateway..."
	python eval/gate.py \
	  --gateway-url http://localhost:8000 \
	  --rag-url http://localhost:8080 \
	  --eval-set eval/eval_set.jsonl \
	  --output evidence/eval-$(shell date +%Y%m%d-%H%M%S).json
