#!/usr/bin/env bash
# Собирает дисковый образ Talos (metal) с системными расширениями.
# Нужен потому, что machine.install.image применяется только при установке или
# `talosctl upgrade`: узлы в Yandex грузятся с готового образа диска, и
# расширения должны быть уже внутри него.
#
# Окружение:
#   TALOS_VERSION - например v1.12.12
#   EXTENSIONS    - через пробел: "siderolabs/drbd"
#   OUT           - куда положить metal-amd64.raw.zst
set -euo pipefail

: "${TALOS_VERSION:?}" "${EXTENSIONS:?}" "${OUT:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v docker >/dev/null || { echo "нужен docker" >&2; exit 1; }

echo "==> Версии расширений для $TALOS_VERSION"
args=()
while read -r ref; do
  echo "    $ref"
  args+=(--system-extension-image "$ref")
done < <(TALOS_VERSION="$TALOS_VERSION" EXTENSIONS="$EXTENSIONS" "$here/resolve-extensions.sh")

# imager создаёт образ через loopback-устройство, поэтому --privileged и /dev.
echo "==> imager metal ($TALOS_VERSION, amd64)"
tmp="$(mktemp -d)"
# console=ttyS0: иначе serial console Yandex для узлов Talos пуст, и зависший
# на загрузке узел диагностировать нечем.
docker run --rm -v "$tmp:/out" -v /dev:/dev --privileged \
  "ghcr.io/siderolabs/imager:$TALOS_VERSION" metal --arch amd64 \
  --extra-kernel-arg console=tty0 --extra-kernel-arg console=ttyS0,115200n8 \
  "${args[@]}" >/dev/null
mkdir -p "$(dirname "$OUT")"
mv "$tmp/metal-amd64.raw.zst" "$OUT"
rm -rf "$tmp"
echo "==> Готово: $OUT"
