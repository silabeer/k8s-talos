# kube-apiserver: внешний NLB на 3 control-plane узла. Его IP = cluster endpoint.
resource "yandex_lb_target_group" "controlplane" {
  name = "${var.cluster_name}-controlplane"

  dynamic "target" {
    for_each = local.controlplanes
    content {
      subnet_id = yandex_vpc_subnet.this.id
      address   = target.value.ip
    }
  }
}

resource "yandex_lb_network_load_balancer" "api" {
  name = "${var.cluster_name}-api"
  type = "external"

  listener {
    name        = "kube-apiserver"
    port        = 6443
    target_port = 6443
    protocol    = "tcp"
    external_address_spec {
      address    = local.api_ip
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.controlplane.id

    healthcheck {
      name                = "tcp-6443"
      interval            = 5
      timeout             = 2
      healthy_threshold   = 2
      unhealthy_threshold = 2
      tcp_options {
        port = 6443
      }
    }
  }
}

# Ingress: внешний NLB на worker узлы, NodePort Traefik 30080/30443.
resource "yandex_lb_target_group" "workers" {
  name = "${var.cluster_name}-workers"

  dynamic "target" {
    for_each = local.workers
    content {
      subnet_id = yandex_vpc_subnet.this.id
      address   = target.value.ip
    }
  }
}

resource "yandex_lb_network_load_balancer" "ingress" {
  name = "${var.cluster_name}-ingress"
  type = "external"

  listener {
    name        = "http"
    port        = 80
    target_port = 30080
    protocol    = "tcp"
    external_address_spec {
      address    = local.ingress_ip
      ip_version = "ipv4"
    }
  }

  listener {
    name        = "https"
    port        = 443
    target_port = 30443
    protocol    = "tcp"
    external_address_spec {
      address    = local.ingress_ip
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.workers.id

    healthcheck {
      name                = "tcp-30080"
      interval            = 5
      timeout             = 2
      healthy_threshold   = 2
      unhealthy_threshold = 2
      tcp_options {
        port = 30080
      }
    }
  }
}
