#!/usr/bin/env bash
#
# Автотесты Storage Analyzer на временных каталогах и подменённых командах: разбор размера журнала,
# подсчёт по каталогам (в т. ч. таймаут), архивы логов, логи контейнеров, старые ядра и snap, безопасная
# очистка (предпросмотр, отказ, выполнение), защита путей при обнулении файлов.
# Запуск:  bash tests/storage.sh   (из корня репозитория)

# shellcheck disable=SC2034   # переменные ST_* читает подключаемый vpsmenu.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VPSMENU_SOURCE_ONLY=1 NO_COLOR=1
export VPSMENU_LOG_FILE="$TMP/log" VPSMENU_CONF_FILE="$TMP/conf" VPSMENU_BACKUP_DIR="$TMP/backups"
export VPSMENU_STATE_DIR="$TMP/state" VPSMENU_PROFILE_DIR="$TMP/profiles"
export VPSMENU_ST_LOG_DIR="$TMP/varlog" VPSMENU_ST_APT_CACHE="$TMP/aptcache" VPSMENU_ST_DOCKER_DIR="$TMP/dockercont"
export VPSMENU_ST_SNAP_DIR="$TMP/snaps" VPSMENU_ST_CRASH_DIRS="$TMP/crash1 $TMP/crash2"
# shellcheck source=/dev/null
source ./vpsmenu.sh

PASS=0; FAIL=0
ok_()  { PASS=$((PASS + 1)); }
bad_() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
eq()   { if [[ "$1" == "$2" ]]; then ok_; else bad_ "$3: ожидали [$1], получили [$2]"; fi; }
yes()  { if "$@" >/dev/null 2>&1; then ok_; else bad_ "должно пройти: $*"; fi; }
no()   { if "$@" >/dev/null 2>&1; then bad_ "должно отказать: $*"; else ok_; fi; }
mk()   { dd if=/dev/zero of="$1" bs=1024 count="$2" status=none; }   # настоящий файл на N КБ
old()  { touch -d "30 days ago" "$@"; }
sleep() { :; }

# размер журнала systemd из текста journalctl --disk-usage
journalctl() { echo "Archived and active journals take up ${JSIZE:-1.4G} in the file system."; }
JSIZE=1.4G;   eq 1468006 "$(st_journal_kb)" "журнал: 1.4G"
JSIZE=512.0M; eq 524288  "$(st_journal_kb)" "журнал: 512.0M"
JSIZE=8.0K;   eq 8       "$(st_journal_kb)" "журнал: 8.0K"
JSIZE=2T;     eq 2147483648 "$(st_journal_kb)" "журнал: 2T"
journalctl() { echo "No journal files were found."; }; eq 0 "$(st_journal_kb)" "журнал: нет данных"
unset -f journalctl
eq 204800 "$(st_keep_kb)" "оставляемый размер журнала 200M → КБ"
ST_JOURNAL_KEEP=1G; eq 1048576 "$(st_keep_kb)" "1G → КБ"; ST_JOURNAL_KEEP=200M

