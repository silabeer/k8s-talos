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
| Piraeus Operator + LINSTOR (PV) | v2.11.0 | Argo CD |
| whoami (демо) | | Argo CD |
| Artifact Keeper (прокси образов и чартов) | 1.8.2 | `infra/registry.tf` (отдельная ВМ) |

Топология: 3 control plane + N worker в одной зоне, внешний NLB на `6443` (endpoint
кластера) и внешний NLB на `80/443` → NodePort Traefik на worker-узлах.

```
infra/          OpenTofu: VPC, security group, образ Talos, ВМ, NLB, реестр, Talos machine config, bootstrap
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

Прокси: если в шелле выставлены `HTTP_PROXY`/`HTTPS_PROXY`, Makefile их снимает для
своих команд. Провайдер Talos и talosctl не умеют gRPC через HTTP-прокси, а всё
остальное (Yandex API, зеркало провайдеров, GitHub) из РФ доступно напрямую.
При ручном запуске `tofu`/`talosctl` делайте `unset HTTPS_PROXY HTTP_PROXY`.

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

## Реестр Artifact Keeper

Узлы не тянут образы напрямую из интернета: все OCI-реестры (`docker.io`, `ghcr.io`,
`registry.k8s.io`, `quay.io`, `gcr.io`) и Helm-репозитории чартов проксируются через
[Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper) на отдельной ВМ
`<cluster>-registry` (`10.10.0.5`, Ubuntu 24.04, docker compose). Это кэш, а не
air-gap: у ВМ реестра есть NAT, у узлов тоже (нужен для kube-apiserver через NLB и
как запасной путь, если реестр лежит).

- **Образы.** На каждый upstream создаётся remote-репозиторий (`docker-io`, `ghcr-io`, ...),
  а в machine config узлов попадает `machine.registries.mirrors` с `overridePath: true`:
  containerd ходит в `http://10.10.0.5/v2/<ключ>/<образ>`. Имена образов в манифестах
  не меняются. Через реестр идёт и installer Talos, поэтому ВМ реестра создаётся до узлов.
- **Чарты.** Remote Helm-репозитории `helm-*`, в `Chart.yaml` umbrella-чартов
  `repository: http://10.10.0.5/helm/<ключ>`. `bootstrap.sh` с рабочей машины подменяет
  приватный адрес на публичный во временной копии чарта.
- **Хранилище.** Кэш лежит в бакете Object Storage (`STORAGE_BACKEND=s3`), ВМ можно
  пересоздать без потери кэша. PostgreSQL на ВМ, OpenSearch и сканеры не ставятся.
- **Настройка.** `registry` и `registry_docker_mirrors`/`registry_helm_repos` в tfvars.
  Репозитории создаёт `infra/scripts/registry-setup.sh` через REST API (порт 80 открыт
  для `admin_cidrs`). Доступ в UI: `make registry`. SSH: `registry_ssh_public_key`.
- **Отключить:** `registry = { enabled = false, ... }` и вернуть в `Chart.yaml`
  upstream-адреса из `registry_helm_repos`.

Ограничения: git (GitHub) по-прежнему нужен Argo CD напрямую; Let's Encrypt и NTP
тоже ходят в интернет. Образ web UI Artifact Keeper релизных тегов не имеет, поэтому
`web_version = "latest"`. Если меняете `subnet_cidr`, поменяйте `10.10.0.5` в `Chart.yaml`
(адрес реестра = пятый в подсети).

## Хранилище: LINSTOR через Piraeus Operator

`Service type=LoadBalancer` и сетевые диски Yandex как PV не работают без CCM/CSI,
поэтому PV делает LINSTOR: реплицированные DRBD-тома поверх локальных дисков воркеров.

Что для этого включено:

- **Расширение ядра.** `talos_extensions = ["siderolabs/drbd"]` в tfvars. При непустом
  списке `make infra` собирает локально и дисковый образ, и installer (см. следующий
  раздел): `machine.install.image` применяется только при установке или `talosctl upgrade`,
  а узлы в Yandex грузятся с готового образа диска, поэтому расширения должны быть
  уже внутри него.
- **Модули ядра.** `infra/patches/linstor.yaml` (drbd с `usermode_helper=disabled`,
  drbd_transport_tcp, dm-thin-pool) подмешивается автоматически, когда в
  `talos_extensions` есть drbd.
- **Диски.** `worker.data_disk_gb` создаёт на каждом воркере отдельный network-ssd,
  в Talos это `/dev/vdb`. Диск с `auto_delete = false`: пересоздание ВМ данные не теряет.
- **Оператор.** `kubernetes/infrastructure/piraeus/`: манифесты оператора v2.11.0
  вендорены (`operator.yaml`), рядом `linstor.yaml` с `LinstorCluster`,
  overrides для Talos из гайда Piraeus, пул `data` (LVM thin pool на `/dev/vdb`)
  и StorageClass `linstor-r2` по умолчанию: две реплики, `WaitForFirstConsumer`,
  `allowRemoteVolumeAccess: false` (под едет туда, где лежит реплика).

Проверка после `make bootstrap`:

```bash
kubectl -n piraeus-datastore get pods
kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor storage-pool list
talosctl -n <worker-ip> read /proc/modules | grep drbd
kubectl get sc
```

Замечания: минимум два воркера (реплик две); при смене расширений на уже работающем
кластере нужен `make upgrade` (образ диска меняется только для новых узлов);
обновление оператора — перерендерить `operator.yaml` с новым `ref`
(команда записана в `kustomization.yaml`).

Если LINSTOR не отдаёт том с `Not enough available nodes`, сначала проверьте, что
модуль DRBD действительно загружен: `linstor node info` должен показывать `+` в
колонке DRBD, а `talosctl -n <ip> read /proc/modules` — строки drbd. Пустой вывод
означает, что узел стоит на образе без расширения.

