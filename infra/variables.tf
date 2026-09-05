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
  description = "Версия Kubernetes. null = версия по умолчанию для данного Talos."
  type        = string
  default     = null
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
  description = "Системные расширения Talos для Image Factory. Учитываются только при image_source = factory."
  type        = list(string)
  default     = ["siderolabs/qemu-guest-agent"]
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
  description = "Параметры worker узлов."
  type = object({
    count   = number
    cores   = number
    memory  = number
    disk_gb = number
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
