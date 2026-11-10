#!/usr/bin/env bash
#
# Автотесты чистых функций vpsmenu (без root, systemd и Docker): версии, UI-хелперы,
# конфиг, бэкапы, парсер профилей. Запуск:  bash tests/unit.sh   (из корня репозитория)

# shellcheck disable=SC2034   # переменные AUDIT_* читает подключаемый vpsmenu.sh
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

# регрессия: ufw_is_active не должна зависеть от SIGPIPE при длинном выводе ufw (grep -q + pipefail)
if ( cmd_exists() { return 0; }; ufw_c() { echo "Status: active"; seq 1 200000; }; ufw_is_active ); then ok_; else bad_ "ufw_is_active при длинном выводе"; fi
if ( cmd_exists() { return 0; }; ufw_c() { echo "Status: inactive"; }; ufw_is_active ); then bad_ "inactive принят за active"; else ok_; fi

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

# Security Audit: подменяем источники данных, проверяем правила оценки, разбор данных и исправления
eval "$(declare -f audit_listen_list | sed '1s/audit_listen_list/audit_listen_list_real/')"
eval "$(declare -f audit_docker_published | sed '1s/audit_docker_published/audit_docker_published_real/')"
AUDIT_PASSWD="$TMP/passwd"; AUDIT_SHADOW="$TMP/shadow"; AUDIT_SUDOERS="$TMP/sudoers"; AUDIT_SUDOERS_D="$TMP/sudoers.d"
AUDIT_REBOOT_FLAG="$TMP/reboot-required"; AUDIT_APT_AUTO="$TMP/20auto"; AUDIT_APT_STAMP="$TMP/stamp"
AUDIT_ETC="$TMP/etc"; AUDIT_SSHD_CONFIG="$TMP/sshd_config"; AUDIT_LAST_FILE="$TMP/audit-last"
mkdir -p "$AUDIT_SUDOERS_D" "$AUDIT_ETC" "$TMP/home/roman/.ssh"
printf 'root:x:0:0::/root:/bin/bash\nroman:x:1000:1000::%s/home/roman:/bin/bash\n' "$TMP" >"$AUDIT_PASSWD"
printf 'root:*:1:0:::::\nroman:$6$hash:1:0:::::\n' >"$AUDIT_SHADOW"
: >"$AUDIT_SUDOERS"; echo "Include /etc/ssh/sshd_config.d/*.conf" >"$AUDIT_SSHD_CONFIG"
printf 'APT::Periodic::Unattended-Upgrade "1";\n' >"$AUDIT_APT_AUTO"; : >"$AUDIT_APT_STAMP"
: >"$TMP/home/roman/.ssh/authorized_keys"; : >"$TMP/home/roman/.ssh/id_ed25519"
chmod 640 "$AUDIT_SHADOW"; chmod 644 "$AUDIT_SSHD_CONFIG"; chmod 600 "$TMP/home/roman/.ssh/authorized_keys" "$TMP/home/roman/.ssh/id_ed25519"
chmod 700 "$BACKUP_DIR" "$STATE_DIR" 2>/dev/null; chmod 600 "$LOG_FILE" 2>/dev/null

FAKE_DOCKER=0
sshd_effective() { case $1 in permitrootlogin) echo "${T_ROOT:-no}" ;; passwordauthentication) echo "${T_PASS:-no}" ;;
  permitemptypasswords) echo no ;; maxauthtries) echo 3 ;; x11forwarding) echo no ;; esac; }
detect_ssh_ports() { echo 2222; }
ufw_is_active() { return 0; }
ufw_c() { if [[ ${2:-} == verbose ]]; then echo "Default: deny (incoming), allow (outgoing), disabled (routed)"; else printf '%b' "${T_UFW:-2222/tcp ALLOW Anywhere\n}"; fi; }
cmd_exists() { case $1 in ufw|sshd|fail2ban-client|timedatectl|systemctl) return 0 ;; docker) [[ $FAKE_DOCKER == 1 ]] ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
service_active() { return 0; }
fail2ban-client() { return 0; }
audit_apt_security_count() { echo "${T_UPD:-0}"; }
audit_listen_list() { printf '%b' "${T_LISTEN:-tcp 2222 sshd\n}"; }
audit_docker_published() { :; }
systemctl() { :; }
timedatectl() { echo yes; }
sysctl() { case $2 in net.ipv4.tcp_syncookies) echo 1 ;; net.ipv4.conf.all.accept_redirects) echo 0 ;; esac; }
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 100 10 90 10%% /\n'; }
issues() { echo $(( ${AUD_N[critical]} + ${AUD_N[high]} + ${AUD_N[medium]} + ${AUD_N[low]} )); }

