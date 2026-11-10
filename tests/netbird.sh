#!/usr/bin/env bash
#
# Автотесты модуля NetBird на заглушках netbird и ufw: проверка ключей, статус, подключение
# (ключ только через окружение), двухшаговое ограничение SSH, защита при удалении, аудит, профили.
# Запуск:  bash tests/netbird.sh   (из корня репозитория)

# shellcheck disable=SC2034   # переменные читает подключаемый vpsmenu.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs" "$TMP/stubs2" && cp tests/stubs/* "$TMP/stubs/" && chmod +x "$TMP/stubs/"*
cp tests/stubs/ufw tests/stubs/systemctl "$TMP/stubs2/" && chmod +x "$TMP/stubs2/"*
printf '#!/bin/sh\ncp "%s/stubs/netbird" "%s/stubs2/netbird"\nchmod +x "%s/stubs2/netbird"\n' "$TMP" "$TMP" "$TMP" >"$TMP/install.sh"
export PATH="$TMP/stubs:$PATH"
export STUB_NB_STATE="$TMP/nb-state" STUB_NB_LOG="$TMP/nb.log" STUB_UFW_RULES="$TMP/ufw-rules"
export VPSMENU_SOURCE_ONLY=1 NO_COLOR=1 VPSMENU_NETBIRD_URL="file://$TMP/install.sh"
export VPSMENU_LOG_FILE="$TMP/log" VPSMENU_CONF_FILE="$TMP/conf" VPSMENU_BACKUP_DIR="$TMP/backups"
export VPSMENU_STATE_DIR="$TMP/state" VPSMENU_PROFILE_DIR="$TMP/profiles"
# shellcheck source=/dev/null
source ./vpsmenu.sh

PASS=0; FAIL=0
ok_()  { PASS=$((PASS + 1)); }
bad_() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
eq()   { if [[ "$1" == "$2" ]]; then ok_; else bad_ "$3: ожидали [$1], получили [$2]"; fi; }
yes()  { if "$@" >/dev/null 2>&1; then ok_; else bad_ "должно пройти: $*"; fi; }
no()   { if "$@" >/dev/null 2>&1; then bad_ "должно отказать: $*"; else ok_; fi; }

sleep() { :; }
service_active() { return 0; }
detect_ssh_ports() { echo 22; }
nb_iface() { echo wt0; }
nb_ip() { echo 100.64.0.5; }

# проверка ключей и адреса сервера
yes nb_valid_key "AAAA1111-BBBB-2222-CCCC-3333DDDD4444"; yes nb_valid_key "abcdefgh12345678"
no nb_valid_key "short"; no nb_valid_key 'key with spaces and $(rm -rf /) xxxxxxxx'
yes nb_valid_url "https://netbird.example.com:443"; yes nb_valid_url "http://10.0.0.5:33073"
no nb_valid_url 'https://x.com; rm -rf /'; no nb_valid_url "ftp://x.com"

# статус
echo disconnected >"$STUB_NB_STATE"
eq "warn" "$(nb_summary | cut -d'|' -f1)" "не подключён → warn"
echo connected >"$STUB_NB_STATE"
eq "ok|подключён · 100.64.0.5 · пиров 2/3" "$(nb_summary)" "подключён → ok с IP и пирами"
nb_collect; eq "Connected" "$(nb_field Management)" "поле Management"; eq "100.64.0.5/16" "$(nb_field 'NetBird IP')" "поле NetBird IP"

