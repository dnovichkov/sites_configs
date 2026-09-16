# Настройка сервера

Разовые шаги. Как добавлять проекты и деплоить — в [README.md](README.md).

## 1. DNS

У регистратора зоны `dmdp.ru` (reg.ru) добавьте одну запись:

```
*.dmdp.ru.   A   91.188.212.141
```

Существующие записи оставьте: явная запись важнее wildcard. Проверка:
`dig +short любое-имя.dmdp.ru` → `91.188.212.141`.

Wildcard в DNS не означает wildcard-сертификат. Caddy по-прежнему выпускает отдельный
сертификат на каждый домен из Caddyfile, поэтому DNS-challenge и API регистратора не нужны.
Для неизвестного поддомена у Caddy нет сертификата — такой запрос просто не пройдёт TLS.

Отдельным доменам (`uchim-stihi.ru`, `dz-tracker.ru`) нужна A-запись на тот же IP у их регистратора.

## 2. Файрвол

```bash
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp   # HTTP/3
sudo ufw enable
```

Порты приложений открывать не нужно: Caddy ходит к контейнерам через docker-сеть `web`.

## 3. Доступ сервера к GitHub

`deploy.sh` клонирует и обновляет репозитории по HTTPS, `ssh -A` больше не нужен.

- **Код.** Публичным репозиториям ничего не нужно. Для приватных — fine-grained токен
  с правом *Contents: read* на нужные репозитории:

  ```bash
  git config --global credential.helper store
  git ls-remote https://github.com/dnovichkov/<приватный-репозиторий>.git
  # логин — dnovichkov, пароль — токен; git запомнит его
  ```

- **Образы.** Пакеты в ghcr.io по умолчанию приватные, даже у публичного репозитория.
  Сделайте их публичными (страница пакета → *Package settings* → *Change visibility*)
  или один раз войдите токеном (classic) с правом `read:packages`:

  ```bash
  echo "<токен>" | docker login ghcr.io -u dnovichkov --password-stdin
  ```

## 4. Ключ деплоя для CI

На своей машине:

```bash
ssh-keygen -t ed25519 -N "" -C gha-deploy -f ~/.ssh/pets_deploy
```

На сервере добавьте в `/home/user/.ssh/authorized_keys` одну строку с содержимым `pets_deploy.pub`:

```
command="bash /home/user/projects/sites_configs/deploy.sh --ci",restrict ssh-ed25519 AAAA… gha-deploy
```

`restrict` запрещает терминал и все пробросы, а `command=` подменяет любую команду клиента
на `deploy.sh --ci`. Сама команда клиента попадает в `$SSH_ORIGINAL_COMMAND`, и `deploy.sh`
принимает оттуда только «`<репозиторий> [sha]`» из `deploy.list`. Даже утёкший ключ умеет
лишь перевыкатить один из ваших проектов.

Публичные ключи сервера уже записаны в `.github/workflows/deploy.yml` (`DEPLOY_KNOWN_HOSTS`):
по ним CI проверяет, что подключается именно к нему. Если сервер переустановят, обновите их
выводом `ssh-keyscan 91.188.212.141`.

Разложите приватный ключ по репозиториям (у личного аккаунта нет общих секретов организации):

```bash
gh auth login
scripts/set-deploy-secrets.sh ~/.ssh/pets_deploy
```

Пока секрета нет, job `deploy` в проектах пропускается с предупреждением.

Если `sites_configs` — приватный репозиторий, разрешите другим репозиториям вызывать его
workflow: *Settings* → *Actions* → *General* → *Access* →
«Accessible from repositories owned by the user».

## 5. Переход на новую схему

Порядок важен. CI проектов ссылается на workflow из `sites_configs`: пока их нет на GitHub,
у проекта падает весь запуск, включая сборку образа. А новый `deploy.sh` на сервере,
наоборот, ждёт уже переведённые compose-файлы проектов.

1. Запушьте `sites_configs` на GitHub (если репозиторий приватный — сначала откройте доступ
   к его workflow, см. раздел 4). На сервере пока ничего не делайте: собственный деплой
   `sites_configs` пропустится, потому что секрета ещё нет.
