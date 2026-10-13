#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() { printf '\nОшибка загрузчика: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Запусти под root или через sudo bash install.sh.'
[[ -r /etc/os-release ]] || fail 'Не удалось определить ОС.'
. /etc/os-release
case "$ID:$VERSION_ID" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
    *) fail "Поддерживаются Debian 12/13 и Ubuntu 22.04/24.04. Здесь: $PRETTY_NAME" ;;
esac
[[ -r /dev/tty ]] || fail 'Нужен интерактивный терминал для вопросов мастера.'

BASE_URL='https://raw.githubusercontent.com/killwithlove/sound/main'
if ! command -v curl >/dev/null 2>&1 || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl ca-certificates
fi
command -v tar >/dev/null || fail 'Не установлена утилита tar.'
WORK="$(mktemp -d /root/sound-installer.XXXXXX)"
trap 'printf "\nЗагрузчик остановился на строке %s. Файлы: %s\n" "$LINENO" "$WORK" >&2' ERR
printf '\nЗагрузка установщика из killwithlove/sound\nПапка: %s\n' "$WORK"

for name in deploy-sound-wizard.sh sound-project.tar.gz; do
    printf '\nСкачиваю %s…\n' "$name"
    curl --proto '=https' --proto-redir '=https' \
        --fail --location --show-error --silent \
        --retry 3 --connect-timeout 20 --max-time 300 \
        "$BASE_URL/$name" -o "$WORK/$name.download"
    [[ -s "$WORK/$name.download" ]] || fail "Пустой файл: $name"
done

# Reject an HTML error page before executing anything.
IFS= read -r FIRST_LINE < "$WORK/deploy-sound-wizard.sh.download" || true
[[ "$FIRST_LINE" == '#!/usr/bin/env bash' || "$FIRST_LINE" == '#!/bin/bash' ]] \
    || fail 'Вместо Bash-скрипта получен другой файл. Проверь имя deploy-sound-wizard.sh в репозитории.'
bash -n "$WORK/deploy-sound-wizard.sh.download"
tar -tzf "$WORK/sound-project.tar.gz.download" > "$WORK/archive-files.txt"
grep -Fxq 'project/site/index.html' "$WORK/archive-files.txt" || fail 'В архиве нет project/site/index.html.'
grep -Fxq 'project/CONTENTS.sha256' "$WORK/archive-files.txt" || fail 'В архиве нет project/CONTENTS.sha256.'

mv "$WORK/deploy-sound-wizard.sh.download" "$WORK/deploy-sound-wizard.sh"
mv "$WORK/sound-project.tar.gz.download" "$WORK/sound-project.tar.gz"
chmod 600 "$WORK/deploy-sound-wizard.sh" "$WORK/sound-project.tar.gz"

printf '\nФайлы скачаны. Запускаю мастер; отвечай на вопросы.\n'
printf 'Путь к архиву оставь предложенный: %s/sound-project.tar.gz\n\n' "$WORK"
bash "$WORK/deploy-sound-wizard.sh"
printf '\nУстановка завершена. Скачанные файлы сохранены в %s\n' "$WORK"
