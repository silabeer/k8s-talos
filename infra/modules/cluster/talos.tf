resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

locals {
  patch_common = file("${var.patches_dir}/common.yaml")
  patch_role = {
    controlplane = file("${var.patches_dir}/controlplane.yaml")
    worker       = file("${var.patches_dir}/worker.yaml")
  }

  # Подсети подов и сервисов у кластеров меша не должны пересекаться.
  patch_dynamic = {
    controlplane = yamlencode({
      machine = {
        install = { image = var.install_image }
        kubelet = { nodeIP = { validSubnets = [var.subnet_cidr] } }
      }
      cluster = {
        etcd = { advertisedSubnets = [var.subnet_cidr] }
        network = {
          podSubnets     = [var.pod_subnet]
          serviceSubnets = [var.service_subnet]
        }
      }
    })
    worker = yamlencode({
      machine = {
        install = { image = var.install_image }
        kubelet = { nodeIP = { validSubnets = [var.subnet_cidr] } }
      }
      cluster = {
        network = {
          podSubnets     = [var.pod_subnet]
          serviceSubnets = [var.service_subnet]
        }
      }
    })
  }
}

data "talos_machine_configuration" "this" {
  for_each = local.nodes

  cluster_name       = var.name
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
    # machine.network.hostname с ним конфликтует. Меняем документ целиком.
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
    var.extra_patches,
  )
}

data "talos_client_configuration" "this" {
  cluster_name         = var.name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for name in keys(local.controlplanes) : local.node_public_ip[name]]
  nodes                = [for node in local.nodes : node.ip]
}

# Узлы загружаются в maintenance mode и ждут конфиг по API (порт 50000).
# Перед применением конфига дожидаемся порта: провайдер talos на зависшем
# узле отдаёт "i/o timeout" без имени узла, а скрипт называет виновника.
resource "terraform_data" "wait_api" {
  depends_on = [yandex_compute_instance.node]

  triggers_replace = { for name, vm in yandex_compute_instance.node : name => vm.id }

  provisioner "local-exec" {
    command = "${var.scripts_dir}/wait-talos-api.sh"
    environment = {
      NODES = join(" ", [for name, ip in local.node_public_ip : "${name}=${ip}"])
    }
  }
}

resource "talos_machine_configuration_apply" "this" {
  for_each = local.nodes

  depends_on = [terraform_data.wait_api]

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

# `make infra` не должен отдавать управление, пока control plane не готов.
resource "terraform_data" "wait_apiserver" {
  depends_on = [talos_cluster_kubeconfig.this]

  triggers_replace = talos_machine_bootstrap.this.id

  provisioner "local-exec" {
    command = "${var.scripts_dir}/wait-apiserver.sh"
    environment = {
      CLUSTER  = var.name
      ENDPOINT = local.cluster_endpoint
    }
  }
}

resource "local_sensitive_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${var.out_dir}/kubeconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${var.out_dir}/talosconfig"
  file_permission = "0600"
}
