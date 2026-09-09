# Текущий публичный адрес машины, с которой запускается tofu. Хост
# ipv4.icanhazip.com имеет только A-запись, поэтому ответ гарантированно
# IPv4: у провайдера http нет способа запретить IPv6, а адрес IPv6 сломал бы
# маску /32.
data "http" "my_ip" {
  count = var.auto_admin_ip ? 1 : 0

  url = "https://ipv4.icanhazip.com"

  retry {
    attempts     = 3
    min_delay_ms = 500
  }
}

locals {
  admin_cidrs = distinct(concat(
    var.admin_cidrs,
    var.auto_admin_ip ? ["${trimspace(data.http.my_ip[0].response_body)}/32"] : [],
  ))
}

resource "yandex_vpc_network" "this" {
  name = var.project_name
}

# По подсети на кластер: адреса узлов не должны пересекаться, а Istio
# объявляет кластеры разными сетями.
resource "yandex_vpc_subnet" "this" {
  for_each = var.clusters

  name           = "${each.key}-${var.zone}"
  zone           = var.zone
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = [each.value.subnet_cidr]
}

# Зарезервированный публичный адрес на первый control plane: он же cluster
# endpoint, и при динамическом NAT он менялся бы после stop/start ВМ.
resource "yandex_vpc_address" "controlplane" {
  for_each = { for k, c in var.clusters : k => c if c.controlplane_static_ip }

  name = "${each.key}-cp"
  external_ipv4_address {
    zone_id = var.zone
  }
}

resource "yandex_vpc_address" "ingress" {
  for_each = { for k, c in var.clusters : k => c if c.ingress_lb }

  name = "${each.key}-ingress"
  external_ipv4_address {
    zone_id = var.zone
  }
}

resource "yandex_vpc_security_group" "nodes" {
  name       = "${var.project_name}-nodes"
  network_id = yandex_vpc_network.this.id
}

# Все правила отдельными ресурсами: провайдер не любит смешивать inline-правила
# и yandex_vpc_security_group_rule в одной группе.
locals {
  sg_rules = merge(
    {
      internal = {
        direction         = "ingress"
        protocol          = "ANY"
        from_port         = 0
        to_port           = 65535
        predefined_target = "self_security_group"
        description       = "Весь трафик между узлами обоих кластеров и реестром"
      }
      egress = {
        direction      = "egress"
        protocol       = "ANY"
        from_port      = 0
        to_port        = 65535
        v4_cidr_blocks = ["0.0.0.0/0"]
        description    = "Исходящий трафик без ограничений"
      }
      talos_api = {
        direction      = "ingress"
        protocol       = "TCP"
        port           = 50000
        v4_cidr_blocks = local.admin_cidrs
        description    = "Talos API для администратора и tofu"
      }
      kube_api = {
        direction      = "ingress"
        protocol       = "TCP"
        port           = 6443
        v4_cidr_blocks = var.apiserver_allowed_cidrs
        # Сюда же ходят сами узлы: cluster endpoint — публичный адрес control
        # plane, и через NAT источником оказывается публичный адрес узла.
        # Если сужаете список, добавьте в него адреса узлов обоих кластеров.
        description = "kube-apiserver: узлы, kubectl и istiod соседнего кластера"
      }
      ingress_http = {
        direction      = "ingress"
        protocol       = "TCP"
        port           = 30080
        v4_cidr_blocks = ["0.0.0.0/0"]
        description    = "HTTP через NLB -> NodePort Traefik"
      }
      ingress_https = {
        direction      = "ingress"
        protocol       = "TCP"
        port           = 30443
        v4_cidr_blocks = ["0.0.0.0/0"]
        description    = "HTTPS через NLB -> NodePort Traefik"
      }
      ingress_healthcheck = {
        direction         = "ingress"
        protocol          = "TCP"
        from_port         = 30080
        to_port           = 30443
        predefined_target = "loadbalancer_healthchecks"
        description       = "Health check NLB"
      }
    },
    var.registry.enabled ? {
      registry_http = {
        direction      = "ingress"
        protocol       = "TCP"
        port           = 80
        v4_cidr_blocks = local.admin_cidrs
        description    = "Artifact Keeper: UI/API для администратора и tofu"
      }
      registry_ssh = {
        direction      = "ingress"
        protocol       = "TCP"
        port           = 22
        v4_cidr_blocks = local.admin_cidrs
        description    = "SSH на ВМ реестра"
      }
    } : {}
  )
}

resource "yandex_vpc_security_group_rule" "this" {
  for_each = local.sg_rules

  security_group_binding = yandex_vpc_security_group.nodes.id
  direction              = each.value.direction
  protocol               = each.value.protocol
  description            = each.value.description

  port      = lookup(each.value, "port", null)
  from_port = lookup(each.value, "from_port", null)
  to_port   = lookup(each.value, "to_port", null)

  v4_cidr_blocks    = lookup(each.value, "v4_cidr_blocks", null)
  predefined_target = lookup(each.value, "predefined_target", null)
}
