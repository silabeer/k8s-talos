resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

locals {
  patch_common = file("${path.module}/patches/common.yaml")
  patch_role = {
    controlplane = file("${path.module}/patches/controlplane.yaml")
    worker       = file("${path.module}/patches/worker.yaml")
  }

  # Патчи, зависящие от terraform-переменных.
  patch_dynamic = {
    controlplane = yamlencode({
      machine = {
        install = { image = local.installer_image }
        kubelet = { nodeIP = { validSubnets = [var.subnet_cidr] } }
      }
      cluster = {
        etcd = { advertisedSubnets = [var.subnet_cidr] }
      }
    })
    worker = yamlencode({
      machine = {
        install = { image = local.installer_image }
        kubelet = { nodeIP = { validSubnets = [var.subnet_cidr] } }
      }
    })
  }
}

data "talos_machine_configuration" "this" {
  for_each = local.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    local.patch_common,
    local.patch_role[each.value.role],
    local.patch_dynamic[each.value.role],
    # Публичный IP узла за NAT не виден на интерфейсе, поэтому Talos сам
    # не добавит его в сертификат API. Добавляем явно.
    yamlencode({
      machine = {
        network  = { hostname = each.key }
        certSANs = [local.node_public_ip[each.key]]
      }
    }),
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for name in keys(local.controlplanes) : local.node_public_ip[name]]
  nodes                = [for node in local.nodes : node.ip]
}

# Узлы загружаются в maintenance mode и ждут конфиг по API (порт 50000).
resource "talos_machine_configuration_apply" "this" {
  for_each = local.nodes

  depends_on = [
    yandex_compute_instance.node,
    yandex_vpc_security_group_rule.this,
  ]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = local.node_public_ip[each.key]
}

resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplanes[local.first_controlplane].ip
  endpoint             = local.node_public_ip[local.first_controlplane]
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplanes[local.first_controlplane].ip
  endpoint             = local.node_public_ip[local.first_controlplane]
}

resource "local_sensitive_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/out/kubeconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/out/talosconfig"
  file_permission = "0600"
}
