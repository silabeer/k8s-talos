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
      image_id = yandex_compute_image.talos.id
      size     = each.value.disk_gb
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.this.id
    ip_address         = each.value.ip
    nat                = true
    nat_ip_address     = var.node_static_ips ? yandex_vpc_address.node[each.key].external_ipv4_address[0].address : null
    security_group_ids = [yandex_vpc_security_group.nodes.id]
  }

  metadata = {
    serial-port-enable = "1"
  }

  labels = {
    cluster = var.cluster_name
    role    = each.value.role
  }

  lifecycle {
    # Обновление Talos делается через `talosctl upgrade`, а не пересозданием ВМ.
    ignore_changes = [boot_disk[0].initialize_params[0].image_id]
  }
}
