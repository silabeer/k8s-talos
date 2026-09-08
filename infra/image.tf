# Источник образа. factory.talos.dev из РФ отдаёт ~2 КБ/с, поэтому по умолчанию
# ванильный образ с GitHub (metal-amd64.raw.zst -> qcow2 через qemu-img).
# Image Factory нужна только ради системных расширений (talos_extensions).
data "http" "schematic" {
  count = var.image_source == "factory" ? 1 : 0

  url    = "https://factory.talos.dev/schematics"
  method = "POST"
  request_body = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = var.talos_extensions
      }
    }
  })
}

data "yandex_client_config" "this" {}

locals {
  use_factory  = var.image_source == "factory"
  schematic_id = local.use_factory ? jsondecode(data.http.schematic[0].response_body).id : null
  version_slug = replace(trimprefix(var.talos_version, "v"), ".", "-")

  installer_image = local.use_factory ? "factory.talos.dev/installer/${local.schematic_id}:${var.talos_version}" : "ghcr.io/siderolabs/installer:${var.talos_version}"

  # machine.install.image применяется только при установке или `talosctl upgrade`,
  # а узлы в Yandex грузятся с готового образа диска. Поэтому при непустом
  # talos_extensions дисковый образ собирается локально (imager, профиль metal),
  # а не качается ванильным с GitHub: иначе расширений на узлах не будет.
  build_image = !local.use_factory && length(var.talos_extensions) > 0
  image_tag   = local.use_factory ? substr(local.schematic_id, 0, 8) : (local.build_image ? "ext-${substr(sha1(join(",", sort(var.talos_extensions))), 0, 8)}" : "vanilla")

  image_slug  = "talos-${local.version_slug}-${local.image_tag}"
  image_file  = "${local.image_slug}-metal-amd64.qcow2"
  image_cache = "${path.module}/.cache/${local.image_file}"
  bucket_name = "${var.cluster_name}-talos-images-${substr(sha1(data.yandex_client_config.this.folder_id), 0, 10)}"

  image_url = local.use_factory ? "https://factory.talos.dev/image/${local.schematic_id}/${var.talos_version}/metal-amd64.qcow2" : "https://github.com/siderolabs/talos/releases/download/${var.talos_version}/metal-amd64.raw.zst"

  # Оба пути дают raw.zst, дальше одинаково: распаковка и конвертация в qcow2.
  image_fetch_cmd = local.build_image ? join(" ", [
    "TALOS_VERSION='${var.talos_version}'",
    "EXTENSIONS='${join(" ", var.talos_extensions)}'",
    "OUT='${local.image_cache}.raw.zst'",
    "${path.module}/scripts/build-image.sh",
  ]) : "curl -fSL -o '${local.image_cache}.raw.zst' '${local.image_url}'"

  image_download_cmd = local.use_factory ? "curl -fSL -o '${local.image_cache}' '${local.image_url}'" : join(" && ", [
    local.image_fetch_cmd,
    "zstd -d -f -q --sparse -o '${local.image_cache}.raw' '${local.image_cache}.raw.zst'",
    "qemu-img convert -f raw -O qcow2 '${local.image_cache}.raw' '${local.image_cache}'",
    "rm -f '${local.image_cache}.raw' '${local.image_cache}.raw.zst'",
  ])
}

# Compute Cloud принимает образы только по ссылке на Object Storage,
# поэтому qcow2 с Image Factory сначала кладём в бакет.
resource "yandex_iam_service_account" "images" {
  name        = "${var.cluster_name}-images"
  description = "Загрузка образов Talos в Object Storage"
}

resource "yandex_resourcemanager_folder_iam_member" "images" {
  folder_id = data.yandex_client_config.this.folder_id
  role      = "storage.admin"
  member    = "serviceAccount:${yandex_iam_service_account.images.id}"
}

resource "yandex_iam_service_account_static_access_key" "images" {
  service_account_id = yandex_iam_service_account.images.id
}

# Права IAM применяются не мгновенно.
resource "terraform_data" "iam_propagation" {
  depends_on       = [yandex_resourcemanager_folder_iam_member.images]
  triggers_replace = yandex_iam_service_account.images.id

  provisioner "local-exec" {
    command = "sleep 20"
  }
}

resource "yandex_storage_bucket" "images" {
  depends_on = [terraform_data.iam_propagation]

  bucket     = local.bucket_name
  access_key = yandex_iam_service_account_static_access_key.images.access_key
  secret_key = yandex_iam_service_account_static_access_key.images.secret_key

  # Compute Cloud забирает образ по публичной ссылке.
  anonymous_access_flags {
    read = true
    list = false
  }

  force_destroy = true
}

resource "terraform_data" "image_download" {
  triggers_replace = local.image_cache

  provisioner "local-exec" {
    command = "test -s '${local.image_cache}' || (mkdir -p '${dirname(local.image_cache)}' && ${local.image_download_cmd})"
  }
}

resource "yandex_storage_object" "talos" {
  depends_on = [terraform_data.image_download]

  bucket       = yandex_storage_bucket.images.bucket
  key          = local.image_file
  source       = local.image_cache
  content_type = "application/octet-stream"
  acl          = "public-read"
  access_key   = yandex_iam_service_account_static_access_key.images.access_key
  secret_key   = yandex_iam_service_account_static_access_key.images.secret_key
}

resource "yandex_compute_image" "talos" {
  name          = local.image_slug
  description   = "Talos Linux ${var.talos_version}, ${local.use_factory ? "schematic ${local.schematic_id}" : (local.build_image ? "локальная сборка с расширениями: ${join(", ", var.talos_extensions)}" : "vanilla image from GitHub")}"
  source_url    = "https://storage.yandexcloud.net/${yandex_storage_bucket.images.bucket}/${yandex_storage_object.talos.key}"
  os_type       = "LINUX"
  min_disk_size = 10
  pooled        = false

  labels = {
    talos_version = trimprefix(var.talos_version, "v")
    source        = local.image_tag
  }
}
