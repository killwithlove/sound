#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Interactive deployment of the sound-project archive; SSH configuration is never changed.
fail() { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Запусти: sudo bash deploy-sound-wizard.sh (или под root).'
[[ -r /etc/os-release ]] || fail 'Не найдена информация об ОС.'
. /etc/os-release
case "$ID:$VERSION_ID" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
    *) fail "Поддерживаются Debian 12/13 и Ubuntu 22.04/24.04. Здесь: $PRETTY_NAME" ;;
esac
command -v systemctl >/dev/null || fail 'Нужна система с systemd.'
exec 3<>/dev/tty || fail 'Запусти скрипт в интерактивном SSH-терминале.'
ask() {
    local key="$1" label="$2" default="$3" _reply
    printf '%s [%s]: ' "$label" "$default" >&3
    IFS= read -r _reply <&3 || fail 'Ввод прерван.'
    printf -v "$key" '%s' "${_reply:-$default}"
}
yesno() {
    local key="$1" label="$2" default="$3" answer
    while :; do
        ask answer "$label (да/нет)" "$default"
        case "${answer,,}" in
            да|д|yes|y) printf -v "$key" '%s' yes; return ;;
            нет|н|no|n) printf -v "$key" '%s' no; return ;;
            *) printf 'Ответь да или нет.\n' >&3 ;;
        esac
    done
}
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONNECTION_PORT=''
if [[ -n ${SSH_CONNECTION:-} ]]; then
    read -r CLIENT_IP CLIENT_PORT SERVER_IP CONNECTION_PORT <<< "$SSH_CONNECTION"
fi
DETECTED_PORT="$CONNECTION_PORT"
if [[ -z "$DETECTED_PORT" ]] && command -v /usr/sbin/sshd >/dev/null; then
    DETECTED_PORT="$(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2;exit}' || true)"
