terraform {
  required_version = ">= 1.9"

  required_providers {
    yandex = {
      source  = "registry.terraform.io/yandex-cloud/yandex"
      version = "~> 0.225"
    }
    talos = {
      source  = "registry.terraform.io/siderolabs/talos"
      version = "~> 0.11.0"
    }
    http = {
      source  = "registry.terraform.io/hashicorp/http"
      version = "~> 3.5"
    }
    local = {
      source  = "registry.terraform.io/hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Для командной работы вынесите state в Object Storage (S3-совместимый backend):
  # backend "s3" {
  #   endpoints = { s3 = "https://storage.yandexcloud.net" }
  #   bucket    = "my-tfstate"
  #   key       = "k8s-talos/infra.tfstate"
  #   region    = "ru-central1"
  #   skip_region_validation      = true
  #   skip_credentials_validation = true
  #   skip_requesting_account_id  = true
  #   skip_s3_checksum            = true
  # }
}
