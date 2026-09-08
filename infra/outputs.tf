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
  value       = local.install_image
}

output "kubeconfig_raw" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}


output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "registry" {
  description = "Artifact Keeper: адреса и созданные репозитории."
  value = local.registry_enabled ? {
    private_url = local.registry_url
    public_url  = local.registry_public_url
    bucket      = yandex_storage_bucket.registry[0].bucket
    docker      = { for host, key in local.registry_docker_key : host => "${local.registry_url}/v2/${key}" }
    helm        = { for key, _ in var.registry_helm_repos : key => "${local.registry_url}/helm/${key}" }
  } : null
}

output "registry_admin_password" {
  description = "Пароль admin в Artifact Keeper."
  value       = local.registry_enabled ? random_password.registry_admin[0].result : null
  sensitive   = true
}
