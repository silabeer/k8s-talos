output "clusters" {
  description = "Кластеры: endpoint, узлы, ingress."
  value = {
    for name, c in module.cluster : name => {
      id                    = c.id
      endpoint              = c.cluster_endpoint
      ingress_ip            = c.ingress_ip
      controlplane_public_ip = c.controlplane_public_ip
      nodes                 = c.nodes
      kubeconfig            = c.kubeconfig_path
      talosconfig           = c.talosconfig_path
    }
  }
}

output "installer_image" {
  description = "Образ для `talosctl upgrade --image`."
  value       = local.install_image
}

output "schematic_id" {
  description = "Схематик Image Factory, null при image_source = github."
  value       = local.schematic_id
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
