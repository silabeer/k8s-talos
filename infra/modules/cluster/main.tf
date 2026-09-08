# Один кластер Talos: узлы, диски данных, machine config, bootstrap.
# Общие для всех кластеров ресурсы (VPC, образ, реестр) живут в корне.

terraform {
  required_providers {
    yandex = { source = "registry.terraform.io/yandex-cloud/yandex" }
    talos  = { source = "registry.terraform.io/siderolabs/talos" }
    local  = { source = "registry.terraform.io/hashicorp/local" }
  }
}

locals {
  controlplanes = {
    for i in range(var.controlplane.count) :
    format("%s-cp-%d", var.name, i + 1) => {
      role    = "controlplane"
      ip      = cidrhost(var.subnet_cidr, 10 + i)
      cores   = var.controlplane.cores
      memory  = var.controlplane.memory
      disk_gb = var.controlplane.disk_gb
      # Статический адрес только у первого control plane: он же cluster endpoint.
      nat_ip = i == 0 ? var.controlplane_static_ip : null
    }
  }

  workers = {
    for i in range(var.worker.count) :
    format("%s-w-%d", var.name, i + 1) => {
      role    = "worker"
      ip      = cidrhost(var.subnet_cidr, 100 + i)
      cores   = var.worker.cores
      memory  = var.worker.memory
      disk_gb = var.worker.disk_gb
      nat_ip  = null
    }
  }

  nodes              = merge(local.controlplanes, local.workers)
  first_controlplane = sort(keys(local.controlplanes))[0]

  node_public_ip = {
    for name, vm in yandex_compute_instance.node : name => vm.network_interface[0].nat_ip_address
  }

  # При одном control plane балансировщик перед kube-apiserver не нужен:
  # endpoint — публичный адрес самого узла (зарезервированный, если задан).
  cluster_endpoint = "https://${local.node_public_ip[local.first_controlplane]}:6443"
}

# Диск под LINSTOR, в Talos виден как /dev/vdb.
resource "yandex_compute_disk" "data" {
  for_each = var.worker.data_disk_gb > 0 ? local.workers : {}

  name = "${each.key}-data"
  zone = var.zone
  type = var.worker.data_disk_type
  size = var.worker.data_disk_gb

  labels = {
    cluster = var.name
    role    = "data"
  }
}

resource "yandex_compute_instance" "node" {
  for_each = local.nodes

  name                      = each.key
  hostname                  = each.key
  zone                      = var.zone
  platform_id               = var.platform_id
  allow_stopping_for_update = true

  resources {
    cores         = each.value.cores
    memory        = each.value.memory
    core_fraction = var.core_fraction
  }

  boot_disk {
    initialize_params {
      image_id = var.image_id
      size     = each.value.disk_gb
      type     = var.boot_disk_type
    }
  }

  dynamic "secondary_disk" {
    for_each = each.value.role == "worker" && var.worker.data_disk_gb > 0 ? [1] : []
    content {
      disk_id     = yandex_compute_disk.data[each.key].id
      device_name = "data"
      auto_delete = false
    }
  }

  network_interface {
    subnet_id          = var.subnet_id
    ip_address         = each.value.ip
    nat                = true
    nat_ip_address     = each.value.nat_ip
    security_group_ids = [var.security_group_id]
  }

  metadata = {
    serial-port-enable = "1"
  }

  labels = {
    cluster = var.name
    role    = each.value.role
  }

  lifecycle {
    # Обновление Talos делается через `talosctl upgrade`, а не пересозданием ВМ.
    ignore_changes = [boot_disk[0].initialize_params[0].image_id]
  }
}

# Ingress: NLB на worker-узлы, NodePort Traefik 30080/30443.
resource "yandex_lb_target_group" "workers" {
  count = var.ingress_lb ? 1 : 0

  name = "${var.name}-workers"

  dynamic "target" {
    for_each = local.workers
    content {
      subnet_id = var.subnet_id
      address   = target.value.ip
    }
  }
}

resource "yandex_lb_network_load_balancer" "ingress" {
  count = var.ingress_lb ? 1 : 0

  name = "${var.name}-ingress"
  type = "external"

  listener {
    name        = "http"
    port        = 80
    target_port = 30080
    protocol    = "tcp"
    external_address_spec {
      address    = var.ingress_ip
      ip_version = "ipv4"
    }
  }

  listener {
    name        = "https"
    port        = 443
    target_port = 30443
    protocol    = "tcp"
    external_address_spec {
      address    = var.ingress_ip
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.workers[0].id

    healthcheck {
      name                = "tcp-30080"
      interval            = 5
      timeout             = 2
      healthy_threshold   = 2
      unhealthy_threshold = 2
      tcp_options {
        port = 30080
      }
    }
  }
}
