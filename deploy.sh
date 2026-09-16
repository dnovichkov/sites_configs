#!/usr/bin/env bash
#
# deploy.sh — разворачивает проекты на сервере.
#
#   ./deploy.sh                  все проекты
#   ./deploy.sh <repo> [tag]     один проект; tag — тег образа (по умолчанию latest),
#                                полный sha заодно фиксирует и коммит репозитория
#   ./deploy.sh --list           список проектов
#   ./deploy.sh --ci             для SSH forced command: "<repo> [sha]" из $SSH_ORIGINAL_COMMAND
#
# Список проектов — deploy.list. Его генерирует build.py из projects.toml; руками не правится.
#
# Режимы:
#   self    сам sites_configs: git → compose up → caddy reload. Выполняется перед любым деплоем,
#           поэтому новый проект из реестра получает маршрут до того, как запустится.
#   image   git → compose up --pull (образы собирает CI) → ждём healthcheck
#   build   git → compose up --build (сборка на сервере — для ещё не переведённых проектов)
#   static  git (файлы раздаёт Caddy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
BASE_DIR="${DEPLOY_BASE_DIR:-$(dirname "$SCRIPT_DIR")}"
readonly BASE_DIR
readonly LIST_FILE="$SCRIPT_DIR/deploy.list"
readonly GITHUB_OWNER="${GITHUB_OWNER:-dnovichkov}"
# HTTPS не требует ssh-agent на сервере. Для приватных репозиториев нужен git credential helper
# (см. INSTALL.md); вернуть SSH можно так: GIT_URL_TEMPLATE='git@github.com:%s/%s.git'.
readonly GIT_URL_TEMPLATE="${GIT_URL_TEMPLATE:-https://github.com/%s/%s.git}"
readonly LOCK_FILE="${DEPLOY_LOCK_FILE:-/tmp/pets-deploy.lock}"
# Столько сайт может пролежать, прежде чем сработает откат; самому медленному сервису
# (craft-picker: миграции и start_period 40s) хватает с запасом.
readonly WAIT_TIMEOUT="${DEPLOY_WAIT_TIMEOUT:-120}"
readonly ROLLBACK_TAG="rollback"

readonly SELF_REPO="sites_configs"
readonly SELF_ENTRY="$SELF_REPO|self|main|docker-compose.yml,compose.static.yml"
readonly SHA_RE='^[0-9a-f]{40}$'
readonly TAG_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
readonly ARGS=("$@")