## Свой installer с расширениями (локальная сборка)

Всё описанное ниже делает `make infra` автоматически, если в tfvars задан
`talos_extensions` (нужны `docker` и `crane`, ставятся через `make tools`). Собирается
два образа, оба через `ghcr.io/siderolabs/imager` за считаные секунды:

- **дисковый образ** (`infra/scripts/build-image.sh`, профиль `metal`) — с него грузятся
  узлы, поэтому расширения обязаны быть внутри. Требует `--privileged` и `/dev`: imager
  собирает образ через loopback. Дальше он идёт по обычному пути: qcow2, бакет,
  `yandex_compute_image` с именем `talos-<версия>-ext-<хэш расширений>`;
- **installer** (`infra/scripts/build-installer.sh`) — публикуется в hosted-репозиторий
  `talos` в Artifact Keeper, попадает в `machine.install.image` и используется при
  `talosctl upgrade`. Тарбол кэшируется в `infra/.cache/installer/`, повторная сборка
  пропускается, если образ уже в реестре.

Версии расширений привязываются к релизу Talos через каталог
`ghcr.io/siderolabs/extensions` (`infra/scripts/resolve-extensions.sh`).
Готовый installer можно задать напрямую через `installer_image`.

Смена расширений на живом кластере: новый дисковый образ действует только на новые
узлы (у существующих `image_id` в `ignore_changes`), поэтому после `make infra`
выполните `make upgrade` — он прогонит `talosctl upgrade` по узлам по одному.

Ручная сборка (если нужно собрать вне OpenTofu). Расширения Talos живут в образе **installer**,
а не в дисковом образе. Узел грузится с ванильного `metal-amd64.raw.zst`, а при
установке и при каждом `talosctl upgrade` на диск пишется содержимое
`machine.install.image`. Поэтому пересобирать нужно только installer, Image Factory
(медленная из РФ) не нужна. Нужен docker, сборка занимает секунды.

```bash
# 1. Версии расширений под конкретный Talos берутся из каталога siderolabs/extensions
crane export ghcr.io/siderolabs/extensions:v1.12.12 - | tar x -O image-digests | grep qemu
#   для v1.12.12: ghcr.io/siderolabs/qemu-guest-agent:10.2.0
#                 ghcr.io/siderolabs/iscsi-tools:v0.2.0
#                 ghcr.io/siderolabs/util-linux-tools:2.41.4

# 2. Сборка installer (на Apple Silicon --arch amd64 обязателен)
mkdir -p _out
docker run --rm -v "$PWD/_out:/out" ghcr.io/siderolabs/imager:v1.12.12 installer \
  --arch amd64 \
  --system-extension-image ghcr.io/siderolabs/qemu-guest-agent:10.2.0 \
  --system-extension-image ghcr.io/siderolabs/iscsi-tools:v0.2.0
# -> _out/installer-amd64.tar (~130 МБ). Есть также --extra-kernel-arg и --meta.

# 3. Публикация. Вариант А: свой ghcr.io (узлы уже ходят туда через реестр)
crane push _out/installer-amd64.tar ghcr.io/<user>/talos-installer:v1.12.12-qga
# Вариант Б: hosted-репозиторий в Artifact Keeper (см. ниже, что для этого нужно)
crane auth login <публичный ip реестра> -u admin -p "$(tofu -chdir=infra output -raw registry_admin_password)"
crane push --insecure _out/installer-amd64.tar <публичный ip реестра>/talos/installer:v1.12.12-qga
```

Дальше образ прописывается в `machine.install.image` (сейчас это `local.installer_image`
в `infra/talos.tf`), `make infra` обновляет конфиг, и узлы обновляются по одному:
`talosctl upgrade --nodes <ip> --image <образ>`. Дисковый образ тем же imager собирается
профилем `metal` с теми же `--system-extension-image`, но требует `--privileged -v /dev:/dev`
и в этой схеме не нужен.

Hosted-репозиторий `talos` и http-зеркало для самого `10.10.0.5` в
`machine.registries.mirrors` (без него containerd пошёл бы к реестру по HTTPS)
создаются автоматически.

## Повседневные операции

**Добавить worker:** увеличить `worker.count` → `make infra`. Узел сам попадёт в NLB.

**Обновить Talos:** поднять `talos_version` → `make infra` (создаст новый образ и
installer; при своём installer с расширениями пересоберите и его), затем по одному узлу:
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
  `PersistentVolume` на сетевых дисках не работают из коробки. PV решает LINSTOR
  (см. выше), NLB создаются в OpenTofu.
- Публичные IP на узлах для NAT. Квота `vpc.externalAddresses.count` по умолчанию 8:
  два балансировщика, ВМ реестра и до пяти узлов. Замена: NAT-шлюз Yandex и bastion/VPN для Talos API.
- Квота `ylb.networkLoadBalancers.count` по умолчанию 2, оба уже заняты.
- State OpenTofu локальный (`infra/terraform.tfstate`, в `.gitignore`). Для команды:
  S3-backend в Object Storage, шаблон в `infra/versions.tf`.

## Отладка

```bash
talosctl -n <private-ip> dashboard         # консоль узла
talosctl -n <private-ip> logs kubelet
talosctl -n <private-ip> get members       # discovery
yc compute instance get-serial-port-output <name>   # если Talos не поднялся
ssh ubuntu@$(tofu -chdir=infra output -json registry | jq -r .public_url | sed 's#http://##')  # реестр
sudo docker compose -f /opt/artifact-keeper/docker-compose.yml logs backend        # на ВМ реестра
kubectl -n argocd get applications          # состояние GitOps
```
