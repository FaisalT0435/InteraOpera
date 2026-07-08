terraform {
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.4"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ── Kind cluster ──────────────────────────────────────────────────────────────
resource "kind_cluster" "meridian" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
      # Expose NodePorts for gateway and rag-api
      extra_port_mappings {
        container_port = 30800
        host_port      = 8000
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 30801
        host_port      = 8080
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 30090
        host_port      = 9090
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 30030
        host_port      = 3000
        protocol       = "TCP"
      }
    }
  }
}

# ── Kubernetes & Helm providers ───────────────────────────────────────────────
provider "kubernetes" {
  host                   = kind_cluster.meridian.endpoint
  cluster_ca_certificate = base64decode(kind_cluster.meridian.cluster_ca_certificate)
  client_certificate     = base64decode(kind_cluster.meridian.client_certificate)
  client_key             = base64decode(kind_cluster.meridian.client_key)
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.meridian.endpoint
    cluster_ca_certificate = base64decode(kind_cluster.meridian.cluster_ca_certificate)
    client_certificate     = base64decode(kind_cluster.meridian.client_certificate)
    client_key             = base64decode(kind_cluster.meridian.client_key)
  }
}

# ── Namespace ─────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "meridian" {
  metadata {
    name = "meridian"
  }
  depends_on = [kind_cluster.meridian]
}

# ── kube-prometheus-stack (Prometheus + Grafana + Alertmanager) ───────────────
resource "helm_release" "prometheus_stack" {
  name             = "prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "60.3.0"
  namespace        = "monitoring"
  create_namespace = true

  values = [file("${path.module}/../deploy/observability/prometheus-values.yaml")]

  depends_on = [kind_cluster.meridian]
}

# ── Load images into kind cluster ─────────────────────────────────────────────
resource "null_resource" "build_and_load_images" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ${path.module}/.. && \
      docker build -t meridian-slm:1.0 --build-arg MODEL_VERSION=1.0 services/model-server/ && \
      docker build -t meridian-slm:1.1 --build-arg MODEL_VERSION=1.1 services/model-server/ && \
      docker build -t meridian-slm:2.0 --build-arg MODEL_VERSION=2.0 services/model-server/ && \
      docker build -t meridian-gateway:latest services/gateway/ && \
      docker build -t meridian-rag-api:latest services/rag-api/ && \
      kind load docker-image meridian-slm:1.0 --name ${var.cluster_name} && \
      kind load docker-image meridian-slm:1.1 --name ${var.cluster_name} && \
      kind load docker-image meridian-slm:2.0 --name ${var.cluster_name} && \
      kind load docker-image meridian-gateway:latest --name ${var.cluster_name} && \
      kind load docker-image meridian-rag-api:latest --name ${var.cluster_name}
    EOT
  }

  depends_on = [kind_cluster.meridian]
}

# ── Deploy Kubernetes manifests ───────────────────────────────────────────────
resource "null_resource" "deploy_manifests" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f ${path.module}/../deploy/qdrant/deployment.yaml && \
      kubectl apply -f ${path.module}/../deploy/model-server/deployment.yaml && \
      kubectl apply -f ${path.module}/../deploy/gateway/deployment.yaml && \
      kubectl apply -f ${path.module}/../deploy/rag-api/corpus-configmap.yaml && \
      kubectl apply -f ${path.module}/../deploy/rag-api/deployment.yaml
    EOT
  }

  depends_on = [null_resource.build_and_load_images, kubernetes_namespace.meridian]
}
