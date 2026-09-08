output "name" {
  value = var.name
}

output "id" {
  value = var.id
}

output "cluster_endpoint" {
  value = local.cluster_endpoint
}

output "ingress_ip" {
  description = "Адрес NLB ingress или, если балансировщика нет, публичные адреса worker-узлов."
  value       = var.ingress_lb ? var.ingress_ip : join(",", [for name in keys(local.workers) : local.node_public_ip[name]])
}

output "nodes" {
  value = {
    for name, node in local.nodes : name => {
      role       = node.role
      private_ip = node.ip
      public_ip  = local.node_public_ip[name]
    }
  }
}

output "node_public_ips" {
  value = [for name in keys(local.nodes) : local.node_public_ip[name]]
}

output "controlplane_public_ip" {
  value = local.node_public_ip[local.first_controlplane]
}

output "kubeconfig_path" {
  value = local_sensitive_file.kubeconfig.filename
}

output "talosconfig_path" {
  value = local_sensitive_file.talosconfig.filename
}

output "kubeconfig_raw" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}
