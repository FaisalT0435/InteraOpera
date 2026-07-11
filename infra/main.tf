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
      extra_port_mappings {
        container_port = 30093
        host_port      = 9093
        protocol       = "TCP"
      }
    }
  }
}

# ── Kubernetes & Helm providers ───────────────────────────────────────────────
provider "kubernetes" {
  host                   = kind_cluster.meridian.endpoint
  cluster_ca_certificate = kind_cluster.meridian.cluster_ca_certificate
  client_certificate     = kind_cluster.meridian.client_certificate
  client_key             = kind_cluster.meridian.client_key
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.meridian.endpoint
    cluster_ca_certificate = kind_cluster.meridian.cluster_ca_certificate
    client_certificate     = kind_cluster.meridian.client_certificate
    client_key             = kind_cluster.meridian.client_key
  }
  repository_config_path = "${path.module}/.helm/repositories.yaml"
  repository_cache       = "${path.module}/.helm/cache"
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

# Manifests and image loading are handled by up.sh / up.ps1 natively

