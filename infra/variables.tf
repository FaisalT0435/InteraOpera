variable "cluster_name" {
  description = "Name of the kind cluster"
  type        = string
  default     = "meridian-cluster"
}

variable "kubeconfig_path" {
  description = "Path to write the kubeconfig file"
  type        = string
  default     = "./kubeconfig.yaml"
}
