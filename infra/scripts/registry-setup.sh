#!/usr/bin/env bash
# Создаёт remote-репозитории в Artifact Keeper. Вызывается из OpenTofu
# (terraform_data.registry_repos), можно запускать и руками.
#
# Окружение:
#   REGISTRY_URL    - http://<публичный ip реестра>
#   ADMIN_PASSWORD  - пароль admin
#   REPOS           - JSON-массив [{key,name,format,repo_type,upstream_url}]
#                     repo_type: remote (прокси upstream_url) или local (hosted)
#   REGISTRY_WAIT   - сколько секунд ждать старта (по умолчанию 900: cloud-init
#                     ставит docker и тянет образы)
set -euo pipefail

: "${REGISTRY_URL:?}" "${ADMIN_PASSWORD:?}" "${REPOS:?}"
wait_secs="${REGISTRY_WAIT:-900}"
api="$REGISTRY_URL/api/v1"

echo "==> Ждём Artifact Keeper на $REGISTRY_URL (до ${wait_secs}s)"
deadline=$(( $(date +%s) + wait_secs ))
until curl -fsS --connect-timeout 5 --max-time 10 "$REGISTRY_URL/health" >/dev/null 2>&1; do
  if (( $(date +%s) > deadline )); then
    echo "Artifact Keeper не поднялся. Смотрите: yc compute instance get-serial-port-output <cluster>-registry" >&2
    exit 1
  fi
  sleep 10
done

login_body=$(python3 -c 'import json,os; print(json.dumps({"username":"admin","password":os.environ["ADMIN_PASSWORD"]}))')
token=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' -d "$login_body" "$api/auth/login" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["access_token"])')
auth=(-H "Authorization: Bearer $token" -H 'Content-Type: application/json')

echo "$REPOS" | python3 -c '
import sys, json
for r in json.load(sys.stdin):
    print(r["key"], r["format"], r.get("repo_type") or "remote", r.get("upstream_url") or "", r["name"], sep="\t")
' | while IFS=$'\t' read -r key format rtype upstream name; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${auth[@]}" "$api/repositories/$key")
  if [[ "$code" == "200" ]]; then
    echo "    $key: уже есть"
    continue
  fi
  body=$(python3 -c 'import json,sys; k,f,t,u,n=sys.argv[1:]
d={"key":k,"name":n,"format":f,"repo_type":t,"is_public":True,"allow_anonymous_access":True}
if u: d["upstream_url"]=u
print(json.dumps(d))' "$key" "$format" "$rtype" "$upstream" "$name")
  curl -fsS --max-time 60 "${auth[@]}" -d "$body" "$api/repositories" >/dev/null
  echo "    $key: создан ($rtype $format${upstream:+ <- $upstream})"
done

echo "==> Готово"