fi
DETECTED_PORT="${DETECTED_PORT:-22}"
printf '\nМастер развёртывания Sound\nОС определена: %s\n' "$PRETTY_NAME" >&3
printf 'SSH-порт, способ входа, пользователи и ключи НЕ изменяются.\n' >&3
ask ARCHIVE 'Путь к архиву проекта' "$BASE/sound-project.tar.gz"
[[ -f "$ARCHIVE" ]] || fail "Нет архива: $ARCHIVE"
ARCHIVE="$(readlink -f -- "$ARCHIVE")"
ask DOMAIN 'Домен (без https:// и пути)' 'sound.stupes.su'
DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN%.}"
[[ ${#DOMAIN} -le 253 && "$DOMAIN" == *.* ]] || fail 'Нужен полный домен.'
IFS='.' read -ra LABELS <<< "$DOMAIN"
for label in "${LABELS[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail 'Некорректный домен; для IDN используй punycode.'
done
ask EMAIL 'Email для Certbot' 'rost07122002@gmail.com'
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || fail 'Некорректный email.'
ask IPV4 'Публичный IPv4 НОВОГО сервера, обязательный' ''
[[ "$IPV4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Укажи IPv4.'
ask IPV6 'IPv6 для AAAA-записи (пусто, если IPv6 не используешь)' ''
ask SSH_PORT 'ТЕКУЩИЙ SSH-порт (это не команда смены порта)' "$DETECTED_PORT"
[[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] || fail 'Некорректный SSH-порт.'
SSH_PORT=$((10#$SSH_PORT))
((SSH_PORT>=1 && SSH_PORT<=65535)) || fail 'SSH-порт должен быть 1–65535.'
if [[ -n "$CONNECTION_PORT" && "$SSH_PORT" != "$CONNECTION_PORT" ]]; then
    fail "В текущем SSH-соединении серверный порт $CONNECTION_PORT. Укажи его; порт скрипт не меняет."
fi
yesno USE_UFW 'Настроить UFW? Существующие разрешения будут сохранены' да
yesno USE_F2B 'Включить защиту SSH через Fail2ban' да
printf '\nИтог:\nОС: %s\nАрхив: %s\nДомен: %s\nIPv4: %s\nIPv6: %s\nEmail: %s\nSSH: %s\nUFW: %s; Fail2ban: %s\n' \
    "$PRETTY_NAME" "$ARCHIVE" "$DOMAIN" "$IPV4" "${IPV6:-не используется}" "$EMAIL" "$SSH_PORT" "$USE_UFW" "$USE_F2B" >&3
printf 'Будут обновлены /var/www/sound и конфиг sites-available/sound.\n' >&3
printf 'Это мастер одного проекта. Старые системные конфиги из архива НЕ восстанавливаются.\n' >&3
printf 'DNS и внешний файрвол хостинга скрипт изменить не может.\n' >&3
printf 'Убедись, что внешний файрвол разрешает SSH и TCP 80/443.\n' >&3
yesno APPROVED 'Продолжить установку и принять условия Let’s Encrypt' нет
[[ "$APPROVED" == yes ]] || exit 0

STAMP="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP="/root/sound-deploy-backups/$STAMP"
mkdir -p "$BACKUP"
exec > >(tee -a "$BACKUP/deploy.log") 2>&1
WORK="$(mktemp -d /root/sound-deploy.XXXXXX)"
trap 'status=$?; rm -rf -- "$WORK"; if ((status!=0)); then printf "\nРабота остановлена. Лог и копии: %s\nSSH-настройки не менялись. Это не полный откат установки пакетов.\n" "$BACKUP"; fi' EXIT
trap 'printf "\nОшибка на строке %s.\n" "$LINENO"' ERR
export DEBIAN_FRONTEND=noninteractive
apt-get update
PACKAGES=(nginx certbot ca-certificates curl dnsutils python3 openssl)
[[ "$USE_UFW" == yes ]] && PACKAGES+=(ufw)
[[ "$USE_F2B" == yes ]] && PACKAGES+=(fail2ban python3-systemd)
apt-get install -y "${PACKAGES[@]}"

# Only regular website files are read, never config symlinks or arbitrary paths.
python3 - "$ARCHIVE" "$WORK/site" "$IPV4" "$IPV6" <<'PY'
import hashlib, ipaddress, pathlib, re, sys, tarfile
archive, destination, ipv4, ipv6 = sys.argv[1:]
assert ipaddress.ip_address(ipv4).version == 4, 'Некорректный IPv4'
if ipv6:
    assert ipaddress.ip_address(ipv6).version == 6, 'Некорректный IPv6'
root = pathlib.Path(destination)
root.mkdir()
expected = {'index.html', 'track.mp3'} | {f'{n:03d}.webm' for n in range(1,50)}
with tarfile.open(archive, 'r:gz') as t:
    hashes = {}
    mf = t.getmember('project/CONTENTS.sha256')
    if not mf.isfile() or mf.size > 2_000_000:
        raise ValueError('Некорректный манифест')
    for line in t.extractfile(mf).read().decode().splitlines():
        digest, name = line.split('  ', 1)
        if re.fullmatch('[0-9a-f]{64}', digest):
            hashes[name] = digest
    seen = set()
    for member in t.getmembers():
        if not member.name.startswith('project/site/'):
            continue
        name = member.name[len('project/site/'):]
        if not name:
            continue
        if name not in expected or name in seen or not member.isfile():
            raise ValueError('Неожиданный файл сайта: '+member.name)
        if not 0 < member.size <= 100_000_000:
            raise ValueError('Недопустимый размер файла: '+name)
        data = t.extractfile(member).read()
        if hashlib.sha256(data).hexdigest() != hashes.get('site/'+name):
            raise ValueError('Не совпала контрольная сумма: '+name)
        (root/name).write_bytes(data)
        seen.add(name)
    if seen != expected:
        raise ValueError('В архиве не хватает файлов: '+str(expected-seen))
print('Архив проверен: HTML, MP3, 49 WebM. Все SHA-256 совпадают.')
PY

nginx -t
nginx -T > "$BACKUP/nginx-before.txt" 2>&1
CONF=/etc/nginx/sites-available/sound
LINK=/etc/nginx/sites-enabled/sound
WEB=/var/www/sound
[[ ! -L "$WEB" ]] || fail '/var/www/sound является ссылкой; требуется ручная проверка.'
[[ ! -L "$CONF" ]] || fail 'sites-available/sound является ссылкой; требуется ручная проверка.'
[[ ! -d "$LINK" ]] || fail 'sites-enabled/sound является каталогом.'
grep -Eq 'include[[:space:]]+/etc/nginx/sites-enabled/\*;' /etc/nginx/nginx.conf \
    || fail 'В nginx.conf нет стандартного подключения sites-enabled/*. Мастер не станет переписывать основной конфиг.'
python3 - "$BACKUP/nginx-before.txt" "$DOMAIN" "$CONF" <<'PY'
import pathlib, re, sys
text, domain, own = sys.argv[1:]
own = pathlib.Path(own).resolve()
for part in re.split(r'^# configuration file ', pathlib.Path(text).read_text(), flags=re.M)[1:]:
    header, _, body = part.partition('\n')
    filename = header.removesuffix(':')
    body = re.sub(r'#.*', '', body)
    for names in re.findall(r'\bserver_name\s+([^;]+);', body):
        if domain in names.split() and pathlib.Path(filename).resolve() != own:
            raise SystemExit('Домен уже настроен в другом конфиге: '+filename)
PY

# Check both address families before requesting a real certificate.
check_dns() {
    python3 - "$DOMAIN" "$IPV4" "$IPV6" <<'PY'
import ipaddress, subprocess, sys
domain, v4, v6 = sys.argv[1:]
expected4 = str(ipaddress.ip_address(v4))
expected6 = str(ipaddress.ip_address(v6)) if v6 else None
records = {}
for typ, version in [('A',4),('AAAA',6)]:
    result = subprocess.run(['dig','+time=3','+tries=1','+short',domain,typ], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit('Ошибка DNS-запроса '+typ)
    values = set()
    for line in result.stdout.splitlines():
        try:
            ip = ipaddress.ip_address(line.strip())
        except ValueError:
            continue
        if ip.version == version:
            values.add(str(ip))
    records[typ] = values
print('DNS A:', ', '.join(sorted(records['A'])) or 'нет')
print('DNS AAAA:', ', '.join(sorted(records['AAAA'])) or 'нет')
if records['A'] != {expected4}:
    raise SystemExit('A-запись должна указывать только на введённый IPv4. Для этого мастера отключи DNS-прокси.')
if records['AAAA'] != ({expected6} if expected6 else set()):
    raise SystemExit('Исправь AAAA: укажи введённый IPv6 или удали AAAA, если IPv6 не используешь.')
PY
}
until check_dns; do
    printf '\nИсправь DNS у регистратора/провайдера. Enter — проверить снова; q — выйти.\n' >&3
    IFS= read -r answer <&3
    [[ "$answer" != q ]] || fail 'DNS пока не готов. Можно запустить мастер повторно.'
done

# Save the current site, firewall settings and local jail before changing them.
if [[ -d "$WEB" ]]; then tar -czf "$BACKUP/site-before.tar.gz" -C /var/www sound; fi
for path in /etc/ufw /etc/default/ufw /etc/fail2ban/jail.d/zz-sound-sshd.local; do
    [[ ! -e "$path" ]] || cp -a --parents "$path" "$BACKUP/"
done
SSH_PORTS=("$SSH_PORT")
if command -v /usr/sbin/sshd >/dev/null; then
    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] && SSH_PORTS+=("$port")
    done < <(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2}' || true)
fi
[[ -z "$CONNECTION_PORT" ]] || SSH_PORTS+=("$CONNECTION_PORT")
mapfile -t SSH_PORTS < <(printf '%s\n' "${SSH_PORTS[@]}" | sort -nu)
if [[ "$USE_UFW" == yes ]]; then
    WAS_ACTIVE=no
    LC_ALL=C ufw status | grep -q '^Status: active' && WAS_ACTIVE=yes
    for port in "${SSH_PORTS[@]}"; do ufw allow "$port/tcp" comment 'SSH preserved by Sound deploy'; done
    ufw allow 80/tcp comment 'Sound HTTP'
    ufw allow 443/tcp comment 'Sound HTTPS'
    if [[ "$WAS_ACTIVE" == no ]]; then
        ufw default deny incoming
        ufw default allow outgoing
    fi
    ufw --force enable
    ufw status verbose
fi

install -d -m 755 "$WEB" "$WEB/.well-known" "$WEB/.well-known/acme-challenge"
for file in "$WORK/site/"*.webm "$WORK/site/track.mp3"; do
    install -m 644 -o www-data -g www-data "$file" "$WEB/"
done
install -m 644 -o www-data -g www-data "$WORK/site/index.html" "$WEB/index.html.new"
mv -f "$WEB/index.html.new" "$WEB/index.html"
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
NGINX_VERSION="$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')"
HTTP2_MODERN=no
dpkg --compare-versions "$NGINX_VERSION" ge 1.25.1 && HTTP2_MODERN=yes
IPV6_LISTEN=no
[[ ! -s /proc/net/if_inet6 ]] || IPV6_LISTEN=yes
[[ -z "$IPV6" || "$IPV6_LISTEN" == yes ]] || fail 'Введён IPv6, но на сервере IPv6 отключён.'
CERT=/etc/letsencrypt/live/$DOMAIN
write_config() {
    local tls="$1" target="$2"
    {
        printf '# Managed by deploy-sound.sh\nserver {\n    listen 80;\n'
        [[ "$IPV6_LISTEN" != yes ]] || printf '    listen [::]:80;\n'
        printf '    server_name %s;\n    root /var/www/sound;\n    index index.html;\n' "$DOMAIN"
        printf '    location ^~ /.well-known/acme-challenge/ { default_type text/plain; try_files $uri =404; }\n'
        if [[ "$tls" == yes ]]; then
            printf '    location / { return 301 https://$host$request_uri; }\n}\n\nserver {\n'
            if [[ "$HTTP2_MODERN" == yes ]]; then
                printf '    listen 443 ssl;\n'
                [[ "$IPV6_LISTEN" != yes ]] || printf '    listen [::]:443 ssl;\n'
                printf '    http2 on;\n'
            else
                printf '    listen 443 ssl http2;\n'
                [[ "$IPV6_LISTEN" != yes ]] || printf '    listen [::]:443 ssl http2;\n'
            fi
            printf '    server_name %s;\n    root /var/www/sound;\n    index index.html;\n' "$DOMAIN"
            printf '    ssl_certificate %s/fullchain.pem;\n    ssl_certificate_key %s/privkey.pem;\n' "$CERT" "$CERT"
            printf '    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_session_cache shared:SoundSSL:10m;\n    ssl_session_timeout 1d;\n    ssl_session_tickets off;\n'
            printf '    location ^~ /.well-known/acme-challenge/ { default_type text/plain; try_files $uri =404; }\n'
        fi
        printf '    server_tokens off;\n    location / { try_files $uri $uri/ =404; }\n'
        printf '    location = /index.html { add_header Cache-Control "no-cache"; }\n'
        printf '    location ~* \\.(webm|mp3)$ { try_files $uri =404; expires 7d; }\n'
        printf '    location ~ /\\. { deny all; }\n}\n'
    } > "$target"
}
apply_config() {
    local candidate="$1" phase="$2" saved="$BACKUP/nginx-$2"
    mkdir -p "$saved"
    [[ ! -e "$CONF" && ! -L "$CONF" ]] || cp -a "$CONF" "$saved/available"
    [[ ! -e "$LINK" && ! -L "$LINK" ]] || cp -a "$LINK" "$saved/enabled"
    install -m 644 "$candidate" "$CONF.new"
    mv -f "$CONF.new" "$CONF"
    ln -sfn "$CONF" "$LINK.new"
    mv -Tf "$LINK.new" "$LINK"
    if ! nginx -t; then
        rm -f "$CONF" "$LINK"
        [[ ! -e "$saved/available" && ! -L "$saved/available" ]] || cp -a "$saved/available" "$CONF"
        [[ ! -e "$saved/enabled" && ! -L "$saved/enabled" ]] || cp -a "$saved/enabled" "$LINK"
        fail "Новый конфиг не прошёл проверку; предыдущие файлы возвращены ($phase)."
    fi
    if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl start nginx; fi
}
TLS_READY=no
if [[ -s "$CERT/fullchain.pem" && -s "$CERT/privkey.pem" ]] \
    && openssl x509 -in "$CERT/fullchain.pem" -noout -checkend 0 >/dev/null \
    && openssl x509 -in "$CERT/fullchain.pem" -noout -checkhost "$DOMAIN" >/dev/null; then
    TLS_READY=yes
fi
write_config "$TLS_READY" "$WORK/bootstrap.conf"
apply_config "$WORK/bootstrap.conf" bootstrap
systemctl enable nginx

# Probe the exact ACME URL without touching the existing certificate.
PROBE="sound-probe-$STAMP"
PROBE_TEXT="sound-deploy-$STAMP"
printf '%s' "$PROBE_TEXT" > "$WEB/.well-known/acme-challenge/$PROBE"
chmod 644 "$WEB/.well-known/acme-challenge/$PROBE"
if ! GOT="$(curl --noproxy '*' -fsS --max-time 20 "http://$DOMAIN/.well-known/acme-challenge/$PROBE")" \
    || [[ "$GOT" != "$PROBE_TEXT" ]]; then
    rm -f "$WEB/.well-known/acme-challenge/$PROBE"
    fail 'HTTP-проверка не прошла. Проверь DNS, TCP 80 во внешнем файрволе и доступность сервера. Это не проверка из сети Let’s Encrypt.'
fi
rm -f "$WEB/.well-known/acme-challenge/$PROBE"

certbot certonly --webroot -w "$WEB" -d "$DOMAIN" --cert-name "$DOMAIN" \
    --email "$EMAIL" --agree-tos --non-interactive --keep-until-expiring
write_config yes "$WORK/https.conf"
apply_config "$WORK/https.conf" https

HOOK=/etc/letsencrypt/renewal-hooks/deploy/90-sound-nginx-reload
mkdir -p "$(dirname "$HOOK")"
[[ ! -e "$HOOK" ]] || cp -a "$HOOK" "$BACKUP/renewal-hook-before"
cat > "$HOOK" <<'HOOKSCRIPT'
#!/bin/sh
set -e
/usr/sbin/nginx -t
/bin/systemctl reload nginx
HOOKSCRIPT
chmod 755 "$HOOK"
if systemctl list-unit-files certbot.timer --no-legend | grep -q '^certbot.timer'; then
    systemctl enable --now certbot.timer
else
    fail 'Не найден certbot.timer. Настрой автопродление вручную; сайт уже развёрнут.'
fi

if [[ "$USE_F2B" == yes ]]; then
    PORT_LIST="$(IFS=,; printf '%s' "${SSH_PORTS[*]}")"
    JAIL=/etc/fail2ban/jail.d/zz-sound-sshd.local
    cat > "$JAIL" <<JAILCONFIG
[sshd]
enabled = true
backend = systemd
port = $PORT_LIST
mode = aggressive
bantime = 1h
findtime = 10m
maxretry = 5
JAILCONFIG
    chmod 644 "$JAIL"
    if ! fail2ban-client -t; then
        rm -f "$JAIL"
        OLD="$BACKUP/etc/fail2ban/jail.d/zz-sound-sshd.local"
        [[ ! -e "$OLD" ]] || cp -a "$OLD" "$JAIL"
        fail 'Fail2ban не прошёл проверку. Сайт развёрнут; jail возвращён к предыдущему состоянию.'
    fi
    systemctl enable fail2ban
    systemctl restart fail2ban

    F2B_READY=no

    # Ждать готовности сервера и SSH-jail до 30 секунд
    for attempt in $(seq 1 30); do
        if fail2ban-client ping >/dev/null 2>&1 \
            && fail2ban-client status sshd >/dev/null 2>&1
        then
            F2B_READY=yes
            break
        fi

        sleep 1
    done

    if [[ "$F2B_READY" != yes ]]; then
        systemctl status fail2ban --no-pager -l || true
        journalctl -u fail2ban -n 80 --no-pager || true
        tail -n 80 /var/log/fail2ban.log || true

        fail 'Fail2ban не стал готов за 30 секунд. Диагностика выведена выше; сайт уже развёрнут.'
    fi

    fail2ban-client status sshd
fi

# Direct-origin checks verify both certificates and actual response bodies.
for path in / /001.webm /track.mp3; do
    curl --noproxy '*' --resolve "$DOMAIN:443:$IPV4" \
        -fsS --max-time 40 "https://$DOMAIN$path" -o /dev/null
    printf 'HTTPS проверка: %s — OK\n' "$path"
done
certbot renew --cert-name "$DOMAIN" --dry-run
printf '\nГотово: https://%s/\nРезервные копии и лог: %s\n' "$DOMAIN" "$BACKUP"
printf 'SSH-пользователи, пароли, ключи и настройки входа не изменялись.\n'
