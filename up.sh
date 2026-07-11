#!/usr/bin/env bash
set -e

# Automatically add local bin/ to PATH so kind.exe works without Windows setup
export PATH="$PWD/bin:$PATH"

CLUSTER_NAME="meridian-cluster"

echo -e "\n\033[1;36m==> Checking prerequisites...\033[0m"
if ! command -v kind &> /dev/null; then
    echo -e "\033[1;31mERROR: 'kind' is not found.\033[0m"
    echo "Please download kind for Windows and place it in the 'bin/' folder as 'kind.exe'."
    exit 1
fi

echo -e "\n\033[1;36m==> Building Docker images...\033[0m"
docker build -t meridian-slm:1.0 --build-arg MODEL_VERSION=1.0 services/model-server/
docker build -t meridian-slm:1.1 --build-arg MODEL_VERSION=1.1 services/model-server/
docker build -t meridian-slm:2.0 --build-arg MODEL_VERSION=2.0 services/model-server/
docker build -t meridian-gateway:latest services/gateway/
docker build -t meridian-rag-api:latest services/rag-api/

echo -e "\n\033[1;36m==> Provisioning kind cluster + Helm releases via Terraform...\033[0m"
cd infra
terraform init -input=false
terraform apply -auto-approve
cd ..

echo -e "\n\033[1;36m==> Creating namespace...\033[0m"
kubectl apply -f deploy/namespace.yaml

echo -e "\n\033[1;36m==> Loading images into kind...\033[0m"
docker save -o tmp-images.tar meridian-slm:1.0 meridian-slm:1.1 meridian-slm:2.0 meridian-gateway:latest meridian-rag-api:latest
kind load image-archive tmp-images.tar --name $CLUSTER_NAME
rm -f tmp-images.tar

echo -e "\n\033[1;36m==> Deploying corpus ConfigMap...\033[0m"
kubectl create configmap corpus-files --from-file=corpus/ --namespace=meridian --dry-run=client -o yaml > corpus.yaml
kubectl apply -f corpus.yaml
rm corpus.yaml

echo -e "\n\033[1;36m==> Deploying all services...\033[0m"
kubectl apply -f deploy/qdrant/deployment.yaml
kubectl apply -f deploy/model-server/deployment.yaml
kubectl apply -f deploy/gateway/deployment.yaml
kubectl apply -f deploy/rag-api/deployment.yaml
kubectl apply -f deploy/observability/alertrules.yaml

echo -e "\n\033[1;36m==> Waiting for pods to be ready (this may take a minute)...\033[0m"
kubectl wait --for=condition=ready pod -l app=qdrant -n meridian --timeout=120s
kubectl wait --for=condition=ready pod -l app=model-server -n meridian --timeout=120s
kubectl wait --for=condition=ready pod -l app=gateway -n meridian --timeout=120s
kubectl wait --for=condition=ready pod -l app=rag-api -n meridian --timeout=180s

echo -e "\n\033[1;32m✅ Platform is up!\033[0m"
echo "   Gateway:      http://localhost:8000"
echo "   RAG API:      http://localhost:8080"
echo "   Grafana:      http://localhost:3000  (admin/admin)"
echo "   Prometheus:   http://localhost:9090"
echo "   Alertmanager: http://localhost:9093"