2. Закоммитьте и запушьте изменения в проектах. Их CI опубликует образы в ghcr.io,
   деплой тоже пропустится.
3. Выполните разовые шаги для проектов из таблицы ниже.
4. На сервере:

   ```bash
   cd /home/user/projects/sites_configs
   git pull
   bash deploy.sh
   ```

   Контейнер `projects-placeholder` удалится сам (`--remove-orphans`): витрину теперь отдаёт Caddy.
   Том `sites_configs_caddy_data` с сертификатами сохраняется, потому что имя проекта не меняется.

5. Настройте ключ деплоя (раздел 4). Дальше проекты разворачиваются сами после push.

### Разовые шаги для проектов

| Проект | До пуша проекта | На сервере |
|---|---|---|
| gift-planner | Сейчас прод работает без Supabase: данные хранятся только в браузере. Чтобы включить вход и синхронизацию, заведите в GitHub vars репозитория `VITE_SUPABASE_URL` и `VITE_SUPABASE_ANON_KEY` — Vite вшивает их при сборке, так что нужен новый коммит или перезапуск CI | — |
| learn-poetry | Проверить секреты `NEXT_PUBLIC_SUPABASE_URL` и `NEXT_PUBLIC_SUPABASE_ANON_KEY`: без них CI не соберёт образ | Проверить, что есть `docker/.env`. Прямо перед первым деплоем — `docker rm -f learn-poetry`: старый контейнер принадлежит compose-проекту `docker`, новый называется `learn-poetry` |
| craft-picker | — | Секреты читаются из `.env` рядом с compose-файлом; если они лежат в `.env.prod` — `ln -s .env.prod .env` |
| studyflow | — | В `.env` должны быть `VITE_SUPABASE_*` (подставляются при старте контейнера). Umami поднимается, только если добавить `COMPOSE_PROFILES=analytics`, `UMAMI_DB_PASSWORD` и `UMAMI_APP_SECRET` |
| Excel2Markdown | — | После первого удачного деплоя можно удалить ненужный том: `docker volume rm excel2markdown_static_files` |
| money-envelope | Новая схема — в ветке `feature/client-side-envelope-mvp`; до её мержа сервер собирает `main` сам (`mode = "build"`) | После мержа: в `projects.toml` убрать `api` и `mode = "build"`, запустить `python build.py`. Том `money-envelope_redis_data` можно удалить |
| netwalk_game, статические сайты | — | — |

Нужен свежий Docker Compose (`docker compose version` — 2.24 или новее): `deploy.sh`
ждёт healthcheck через `up --wait`, а learn-poetry использует необязательные `env_file`.

## Полезные команды

```bash
docker logs -f caddy                                             # логи, выпуск сертификатов
docker exec caddy caddy validate --config /etc/caddy/Caddyfile   # проверить конфиг
docker exec caddy caddy reload --config /etc/caddy/Caddyfile     # применить без перезапуска
docker network inspect web --format '{{range .Containers}}{{.Name}} {{end}}'
echo | openssl s_client -servername dz-tracker.ru -connect dz-tracker.ru:443 2>/dev/null \
  | openssl x509 -noout -dates                                   # срок сертификата
```

## Если что-то не работает

- **Caddy не получает сертификат** — DNS ещё не обновился (`dig +short домен`), закрыты 80/443
  или домен упёрся в лимиты Let's Encrypt; смотрите `docker logs caddy`.
- **502 Bad Gateway** — контейнер не запущен или не в сети `web`. Проверьте `docker ps` и список
  выше. Локально `python build.py` подскажет, если `container_name` в проекте не совпадает с реестром.
- **«нельзя перемотать … есть локальные коммиты?»** — на сервере правили файлы руками:
  `git -C /home/user/projects/<проект> status`.
- **«Проекта … нет в deploy.list»** — запись в `projects.toml` есть, но `python build.py`
  не запускали или результат не запушили.
