locals {
  controlplanes = {
    for i in range(var.controlplane.count) :
    format("%s-cp-%d", var.cluster_name, i + 1) => {
      role    = "controlplane"
      ip      = cidrhost(var.subnet_cidr, 10 + i)
      cores   = var.controlplane.cores
      memory  = var.controlplane.memory
      disk_gb = var.controlplane.disk_gb
    }
  }

  workers = {
    for i in range(var.worker.count) :
    format("%s-w-%d", var.cluster_name, i + 1) => {
      role    = "worker"
      ip      = cidrhost(var.subnet_cidr, 100 + i)
      cores   = var.worker.cores
      memory  = var.worker.memory
      disk_gb = var.worker.disk_gb
    }
  }

  nodes = merge(local.controlplanes, local.workers)

  first_controlplane = sort(keys(local.controlplanes))[0]

  api_ip     = yandex_vpc_address.api.external_ipv4_address[0].address
  ingress_ip = yandex_vpc_address.ingress.external_ipv4_address[0].address

  # Публичный IP берём с ВМ: при node_static_ips это зарезервированный адрес,
  # иначе динамический NAT-IP, который известен только после создания ВМ.
  node_public_ip = {
    for name, vm in yandex_compute_instance.node : name => vm.network_interface[0].nat_ip_address
  }

  cluster_endpoint = "https://${local.api_ip}:6443"
}