readonly RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' BLUE=$'\033[0;34m' NC=$'\033[0m'

log()  { printf '%s[deploy]%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s  ⚠%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s  ✗%s %s\n' "$RED" "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ── Список проектов ──────────────────────────────────────────────────────────

ENTRIES=()

load_list() {
  [ -f "$LIST_FILE" ] || die "Нет $LIST_FILE — запустите python build.py и закоммитьте результат"
  ENTRIES=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in '' | '#'*) continue ;; esac
    ENTRIES+=("$line")
  done <"$LIST_FILE"
}

find_entry() {
  local entry
  for entry in "${ENTRIES[@]}"; do
    if [ "${entry%%|*}" = "$1" ]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done
  return 1
}

show_list() {
  printf 'Проекты (deploy.list):\n\n'
  printf '  %-45s %s\n' "$SELF_REPO" "self (Caddy и витрина)"
  local entry repo mode branch files
  for entry in "${ENTRIES[@]}"; do
    IFS='|' read -r repo mode branch files <<<"$entry"
    printf '  %-45s %s, %s%s\n' "$repo" "$mode" "$branch" "${files:+, $files}"
  done
  printf '\n'
}

# ── Git ──────────────────────────────────────────────────────────────────────

GIT_CHANGED=0

# git_update <каталог> <repo> <ветка> [sha]
# Приводит рабочую копию к голове ветки или к указанному коммиту из неё. Только fast-forward:
# правки, сделанные прямо на сервере, останавливают деплой, а не теряются.
git_update() {
  local dir=$1 repo=$2 branch=$3 ref=${4:-}
  local url
  # shellcheck disable=SC2059  # шаблон задаётся переменной окружения намеренно
  url=$(printf "$GIT_URL_TEMPLATE" "$GITHUB_OWNER" "$repo")

  local before=""
  if [ -d "$dir/.git" ]; then
    before=$(git -C "$dir" rev-parse HEAD)
  else
    warn "Нет $dir — клонирую $url"
    git clone --quiet --branch "$branch" "$url" "$dir"
  fi
  # Сеть до GitHub иногда моргает: без повтора деплой падал бы на ровном месте.
  local attempt
  for attempt in 1 2 3; do
    git -C "$dir" fetch --quiet "$url" "$branch" && break
    [ "$attempt" = 3 ] && die "Не удалось получить $branch из $url за три попытки"
    warn "git fetch не удался, повторяю через $((attempt * 5)) с"
    sleep $((attempt * 5))
  done
  if [ -n "$ref" ]; then
    git -C "$dir" merge-base --is-ancestor "$ref" FETCH_HEAD ||
      die "Коммит $ref не найден в ветке $branch — деплоятся только коммиты из неё"
  else
    ref=$(git -C "$dir" rev-parse FETCH_HEAD)
  fi
  if [ "$(git -C "$dir" branch --show-current)" != "$branch" ]; then
    git -C "$dir" checkout --quiet "$branch" 2>/dev/null ||
      git -C "$dir" checkout --quiet -b "$branch" "$ref"
  fi
  git -C "$dir" merge --quiet --ff-only "$ref" ||
    die "В $dir нельзя перемотать $branch до $ref — есть локальные коммиты? (git -C $dir status)"

  local head
  head=$(git -C "$dir" rev-parse --short HEAD)
  if [ -z "$before" ]; then
    GIT_CHANGED=1
    ok "Склонировано ($head)"
  elif [ "$(git -C "$dir" rev-parse HEAD)" = "$before" ]; then
    GIT_CHANGED=0
    ok "Код не изменился ($head)"
  else
    GIT_CHANGED=1
    ok "Код обновлён: $(git -C "$dir" rev-parse --short "$before") → $head"
  fi
}

# ── Docker ───────────────────────────────────────────────────────────────────

PROJECT_DIR=""
COMPOSE_FILES=()

# docker compose в каталоге текущего проекта и с его compose-файлами.
compose() {
  (cd "$PROJECT_DIR" && docker compose "${COMPOSE_FILES[@]}" "$@")
}

# На сервере живут и чужие проекты, поэтому чистим только свои образы из ghcr.io:
# у каждого остаются три последние сборки (на них можно откатиться), остальные
# удаляются, если ими не пользуется ни один контейнер. Плюс слои без тегов.
KEEP_BUILDS=3
prune_images() {
  local repo tag repos
  # «|| true»: у образа может не быть ни одного sha-тега, и grep тогда вернёт 1 —
  # при set -e и pipefail это оборвало бы скрипт уже после успешного деплоя.
  repos=$(docker images --format '{{.Repository}}' \
    --filter "reference=ghcr.io/$GITHUB_OWNER/*" --filter "reference=ghcr.io/$GITHUB_OWNER/*/*" | sort -u) || true
  for repo in $repos; do
    # docker images выводит теги от новых к старым.
    for tag in $(docker images "$repo" --format '{{.Tag}}' | grep -E "$SHA_RE" | tail -n +$((KEEP_BUILDS + 1)) || true); do
      docker rmi "$repo:$tag" >/dev/null 2>&1 || true
    done
  done
  docker image prune --force >/dev/null 2>&1 || true
}

ensure_network() {
  if ! docker network inspect web >/dev/null 2>&1; then
    docker network create web >/dev/null
    ok "Создана docker-сеть web"
  fi
}

# Тег нашего образа (ghcr.io/<owner>/…), с которым сейчас работают контейнеры проекта.
running_tag() {
  local id ref
  for id in $(compose ps -q 2>/dev/null || true); do
    ref=$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null) || continue
    case "$ref" in
      "ghcr.io/$GITHUB_OWNER/"*:*)
        printf '%s\n' "${ref##*:}"
        return 0
        ;;
    esac
  done
}

# Образы, на которых сервисы проекта работают до деплоя: «сервис=id образа».
# Запоминаются именно id: прежний образ мог быть собран на сервере или иметь тег latest,
# который pull уже перенёс на новую сборку.
SNAPSHOT=()
snapshot_images() {
  SNAPSHOT=()
  local id entry
  for id in $(compose ps -q 2>/dev/null || true); do
    entry=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}={{.Image}}' "$id" 2>/dev/null) ||
      continue
    SNAPSHOT+=("$entry")
  done
}

snapshot_image() {
  local entry
  for entry in "${SNAPSHOT[@]}"; do
    if [ "${entry%%=*}" = "$1" ]; then
      printf '%s\n' "${entry#*=}"
      return 0
    fi
  done
  return 0
}

# «сервис образ» для каждого сервиса проекта при текущем IMAGE_TAG.
service_images() {
  compose config --format json | python3 -c '
import json, sys
for name, service in json.load(sys.stdin)["services"].items():
    print(name, service.get("image", ""))
'
}

