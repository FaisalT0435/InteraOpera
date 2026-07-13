param (
    [string]$Version = "1.1"
)

$env:Path = "$PSScriptRoot\bin;" + $env:Path

$ClusterName = "meridian-cluster"
$ErrorActionPreference = "Stop"

Write-Host "==> Building Docker images..." -ForegroundColor Cyan
docker build -t meridian-slm:1.0 --build-arg MODEL_VERSION=1.0 services/model-server/
docker build -t meridian-slm:1.1 --build-arg MODEL_VERSION=1.1 services/model-server/
docker build -t meridian-slm:2.0 --build-arg MODEL_VERSION=2.0 services/model-server/
docker build -t meridian-gateway:latest services/gateway/
docker build -t meridian-rag-api:latest services/rag-api/

Write-Host "==> Provisioning kind cluster + Helm releases via Terraform..." -ForegroundColor Cyan
Push-Location infra
terraform init -input=false
terraform apply -auto-approve
Pop-Location

Write-Host "==> Creating namespace..." -ForegroundColor Cyan
kubectl apply -f deploy/namespace.yaml

Write-Host "==> Loading images into kind..." -ForegroundColor Cyan
docker save -o tmp-images.tar meridian-slm:1.0 meridian-slm:1.1 meridian-slm:2.0 meridian-gateway:latest meridian-rag-api:latest
kind load image-archive tmp-images.tar --name $ClusterName
Remove-Item tmp-images.tar -ErrorAction SilentlyContinue

Write-Host "==> Deploying corpus ConfigMap..." -ForegroundColor Cyan
# Trick for Windows to apply configmap from file
kubectl create configmap corpus-files --from-file=corpus/ --namespace=meridian --dry-run=client -o yaml > corpus.yaml
kubectl apply -f corpus.yaml
Remove-Item corpus.yaml

Write-Host "==> Deploying all services..." -ForegroundColor Cyan
kubectl apply -f deploy/qdrant/deployment.yaml
kubectl apply -f deploy/model-server/deployment.yaml
kubectl apply -f deploy/gateway/deployment.yaml
kubectl apply -f deploy/rag-api/deployment.yaml
kubectl apply -f deploy/observability/alertrules.yaml

Write-Host "==> Waiting for pods to be ready (this may take a minute)..." -ForegroundColor Cyan
kubectl wait --for=condition=ready pod -l app=qdrant -n meridian --timeout=120s
kubectl wait --for=condition=ready pod -l app=model-server -n meridian --timeout=120s
kubectl wait --for=condition=ready pod -l app=gateway -n meridian --timeout=120s
kubectl wait --for=condition=ready pod -l app=rag-api -n meridian --timeout=180s

Write-Host ""
Write-Host "✅ Platform is up!" -ForegroundColor Green
Write-Host "   Gateway:      http://localhost:8000"
Write-Host "   RAG API:      http://localhost:8080"
Write-Host "   Grafana:      http://localhost:3000  (admin/admin)"
Write-Host "   Prometheus:   http://localhost:9090"
Write-Host "   Alertmanager: http://localhost:9093"
