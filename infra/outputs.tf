output "cluster_endpoint" {
  description = "Endpoint kube-apiserver (внешний NLB)."
  value       = local.cluster_endpoint
}

output "ingress_ip" {
  description = "Публичный IP ingress. Направьте сюда A-записи ваших доменов."
  value       = local.ingress_ip
}

output "nodes" {
  description = "Узлы кластера."
  value = {
    for name, node in local.nodes : name => {
      role       = node.role
      private_ip = node.ip
      public_ip  = local.node_public_ip[name]
    }
  }
}

output "schematic_id" {
  description = "Схематик Image Factory, null при image_source = github."
  value       = local.schematic_id
}

output "installer_image" {
  description = "Образ для `talosctl upgrade --image`."
  value       = local.installer_image
}

output "kubeconfig_raw" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}


output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}
