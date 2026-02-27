#!/bin/bash
#
# deploy.sh — Deploy pet projects on the server
#
# Usage:
#   ./deploy.sh              Deploy all projects
#   ./deploy.sh <project>    Deploy specific project
#   ./deploy.sh --list       Show available projects
#
set -euo pipefail

BASE_DIR="/home/user/projects"
GITHUB_USER="dnovichkov"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()  { echo -e "${BLUE}[deploy]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }
err()  { echo -e "${RED}  ✗${NC} $1"; }

# Project definitions: name|compose_file|strategy|github_repo
# strategy: "docker" = git pull + docker compose build + up
#           "docker-nobuild" = git pull + docker compose up (no build, image pull)
#           "static" = git pull only
PROJECTS=(
  "sites_configs|docker-compose.yml|docker-nobuild|sites_configs"
  "craft-picker|docker-compose.prod.yml|docker|craft-picker"
  "money-envelope|docker-compose.prod.yml|docker|money-envelope"
  "Excel2Markdown|docker-compose.yml|docker|Excel2Markdown"
  "learn-poetry|docker/docker-compose.yml|docker|learn-poetry"
  "studyflow|docker-compose.yml|docker|studyflow"
  "gift-planner|docker-compose.yml|docker|gift-planner"
  "netwalk_game|docker-compose.yml|docker|netwalk_game"
  "english_training||static|english_training"
  "math_training||static|math_training"
  "russkij-yazyk-2-klass-kanakina-trenazhery||static|russkij-yazyk-2-klass-kanakina-trenazhery"
)

show_list() {
  echo "Available projects:"
  echo ""
  for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r name compose strategy repo <<< "$entry"
    case "$strategy" in
      docker)         label="Docker (build)" ;;
      docker-nobuild) label="Docker (no build)" ;;
      static)         label="Static files" ;;
    esac
    printf "  %-45s %s\n" "$name" "$label"
  done
  echo ""
  echo "Usage: ./deploy.sh [project-name|--list]"
}

ensure_network() {
  if ! docker network inspect web &>/dev/null; then
    log "Creating Docker network 'web'..."
    docker network create web
    ok "Network 'web' created"
  fi
}

clone_if_missing() {
  local name="$1"
  local repo="$2"
  local dir="$BASE_DIR/$name"

  if [ ! -d "$dir" ]; then
    warn "Directory $dir not found, cloning..."
    git clone "git@github.com:${GITHUB_USER}/${repo}.git" "$dir"
    ok "Cloned $repo"
  fi
}

deploy_project() {
  local name="$1"
  local compose="$2"
  local strategy="$3"
  local repo="$4"
  local dir="$BASE_DIR/$name"

  echo ""
  log "Deploying ${YELLOW}${name}${NC}..."

  # Clone if missing
  clone_if_missing "$name" "$repo"

  # Git pull
  cd "$dir"
  local pull_output
  pull_output=$(git pull 2>&1) || {
    err "git pull failed: $pull_output"
    return 1
  }

  if [ "$pull_output" = "Already up to date." ]; then
    ok "Already up to date"
    # If static site, nothing more to do
    if [ "$strategy" = "static" ]; then
      return 0
    fi
    # For Docker projects, still check if containers are running
    if [ -n "$compose" ]; then
      local running
      running=$(docker compose -f "$compose" ps -q 2>/dev/null | wc -l)
      if [ "$running" -gt 0 ]; then
        ok "Containers already running ($running)"
        return 0
      fi
      warn "Containers not running, starting..."
    fi
  else
    ok "Pulled new changes"
  fi

  case "$strategy" in
    static)
      ok "Static site updated"
      ;;
    docker)
      docker compose -f "$compose" build --quiet 2>&1 && ok "Built" || { err "Build failed"; return 1; }
      docker compose -f "$compose" up -d --remove-orphans 2>&1 && ok "Started" || { err "Start failed"; return 1; }
      ;;
    docker-nobuild)
      docker compose -f "$compose" up -d --remove-orphans 2>&1 && ok "Started" || { err "Start failed"; return 1; }
      ;;
  esac

  return 0
}

reload_caddy() {
  log "Reloading Caddy configuration..."
  local caddy_id
  caddy_id=$(docker ps -q -f name=caddy)
  if [ -n "$caddy_id" ]; then
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>&1 && ok "Caddy reloaded" || warn "Caddy reload failed (may need restart)"
  else
    warn "Caddy container not running"
  fi
}

cleanup() {
  log "Cleaning up dangling images..."
  docker image prune -f --filter "until=24h" &>/dev/null && ok "Cleanup done" || true
}

# --- Main ---

if [ "${1:-}" = "--list" ]; then
  show_list
  exit 0
fi

TARGET="${1:-all}"

echo "================================================"
echo "  Pet Projects Deployment"
echo "  Server: $(hostname) | $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================"

ensure_network

FAILED=()
DEPLOYED=()

if [ "$TARGET" = "all" ]; then
  for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r name compose strategy repo <<< "$entry"
    if deploy_project "$name" "$compose" "$strategy" "$repo"; then
      DEPLOYED+=("$name")
    else
      FAILED+=("$name")
    fi
  done
else
  # Find matching project
  FOUND=false
  for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r name compose strategy repo <<< "$entry"
    if [ "$name" = "$TARGET" ]; then
      FOUND=true
      if deploy_project "$name" "$compose" "$strategy" "$repo"; then
        DEPLOYED+=("$name")
      else
        FAILED+=("$name")
      fi
      break
    fi
  done
  if [ "$FOUND" = false ]; then
    err "Unknown project: $TARGET"
    echo ""
    show_list
    exit 1
  fi
fi

# Reload Caddy after deploying sites_configs or all
if [ "$TARGET" = "all" ] || [ "$TARGET" = "sites_configs" ]; then
  reload_caddy
fi

cleanup

# Summary
echo ""
echo "================================================"
echo "  Deployment Summary"
echo "================================================"
if [ ${#DEPLOYED[@]} -gt 0 ]; then
  ok "Deployed (${#DEPLOYED[@]}): ${DEPLOYED[*]}"
fi
if [ ${#FAILED[@]} -gt 0 ]; then
  err "Failed (${#FAILED[@]}): ${FAILED[*]}"
  exit 1
fi
echo ""
