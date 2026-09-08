#!/usr/bin/env bash
# Печатает ссылки на образы системных расширений Talos с версиями, привязанными
# к конкретному релизу: каталог ghcr.io/siderolabs/extensions:<версия> содержит
# файл image-digests со строками вида
#   ghcr.io/siderolabs/drbd:9.2.16-v1.12.12@sha256:...
#
# Окружение:
#   TALOS_VERSION - например v1.12.12
#   EXTENSIONS    - через пробел: "siderolabs/drbd siderolabs/qemu-guest-agent"
set -euo pipefail

: "${TALOS_VERSION:?}" "${EXTENSIONS:?}"
command -v crane >/dev/null || { echo "нужен crane (make tools)" >&2; exit 1; }

catalog="$(crane export "ghcr.io/siderolabs/extensions:$TALOS_VERSION" - | tar x -O image-digests)"
for ext in $EXTENSIONS; do
  ref="$(grep -m1 "^ghcr.io/$ext:" <<<"$catalog" || true)"
  [[ -n "$ref" ]] || { echo "расширение $ext не найдено в каталоге для $TALOS_VERSION" >&2; exit 1; }
  echo "$ref"
done
