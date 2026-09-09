variable "project_name" {
  description = "Общий префикс для VPC и security group."
  type        = string
  default     = "talos"
}

variable "clusters" {
  description = <<-EOT
    Кластеры Talos. Ключ карты — имя кластера, оно же cluster.name в Cilium
    и Istio. Подсети узлов, подов и сервисов у кластеров не должны
    пересекаться: для Istio это разные сети, трафик между ними идёт через
    east-west gateway.

    Учтите квоты: vpc.externalAddresses.count по умолчанию 8 (у каждого узла
    и у ВМ реестра свой NAT-адрес, NLB тоже занимает адрес), а
    ylb.networkLoadBalancers.count — 2.
  EOT
  type = map(object({
    id             = number
    subnet_cidr    = string
    pod_subnet     = string
    service_subnet = string
    controlplane = object({
      count   = number
      cores   = number
      memory  = number
      disk_gb = number
    })
    worker = object({
      count          = number
      cores          = number
      memory         = number
      disk_gb        = number
      data_disk_gb   = optional(number, 0)
      data_disk_type = optional(string, "network-hdd")
    })
    boot_disk_type        = optional(string, "network-ssd")
    controlplane_static_ip = optional(bool, false)
    ingress_lb            = optional(bool, false)
  }))

  validation {
    condition     = length(distinct([for c in var.clusters : c.id])) == length(var.clusters)
    error_message = "Идентификаторы кластеров должны быть уникальными."
  }
}

variable "zone" {
  description = "Зона доступности Yandex Cloud. Кластер поднимается в одной зоне."
  type        = string
  default     = "ru-central1-a"
}

variable "talos_version" {
  description = "Версия Talos Linux (тег образа на Image Factory)."
  type        = string
  default     = "v1.12.12"
}

variable "kubernetes_version" {
  description = "Версия Kubernetes. Задаём явно: провайдер Talos по умолчанию берёт версию из своего SDK, которая может быть новее, чем поддерживает talos_version."
  type        = string
  default     = "1.35.8"
}

variable "image_source" {
  description = "Откуда брать образ Talos: github (ванильный metal-amd64.raw.zst, конвертация в qcow2 локально) или factory (Image Factory с расширениями; из РФ качается очень медленно)."
  type        = string
  default     = "github"

  validation {
    condition     = contains(["github", "factory"], var.image_source)
    error_message = "image_source: github или factory."
  }
}

variable "talos_extensions" {
  description = "Системные расширения Talos (имена из каталога siderolabs/extensions, например siderolabs/drbd). При image_source = github installer с ними собирается локально через imager и кладётся в Artifact Keeper (см. registry.tf), при image_source = factory их включает Image Factory."
  type        = list(string)
  default     = []
}

variable "installer_image" {
  description = "Готовый образ installer вместо автоматически собранного/стандартного. null = вычислить из image_source и talos_extensions."
  type        = string
  default     = null
}

variable "platform_id" {
  description = "Платформа ВМ Yandex Cloud."
  type        = string
  default     = "standard-v3"
}

variable "core_fraction" {
  description = "Гарантированная доля vCPU (20/50/100). 100 для production."
  type        = number
  default     = 100
}

variable "auto_admin_ip" {
  description = "Добавлять текущий публичный IPv4 машины, с которой запущен tofu, в правила для Talos API и реестра. Провайдеры часто меняют адрес, а симптомы выглядят как зависший узел."
  type        = bool
  default     = true
}

variable "admin_cidrs" {
  description = "Откуда разрешён доступ к Talos API (порт 50000) и к реестру. Текущий адрес машины добавляется автоматически, см. auto_admin_ip; здесь перечисляют постоянные адреса, например офисные."
  type        = list(string)
  default     = []
}

variable "apiserver_allowed_cidrs" {
  description = "Откуда разрешён доступ к kube-apiserver (порт 6443) через балансировщик."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "registry" {
  description = "Artifact Keeper: кэширующий прокси образов (Docker/OCI) и Helm-чартов на отдельной ВМ в той же подсети. Узлы Talos тянут все образы через него (machine.registries.mirrors), Argo CD берёт чарты."
  type = object({
    enabled     = bool
    version     = string # тег образа backend (без v)
    web_version = string # у образа web нет релизных тегов, только latest
    cores       = number
    memory      = number
    disk_gb     = number
    disk_type   = optional(string, "network-hdd") # артефакты лежат в Object Storage, SSD-квоту не тратим
    cluster     = optional(string)                # в подсети какого кластера жить; по умолчанию первый
  })
  default = {
    enabled     = true
    version     = "1.8.2"
    web_version = "latest"
    cores       = 2
    memory      = 4
    disk_gb     = 30
  }
}

variable "registry_ssh_public_key" {
  description = "Публичный SSH-ключ для пользователя ubuntu на ВМ реестра (порт 22 открыт для admin_cidrs). null = без SSH."
  type        = string
  default     = null
}

variable "registry_docker_mirrors" {
  description = "Зеркала OCI-реестров: хост -> upstream. На каждый хост создаётся remote-репозиторий Artifact Keeper с ключом из имени, а в Talos добавляется machine.registries.mirrors."
  type        = map(string)
  default = {
    "docker.io"       = "https://registry-1.docker.io"
    "ghcr.io"         = "https://ghcr.io"
    "registry.k8s.io" = "https://registry.k8s.io"
    "quay.io"         = "https://quay.io"
    "gcr.io"          = "https://gcr.io"
  }
}

variable "registry_helm_repos" {
  description = "Remote Helm-репозитории: ключ -> upstream. В Chart.yaml umbrella-чартов repository указывает на http://<registry>/helm/<ключ>."
  type        = map(string)
  default = {
    "helm-argo"           = "https://argoproj.github.io/argo-helm"
    "helm-cilium"         = "https://helm.cilium.io"
    "helm-jetstack"       = "https://charts.jetstack.io"
    "helm-metrics-server" = "https://kubernetes-sigs.github.io/metrics-server/"
    "helm-traefik"        = "https://traefik.github.io/charts"
    "helm-istio"          = "https://istio-release.storage.googleapis.com/charts"
  }
}
