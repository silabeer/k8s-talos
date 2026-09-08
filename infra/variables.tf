variable "cluster_name" {
  description = "Имя кластера. Используется как префикс для всех ресурсов."
  type        = string
  default     = "talos"
}

variable "zone" {
  description = "Зона доступности Yandex Cloud. Кластер поднимается в одной зоне."
  type        = string
  default     = "ru-central1-a"
}

variable "subnet_cidr" {
  description = "CIDR подсети для узлов кластера."
  type        = string
  default     = "10.10.0.0/24"
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

variable "controlplane" {
  description = "Параметры control-plane узлов."
  type = object({
    count   = number
    cores   = number
    memory  = number
    disk_gb = number
  })
  default = {
    count   = 3
    cores   = 2
    memory  = 4
    disk_gb = 20
  }

  validation {
    condition     = var.controlplane.count % 2 == 1
    error_message = "Количество control-plane узлов должно быть нечётным (кворум etcd)."
  }
}

variable "worker" {
  description = "Параметры worker узлов. data_disk_gb > 0 добавляет отдельный диск (/dev/vdb) под LINSTOR."
  type = object({
    count        = number
    cores        = number
    memory       = number
    disk_gb      = number
    data_disk_gb = optional(number, 0)
  })
  default = {
    count   = 2
    cores   = 2
    memory  = 4
    disk_gb = 40
  }

  validation {
    condition     = var.worker.count >= 1
    error_message = "Нужен хотя бы один worker: на них живёт ingress и на них смотрит балансировщик."
  }
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

variable "node_static_ips" {
  description = "Резервировать статический публичный IP на каждый узел. Квота vpc.externalStaticAddresses.count по умолчанию 2 (уходят на балансировщики), так что включайте после её увеличения."
  type        = bool
  default     = false
}

variable "admin_cidrs" {
  description = "Откуда разрешён доступ к Talos API (порт 50000). Обычно ваш публичный IP /32."
  type        = list(string)
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
  }
}