# оценка: чистый сервер = 100 в обоих режимах
audit_scan full;  eq "100 0" "$AUD_SCORE $(issues)" "Full: чистый сервер"
audit_scan quick; eq "100 0" "$AUD_SCORE $(issues)" "Quick: чистый сервер"
yes test "$(audit_last_line | cut -d'|' -f1)" = ok
# штрафы: root (high 10) + пароль (high 10) + обновления (medium 5) + перезагрузка (low 2) = 27
T_ROOT=yes; T_PASS=yes; T_UPD=3; : >"$AUDIT_REBOOT_FLAG"
audit_scan quick; eq "73 2 1 1" "$AUD_SCORE ${AUD_N[high]} ${AUD_N[medium]} ${AUD_N[low]}" "штрафы по важности"
audit_cli quick >/dev/null; eq 1 $? "код выхода: есть высокие"
audit_accept reboot; audit_scan quick; eq "75 1" "$AUD_SCORE ${AUD_N[accepted]}" "принятый риск не учитывается"
audit_accept reboot; eq "reboot" "$(conf_get AUDIT_ACCEPTED)" "принятие идемпотентно"
T_ROOT=no; T_PASS=no; T_UPD=0; rm -f "$AUDIT_REBOOT_FLAG"; conf_set AUDIT_ACCEPTED ""
# критичные находки и пол оценки
printf 'root:x:0:0::/root:/bin/bash\ntoor:x:0:0::/root:/bin/sh\n' >"$AUDIT_PASSWD"
printf 'root:*:1:0:::::\nbob::1:0:::::\n' >"$AUDIT_SHADOW"
audit_scan quick; eq "60 2" "$AUD_SCORE ${AUD_N[critical]}" "UID 0 и пустой пароль: два критичных"
audit_cli quick >/dev/null; eq 2 $? "код выхода: есть критичные"
printf 'root:x:0:0::/root:/bin/bash\nroman:x:1000:1000::%s/home/roman:/bin/bash\n' "$TMP" >"$AUDIT_PASSWD"
printf 'root:*:1:0:::::\nroman:$6$hash:1:0:::::\n' >"$AUDIT_SHADOW"; chmod 640 "$AUDIT_SHADOW"
# лимит категории «порты»: 5 открытых портов = 25, но не больше 15
T_LISTEN='tcp 2222 sshd\ntcp 8001 a\ntcp 8002 b\ntcp 8003 c\ntcp 8004 d\ntcp 8005 e\n'
T_UFW='2222/tcp ALLOW Anywhere\n8001/tcp ALLOW Anywhere\n8002/tcp ALLOW Anywhere\n8003/tcp ALLOW Anywhere\n8004/tcp ALLOW Anywhere\n8005/tcp ALLOW Anywhere\n'
audit_scan quick; eq "85 5" "$AUD_SCORE ${AUD_N[medium]}" "лимит штрафа за порты"
# порт закрыт UFW — не считается открытым; ожидаемый порт — не считается проблемой
T_UFW='2222/tcp ALLOW Anywhere\n'; audit_scan quick; eq "100 0" "$AUD_SCORE $(issues)" "порты, закрытые UFW, не штрафуются"
T_UFW='2222/tcp ALLOW Anywhere\n8001/tcp ALLOW Anywhere\n'; T_LISTEN='tcp 2222 sshd\ntcp 8001 a\n'
audit_scan quick; eq 95 "$AUD_SCORE" "открытый порт: -5"
audit_accept "port:8001/tcp"; yes audit_port_expected 8001 tcp; no audit_port_expected 8001 udp
audit_scan quick; eq 100 "$AUD_SCORE" "ожидаемый порт не штрафуется"
T_LISTEN='tcp 2222 sshd\n'; T_UFW='2222/tcp ALLOW Anywhere\n'; conf_set AUDIT_EXPECTED_PORTS ""