# подключение: ключ идёт только через переменную окружения, а не аргументом
KEY="AAAA1111-BBBB-2222-CCCC-3333DDDD4444"
echo disconnected >"$STUB_NB_STATE"; : >"$STUB_NB_LOG"
printf 'n\n%s\n\n' "$KEY" | mod_nb_connect >/dev/null 2>&1
eq "up key_env=yes url=none args=up" "$(grep '^up' "$STUB_NB_LOG")" "подключение: ключ в окружении, не в аргументах"
eq 0 "$(grep -c "$KEY" "$STUB_NB_LOG")" "ключ не попал в журнал вызовов"
eq 0 "$(grep -c "$KEY" "$VPSMENU_LOG_FILE")" "ключ не попал в журнал vpsmenu"
eq "connected" "$(cat "$STUB_NB_STATE")" "после подключения состояние connected"
echo disconnected >"$STUB_NB_STATE"; : >"$STUB_NB_LOG"
printf 'y\nhttps://nb.example.com:443\n%s\n\n' "$KEY" | mod_nb_connect >/dev/null 2>&1
eq "up key_env=yes url=https://nb.example.com:443 args=up" "$(grep '^up' "$STUB_NB_LOG")" "self-hosted: Management URL через окружение"
echo disconnected >"$STUB_NB_STATE"; : >"$STUB_NB_LOG"
printf 'n\nshort\n\n' | mod_nb_connect >/dev/null 2>&1
eq 0 "$(grep -c '^up' "$STUB_NB_LOG")" "некорректный ключ отклоняется до вызова netbird up"

# SSH только через NetBird: два шага, откат, защита
echo connected >"$STUB_NB_STATE"; printf '22/tcp              ALLOW       Anywhere\n' >"$STUB_UFW_RULES"
yes nb_ssh_public 22; no nb_ssh_rule_present 22 wt0
nb_ssh_step1 wt0 100.64.0.5 22 >/dev/null 2>&1
yes nb_ssh_rule_present 22 wt0; yes nb_ssh_public 22
printf 'нет\n' | nb_ssh_step2 wt0 22 >/dev/null 2>&1
yes nb_ssh_public 22
printf 'да\n' | nb_ssh_step2 wt0 22 >/dev/null 2>&1
no nb_ssh_public 22; yes nb_ssh_rule_present 22 wt0
: >"$STUB_NB_LOG"
printf 'да\n\n' | mod_nb_uninstall >/dev/null 2>&1
eq 0 "$(grep -c 'service uninstall' "$STUB_NB_LOG")" "удаление блокируется, пока SSH закрыт для интернета"
nb_ssh_rollback 22 >/dev/null 2>&1
yes nb_ssh_public 22
printf '22/tcp on wt0              ALLOW       Anywhere\n' >"$STUB_UFW_RULES"
printf 'да\n' | nb_ssh_step2 wt0 22 >/dev/null 2>&1
yes nb_ssh_rule_present 22 wt0
printf '22/tcp              ALLOW       Anywhere\n' >"$STUB_UFW_RULES"
no nb_ssh_step2 wt0 22
eq 1 "$(grep -c '^22/tcp ' "$STUB_UFW_RULES")" "шаг 2 без шага 1 ничего не удаляет"

# аудит: подсказка про NetBird и подтверждение закрытого SSH
audit_reset
audit_check_netbird
eq "info" "${AUD_STATUS[0]}" "аудит: SSH открыт при подключённом NetBird → info"
printf '22/tcp on wt0              ALLOW       Anywhere\n' >"$STUB_UFW_RULES"
audit_reset; audit_check_netbird
eq "ok" "${AUD_STATUS[0]}" "аудит: SSH только через NetBird → ok"
echo disconnected >"$STUB_NB_STATE"; audit_reset; audit_check_netbird
eq 0 "${#AUD_ID[@]}" "аудит: при отключённом NetBird ничего не добавляет"

# профили: ключ NETBIRD
yes profile_value_ok NETBIRD 1; no profile_value_ok NETBIRD yes
profile_reset; P[NETBIRD]=1; profile_plan
eq "netbird" "${PLAN_IDS[0]}" "профиль: шаг netbird в плане"

# установка: команды netbird нет → скрипт установки (file://) ставит заглушку
(
  PATH="$TMP/stubs2:/usr/bin:/bin"
  unset -f service_active; service_active() { return 0; }
  if nb_installed; then echo "SKIP-already"; fi
  nb_install_apply >/dev/null 2>&1; rc=$?
  nb_installed && echo "INSTALLED rc=$rc"
) >"$TMP/install.out" 2>&1
eq "INSTALLED rc=0" "$(cat "$TMP/install.out")" "установка через официальный скрипт и проверка «уже есть»"

echo "NetBird: тестов пройдено: $PASS, провалено: $FAIL"
[[ $FAIL -eq 0 ]]
