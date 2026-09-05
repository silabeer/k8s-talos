SHELL := /bin/bash
.DEFAULT_GOAL := help

# OpenTofu вместо Terraform: releases.hashicorp.com и registry.terraform.io
# недоступны из РФ. Провайдеры берутся с зеркала Yandex, а siderolabs/talos
# (его на зеркале нет) скачивается с GitHub в локальное filesystem-зеркало.
TF ?= tofu
REPO ?=
TALOS_PROVIDER_VERSION ?= 0.11.0
OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

PROVIDERS_DIR := $(CURDIR)/.providers
export TF_CLI_CONFIG_FILE := $(CURDIR)/.tofurc
export KUBECONFIG := $(CURDIR)/infra/out/kubeconfig
export TALOSCONFIG := $(CURDIR)/infra/out/talosconfig

.PHONY: help tools providers set-repo infra bootstrap up check env destroy

help: ## Список целей
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

tools: ## Установить opentofu, talosctl, helm, kubectl, zstd, qemu-img, yc (macOS)
	brew install opentofu siderolabs/tap/talosctl helm kubectl zstd qemu
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

set-repo: ## Прописать URL GitOps-репозитория: make set-repo REPO=https://github.com/user/k8s-talos.git
	@test -n "$(REPO)" || (echo "Укажите REPO=https://github.com/<user>/<repo>.git"; exit 1)
	@grep -rl 'CHANGE_ME/k8s-talos.git' kubernetes | xargs sed -i '' 's#https://github.com/CHANGE_ME/k8s-talos.git#$(REPO)#g'
	@echo "Готово. Проверьте: git grep CHANGE_ME"

infra: providers ## Стейдж 1: Yandex Cloud + Talos (tofu apply)
	cd infra && $(TF) init -input=false && $(TF) apply

bootstrap: ## Стейдж 2: Cilium + Argo CD (helm)
	./bootstrap/bootstrap.sh

up: infra bootstrap ## Поднять всё

check: ## Проверить состояние кластера
	talosctl health --wait-timeout 5m
	kubectl get nodes -o wide
	kubectl -n argocd get applications

env: ## Показать export для kubectl/talosctl
	@echo "export KUBECONFIG=$(KUBECONFIG)"
	@echo "export TALOSCONFIG=$(TALOSCONFIG)"

destroy: providers ## Снести инфраструктуру
	cd infra && $(TF) destroy
