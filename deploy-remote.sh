#!/usr/bin/env bash
#
# deploy-remote.sh — запускает deploy.sh на сервере со своей машины.
#
#   ./deploy-remote.sh                 все проекты
#   ./deploy-remote.sh <repo> [tag]    один проект
#   ./deploy-remote.sh --list          список проектов
#
# Нужен ваш обычный SSH-доступ к серверу. Ключ CI для этого не подходит:
# он ограничен forced command и умеет только «<repo> [sha]».

set -euo pipefail

SERVER="${DEPLOY_HOST:-91.188.212.141}"
SERVER_USER="${DEPLOY_USER:-user}"
DEPLOY_SCRIPT="/home/user/projects/sites_configs/deploy.sh"

# Аргументы экранируются: удалённая сторона склеивает их в одну строку для shell.
ssh -t "${SERVER_USER}@${SERVER}" "bash ${DEPLOY_SCRIPT} $(printf '%q ' "$@")"
