#!/usr/bin/env bash
#
# set-deploy-secrets.sh — кладёт приватный ключ деплоя в секрет DEPLOY_SSH_KEY
# самого sites_configs и каждого репозитория из deploy.list.
#
#   scripts/set-deploy-secrets.sh ~/.ssh/pets_deploy
#
# Нужен GitHub CLI с доступом к репозиториям (gh auth login). У личного аккаунта
# нет секретов уровня организации, поэтому ключ раскладывается по репозиториям;
# после добавления проекта в реестр скрипт достаточно запустить ещё раз.

set -euo pipefail

key=${1:?Укажите путь к приватному ключу деплоя}
owner=${GITHUB_OWNER:-dnovichkov}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

[ -f "$key" ] || {
  echo "Нет файла $key" >&2
  exit 1
}
grep -q "PRIVATE KEY" "$key" || {
  echo "$key не похож на приватный ключ" >&2
  exit 1
}

repos=(sites_configs)
while IFS='|' read -r repo _; do
  case "$repo" in '' | '#'*) continue ;; esac
  repos+=("$repo")
done <"$root/deploy.list"

for repo in "${repos[@]}"; do
  gh secret set DEPLOY_SSH_KEY --repo "$owner/$repo" <"$key"
  echo "  ✓ $owner/$repo"
done
