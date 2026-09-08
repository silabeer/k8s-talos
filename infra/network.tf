resource "yandex_vpc_network" "this" {
  name = var.cluster_name
}

resource "yandex_vpc_subnet" "this" {
  name           = "${var.cluster_name}-${var.zone}"
  zone           = var.zone
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = [var.subnet_cidr]
}

# Статические публичные адреса: endpoint kube-apiserver и вход ingress.
resource "yandex_vpc_address" "api" {
  name = "${var.cluster_name}-api"
  external_ipv4_address {
    zone_id = var.zone
  }
}

resource "yandex_vpc_address" "ingress" {
  name = "${var.cluster_name}-ingress"
  external_ipv4_address {
    zone_id = var.zone
  }
}

# Опционально: статический публичный IP на каждый узел (см. var.node_static_ips).
# Без него узел получает динамический NAT-IP: после stop/start ВМ он поменяется,
# и нужно будет повторить `make infra`, чтобы обновить certSANs Talos API.
resource "yandex_vpc_address" "node" {
  for_each = var.node_static_ips ? local.nodes : {}

  name = each.key
  external_ipv4_address {
    zone_id = var.zone
  }
}

resource "yandex_vpc_security_group" "nodes" {
  name       = "${var.cluster_name}-nodes"
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
        description       = "Весь трафик между узлами кластера"
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
        v4_cidr_blocks = var.admin_cidrs
        description    = "Talos API для администратора и terraform"
      }
      kube_api = {
        direction      = "ingress"
        protocol       = "TCP"
        port           = 6443
        v4_cidr_blocks = var.apiserver_allowed_cidrs
        description    = "kube-apiserver через NLB"
      }
      kube_api_from_nodes = {
        direction      = "ingress"
        protocol       = "TCP"
        port           = 6443
        v4_cidr_blocks = [for ip in local.node_public_ip : "${ip}/32"]
        description    = "Узлы ходят на публичный endpoint через NAT"
      }
      kube_api_healthcheck = {
        direction         = "ingress"
        protocol          = "TCP"
        port              = 6443
        predefined_target = "loadbalancer_healthchecks"
        description       = "Health check NLB"
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
    # ВМ реестра в той же группе: узлы ходят к ней по правилу internal.
    var.registry.enabled ? {
      registry_http = {
        direction      = "ingress"
        protocol       = "TCP"
        port           = 80
        v4_cidr_blocks = var.admin_cidrs
        description    = "Artifact Keeper: UI/API для администратора и tofu"
      }
      registry_ssh = {
        direction      = "ingress"
        protocol       = "TCP"
        port           = 22
        v4_cidr_blocks = var.admin_cidrs
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
