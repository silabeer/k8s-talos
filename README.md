# Kubernetes на Talos Linux в Yandex Cloud, GitOps через Argo CD

Полностью декларативный стенд: OpenTofu создаёт инфраструктуру и кластер,
Argo CD разворачивает всё внутри кластера из этого репозитория, включая самого себя.

## Что получается

| Компонент | Версия | Откуда управляется |
|---|---|---|
| Talos Linux | v1.12.12 (K8s 1.35) | `infra/` (OpenTofu) |
| Cilium (CNI, без kube-proxy) | 1.20.1 | `bootstrap/bootstrap.sh` один раз, дальше Argo CD |
| Argo CD | chart 10.8.0 / v3.5.2 | `bootstrap/bootstrap.sh` один раз, дальше Argo CD |
| Traefik (ingress) | chart 41.4.0 | Argo CD |
| cert-manager + Let's Encrypt | v1.21.1 | Argo CD |
| metrics-server + kubelet-serving-cert-approver | 3.14.0 / v0.12.0 | Argo CD |
| whoami (демо) | | Argo CD |

Топология: 3 control plane + N worker в одной зоне, внешний NLB на `6443` (endpoint
кластера) и внешний NLB на `80/443` → NodePort Traefik на worker-узлах.

```
infra/          OpenTofu: VPC, security group, образ Talos, ВМ, NLB, Talos machine config, bootstrap
bootstrap/      bootstrap.sh: helm install umbrella-чартов cilium и argocd из kubernetes/infrastructure/
kubernetes/
  bootstrap/    AppProject'ы и ApplicationSet'ы (root app указывает сюда)
  infrastructure/<name>/   платформенные компоненты, каждый = umbrella-чарт или kustomize + app.yaml
  apps/<name>/             ваши приложения, тот же формат
```

Как это связано: `bootstrap.sh` ставит Argo CD с `extraObjects` → Application `root` →
`kubernetes/bootstrap` → два ApplicationSet сканируют `kubernetes/{infrastructure,apps}/*/app.yaml`
и создают Application на каждую папку. Чтобы добавить сервис, достаточно положить папку
с `app.yaml` (`name`, `namespace`) и манифестами и сделать push.

## Предварительно

1. Инструменты: `make tools` ставит opentofu, talosctl, helm, kubectl, zstd, qemu, yc.
2. Yandex Cloud CLI: `yc init`, затем окружение для провайдера:
   ```bash
   export YC_TOKEN=$(yc iam create-token)
   export YC_CLOUD_ID=$(yc config get cloud-id)
   export YC_FOLDER_ID=$(yc config get folder-id)
   ```
3. Провайдеры. Сайты HashiCorp и реестр OpenTofu из РФ не открываются, поэтому
   `make providers` (вызывается автоматически из `make infra`) делает две вещи:
   скачивает `siderolabs/talos` с GitHub в `.providers/` и создаёт `.tofurc`
   с зеркалом Yandex для остальных провайдеров. Makefile экспортирует
   `TF_CLI_CONFIG_FILE`, руками ничего настраивать не нужно. Если запускаете
   `tofu` напрямую: `export TF_CLI_CONFIG_FILE=$PWD/.tofurc`.

## Запуск

```bash
# 1. Репозиторий на GitHub (публичный или приватный)
git init && git remote add origin https://github.com/<user>/k8s-talos.git
make set-repo REPO=https://github.com/<user>/k8s-talos.git
# заполните email в kubernetes/infrastructure/cert-manager/values.yaml
# и домены в kubernetes/infrastructure/argocd/values.yaml, kubernetes/apps/whoami/ingress.yaml
git add -A && git commit -m "init" && git push -u origin main

# 2. Инфраструктура и кластер (~10 минут)
cp infra/terraform.tfvars.example infra/terraform.tfvars   # впишите admin_cidrs
make infra

# 3. Cilium + Argo CD
#    для приватного репозитория: export GITHUB_TOKEN=github_pat_...
make bootstrap

# 4. Проверка
eval "$(make env)"
make check
```

DNS: A-записи `argocd.<domain>`, `whoami.<domain>` → `tofu -chdir=infra output ingress_ip`.
Пока домена нет, Argo CD доступен через `kubectl -n argocd port-forward svc/argocd-server 8080:80`,
пароль admin: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.