# подсчёт по каталогам: порядок, итог, исключение самого каталога
mkdir -p "$TMP/tree/a" "$TMP/tree/b" "$TMP/tree/c"
mk "$TMP/tree/a/f" 3000; mk "$TMP/tree/b/f" 1000; mk "$TMP/tree/c/f" 2000
st_du_scan "$TMP/tree" 9
eq "$TMP/tree/a $TMP/tree/c $TMP/tree/b" "$(for r in "${ST_ROWS[@]}"; do printf '%s ' "${r#*|}"; done | sed 's/ $//')" "du: порядок по убыванию"
yes test "$ST_TOTAL_KB" -ge 6000
eq 0 "$ST_PARTIAL" "du: без таймаута"
mkdir -p "$TMP/slow"; printf '#!/bin/sh\nsleep 5\n' >"$TMP/slow/du"; chmod +x "$TMP/slow/du"
( PATH="$TMP/slow:$PATH"; ST_DU_TIMEOUT=1; st_du_scan "$TMP/tree" 9; echo "partial=$ST_PARTIAL" ) >"$TMP/slow.out"
eq "partial=1" "$(cat "$TMP/slow.out")" "du: таймаут помечает результат неполным"

# архивы журналов и крупные файлы
mkdir -p "$TMP/varlog"
mk "$TMP/varlog/syslog" 100; mk "$TMP/varlog/syslog.1" 500; mk "$TMP/varlog/auth.log.2.gz" 300; mk "$TMP/varlog/kern.log.1" 200; truncate -s 60M "$TMP/varlog/big.log"
old "$TMP/varlog/syslog.1" "$TMP/varlog/auth.log.2.gz"
mk "$TMP/varlog/mid.log.1" 50; touch -d "5 days ago" "$TMP/varlog/mid.log.1"   # моложе порога в 14 дней — должен уцелеть
eq "auth.log.2.gz syslog.1" "$(st_logs_rotated_list | cut -f2 | xargs -n1 basename | sort | paste -sd' ')" "старые архивы: только старше порога"
eq "800" "$(st_logs_rotated_list | st_sum_bytes_kb)" "размер архивов, КБ"
eq "big.log" "$(st_logs_big_list 50 | cut -f2 | xargs -n1 basename)" "крупные файлы от 50 МБ"
st_do_step logs
eq "big.log kern.log.1 mid.log.1 syslog" "$(ls "$TMP/varlog" | sort | paste -sd' ')" "удалены только старые архивы (5-дневный остаётся)"

# защита путей при обнулении
mkdir -p "$TMP/other"; : >"$TMP/other/file"; mkdir -p "$TMP/dockercont/aaaabbbbcccc1111"
mk "$TMP/dockercont/aaaabbbbcccc1111/aaaabbbbcccc1111-json.log" 4000
mk "$TMP/dockercont/aaaabbbbcccc1111/config.v2.json" 1
yes st_path_allowed "$TMP/varlog/syslog"
yes st_path_allowed "$TMP/dockercont/aaaabbbbcccc1111/aaaabbbbcccc1111-json.log"
no  st_path_allowed "$TMP/other/file"
no  st_path_allowed "$TMP/dockercont/aaaabbbbcccc1111/config.v2.json"
no  st_path_allowed "$TMP/varlog/../other/file"
no  st_path_allowed "$TMP/varlog"
# Символические ссылки не должны позволять обнулить файл за пределами разрешённых каталогов.
ln -s "$TMP/other/file" "$TMP/varlog/escape.log"
no st_path_allowed "$TMP/varlog/escape.log"
mkdir -p "$TMP/outside"
ln -s "$TMP/outside" "$TMP/dockercont/aaaabbbbcccc1111/escape-dir"
: >"$TMP/outside/escape-json.log"
no st_path_allowed "$TMP/dockercont/aaaabbbbcccc1111/escape-dir/escape-json.log"
ln -s "$TMP/other/file" "$TMP/dockercont/aaaabbbbcccc1111/escape-json.log"
no st_path_allowed "$TMP/dockercont/aaaabbbbcccc1111/escape-json.log"
st_truncate_file "$TMP/varlog/syslog" >/dev/null 2>&1
eq "0 yes" "$(stat -c %s "$TMP/varlog/syslog") $([[ -f $TMP/varlog/syslog ]] && echo yes)" "обнуление: файл остаётся, размер 0"
no st_truncate_file "$TMP/other/file"

# логи контейнеров: сопоставление ID с именем, порядок
mkdir -p "$TMP/dockercont/bbbbccccdddd2222"; mk "$TMP/dockercont/bbbbccccdddd2222/bbbbccccdddd2222-json.log" 9000
st_docker_names() { printf 'aaaabbbbcccc web\nbbbbccccdddd db\n'; }
eq "db web" "$(st_docker_logs_list | cut -f2 | paste -sd' ')" "логи контейнеров: имена и порядок"

# старые ядра: только пакеты linux-*
st_autoremove_sim() { printf 'Remv linux-image-5.15.0-91-generic [5.15.0-91.101]\nRemv linux-headers-5.15.0-91 [5.15.0-91.101]\nRemv libfoo [1.0]\n'; }
eq "linux-headers-5.15.0-91 linux-image-5.15.0-91-generic" "$(st_old_kernels | cut -f2 | sort | paste -sd' ')" "старые ядра: только linux-*"

# snap: только отключённые ревизии
mkdir -p "$TMP/snaps"; mk "$TMP/snaps/core20_2105.snap" 1024
snap() { printf 'Name Version Rev Tracking Publisher Notes\ncore20 20231123 2105 latest/stable canonical** base,disabled\ncore20 20231218 2182 latest/stable canonical** base\nlxd 5.0 29351 5.0/stable canonical** disabled\n'; }
eq "core20 lxd" "$(st_snap_old_list | cut -f2 | paste -sd' ')" "snap: отключённые ревизии"
eq "1024" "$(st_snap_old_list | head -n 1 | cut -f1)" "размер snap ревизии из файла"

# дампы: только старше порога
mkdir -p "$TMP/crash1" "$TMP/crash2"; mk "$TMP/crash1/old.crash" 100; mk "$TMP/crash2/new.core" 100; old "$TMP/crash1/old.crash"
eq "old.crash" "$(st_crash_list | cut -f2 | xargs -n1 basename)" "дампы: только старые"

# подсказки по каталогам
yes test -n "$(st_hint_for /var/lib/docker/overlay2)"; yes test -n "$(st_hint_for /var/log/journal)"; no test -n "$(st_hint_for /srv/data)"

# безопасная очистка: план, отказ, выполнение
mkdir -p "$TMP/aptcache"; mk "$TMP/aptcache/pkg.deb" 2048
mk "$TMP/varlog/old.1" 700; old "$TMP/varlog/old.1"
st_journal_kb() { echo 1048576; }
st_docker_ok() { return 0; }
st_safe_plan
eq "apt journal logs snap crash docker" "${ST_PLAN_IDS[*]}" "план безопасной очистки"
eq "-1" "${ST_PLAN_EST[5]}" "оценка Docker неизвестна"
CALLS="$TMP/calls.log"; : >"$CALLS"
apt-get()    { echo "apt-get $*" >>"$CALLS"; }
journalctl() { echo "journalctl $*" >>"$CALLS"; }
docker()     { echo "docker $*" >>"$CALLS"; }
snap() { if [[ ${1:-} == remove ]]; then echo "snap $*" >>"$CALLS"; else printf 'Name Version Rev Tracking Publisher Notes\ncore20 1 2105 x y disabled\n'; fi; }
printf 'n\n\n' | mod_st_safe_clean >/dev/null 2>&1
eq 0 "$(wc -l <"$CALLS")" "отказ: ничего не выполняется"
yes test -f "$TMP/varlog/old.1"
printf 'y\n\n' | mod_st_safe_clean >/dev/null 2>&1
eq "apt-get clean|journalctl --vacuum-size=200M|snap remove core20 --revision=2105|docker image prune -f|docker builder prune -f" \
   "$(paste -sd'|' <"$CALLS")" "выполнены все шаги плана"
no test -f "$TMP/varlog/old.1"
yes test -f "$TMP/varlog/big.log"
unset -f apt-get journalctl docker snap

echo "Storage: тестов пройдено: $PASS, провалено: $FAIL"
[[ $FAIL -eq 0 ]]
