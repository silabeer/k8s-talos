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
        install = { image = local.install_image }
        kubelet = { nodeIP = { validSubnets = [var.subnet_cidr] } }
      }
      cluster = {
        etcd = { advertisedSubnets = [var.subnet_cidr] }
      }
    })
    worker = yamlencode({
      machine = {
        install = { image = local.install_image }
        kubelet = { nodeIP = { validSubnets = [var.subnet_cidr] } }
      }
    })
  }
}

data "talos_machine_configuration" "this" {
  for_each = local.nodes

  lifecycle {
    precondition {
      condition     = !(local.custom_installer && !local.registry_enabled)
      error_message = "talos_extensions при image_source = github требуют registry.enabled = true: собранный installer публикуется в Artifact Keeper."
    }
  }

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat([
    local.patch_common,
    local.patch_role[each.value.role],
    local.patch_dynamic[each.value.role],
    # Публичный IP узла за NAT не виден на интерфейсе, поэтому Talos сам
    # не добавит его в сертификат API. Добавляем явно.
    yamlencode({
      machine = {
        certSANs = [local.node_public_ip[each.key]]
      }
    }),
    # Генератор кладёт документ HostnameConfig с auto: stable, а поле
    # machine.network.hostname с ним конфликтует. Меняем документ целиком:
    # сначала удаляем сгенерированный, затем добавляем свой.
    <<-EOT
      apiVersion: v1alpha1
      kind: HostnameConfig
      $patch: delete
    EOT
    ,
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = each.key
    }),
    ],
    # Зеркала образов через Artifact Keeper (см. registry.tf).
    local.registry_enabled ? [local.patch_registry] : [],
    # Модули ядра DRBD для LINSTOR, если есть расширение drbd.
    contains(var.talos_extensions, "siderolabs/drbd") ? [file("${path.module}/patches/linstor.yaml")] : [],
  )
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
    # Installer и образы control plane тянутся через реестр, он должен быть готов.
    terraform_data.registry_repos,
    terraform_data.installer,
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
