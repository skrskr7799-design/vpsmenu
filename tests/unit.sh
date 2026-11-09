#!/usr/bin/env bash
#
# Автотесты чистых функций vpsmenu (без root, systemd и Docker): версии, UI-хелперы,
# конфиг, бэкапы, парсер профилей. Запуск:  bash tests/unit.sh   (из корня репозитория)

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VPSMENU_SOURCE_ONLY=1 NO_COLOR=1
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

# версии
yes version_gt 2.0.1 2.0.0; yes version_gt 2.10.0 2.9.9; yes version_gt 3.0.0 2.1.0
no version_gt 2.0.0 2.0.0;  no version_gt 1.9 2.0.0
eq "$APP_VERSION" "$(script_version_of ./vpsmenu.sh)" "версия из файла"
eq "22 2222 40000" "$(sorted_ports 2222 22 22 40000)" "sorted_ports"

# UI-хелперы
eq 5 "$(ui_vlen $'\e[31mhello\e[0m')" "vlen с ANSI"
eq 6 "$(ui_vlen "Привет")" "vlen кириллица"
eq "Привет    |" "$(ui_pad "Привет" 10)|" "pad кириллицы"
eq "ab…" "$(ui_trunc abcdef 3)" "trunc"
eq "━━━" "$(ui_rule 3 ━)" "rule"
eq "340K 512M 1.2G" "$(ui_human_kb 340) $(ui_human_kb 524288) $(ui_human_kb 1300000)" "human_kb"
eq "░░░░░░░░░░" "$(ui_bar 0 10)" "bar 0%"
eq "█████░░░░░" "$(ui_bar 50 10)" "bar 50%"
eq "██████████" "$(ui_bar 999 10)" "bar >100%"

# конфиг
conf_set GITHUB_REPO a/b; conf_set GITHUB_REPO c/d; conf_set GITHUB_BRANCH dev
eq "c/d dev" "$(conf_get GITHUB_REPO) $(conf_get GITHUB_BRANCH)" "conf set/get"
yes update_repo_ok; rm -f "$VPSMENU_CONF_FILE"; no update_repo_ok

# бэкапы: создание, права, ретеншн (10 последних), отказ при пустом списке
mkdir -p "$TMP/src/sub"; echo secret >"$TMP/src/a"; echo x >"$TMP/src/sub/b"
for _ in $(seq 1 12); do backup_create demo "$TMP/src" /nonexistent >/dev/null 2>&1; done
eq 10 "$(backup_files 'demo-*.tar.gz' | wc -l)" "ретеншн бэкапов"
eq "600 700" "$(stat -c '%a' "$BACKUP_RESULT") $(stat -c '%a' "$BACKUP_DIR")" "права бэкапов"
no backup_create x /nonexistent1 /nonexistent2

# профили: готовые наборы, валидация, безопасный парсер
for id in node-full minimal hardened; do yes profile_load_preset "$id"; done
profile_load_preset node-full; profile_plan
eq 14 "${#PLAN_IDS[@]}" "число шагов node-full"
yes profile_value_ok BBR 1;               no profile_value_ok BBR yes
yes profile_value_ok TIMEZONE Europe/Moscow; no profile_value_ok TIMEZONE 'UTC;rm -rf /'
yes profile_value_ok NEW_USER ASK;        no profile_value_ok NEW_USER 'Roman$(id)'
yes profile_value_ok F2B_BANTIME -1;      no profile_value_ok F2B_BANTIME abc
yes profile_value_ok UFW_EXTRA_PORTS "443/tcp 2222"; no profile_value_ok UFW_EXTRA_PORTS "443;ls"
no profile_value_ok UNKNOWN_KEY 1
no profile_parse < <(printf 'NEW_USER=$(touch %s/PWNED)\n' "$TMP") 2>/dev/null
eq no "$([[ -e $TMP/PWNED ]] && echo yes || echo no)" "парсер ничего не исполняет"
yes profile_parse < <(printf '# c\n\nBBR=1\r\nSWAP_SIZE="1G"\nF2B_IGNOREIP=127.0.0.1/8 10.0.0.1\n')
eq "1 1G 127.0.0.1/8 10.0.0.1 0" "${P[BBR]} ${P[SWAP_SIZE]} ${P[F2B_IGNOREIP]} ${P[UFW]}" "CRLF, кавычки, умолчания"

