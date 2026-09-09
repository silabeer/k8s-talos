#!/usr/bin/env bash
# Ждёт, пока kube-apiserver кластера начнёт отвечать. После bootstrap etcd
# ещё проходит pre state, apiserver не слушает, и первая же команда kubectl
# падает с "connection refused". Проверка живёт здесь, а не в bootstrap.sh,
# чтобы `make infra` не отдавал управление на недоделанном кластере.
#
# Окружение:
#   CLUSTER  - имя кластера, для сообщений
#   ENDPOINT - https://<адрес>:6443
#   TIMEOUT  - сколько секунд ждать (по умолчанию 600)
set -euo pipefail

: "${CLUSTER:?}" "${ENDPOINT:?}"
timeout_secs="${TIMEOUT:-600}"
deadline=$(( $(date +%s) + timeout_secs ))

echo "==> $CLUSTER: ждём kube-apiserver на $ENDPOINT"
while :; do
  # 401 и 403 тоже годятся: сервер слушает и отвечает, просто запрос без
  # сертификата клиента. Нам важен именно факт готовности сокета и TLS.
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$ENDPOINT/readyz" || true)"
  case "$code" in
    200 | 401 | 403) echo "    $CLUSTER: kube-apiserver отвечает (HTTP $code)"; exit 0 ;;
  esac
  if (( $(date +%s) > deadline )); then
    echo "kube-apiserver кластера $CLUSTER не ответил за ${timeout_secs}s." >&2
    echo "Смотрите: talosctl --talosconfig infra/out/$CLUSTER/talosconfig -n <ip> services" >&2
    exit 1
  fi
  sleep 10
done
