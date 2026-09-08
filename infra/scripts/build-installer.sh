#!/usr/bin/env bash
# Собирает installer Talos с системными расширениями через imager и публикует
# его в hosted-репозиторий Artifact Keeper. Вызывается из OpenTofu
# (terraform_data.installer), можно запускать и руками.
#
# Окружение:
#   TALOS_VERSION   - например v1.12.12
#   EXTENSIONS      - через пробел: "siderolabs/drbd siderolabs/qemu-guest-agent"
#   IMAGE           - куда пушить: <публичный ip реестра>/talos/installer:<tag>
#   ADMIN_PASSWORD  - пароль admin Artifact Keeper
#   CACHE_DIR       - кэш собранных тарболов (по умолчанию .cache/installer)
#   REGISTRY_WAIT   - сколько секунд ждать готовности реестра (по умолчанию 900)
set -euo pipefail

: "${TALOS_VERSION:?}" "${EXTENSIONS:?}" "${IMAGE:?}" "${ADMIN_PASSWORD:?}"
CACHE_DIR="${CACHE_DIR:-.cache/installer}"
wait_secs="${REGISTRY_WAIT:-900}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for tool in docker crane; do
  command -v "$tool" >/dev/null || { echo "нужен $tool (make tools)" >&2; exit 1; }
done

registry="${IMAGE%%/*}"
tag="${IMAGE##*:}"
tar="$CACHE_DIR/installer-$tag.tar"

# Реестр мог быть только что пересоздан: cloud-init ставит docker и тянет образы.
echo "==> Ждём Artifact Keeper на http://$registry (до ${wait_secs}s)"
deadline=$(( $(date +%s) + wait_secs ))
until curl -fsS --connect-timeout 5 --max-time 10 "http://$registry/health" >/dev/null 2>&1; do
  if (( $(date +%s) > deadline )); then
    echo "Artifact Keeper не отвечает на http://$registry" >&2
    exit 1
  fi
  sleep 10
done

if crane manifest --insecure "$IMAGE" >/dev/null 2>&1; then
  echo "==> $IMAGE уже в реестре"
  exit 0
fi

if [[ ! -s "$tar" ]]; then
  echo "==> Версии расширений для $TALOS_VERSION"
  args=()
  while read -r ref; do
    echo "    $ref"
    args+=(--system-extension-image "$ref")
  done < <(TALOS_VERSION="$TALOS_VERSION" EXTENSIONS="$EXTENSIONS" "$here/resolve-extensions.sh")

  echo "==> imager installer ($TALOS_VERSION, amd64)"
  mkdir -p "$CACHE_DIR"
  out="$(mktemp -d)"
  docker run --rm -v "$out:/out" "ghcr.io/siderolabs/imager:$TALOS_VERSION" installer --arch amd64 "${args[@]}" >/dev/null
  mv "$out/installer-amd64.tar" "$tar"
  rm -rf "$out"
fi

echo "==> Публикация $IMAGE"
crane auth login "$registry" -u admin -p "$ADMIN_PASSWORD" >/dev/null
crane push --insecure "$tar" "$IMAGE" >/dev/null
echo "==> Готово"
