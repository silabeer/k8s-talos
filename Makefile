SHELL := /bin/bash
.DEFAULT_GOAL := help

# OpenTofu вместо Terraform: releases.hashicorp.com и registry.terraform.io
# недоступны из РФ. Провайдеры берутся с зеркала Yandex, а siderolabs/talos
# (его на зеркале нет) скачивается с GitHub в локальное filesystem-зеркало.
TF ?= tofu
export TF
REPO ?=
TALOS_PROVIDER_VERSION ?= 0.11.0
OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

PROVIDERS_DIR := $(CURDIR)/.providers
export TF_CLI_CONFIG_FILE := $(CURDIR)/.tofurc

# Провайдер Talos и talosctl ходят на узлы по gRPC/TLS напрямую; через локальный
# HTTP-прокси (HTTPS_PROXY=localhost:1081 и т.п.) рукопожатие не проходит.
# Yandex API, зеркало провайдеров и GitHub из РФ доступны без прокси.
unexport HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
export NO_PROXY := *
export no_proxy := *
# Кластер по умолчанию для kubectl/talosctl и целей bootstrap, check, upgrade.
CLUSTER ?= east
export KUBECONFIG := $(CURDIR)/infra/out/$(CLUSTER)/kubeconfig
export TALOSCONFIG := $(CURDIR)/infra/out/$(CLUSTER)/talosconfig

.PHONY: help tools providers set-repo set-admin-ip set-ingress-ip infra bootstrap up check env registry upgrade replace destroy

help: ## Список целей
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

tools: ## Установить opentofu, talosctl, helm, kubectl, zstd, qemu-img, crane, yc (macOS)
	brew install opentofu siderolabs/tap/talosctl helm kubectl zstd qemu crane
	@command -v yc >/dev/null || curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash

providers: $(TF_CLI_CONFIG_FILE) ## Скачать провайдер talos с GitHub и настроить зеркала
	@dir=$(PROVIDERS_DIR)/registry.terraform.io/siderolabs/talos; \
	zip=terraform-provider-talos_$(TALOS_PROVIDER_VERSION)_$(OS)_$(ARCH).zip; \
	mkdir -p $$dir; \
	test -f $$dir/$$zip || curl -fsSL -o $$dir/$$zip \
	  https://github.com/siderolabs/terraform-provider-talos/releases/download/v$(TALOS_PROVIDER_VERSION)/$$zip; \
	echo "provider talos $(TALOS_PROVIDER_VERSION) -> $$dir/$$zip"

$(TF_CLI_CONFIG_FILE):
	@printf 'provider_installation {\n  filesystem_mirror {\n    path    = "%s"\n    include = ["registry.terraform.io/siderolabs/talos"]\n  }\n  network_mirror {\n    url     = "https://terraform-mirror.yandexcloud.net/"\n    exclude = ["registry.terraform.io/siderolabs/talos"]\n  }\n}\n' "$(PROVIDERS_DIR)" > $@
	@echo "создан $@"

set-admin-ip: ## Записать текущий публичный IPv4 в admin_cidrs (провайдер выдал новый адрес)
	@ip=$$(curl -4 -s --max-time 15 https://ifconfig.me); \
	test -n "$$ip" || (echo "не удалось определить адрес"; exit 1); \
	sed -i '' "s#admin_cidrs = \[.*\]#admin_cidrs = [\"$$ip/32\"]#" infra/terraform.tfvars; \
	echo "admin_cidrs = [\"$$ip/32\"], теперь make infra"

set-ingress-ip: ## Прописать IP балансировщика в values Traefik (после make infra)
	@ip=$$(cd infra && $(TF) output -json clusters | python3 -c 'import sys,json; print(json.load(sys.stdin)["$(CLUSTER)"]["ingress_ip"])'); \
	sed -i '' "s#statusaddress.ip=.*#statusaddress.ip=$$ip#" kubernetes/infrastructure/traefik/values.yaml; \
	echo "ingress_ip=$$ip записан в kubernetes/infrastructure/traefik/values.yaml, закоммитьте и запушьте"

set-repo: ## Прописать URL GitOps-репозитория: make set-repo REPO=https://github.com/user/k8s-talos.git
	@test -n "$(REPO)" || (echo "Укажите REPO=https://github.com/<user>/<repo>.git"; exit 1)
	@grep -rl 'CHANGE_ME/k8s-talos.git' kubernetes | xargs sed -i '' 's#https://github.com/CHANGE_ME/k8s-talos.git#$(REPO)#g'
	@echo "Готово. Проверьте: git grep CHANGE_ME"

infra: providers ## Стейдж 1: Yandex Cloud + Talos (tofu apply)
	cd infra && $(TF) init -input=false && $(TF) apply

bootstrap: ## Стейдж 2: Cilium + Argo CD в кластере CLUSTER (по умолчанию east)
	./bootstrap/bootstrap.sh $(CLUSTER)

up: infra ## Поднять всё: инфраструктура и bootstrap обоих кластеров
	$(MAKE) bootstrap CLUSTER=east
	$(MAKE) bootstrap CLUSTER=west

check: ## Проверить состояние кластера CLUSTER
	talosctl health --wait-timeout 5m
	kubectl get nodes -o wide
	kubectl -n argocd get applications

env: ## Показать export для kubectl/talosctl (кластер CLUSTER)
	@echo "export KUBECONFIG=$(KUBECONFIG)"
	@echo "export TALOSCONFIG=$(TALOSCONFIG)"

upgrade: ## Обновить узлы до текущего installer (по одному): make upgrade
	@set -e; image=$$(cd infra && $(TF) output -raw installer_image); \
	echo "образ: $$image"; \
	for ip in $$(cd infra && $(TF) output -json clusters | python3 -c 'import sys,json; [print(n["private_ip"]) for n in json.load(sys.stdin)["$(CLUSTER)"]["nodes"].values()]'); do \
	  echo "==> $$ip"; \
	  talosctl --nodes $$ip upgrade --image "$$image" --wait --timeout 15m; \
	done

registry: ## Адрес и пароль Artifact Keeper
	@cd infra && $(TF) output -json registry | python3 -c 'import sys,json; d=json.load(sys.stdin); print("UI:", d["public_url"]); print("user: admin")'
	@cd infra && echo "password: $$($(TF) output -raw registry_admin_password)"

replace: providers ## Пересоздать ВМ: make replace NODES="talos-w-1 talos-w-2" или make replace REGISTRY=1
	@test -n "$(NODES)$(REGISTRY)" || (echo 'Укажите NODES="talos-w-1 talos-w-2" и/или REGISTRY=1'; exit 1)
	cd infra && $(TF) apply \
	  $(foreach n,$(NODES),-replace='module.cluster["$(CLUSTER)"].yandex_compute_instance.node["$(n)"]') \
	  $(if $(REGISTRY),-replace='yandex_compute_instance.registry[0]')

destroy: providers ## Снести инфраструктуру
	cd infra && $(TF) destroy