# Новые контейнеры не стали healthy: сервисы с нашими образами (ghcr.io/<owner>/…) возвращаются
# к образам, на которых работали до деплоя. Откатываются только образы — compose-файл остаётся
# новым, и миграции базы, если новая версия успела их применить, не отменяются.
# Код возврата всегда ненулевой: выкатка не удалась, даже если откат прошёл.
on_failed_rollout() {
  local repo=$1 tag=$2
  err "$repo: контейнеры с тегом $tag не поднялись (ждали до ${WAIT_TIMEOUT}s)"
  if [ ${#SNAPSHOT[@]} -eq 0 ]; then
    warn "До деплоя контейнеры проекта не работали — откатываться не на что"
    return 1
  fi

  local mapping service image old
  if ! mapping=$(service_images); then
    err "Не удалось прочитать compose-конфигурацию — откатите вручную"
    return 1
  fi
  while read -r service image; do
    case "$image" in
      "ghcr.io/$GITHUB_OWNER/"*) ;;
      *) continue ;; # postgres, redis и другие чужие образы деплой не меняет
    esac
    old=$(snapshot_image "$service")
    # Сервис, которого до деплоя не было, остаётся на новом образе.
    docker tag "${old:-$image}" "${image%:*}:$ROLLBACK_TAG"
  done <<<"$mapping"

  log "Откатываю $repo к образам, на которых он работал до деплоя"
  export IMAGE_TAG=$ROLLBACK_TAG
  if compose up -d --no-build --pull never --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"; then
    warn "$repo снова работает на прежних образах, а выкатка $tag не удалась"
  else
    err "$repo: откат тоже не удался — проверьте вручную (docker compose ps, logs)"
  fi
  return 1
}

deploy_image() {
  local repo=$1 tag=$2
  local previous image
  previous=$(running_tag)
  snapshot_images
  export IMAGE_TAG=$tag

  log "Образы с тегом $tag${previous:+ (сейчас работает $previous)}"
  # Свои образы проверяем в реестре всегда: CI мог пересобрать тот же sha, например после
  # смены vars. Чужие (postgres, redis) качаем, только если их нет, — без внезапных обновлений баз.
  for image in $(compose config --images); do
    case "$image" in
      "ghcr.io/$GITHUB_OWNER/"*) docker pull --quiet "$image" >/dev/null ;;
    esac
  done
  if compose up -d --pull missing --no-build --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"; then
    ok "Запущено"
    return 0
  fi
  compose ps --all || true
  compose logs --no-color --tail 40 || true
  on_failed_rollout "$repo" "$tag"
}

deploy_build() {
  if [ "$GIT_CHANGED" = 0 ] && [ -n "$(compose ps -q --status running)" ]; then
    ok "Контейнеры уже запущены — пересборка не нужна"
    return 0
  fi
  compose up -d --build --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"
  ok "Собрано и запущено"
}

deploy_self() {
  # Каталоги статических сайтов монтируются в Caddy. Если их ещё нет, Docker создал бы
  # пустые каталоги от root, и git clone в них потом не смог бы писать.
  load_list
  local entry repo mode branch files
  for entry in "${ENTRIES[@]}"; do
    IFS='|' read -r repo mode branch files <<<"$entry"
    if [ "$mode" = static ] && [ ! -d "$BASE_DIR/$repo/.git" ]; then
      git_update "$BASE_DIR/$repo" "$repo" "$branch"
    fi
  done

  compose up -d --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"
  # Caddyfile и site/ смонтированы каталогами, так что reload видит новые файлы без перезапуска.
  # Неизменившийся конфиг Caddy не применяет повторно.
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile
  ok "Caddy перечитал конфигурацию"
}

# deploy_one "<repo|mode|branch|files>" [tag]
# Запускать только в подоболочке с set -e: см. run_isolated.
deploy_one() {
  local repo mode branch files tag=${2:-}
  IFS='|' read -r repo mode branch files <<<"$1"

  PROJECT_DIR="$BASE_DIR/$repo"
  COMPOSE_FILES=()
  local file
  local -a file_list=()
  [ -n "$files" ] && IFS=',' read -r -a file_list <<<"$files"
  for file in "${file_list[@]}"; do
    COMPOSE_FILES+=(-f "$file")
  done

  printf '\n'
  log "${YELLOW}$repo${NC} — $mode${tag:+, $tag}"

  local sha=""
  [[ $tag =~ $SHA_RE ]] && sha=$tag
  git_update "$PROJECT_DIR" "$repo" "$branch" "$sha"

  case "$mode" in
    self) deploy_self ;;
    image) deploy_image "$repo" "${tag:-latest}" ;;
    build) deploy_build ;;
    static) ok "Файлы раздаёт Caddy — больше ничего не нужно" ;;
    *) die "Неизвестный режим «$mode» в deploy.list" ;;
  esac
}

