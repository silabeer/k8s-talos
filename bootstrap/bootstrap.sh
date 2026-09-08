#!/usr/bin/env bash
# Стейдж 2: одноразовая установка Cilium и Argo CD.
# Ставит те же umbrella-чарты из kubernetes/infrastructure/, которыми дальше
# управляет сам Argo CD, поэтому после первого sync диффа не будет.
#
# Окружение:
#   KUBECONFIG      - по умолчанию infra/out/kubeconfig
#   GITHUB_TOKEN    - токен для приватного GitOps-репозитория (необязательно)
#   GITHUB_USERNAME - имя пользователя для токена (по умолчанию git)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT/kubernetes/infrastructure"
export KUBECONFIG="${KUBECONFIG:-$ROOT/infra/out/kubeconfig}"

for tool in helm kubectl; do
  command -v "$tool" >/dev/null || { echo "нужен $tool"; exit 1; }
done
[[ -f "$KUBECONFIG" ]] || { echo "нет kubeconfig: $KUBECONFIG (сначала make infra)"; exit 1; }

# Chart.yaml ссылаются на Artifact Keeper по приватному адресу; с рабочей машины
# он недоступен, поэтому для bootstrap подменяем его на публичный во временной
# копии чарта. Внутри кластера Argo CD ходит по приватному.
registry_private="" registry_public=""
if command -v "${TF:-tofu}" >/dev/null; then
  read -r registry_private registry_public < <(
    "${TF:-tofu}" -chdir="$ROOT/infra" output -json registry 2>/dev/null \
      | python3 -c 'import sys,json; d=json.load(sys.stdin) or {}; print(d.get("private_url",""), d.get("public_url",""))' 2>/dev/null \
      || echo ""
  )
fi
chart_dir() {
  local src="$INFRA_DIR/$1"
  if [[ -z "$registry_private" || -z "$registry_public" ]]; then
    echo "$src"
    return
  fi
  local tmp
  tmp="$(mktemp -d)/$1"
  cp -R "$src" "$tmp"
  sed "s#$registry_private#$registry_public#g" "$src/Chart.yaml" > "$tmp/Chart.yaml"
  echo "$tmp"
}
cilium_chart="$(chart_dir cilium)"
argocd_chart="$(chart_dir argocd)"

repo_url="$(grep -m1 -E '^\s*repoURL:' "$INFRA_DIR/argocd/values.yaml" | awk '{print $2}')"
if [[ "$repo_url" == *CHANGE_ME* ]]; then
  echo "В kubernetes/ остался плейсхолдер репозитория. Выполните: make set-repo REPO=<url>"
  exit 1
fi

echo "==> Cilium"
helm dependency update "$cilium_chart" >/dev/null
helm upgrade --install cilium "$cilium_chart" \
  --namespace kube-system \
  --wait --timeout 10m

# Traefik стартует с провайдером Gateway API, ему нужны CRD. Дальше ими владеет
# приложение gateway-api в Argo CD, здесь только снимаем гонку на чистом кластере.
echo "==> CRD Gateway API"
kubectl apply --server-side -k "$INFRA_DIR/gateway-api" >/dev/null

echo "==> Ждём готовности узлов"
kubectl wait --for=condition=Ready nodes --all --timeout=5m

echo "==> Argo CD"
helm dependency update "$argocd_chart" >/dev/null
extra_args=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  extra_args+=(
    --set configs.repositories.gitops.type=git
    --set "configs.repositories.gitops.url=$repo_url"
    --set "configs.repositories.gitops.username=${GITHUB_USERNAME:-git}"
    --set "configs.repositories.gitops.password=$GITHUB_TOKEN"
  )
fi
# Helm валидирует объекты релиза до установки CRD, поэтому корневое Application
# из extraObjects ставим отдельно, после чарта. Дальше им владеет сам Argo CD
# (приложение argocd из git рендерит тот же extraObjects).
helm upgrade --install argocd "$argocd_chart" \
  --namespace argocd --create-namespace \
  --set argo-cd.extraObjects=null \
  --wait --timeout 10m \
  ${extra_args[@]+"${extra_args[@]}"}

echo "==> Корневое приложение"
helm template argocd "$argocd_chart" -s charts/argo-cd/templates/extra-manifests.yaml \
  | kubectl apply -n argocd -f -

echo
echo "Готово. Argo CD подхватит $repo_url и развернёт остальное."
echo "Пароль admin: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "UI без домена: kubectl -n argocd port-forward svc/argocd-server 8080:80"
