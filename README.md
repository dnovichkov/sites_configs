# sites_configs

Единая точка входа для веб-проектов на сервере `91.188.212.141`: Caddy (HTTPS для всех доменов),
витрина [projects.dmdp.ru](https://projects.dmdp.ru) и деплой. Разовая настройка сервера — в [INSTALL.md](INSTALL.md).

## Как устроено

```
projects.toml ── python build.py ──▶ caddy/Caddyfile      маршруты
   (руками)                          compose.static.yml   статические сайты в контейнере Caddy
                                     deploy.list          что и как разворачивает deploy.sh
                                     site/index.html      витрина
```

- Сгенерированные файлы лежат в git: серверу нужны только `git` и `docker`. CI (`check.yml`)
  падает, если генерацию забыли запустить, и проверяет Caddyfile официальным образом Caddy.
- Caddy находит контейнеры проектов по `container_name` в общей docker-сети `web`,
  поэтому публиковать порты на хосте проектам не нужно.
- Деплой проекта:

  ```
  push в основную ветку ─▶ CI: тесты ─▶ образ в ghcr.io (теги latest и <sha>)
      ─▶ ssh с ключом, которому разрешена только команда deploy.sh --ci
      ─▶ deploy.sh: обновить sites_configs ─▶ git проекта до <sha>
                    ─▶ docker compose up --pull ─▶ ждать healthcheck
  ```

  Перед каждым деплоем `deploy.sh` обновляет сам `sites_configs`, так что маршрут нового
  проекта появляется раньше, чем проект запустится.

## Добавить проект

### Сайт

1. В репозитории проекта — `docker-compose.prod.yml` и CI по [контракту](#контракт-веб-проекта).
2. В `projects.toml` — запись (все поля описаны в шапке файла):

   ```toml
   [[project]]
   id = "foo"
   title = "Foo"
   description = "Что делает проект — одной фразой."
   category = "tools"
   icon = "foo.svg"          # файл в site/icons/
   web = "foo.dmdp.ru"
   upstream = "foo:80"       # container_name:порт

   [project.deploy]
   repo = "foo"
   ```

3. `python build.py`, коммит, push. Для нового репозитория — ещё
   `scripts/set-deploy-secrets.sh ~/.ssh/pets_deploy`, чтобы у него появился ключ деплоя.

DNS трогать не нужно: `*.dmdp.ru` уже указывает на сервер. Отдельному домену
(как `uchim-stihi.ru`) нужна A-запись у регистратора.

Бэкенд в отдельном контейнере — поле `api` (для `/api/*`); старые адреса — `aliases`
(постоянный редирект); сайт, который не нужно показывать на витрине, — `hidden = true`.

### Приложение в RuStore

Только запись с `rustore = "<package name>"` и иконкой: маршрута и деплоя у неё нет.

### Статический сайт

`mode = "static"` в `[project.deploy]`: Caddy раздаёт файлы прямо из репозитория, а служебные
(`/.git`, `node_modules`, `android/` и т. п.) закрывает. В CI проекта достаточно вызвать деплой:

```yaml
jobs:
  deploy:
    uses: dnovichkov/sites_configs/.github/workflows/deploy.yml@main
    secrets: inherit
```

## Контракт веб-проекта

```yaml
# docker-compose.prod.yml
name: foo                        # не меняется: от имени проекта зависят имена томов

services:
  foo:
    image: ghcr.io/dnovichkov/foo:${IMAGE_TAG:-latest}
    build: .                     # необязательно: для CI и локальной сборки
    container_name: foo          # = upstream в projects.toml
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1/"]
      interval: 30s
    networks: [web]              # плюс default, если сервису нужны соседние контейнеры

networks:
  web:
    external: true
```

- `ports:` не нужны: снаружи сайт доступен только через Caddy.
- `${IMAGE_TAG}` обязателен: по нему `deploy.sh` выкатывает ровно тот коммит, который собрал CI.
- Секреты — в `.env` рядом с compose-файлом на сервере, не в git.
- `python build.py` сверяет реестр с соседними репозиториями (если они лежат рядом)
  и предупреждает, если нет `container_name`, есть `ports` или не используется `IMAGE_TAG`.

CI проекта — сборка через общий workflow и деплой после неё:

```yaml
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:             # «Run workflow»: пересобрать и выкатить голову основной ветки

jobs:
  # … тесты …

  image:
    needs: [test]
    uses: dnovichkov/sites_configs/.github/workflows/build-image.yml@main
    permissions:
      contents: read
      packages: write
    with:
      image: foo                 # → ghcr.io/dnovichkov/foo
      build-args: |
        VITE_SITE_URL=https://foo.dmdp.ru

  deploy:
    needs: [image]
    if: github.event_name != 'pull_request' && github.ref_name == github.event.repository.default_branch
    uses: dnovichkov/sites_configs/.github/workflows/deploy.yml@main
    secrets: inherit
```

Если сборке нужны секреты (в `with:` доступны только `vars`), образ собирается своими шагами
с тегами `latest` и полным sha (`docker/metadata-action`: `type=sha,format=long,prefix=`).

## Деплой вручную

```bash
./deploy-remote.sh --list
./deploy-remote.sh                        # всё
./deploy-remote.sh craft-picker           # один проект с образом latest
./deploy-remote.sh craft-picker <sha>     # конкретный коммит — так делает CI
```

Откат: перезапустить job `deploy` у предыдущего успешного запуска в GitHub Actions
или `./deploy-remote.sh <repo> <sha старого коммита>`. На сервере хранятся три последние
сборки каждого образа; чужие образы и тома `deploy.sh` не трогает.

## Файлы

| Файл | Кто правит |
|---|---|
| `projects.toml` | вы |
| `build.py` | вы |
| `caddy/snippets.caddy` | вы |
| `caddy/Caddyfile`, `compose.static.yml`, `deploy.list`, `site/index.html` | `build.py` |
| `site/style.css`, `site/favicon.svg`, `site/icons/`, `site/fonts/` | вы |
| `docker-compose.yml` | вы |
| `deploy.sh`, `deploy-remote.sh`, `scripts/` | вы |
| `.github/workflows/` | вы (`build-image.yml` и `deploy.yml` вызываются из проектов) |
