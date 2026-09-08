# Два кластера Talos в одной VPC, но в разных подсетях: для Istio они
# объявляются разными сетями, и межкластерный трафик идёт через east-west
# gateway. Это единственная поддерживаемая конфигурация ambient-мультикластера.

locals {
  # Адреса: квота vpc.externalAddresses.count по умолчанию 8 и расходуется
  # целиком: 6 узлов, ВМ реестра и один NLB для ingress. Балансировщик перед
  # kube-apiserver не создаётся: при одном control plane он ничего не даёт,
  # а зарезервированный адрес закреплён прямо за узлом.
  cluster_defaults = {
    talos_version      = var.talos_version
    kubernetes_version = var.kubernetes_version
    platform_id        = var.platform_id
    core_fraction      = var.core_fraction
    zone               = var.zone
    network_id         = yandex_vpc_network.this.id
    security_group_id  = yandex_vpc_security_group.nodes.id
    image_id           = yandex_compute_image.talos.id
    install_image      = local.install_image
    patches_dir        = "${path.module}/patches"
  }

  # Патчи, общие для всех кластеров: зеркала реестра и модули ядра LINSTOR.
  common_extra_patches = concat(
    local.registry_enabled ? [local.patch_registry] : [],
    contains(var.talos_extensions, "siderolabs/drbd") ? [file("${path.module}/patches/linstor.yaml")] : [],
  )
}

module "cluster" {
  source   = "./modules/cluster"
  for_each = var.clusters

  name = each.key
  id   = each.value.id

  zone              = local.cluster_defaults.zone
  network_id        = local.cluster_defaults.network_id
  subnet_id         = yandex_vpc_subnet.this[each.key].id
  subnet_cidr       = each.value.subnet_cidr
  security_group_id = local.cluster_defaults.security_group_id
  image_id          = local.cluster_defaults.image_id

  pod_subnet     = each.value.pod_subnet
  service_subnet = each.value.service_subnet

  talos_version      = local.cluster_defaults.talos_version
  kubernetes_version = local.cluster_defaults.kubernetes_version
  install_image      = local.cluster_defaults.install_image

  controlplane   = each.value.controlplane
  worker         = each.value.worker
  platform_id    = local.cluster_defaults.platform_id
  core_fraction  = local.cluster_defaults.core_fraction
  boot_disk_type = each.value.boot_disk_type

  controlplane_static_ip = each.value.controlplane_static_ip ? yandex_vpc_address.controlplane[each.key].external_ipv4_address[0].address : null
  ingress_lb             = each.value.ingress_lb
  ingress_ip             = each.value.ingress_lb ? yandex_vpc_address.ingress[each.key].external_ipv4_address[0].address : null

  extra_patches = local.common_extra_patches
  patches_dir   = local.cluster_defaults.patches_dir
  scripts_dir   = "${path.module}/scripts"
  out_dir       = "${path.module}/out/${each.key}"

  depends_on = [
    yandex_vpc_security_group_rule.this,
    terraform_data.registry_repos,
    terraform_data.installer,
  ]
}
