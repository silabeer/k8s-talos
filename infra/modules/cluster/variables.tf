variable "name" {
  description = "Имя кластера. Префикс всех ресурсов и cluster.name в Cilium/Istio."
  type        = string
}

variable "id" {
  description = "Числовой идентификатор кластера, уникальный в пределах меша (1..255)."
  type        = number
}

variable "zone" {
  type = string
}

variable "network_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "subnet_cidr" {
  description = "CIDR подсети кластера: kubelet nodeIP и etcd advertisedSubnets."
  type        = string
}

variable "security_group_id" {
  type = string
}

variable "image_id" {
  description = "Образ Talos."
  type        = string
}

variable "pod_subnet" {
  type = string
}

variable "service_subnet" {
  type = string
}

variable "talos_version" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "install_image" {
  description = "machine.install.image: используется при установке и talosctl upgrade."
  type        = string
}

variable "controlplane" {
  type = object({
    count   = number
    cores   = number
    memory  = number
    disk_gb = number
  })
}

variable "worker" {
  type = object({
    count          = number
    cores          = number
    memory         = number
    disk_gb        = number
    data_disk_gb   = optional(number, 0)
    data_disk_type = optional(string, "network-hdd")
  })
}

variable "platform_id" {
  type = string
}

variable "core_fraction" {
  type = number
}

variable "boot_disk_type" {
  description = "Тип загрузочного диска узлов."
  type        = string
  default     = "network-ssd"
}

variable "controlplane_static_ip" {
  description = "Зарезервированный публичный адрес для первого control plane. null = динамический NAT-адрес, который меняется при stop/start."
  type        = string
  default     = null
}

variable "ingress_lb" {
  description = "Создавать NLB для ingress. Отдельный флаг от адреса: count не может зависеть от атрибута ресурса."
  type        = bool
  default     = false
}

variable "ingress_ip" {
  description = "Зарезервированный адрес для NLB ingress."
  type        = string
  default     = null
}

variable "extra_patches" {
  description = "Дополнительные патчи machine config (зеркала реестра, модули ядра и т.п.)."
  type        = list(string)
  default     = []
}

variable "patches_dir" {
  description = "Каталог с common.yaml, controlplane.yaml, worker.yaml."
  type        = string
}

variable "out_dir" {
  description = "Куда положить kubeconfig и talosconfig."
  type        = string
}

variable "scripts_dir" {
  description = "Каталог вспомогательных скриптов."
  type        = string
}
