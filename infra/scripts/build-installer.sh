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
set -euo pipefail

: "${TALOS_VERSION:?}" "${EXTENSIONS:?}" "${IMAGE:?}" "${ADMIN_PASSWORD:?}"
CACHE_DIR="${CACHE_DIR:-.cache/installer}"

for tool in docker crane; do
  command -v "$tool" >/dev/null || { echo "нужен $tool (make tools)" >&2; exit 1; }
done

registry="${IMAGE%%/*}"
tag="${IMAGE##*:}"
tar="$CACHE_DIR/installer-$tag.tar"

if crane manifest --insecure "$IMAGE" >/dev/null 2>&1; then
  echo "==> $IMAGE уже в реестре"
  exit 0
fi

if [[ ! -s "$tar" ]]; then
  echo "==> Версии расширений из каталога ghcr.io/siderolabs/extensions:$TALOS_VERSION"
  catalog="$(crane export "ghcr.io/siderolabs/extensions:$TALOS_VERSION" - | tar x -O image-digests)"
  args=()
  for ext in $EXTENSIONS; do
    ref="$(grep -m1 "^ghcr.io/$ext:" <<<"$catalog" || true)"
    [[ -n "$ref" ]] || { echo "расширение $ext не найдено в каталоге для $TALOS_VERSION" >&2; exit 1; }
    echo "    $ref"
    args+=(--system-extension-image "$ref")
  done

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
