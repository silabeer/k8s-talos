# Аутентификация Yandex Cloud берётся из переменных окружения:
#   YC_TOKEN (или YC_SERVICE_ACCOUNT_KEY_FILE), YC_CLOUD_ID, YC_FOLDER_ID
provider "yandex" {
  zone = var.zone
}

provider "talos" {}
