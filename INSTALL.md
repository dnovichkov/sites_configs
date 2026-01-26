# Инструкция по настройке Caddy + HTTPS

## Шаг 1: Настрой DNS (у регистратора доменов)

Создай A-записи для каждого домена:

```
dz-tracker.ru   →  A  →  91.188.212.141
uchim-stihi.ru  →  A  →  91.188.212.141
```

DNS может обновляться от 5 минут до нескольких часов.

Проверить можно командой:
```bash
dig dz-tracker.ru +short
# Должен вернуть: 91.188.212.141
```

---

## Шаг 2: Закрой прямой доступ к портам приложений

В docker-compose.yml **каждого приложения** измени секцию ports:

### dz-tracker (docker-compose.yml):
```yaml
# БЫЛО:
ports:
  - "3001:3000"   # или какой там порт

# СТАЛО:
ports:
  - "127.0.0.1:3001:3000"
```

### uchim-stihi (docker-compose.yml):
```yaml
# БЫЛО:
ports:
  - "3000:3000"

# СТАЛО:
ports:
  - "127.0.0.1:3000:3000"
```

Перезапусти каждое приложение:
```bash
cd /путь/к/dz-tracker
docker-compose down && docker-compose up -d

cd /путь/к/uchim-stihi
docker-compose down && docker-compose up -d
```

---

## Шаг 3: Установи Caddy

```bash
# Создай папку
mkdir -p ~/caddy
cd ~/caddy

# Скопируй туда файлы docker-compose.yml и Caddyfile
# (которые я сгенерировал)

# Запусти Caddy
docker-compose up -d

# Проверь логи
docker-compose logs -f
```

При первом запуске Caddy автоматически:
- Получит SSL-сертификаты от Let's Encrypt
- Настроит редирект HTTP → HTTPS
- Начнёт проксировать запросы

---

## Шаг 4: Проверка

```bash
# Должны работать:
curl -I https://dz-tracker.ru
curl -I https://uchim-stihi.ru

# Должны быть НЕДОСТУПНЫ:
curl http://91.188.212.141:3000   # Connection refused
curl http://91.188.212.141:3001   # Connection refused
```

---

## Добавление нового сайта

1. Добавь A-запись для нового домена → 91.188.212.141

2. В приложении измени порт на локальный:
   ```yaml
   ports:
     - "127.0.0.1:3002:3000"
   ```

3. Добавь в ~/caddy/Caddyfile:
   ```
   новый-сайт.ru {
       reverse_proxy host.docker.internal:3002
   }
   ```

4. Перезапусти Caddy:
   ```bash
   cd ~/caddy
   docker-compose restart
   ```

---

## Полезные команды

```bash
# Статус Caddy
docker-compose -f ~/caddy/docker-compose.yml ps

# Логи Caddy (там видно получение сертификатов)
docker-compose -f ~/caddy/docker-compose.yml logs -f

# Перезагрузить конфиг без даунтайма
docker-compose -f ~/caddy/docker-compose.yml exec caddy caddy reload --config /etc/caddy/Caddyfile

# Проверить сертификат домена
echo | openssl s_client -servername dz-tracker.ru -connect dz-tracker.ru:443 2>/dev/null | openssl x509 -noout -dates
```

---

## Возможные проблемы

**Caddy не получает сертификат:**
- Проверь, что DNS уже обновился: `dig домен.ru +short`
- Проверь, что порты 80 и 443 открыты в файрволе
- Посмотри логи: `docker-compose logs caddy`

**"Connection refused" при обращении через домен:**
- Проверь, что приложение запущено: `docker ps`
- Проверь, что приложение слушает нужный порт: `curl http://127.0.0.1:3001`

**Сертификат не обновляется:**
- Caddy обновляет сертификаты автоматически за 30 дней до истечения
- Если контейнер перезапускался, сертификаты сохранены в volume caddy_data
