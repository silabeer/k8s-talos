#!/usr/bin/env bash
# Ждёт, пока узлы откроют Talos API (порт 50000), то есть загрузятся в
# maintenance mode. Нужен потому, что примерно один узел из пяти-семи в
# Yandex Cloud так и не поднимается, а провайдер talos в этом случае даёт
# невнятный "i/o timeout" через несколько минут, не называя узел.
#
# Окружение:
#   NODES   - "имя=адрес имя=адрес ..."
#   TIMEOUT - сколько секунд ждать (по умолчанию 600)
set -euo pipefail

: "${NODES:?}"
timeout_secs="${TIMEOUT:-600}"
deadline=$(( $(date +%s) + timeout_secs ))

port_open() {
  perl -e 'alarm 5; exec @ARGV' bash -c "exec 3<>/dev/tcp/$1/50000" >/dev/null 2>&1
}

pending="$NODES"
while [[ -n "${pending// /}" ]]; do
  still=""
  for entry in $pending; do
    if port_open "${entry##*=}"; then
      echo "    ${entry%%=*}: Talos API отвечает"
    else
      still="$still $entry"
    fi
  done
  pending="$still"
  [[ -z "${pending// /}" ]] && break
  if (( $(date +%s) > deadline )); then
    echo "Узлы не открыли порт 50000 за ${timeout_secs}s:" >&2
    for entry in $pending; do echo "  ${entry%%=*} (${entry##*=})" >&2; done
    echo >&2
    echo "Посмотрите, что с узлом:" >&2
    echo "  yc compute instance get-serial-port-output <имя> | tail -30" >&2
    echo >&2
    echo "Если в выводе Talos пишет \"entering maintenance service\" и называет" >&2
    echo "приватный адрес, узел исправен, а сломан NAT на стороне Yandex: такое" >&2
    echo "встречается примерно на одной машине из шести, конфигурация при этом" >&2
    echo "не отличается от соседних. Помогает только пересоздание, stop/start нет:" >&2
    echo "  make replace CLUSTER=<кластер> NODES=\"<имя>\"" >&2
    echo >&2
    echo "Если вывод пуст или обрывается раньше, узел действительно не загрузился." >&2
    exit 1
  fi
  sleep 10
done
echo "==> Все узлы в maintenance mode"
