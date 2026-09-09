#!/usr/bin/env bash
# Стейдж 3: связывает кластеры в один mesh Istio.
#
# Два шага, которые нельзя выразить манифестами в git:
#   1. Общий корень доверия. Istio каждого кластера по умолчанию выпускает
#      собственный самоподписанный CA, и сертификаты соседа для него чужие.
#      Кладём в секрет cacerts промежуточный CA, подписанный общим корнем.
#      Приватные ключи в репозиторий не попадают, они лежат в infra/out/.
#   2. Обнаружение endpoint'ов. istiod каждого кластера читает API-сервер
#      соседей: доступ выдаётся secret'ом с kubeconfig (istioctl
#      create-remote-secret). East-west gateway для этого не годится, через
#      него ходит только double HBONE.
#
#   ./bootstrap/mesh.sh              # все кластеры из infra/out
#   ./bootstrap/mesh.sh east west
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/infra/out"
CA_DIR="$OUT/istio-ca"
# Домен доверия по умолчанию у Istio один на весь mesh.
TRUST_DOMAIN="${TRUST_DOMAIN:-cluster.local}"

for tool in istioctl kubectl openssl; do
  command -v "$tool" >/dev/null || { echo "нужен $tool (make tools)"; exit 1; }
done

clusters=("$@")
if [[ ${#clusters[@]} -eq 0 ]]; then
  for d in "$OUT"/*/; do
    [[ -f "$d/kubeconfig" ]] && clusters+=("$(basename "$d")")
  done
fi
[[ ${#clusters[@]} -ge 2 ]] || { echo "нужно минимум два кластера, найдено: ${clusters[*]:-нет}"; exit 1; }
echo "==> Кластеры: ${clusters[*]}"

kc() { echo "$OUT/$1/kubeconfig"; }

# Istio разворачивает Argo CD, и после bootstrap это занимает несколько минут.
# Без ожидания скрипт падает на "namespaces istio-system not found".
wait_istio() {
  local cluster="$1" deadline
  deadline=$(( $(date +%s) + ${ISTIO_WAIT:-900} ))
  echo "==> $cluster: ждём Istio"
  until kubectl --kubeconfig "$(kc "$cluster")" -n istio-system get deploy istiod >/dev/null 2>&1; do
    if (( $(date +%s) > deadline )); then
      echo "В кластере $cluster нет istiod. Проверьте: kubectl -n argocd get app istio" >&2
      exit 1
    fi
    sleep 15
  done
  kubectl --kubeconfig "$(kc "$cluster")" -n istio-system rollout status deploy/istiod --timeout=10m >/dev/null
  kubectl --kubeconfig "$(kc "$cluster")" -n istio-system rollout status deploy/istio-eastwestgateway --timeout=10m >/dev/null
  echo "    $cluster: istiod и east-west gateway готовы"
}

for cluster in "${clusters[@]}"; do
  wait_istio "$cluster"
done

# --- 1. Общий корневой CA -----------------------------------------------------

mkdir -p "$CA_DIR"
chmod 700 "$CA_DIR"

if [[ ! -s "$CA_DIR/root-cert.pem" ]]; then
  echo "==> Корневой CA"
  cat > "$CA_DIR/root.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
O = Istio
CN = Root CA
[ext]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
EOF
  openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 3650 \
    -config "$CA_DIR/root.cnf" \
    -keyout "$CA_DIR/root-key.pem" -out "$CA_DIR/root-cert.pem" 2>/dev/null
  chmod 600 "$CA_DIR/root-key.pem"
else
  echo "==> Корневой CA уже есть: $CA_DIR/root-cert.pem"
fi

# --- 2. Промежуточный CA и секрет cacerts в каждом кластере --------------------

for cluster in "${clusters[@]}"; do
  dir="$CA_DIR/$cluster"
  mkdir -p "$dir"

  if [[ ! -s "$dir/ca-cert.pem" ]]; then
    echo "==> $cluster: промежуточный CA"
    cat > "$dir/ca.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
O = Istio
CN = Intermediate CA
L = $cluster
[ext]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
# SAN обязателен: istiod проверяет, что сертификат выписан для его
# служебной учётной записи в домене доверия mesh.
subjectAltName = URI:spiffe://$TRUST_DOMAIN/ns/istio-system/sa/istio-pilot-service-account
EOF
    openssl req -new -nodes -newkey rsa:4096 -sha256 \
      -config "$dir/ca.cnf" -keyout "$dir/ca-key.pem" -out "$dir/ca.csr" 2>/dev/null
    openssl x509 -req -in "$dir/ca.csr" -sha256 -days 1825 \
      -CA "$CA_DIR/root-cert.pem" -CAkey "$CA_DIR/root-key.pem" -CAcreateserial \
      -extfile "$dir/ca.cnf" -extensions ext -out "$dir/ca-cert.pem" 2>/dev/null
    cat "$dir/ca-cert.pem" "$CA_DIR/root-cert.pem" > "$dir/cert-chain.pem"
    cp "$CA_DIR/root-cert.pem" "$dir/root-cert.pem"
    chmod 600 "$dir/ca-key.pem"
  fi

  echo "==> $cluster: секрет cacerts"
  kubectl --kubeconfig "$(kc "$cluster")" -n istio-system create secret generic cacerts \
    --from-file=root-cert.pem="$dir/root-cert.pem" \
    --from-file=cert-chain.pem="$dir/cert-chain.pem" \
    --from-file=ca-cert.pem="$dir/ca-cert.pem" \
    --from-file=ca-key.pem="$dir/ca-key.pem" \
    --dry-run=client -o yaml | kubectl --kubeconfig "$(kc "$cluster")" apply -f - >/dev/null

  # istiod читает cacerts только при старте; ztunnel и шлюзы получат новые
  # сертификаты сами, но перезапуск убирает окно со старым корнем.
  kubectl --kubeconfig "$(kc "$cluster")" -n istio-system rollout restart deploy/istiod >/dev/null
  kubectl --kubeconfig "$(kc "$cluster")" -n istio-system rollout status deploy/istiod --timeout=5m >/dev/null
  kubectl --kubeconfig "$(kc "$cluster")" -n istio-system rollout restart daemonset/ztunnel >/dev/null
  # Шлюзы тоже: их сертификат выписан прежним корнем, и сосед отвергает
  # соединение с "invalid peer certificate: UnknownIssuer".
  for deploy in $(kubectl --kubeconfig "$(kc "$cluster")" -n istio-system get deploy \
      -l gateway.networking.k8s.io/gateway-name -o name 2>/dev/null); do
    kubectl --kubeconfig "$(kc "$cluster")" -n istio-system rollout restart "$deploy" >/dev/null
  done
  echo "    $cluster: istiod, ztunnel и шлюзы перезапущены с общим корнем"

  # Адрес, который istiod рекламирует соседям, он берёт из status сервиса
  # шлюза. Провайдера LoadBalancer в кластере нет, поэтому status пуст, и
  # istiod подставлял ClusterIP, недоступный снаружи кластера. Записываем
  # туда приватные адреса worker-узлов: на них висит сервис с externalIPs.
  addrs="$(kubectl --kubeconfig "$(kc "$cluster")" -n istio-system get svc \
    istio-eastwestgateway-external -o jsonpath='{.spec.externalIPs[*]}' 2>/dev/null || true)"
  if [[ -n "$addrs" ]]; then
    ingress="$(for ip in $addrs; do printf '{"ip":"%s"},' "$ip"; done | sed 's/,$//')"
    kubectl --kubeconfig "$(kc "$cluster")" -n istio-system patch svc istio-eastwestgateway \
      --subresource=status --type=merge \
      -p "{\"status\":{\"loadBalancer\":{\"ingress\":[$ingress]}}}" >/dev/null
    echo "    $cluster: шлюз рекламируется по адресам $addrs"
  else
    echo "    $cluster: нет сервиса istio-eastwestgateway-external, адрес шлюза не проставлен" >&2
  fi
done

# --- 3. Обмен доступом к API-серверам ----------------------------------------

for from in "${clusters[@]}"; do
  for to in "${clusters[@]}"; do
    [[ "$from" == "$to" ]] && continue
    echo "==> $to получает доступ к API-серверу $from"
    istioctl create-remote-secret --kubeconfig "$(kc "$from")" --name "$from" \
      | kubectl --kubeconfig "$(kc "$to")" apply -f - >/dev/null
  done
done

echo
echo "==> Готово. Проверка:"
for cluster in "${clusters[@]}"; do
  echo "  KUBECONFIG=infra/out/$cluster/kubeconfig kubectl -n mesh-demo exec deploy/mesh-client -- wget -qO- http://mesh-demo/"
done
