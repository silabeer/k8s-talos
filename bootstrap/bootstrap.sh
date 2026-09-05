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

repo_url="$(grep -m1 -E '^\s*repoURL:' "$INFRA_DIR/argocd/values.yaml" | awk '{print $2}')"
if [[ "$repo_url" == *CHANGE_ME* ]]; then
  echo "В kubernetes/ остался плейсхолдер репозитория. Выполните: make set-repo REPO=<url>"
  exit 1
fi

echo "==> Cilium"
helm dependency build "$INFRA_DIR/cilium" >/dev/null
helm upgrade --install cilium "$INFRA_DIR/cilium" \
  --namespace kube-system \
  --wait --timeout 10m

echo "==> Ждём готовности узлов"
kubectl wait --for=condition=Ready nodes --all --timeout=5m

echo "==> Argo CD"
helm dependency build "$INFRA_DIR/argocd" >/dev/null
extra_args=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  extra_args+=(
    --set configs.repositories.gitops.type=git
    --set "configs.repositories.gitops.url=$repo_url"
    --set "configs.repositories.gitops.username=${GITHUB_USERNAME:-git}"
    --set "configs.repositories.gitops.password=$GITHUB_TOKEN"
  )
fi
helm upgrade --install argocd "$INFRA_DIR/argocd" \
  --namespace argocd --create-namespace \
  --wait --timeout 10m \
  "${extra_args[@]}"

echo
echo "Готово. Argo CD подхватит $repo_url и развернёт остальное."
echo "Пароль admin: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "UI без домена: kubectl -n argocd port-forward svc/argocd-server 8080:80"