# set -e не действует внутри функций, вызванных из if/&&/||. Поэтому каждый проект
# разворачивается в отдельной подоболочке, запущенной вне условия: первая же ошибка
# останавливает только этот проект, а статус забирается из $?.
RUN_STATUS=0
run_isolated() {
  set +e
  (
    set -e
    deploy_one "$@"
  )
  RUN_STATUS=$?
  set -e
}

# ── Точка входа ──────────────────────────────────────────────────────────────

acquire_lock() {
  # При перезапуске через exec дескриптор 9 уже держит блокировку.
  [ -n "${DEPLOY_REEXEC:-}" ] && return 0
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Идёт другой деплой — жду освобождения…"
    flock 9
  fi
}

parse_ci_command() {
  local cmd=${SSH_ORIGINAL_COMMAND:-}
  local re='^([A-Za-z0-9][A-Za-z0-9._-]*)( ([0-9a-f]{40}))?$'
  [[ $cmd =~ $re ]] || die "Отклонено: ожидается «<репозиторий> [sha]», получено «$cmd»"
  CI_REPO=${BASH_REMATCH[1]}
  CI_SHA=${BASH_REMATCH[3]}
}

script_digest() {
  cat "$SCRIPT_DIR/deploy.sh" "$LIST_FILE" 2>/dev/null | md5sum || true
}

# Сначала всегда обновляется сам sites_configs: так применяются новые маршруты,
# а если поменялись deploy.sh или deploy.list — скрипт перезапускается уже новым.
# Итог (ok/failed) сохраняется в DEPLOY_SELF_RESULT и переживает перезапуск.
sync_self() {
  local target=$1 tag=$2
  [ -n "${DEPLOY_REEXEC:-}" ] && return 0

  local ref="" before after
  [ "$target" = "$SELF_REPO" ] && ref=$tag
  before=$(script_digest)

  run_isolated "$SELF_ENTRY" "$ref"
  if [ "$RUN_STATUS" -eq 0 ]; then
    DEPLOY_SELF_RESULT=ok
  else
    [ "$target" = "$SELF_REPO" ] && exit "$RUN_STATUS"
    DEPLOY_SELF_RESULT=failed
    warn "sites_configs не обновился — продолжаю с текущим списком проектов"
  fi

  after=$(script_digest)
  if [ "$before" != "$after" ]; then
    log "deploy.sh или deploy.list изменились — перезапускаюсь"
    DEPLOY_REEXEC=1 DEPLOY_SELF_RESULT=$DEPLOY_SELF_RESULT exec bash "$SCRIPT_DIR/deploy.sh" "${ARGS[@]}"
  fi
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      return 0
      ;;
    --list)
      load_list
      show_list
      return 0
      ;;
    --ci)
      parse_ci_command
      [ "$CI_REPO" = all ] && die "Отклонено: из CI разворачивается только один проект"
      set -- "$CI_REPO" "$CI_SHA"
      ;;
    all) shift ;; # по старой привычке: ./deploy.sh all
    -*) die "Неизвестный параметр $1 (см. --help)" ;;
  esac

  local target=${1:-} tag=${2:-}
  if [ -n "$tag" ] && ! [[ $tag =~ $TAG_RE ]]; then
    die "Некорректный тег: $tag"
  fi

  acquire_lock
  if [ -z "${DEPLOY_REEXEC:-}" ]; then
    printf '================================================\n'
    printf '  Деплой пет-проектов: %s, %s\n' "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '================================================\n'
  fi
  ensure_network
  sync_self "$target" "$tag"
  load_list

  local -a queue=()
  if [ -z "$target" ]; then
    queue=("${ENTRIES[@]}")
  elif [ "$target" != "$SELF_REPO" ]; then
    local entry
    entry=$(find_entry "$target") || {
      show_list
      die "Проекта $target нет в deploy.list"
    }
    queue=("$entry")
  fi

  local -a deployed=() failed=()
  case "${DEPLOY_SELF_RESULT:-}" in
    ok) deployed+=("$SELF_REPO") ;;
    failed) failed+=("$SELF_REPO") ;;
  esac
  local item
  for item in "${queue[@]}"; do
    run_isolated "$item" "$tag"
    if [ "$RUN_STATUS" -eq 0 ]; then
      deployed+=("${item%%|*}")
    else
      failed+=("${item%%|*}")
    fi
  done

  prune_images

  printf '\n================================================\n'
  [ ${#deployed[@]} -gt 0 ] && ok "Готово (${#deployed[@]}): ${deployed[*]}"
  if [ ${#failed[@]} -gt 0 ]; then
    err "С ошибками (${#failed[@]}): ${failed[*]}"
    return 1
  fi
}

# Весь запуск — одна строка: bash дочитывает файл по ходу выполнения, а git pull
# может заменить deploy.sh прямо во время работы.
main "$@"; exit $?