## Как устроен стейдж infra

- Образ Talos берётся с GitHub (`metal-amd64.raw.zst`), распаковывается и конвертируется
  в qcow2 через `qemu-img` в `infra/.cache/`, затем выгружается в бакет Object Storage:
  Compute Cloud принимает образы только по ссылкам на `storage.yandexcloud.net`. Для этого
  создаются сервисный аккаунт со `storage.admin` и бакет с анонимным чтением.
  Image Factory (`image_source = "factory"`, расширения в `talos_extensions`) из РФ
  качается со скоростью пары килобайт в секунду, поэтому по умолчанию выключена.
  Инсталлер для ванильного образа: `ghcr.io/siderolabs/installer`, см. `installer_image`.
- В Yandex Cloud нет способа передать Talos machine config через метаданные: EC2-формат
  не отдаёт user-data, GCE-формат требует заголовок, который Talos не шлёт. Поэтому узлы
  грузятся в maintenance mode, а OpenTofu применяет конфиг через Talos API (порт 50000,
  открыт только для `admin_cidrs`).
- У каждого узла публичный IP через NAT. Он добавлен в `machine.certSANs`, иначе
  talosctl не пройдёт проверку TLS. По умолчанию IP динамический: после stop/start ВМ
  он меняется, и нужен повторный `make infra`. Статические IP включает
  `node_static_ips = true`, но квота `vpc.externalStaticAddresses.count` по умолчанию 2
  и целиком уходит на балансировщики. Запросите увеличение в консоли: Квоты → VPC.
- kubelet и control-plane компоненты ходят к apiserver через KubePrism (`localhost:7445`),
  внешний NLB нужен для kubectl и как cluster endpoint.
- `image_id` ВМ в `ignore_changes`: обновление Talos делается через `talosctl upgrade`,
  а не пересозданием ВМ.

## Повседневные операции

**Добавить worker:** увеличить `worker.count` → `make infra`. Узел сам попадёт в NLB.

**Обновить Talos:** поднять `talos_version` → `make infra` (создаст новый образ и
installer), затем по одному узлу:
```bash
talosctl upgrade --nodes <ip> --image $(tofu -chdir=infra output -raw installer_image)
```

**Обновить Kubernetes:** `talosctl upgrade-k8s --to <version>`, затем синхронизировать
`kubernetes_version` в tfvars.

**Изменить machine config:** правки в `infra/patches/*.yaml` → `make infra`.
Провайдер применит их в режиме auto (reboot, если Talos этого требует).

**Обновить чарт:** поменять `version` в `kubernetes/infrastructure/<name>/Chart.yaml`,
push. Argo CD пересоберёт зависимости и синхронизирует. Это касается и Cilium с самим
Argo CD: `bootstrap.sh` нужен только один раз, дальше они живут в GitOps.

**Секреты в git:** намеренно не включены. Варианты: External Secrets Operator с
Yandex Lockbox, или SOPS + age через argocd-vault-plugin / ksops.

## Ограничения и что можно добавить

- Одна зона доступности. Для мультизонности нужны подсети в каждой зоне и по target group.
- Нет Yandex Cloud Controller Manager и CSI: `Service type=LoadBalancer` и
  `PersistentVolume` на сетевых дисках не работают из коробки. Для PV самое простое:
  Longhorn или локальные диски; для NLB: OpenTofu, как здесь.
- Публичные IP на узлах для NAT. Квота `vpc.externalAddresses.count` по умолчанию 8:
  два балансировщика плюс до шести узлов. Замена: NAT-шлюз Yandex и bastion/VPN для Talos API.
- Квота `ylb.networkLoadBalancers.count` по умолчанию 2, оба уже заняты.
- State OpenTofu локальный (`infra/terraform.tfstate`, в `.gitignore`). Для команды:
  S3-backend в Object Storage, шаблон в `infra/versions.tf`.

## Отладка

```bash
talosctl -n <private-ip> dashboard         # консоль узла
talosctl -n <private-ip> logs kubelet
talosctl -n <private-ip> get members       # discovery
yc compute instance get-serial-port-output <name>   # если Talos не поднялся
kubectl -n argocd get applications          # состояние GitOps
```
