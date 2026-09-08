# Artifact Keeper: кэширующий прокси для образов (Docker/OCI) и Helm-чартов.
# Живёт на отдельной ВМ в той же подсети, потому что нужен раньше кластера:
# Talos тянет через него installer, kubelet и образы control plane.
# Артефакты хранятся в Object Storage, ВМ можно пересоздавать без потери кэша.

data "yandex_compute_image" "ubuntu" {
  count  = var.registry.enabled ? 1 : 0
  family = "ubuntu-2404-lts"
}

locals {
  registry_enabled = var.registry.enabled
  registry_ip      = cidrhost(var.subnet_cidr, 5)
  registry_url     = "http://${local.registry_ip}"
  registry_bucket  = "${var.cluster_name}-registry-${substr(sha1(data.yandex_client_config.this.folder_id), 0, 10)}"

  registry_public_ip  = local.registry_enabled ? yandex_compute_instance.registry[0].network_interface[0].nat_ip_address : null
  registry_public_url = local.registry_enabled ? "http://${local.registry_public_ip}" : null

  # Ключ репозитория из имени хоста: docker.io -> docker-io.
  registry_docker_key = { for host in keys(var.registry_docker_mirrors) : host => replace(host, ".", "-") }

  registry_repos = concat(
    [for host, upstream in var.registry_docker_mirrors : {
      key          = local.registry_docker_key[host]
      name         = "Proxy ${host}"
      format       = "docker"
      repo_type    = "remote"
      upstream_url = upstream
    }],
    [for key, upstream in var.registry_helm_repos : {
      key          = key
      name         = "Proxy ${upstream}"
      format       = "helm"
      repo_type    = "remote"
      upstream_url = upstream
    }],
    # Hosted-репозиторий для собранных installer Talos: <ip>/talos/installer:<tag>.
    [{
      key          = "talos"
      name         = "Talos installers"
      format       = "docker"
      repo_type    = "local"
      upstream_url = null
    }],
  )

  # Installer с расширениями: собирается локально (scripts/build-installer.sh)
  # и публикуется в hosted-репозиторий talos. Тег зависит от версии и набора расширений.
  custom_installer = length(var.talos_extensions) > 0 && !local.use_factory && var.installer_image == null
  installer_tag    = "${var.talos_version}-${substr(sha1(join(",", sort(var.talos_extensions))), 0, 8)}"
  install_image    = coalesce(var.installer_image, local.custom_installer ? "${local.registry_ip}/talos/installer:${local.installer_tag}" : local.installer_image)

  # Патч Talos: все образы через реестр. overridePath: containerd ходит ровно по
  # указанному пути, без добавления /v2. При недоступности реестра containerd
  # откатывается на upstream (skipFallback по умолчанию false).
  patch_registry = yamlencode({
    machine = {
      registries = {
        mirrors = merge(
          {
            for host, key in local.registry_docker_key : host => {
              endpoints    = ["${local.registry_url}/v2/${key}"]
              overridePath = true
            }
          },
          # Сам реестр по HTTP (hosted-репозиторий talos): без этого containerd
          # пойдёт к 10.10.0.5 по HTTPS.
          { (local.registry_ip) = { endpoints = [local.registry_url] } },
        )
      }
    }
  })
}

resource "random_password" "registry_admin" {
  count   = local.registry_enabled ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "registry_jwt" {
  count   = local.registry_enabled ? 1 : 0
  length  = 48
  special = false
}

resource "random_password" "registry_db" {
  count   = local.registry_enabled ? 1 : 0
  length  = 24
  special = false
}

resource "yandex_storage_bucket" "registry" {
  count      = local.registry_enabled ? 1 : 0
  depends_on = [terraform_data.iam_propagation]

  bucket     = local.registry_bucket
  access_key = yandex_iam_service_account_static_access_key.images.access_key
  secret_key = yandex_iam_service_account_static_access_key.images.secret_key

  force_destroy = true

  # Artifact Keeper не убирает за собой незавершённые записи кэша.
  lifecycle_rule {
    id      = "proxy-cache-staging"
    enabled = true
    filter {
      prefix = "proxy-cache-staging/"
    }
    expiration {
      days = 1
    }
  }
}

resource "yandex_compute_instance" "registry" {
  count = local.registry_enabled ? 1 : 0

  name                      = "${var.cluster_name}-registry"
  hostname                  = "${var.cluster_name}-registry"
  zone                      = var.zone
  platform_id               = var.platform_id
  allow_stopping_for_update = true

  resources {
    cores         = var.registry.cores
    memory        = var.registry.memory
    core_fraction = var.core_fraction
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu[0].id
      size     = var.registry.disk_gb
      type     = var.registry.disk_type
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.this.id
    ip_address         = local.registry_ip
    nat                = true
    security_group_ids = [yandex_vpc_security_group.nodes.id]
  }

  metadata = {
    serial-port-enable = "1"
    ssh-keys           = var.registry_ssh_public_key == null ? null : "ubuntu:${var.registry_ssh_public_key}"
    user-data = templatefile("${path.module}/templates/registry-cloud-init.yaml", {
      version        = var.registry.version
      web_version    = var.registry.web_version
      private_url    = local.registry_url
      admin_password = random_password.registry_admin[0].result
      jwt_secret     = random_password.registry_jwt[0].result
      db_password    = random_password.registry_db[0].result
      s3_bucket      = yandex_storage_bucket.registry[0].bucket
      s3_access_key  = yandex_iam_service_account_static_access_key.images.access_key
      s3_secret_key  = yandex_iam_service_account_static_access_key.images.secret_key
    })
  }

  labels = {
    cluster = var.cluster_name
    role    = "registry"
  }

  lifecycle {
    ignore_changes = [boot_disk[0].initialize_params[0].image_id]
  }
}

# Remote-репозитории создаются через REST API с рабочей машины (порт 80 открыт
# для admin_cidrs). Скрипт идемпотентный: существующие репозитории пропускает.
resource "terraform_data" "registry_repos" {
  count = local.registry_enabled ? 1 : 0

  depends_on = [yandex_vpc_security_group_rule.this]

  input = {
    instance = yandex_compute_instance.registry[0].id
    repos    = local.registry_repos
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/registry-setup.sh"
    environment = {
      REGISTRY_URL   = local.registry_public_url
      ADMIN_PASSWORD = random_password.registry_admin[0].result
      REPOS          = jsonencode(local.registry_repos)
    }
  }
}

# Сборка installer с расширениями: imager в docker + crane push на публичный адрес
# реестра. Кэш тарболов в .cache/installer, повторно не собирается и не пушится.
resource "terraform_data" "installer" {
  count = local.registry_enabled && local.custom_installer ? 1 : 0

  depends_on = [terraform_data.registry_repos]

  input = {
    image      = local.install_image
    extensions = var.talos_extensions
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/build-installer.sh"
    environment = {
      TALOS_VERSION  = var.talos_version
      EXTENSIONS     = join(" ", var.talos_extensions)
      IMAGE          = "${local.registry_public_ip}/talos/installer:${local.installer_tag}"
      ADMIN_PASSWORD = random_password.registry_admin[0].result
      CACHE_DIR      = "${path.module}/.cache/installer"
    }
  }
}
