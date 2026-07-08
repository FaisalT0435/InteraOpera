output "cluster_name" {
  description = "Name of the kind cluster"
  value       = kind_cluster.meridian.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = kind_cluster.meridian.endpoint
}

output "kubeconfig" {
  description = "Kubeconfig for the cluster"
  value       = kind_cluster.meridian.kubeconfig
  sensitive   = true
}