# сохранение и повторное чтение профиля
profile_load_preset hardened
before="$(for k in "${PROFILE_KEYS[@]}"; do echo "$k=${P[$k]}"; done)"
printf 'roundtrip\n' | profile_save >/dev/null 2>&1
profile_parse <"$PROFILE_DIR/roundtrip.conf"
after="$(for k in "${PROFILE_KEYS[@]}"; do echo "$k=${P[$k]}"; done)"
eq "$before" "$after" "профиль сохраняется и читается без потерь"

# пример профиля из репозитория читается парсером
yes profile_parse <profiles/node-full.conf

# Service Manager (на заглушках systemctl и journalctl из tests/stubs)
# заглушки копируем во временную папку и делаем исполняемыми (при загрузке через браузер GitHub права теряются)
mkdir -p "$TMP/stubs" && cp tests/stubs/* "$TMP/stubs/" && chmod +x "$TMP/stubs/"*
PATH="$TMP/stubs:$PATH"
sleep() { :; }
export STUB_LOG="$TMP/systemctl.log"
svc_load
eq 15 "${#SVC_NAMES[@]}" "служб загружено (без шаблонов, alias и not-found)"
svc_build_view all;          eq 15 "${#SVC_VIEW[@]}" "фильтр all"
eq "broken.service snapd.service" "${SVC_NAMES[${SVC_VIEW[0]}]} ${SVC_NAMES[${SVC_VIEW[1]}]}" "упавшие идут первыми"
svc_build_view running;      eq 8  "${#SVC_VIEW[@]}" "фильтр running"
svc_build_view failed;       eq 2  "${#SVC_VIEW[@]}" "фильтр failed"
svc_build_view inactive;     eq 5  "${#SVC_VIEW[@]}" "фильтр inactive"
svc_build_view enabled;      eq 11 "${#SVC_VIEW[@]}" "фильтр enabled"
svc_build_view all ssh;      eq 1  "${#SVC_VIEW[@]}" "поиск по названию"
svc_build_view all DAEMON;   eq 2  "${#SVC_VIEW[@]}" "поиск по описанию без учёта регистра"
svc_build_view all nothing;  eq 0  "${#SVC_VIEW[@]}" "поиск без результатов"
yes test -n "$(svc_critical_reason ssh.service)"
yes test -n "$(svc_critical_reason docker.service)"
yes test -n "$(svc_critical_reason ufw.service)"
yes test -n "$(svc_critical_reason netplan-foo.service)"
no  test -n "$(svc_critical_reason nginx.service)"
card="$(svc_card_render nginx.service 2>&1)"
yes grep -q 'работает (running)' <<<"$card"
yes grep -q '50M' <<<"$card"
yes grep -q 'включён' <<<"$card"
yes grep -q 'sample log line' <<<"$card"
: >"$STUB_LOG"
printf 'y\n' | svc_run stop nginx.service >/dev/null 2>&1
eq "stop nginx.service" "$(tail -n 1 "$STUB_LOG")" "stop обычной службы после подтверждения"
: >"$STUB_LOG"
printf 'нет\n' | svc_run stop ssh.service >/dev/null 2>&1
eq "" "$(cat "$STUB_LOG")" "stop ssh без слова «да» не выполняется"
printf 'да\n' | svc_run stop ssh.service >/dev/null 2>&1
eq "stop ssh.service" "$(tail -n 1 "$STUB_LOG")" "stop ssh со словом «да»"
: >"$STUB_LOG"
printf 'n\n' | svc_run restart docker.service >/dev/null 2>&1
eq "" "$(cat "$STUB_LOG")" "restart критичной службы отменяется по n"
printf 'y\n' | svc_run restart docker.service >/dev/null 2>&1
eq "restart docker.service" "$(tail -n 1 "$STUB_LOG")" "restart критичной службы по y"
no svc_run start broken.service
yes svc_run start foo.service

echo "Тестов пройдено: $PASS, провалено: $FAIL"
[[ $FAIL -eq 0 ]]