# разбор вывода ss: loopback и частные адреса отбрасываются, v4/v6 схлопываются
ss() { cat <<'SSEOF'
tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
tcp LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=1,fd=4))
tcp LISTEN 0 4096 127.0.0.1:631 0.0.0.0:*
tcp LISTEN 0 511 0.0.0.0:8080 0.0.0.0:* users:(("nginx",pid=2,fd=6))
udp UNCONN 0 0 0.0.0.0:68 0.0.0.0:* users:(("dhclient",pid=3,fd=7))
tcp LISTEN 0 100 10.0.0.5:5432 0.0.0.0:*
udp UNCONN 0 0 *:123 *:*
SSEOF
}
eq "tcp 22 sshd|tcp 8080 nginx|udp 123 ?|udp 68 dhclient" "$(audit_listen_list_real | paste -sd'|')" "разбор ss"
unset -f ss

# правила UFW: «разрешено всем» против «только с IP»
T_UFW='22/tcp ALLOW Anywhere\n8080/tcp ALLOW 203.0.113.5\n8000:8010/tcp ALLOW Anywhere\n443 ALLOW Anywhere\n22/tcp (v6) ALLOW Anywhere (v6)\nAnywhere ALLOW 198.51.100.7\n'
yes audit_ufw_allows 22 tcp;   no audit_ufw_allows 8080 tcp;  yes audit_ufw_allows 8005 tcp
no audit_ufw_allows 8005 udp;  yes audit_ufw_allows 443 udp;  yes audit_ufw_allows 443 tcp
no audit_ufw_allows 9999 tcp;  no audit_ufw_allows 80 tcp

# Docker: порты, привилегии, docker.sock
FAKE_DOCKER=1
eq "proxy 3000/tcp|proxy 5353/udp|web 8080/tcp" "$(audit_docker_published_real | paste -sd'|')" "разбор опубликованных портов Docker"
audit_docker_published() { audit_docker_published_real; }
audit_scan full
eq "dport:3000/tcp dport:5353/udp dport:8080/tcp docker_privileged docker_sock" \
   "$(for i in "${!AUD_ID[@]}"; do [[ ${AUD_STATUS[$i]} == issue && ${AUD_CAT[$i]} == docker ]] && printf '%s ' "${AUD_ID[$i]}"; done | sed 's/ $//')" "находки Docker"
eq "70" "$AUD_SCORE" "Docker: порты (лимит 15) + privileged 5 + docker.sock 10"
audit_docker_published() { :; }; FAKE_DOCKER=0

# права на файлы и исправление через меню
chmod 644 "$AUDIT_SHADOW"; chmod 666 "$TMP/home/roman/.ssh/authorized_keys"; chmod 644 "$TMP/home/roman/.ssh/id_ed25519"
chmod 666 "$AUDIT_SSHD_CONFIG"; : >"$AUDIT_ETC/loose"; chmod 666 "$AUDIT_ETC/loose"
audit_scan full
eq "perm_shadow perm_sshd_config perm_authkeys:roman perm_privkey:$TMP/home/roman/.ssh/id_ed25519 world_writable_etc" \
   "$(for i in "${!AUD_ID[@]}"; do [[ ${AUD_STATUS[$i]} == issue && ${AUD_CAT[$i]} == files ]] && printf '%s ' "${AUD_ID[$i]}"; done | sed 's/ $//')" "находки по правам"
printf 'y\n\n' | audit_run_fix "chmod:640:$AUDIT_SHADOW" >/dev/null 2>&1
eq 640 "$(audit_mode "$AUDIT_SHADOW")" "исправление chmod из отчёта"
yes audit_mode_bit 644 other 4; no audit_mode_bit 640 other 7; yes audit_mode_bit 664 group 2; no audit_mode_bit 600 group 7

echo "Тестов пройдено: $PASS, провалено: $FAIL"
[[ $FAIL -eq 0 ]]
