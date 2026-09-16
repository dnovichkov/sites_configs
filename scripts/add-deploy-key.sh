#!/usr/bin/env bash
#
# add-deploy-key.sh — даёт серверу доступ на чтение к приватному репозиторию без токенов.
#
#   scripts/add-deploy-key.sh <репозиторий>
#
# Что делает (повторный запуск ничего не ломает):
#   1. заводит на сервере отдельный SSH-ключ ~/.ssh/deploy_<репозиторий>
#      и алиас github-<репозиторий> в ~/.ssh/config;
#   2. настраивает git на сервере: https-адрес репозитория, который использует deploy.sh,
#      подменяется на SSH через этот ключ (url.<…>.insteadOf);
#   3. добавляет публичный ключ в репозиторий как deploy key — только чтение, без срока действия;
#   4. проверяет, что сервер видит репозиторий.
#
# Нужны GitHub CLI (gh auth login) и SSH-доступ к серверу. Команду подключения можно переопределить:
#   SERVER_SSH="ssh -i ~/.ssh/other_key user@host" scripts/add-deploy-key.sh craft-picker

set -euo pipefail

repo=${1:?Укажите репозиторий, например craft-picker}
owner=${GITHUB_OWNER:-dnovichkov}
read -r -a server <<<"${SERVER_SSH:-ssh user@91.188.212.141}"

if ! [[ $repo =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Некорректное имя репозитория: $repo" >&2
  exit 1
fi

pub=$("${server[@]}" "bash -s $owner $repo" <<'REMOTE'
set -euo pipefail
owner=$1 repo=$2
key=~/.ssh/deploy_$repo
alias=github-$repo
[ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -C "deploy $(hostname) $owner/$repo" -f "$key"
if ! grep -qx "Host $alias" ~/.ssh/config 2>/dev/null; then
  printf '\nHost %s\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' \
    "$alias" "$key" >>~/.ssh/config
  chmod 600 ~/.ssh/config
fi
# Ключи github.com берутся из API GitHub (по HTTPS), а не принимаются на веру при первом подключении.
if ! ssh-keygen -F github.com >/dev/null; then
  curl -fsS https://api.github.com/meta |
    python3 -c 'import json, sys; [print("github.com", k) for k in json.load(sys.stdin)["ssh_keys"]]' \
      >>~/.ssh/known_hosts
fi
git config --global "url.git@$alias:$owner/$repo.git.insteadOf" "https://github.com/$owner/$repo.git"
cat "$key.pub"
REMOTE
)

key_body=$(awk '{print $2}' <<<"$pub")
if gh repo deploy-key list --repo "$owner/$repo" --json key --jq '.[].key' | grep -qF "$key_body"; then
  echo "  ✓ deploy key уже добавлен в $owner/$repo"
else
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$pub" >"$tmp"
  gh repo deploy-key add "$tmp" --repo "$owner/$repo" --title "server: $(awk '{print $4}' <<<"$pub")"
  echo "  ✓ deploy key добавлен в $owner/$repo (только чтение)"
fi

# credential.helper= отключает сохранённые пароли: проверяем именно доступ по ключу.
if "${server[@]}" "GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote https://github.com/$owner/$repo.git HEAD >/dev/null"; then
  echo "  ✓ сервер читает $owner/$repo по deploy key"
else
  echo "  ✗ сервер не получил доступ к $owner/$repo" >&2
  exit 1
fi
