#!/usr/bin/env bash
#
#  vpsmenu — интерактивное меню первичной настройки и обслуживания VPS
#  Целевая система: Ubuntu 22.04 / 24.04. Запуск от root или через sudo.
#
#  Первый запуск:  sudo bash vpsmenu.sh   (предложит установить скрипт как команду)
#  Дальше:         vpsmenu                (сам запросит sudo)
#
#  Модули: sudo-пользователь · SSH (root, ключи, порт) · UFW · nftables · Fail2ban · Docker ·
#          Remnanode (xlogs, бэкапы) · WARP Native · оптимизация (BBR, swap, NTP, автообновления) ·
#          мастер быстрой настройки · профили серверов · watchdog для Remnanode ·
#          диагностика сети и Speedtest · Dashboard · самообновление из GitHub
#  Лог действий:   /var/log/vpsmenu.log
#
#  ВНИМАНИЕ: этот файл собран из src/*.sh командой ./build.sh — правь исходники в src/, а не его.
#
#  Намеренно без `set -e`: в интерактивном меню каждая ошибка проверяется явно,
#  чтобы одна неудачная команда не выкидывала из скрипта целиком.

set -uo pipefail

# ══════════════════════════ Константы и глобальные переменные ══════════════════════════

readonly APP_NAME="vpsmenu"
readonly APP_VERSION="3.1.0"
readonly INSTALL_PATH="/usr/local/bin/${APP_NAME}"
readonly LOG_FILE="${VPSMENU_LOG_FILE:-/var/log/${APP_NAME}.log}"

readonly REMNA_DIR="/opt/remnanode"
readonly REMNA_COMPOSE="${REMNA_DIR}/docker-compose.yml"

readonly DOCKER_URL="https://get.docker.com"
readonly WARP_URL="https://raw.githubusercontent.com/distillium/warp-native/main/install.sh"

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSH_DROPIN="/etc/ssh/sshd_config.d/00-disable-root-login.conf"
readonly F2B_JAIL="/etc/fail2ban/jail.d/sshd.local"
readonly USERNAME_RE='^[a-z_][a-z0-9_-]{0,31}$'

readonly CONF_FILE="${VPSMENU_CONF_FILE:-/etc/${APP_NAME}.conf}"
readonly BACKUP_DIR="${VPSMENU_BACKUP_DIR:-/var/backups/${APP_NAME}}"
readonly STATE_DIR="${VPSMENU_STATE_DIR:-/var/lib/${APP_NAME}}"
readonly SSH_DROPIN_PORT="/etc/ssh/sshd_config.d/10-${APP_NAME}-port.conf"
readonly SSH_DROPIN_AUTH="/etc/ssh/sshd_config.d/00-${APP_NAME}-auth.conf"
readonly DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
readonly REMNA_CONTAINER="remnanode"
readonly SWAPFILE="/swapfile"
readonly SWAP_SYSCTL="/etc/sysctl.d/99-${APP_NAME}-swap.conf"
readonly BBR_SYSCTL="/etc/sysctl.d/99-${APP_NAME}-bbr.conf"
readonly REMNA_STATE="${STATE_DIR}/remnanode.state"
readonly REMNA_STOP_FLAG="${STATE_DIR}/remnanode.stopped"
readonly WD_SERVICE="/etc/systemd/system/${APP_NAME}-watchdog.service"
readonly WD_TIMER="/etc/systemd/system/${APP_NAME}-watchdog.timer"
readonly PROFILE_DIR="${VPSMENU_PROFILE_DIR:-/etc/${APP_NAME}/profiles}"

# ── Самообновление ──────────────────────────────────────────────────────────
# Впиши сюда свой репозиторий (ник/имя). Если оставить CHANGE_ME — скрипт спросит его при первом обновлении
# и сохранит в /etc/vpsmenu.conf. Публичный репозиторий, файл vpsmenu.sh в корне.
readonly DEFAULT_REPO="CHANGE_ME/vpsmenu"
readonly DEFAULT_BRANCH="main"
RAW_BASE="${VPSMENU_RAW_BASE:-https://raw.githubusercontent.com}"

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
OS_PRETTY="Linux"
ASK_RESULT=""
CHOICE=""
APT_UPDATED=0
BACKUP_RESULT=""
BACKUP_PICKED=""
UPDATE_AVAILABLE=""

# ══════════════════════════ Запуск: справка, root/sudo, терминал, локаль ══════════════════════════

usage() {
  cat <<EOF
${APP_NAME} ${APP_VERSION} — меню настройки VPS (Ubuntu)

Использование:
  ${APP_NAME}              запустить меню
  ${APP_NAME} --install    установить скрипт в ${INSTALL_PATH}
  ${APP_NAME} --update     обновить скрипт из GitHub
  ${APP_NAME} --watchdog   разовая проверка Remnanode (вызывается таймером systemd)
  ${APP_NAME} --dashboard  показать Dashboard один раз и выйти (работает и без терминала)
  ${APP_NAME} --version    показать версию
  ${APP_NAME} --help       эта справка
EOF
}

case "${1:-}" in
  -h|--help)    usage; exit 0 ;;
  -v|--version) echo "${APP_NAME} ${APP_VERSION}"; exit 0 ;;
esac

# VPSMENU_SOURCE_ONLY=1 — подключить функции без запуска (для автотестов): проверки root и терминала пропускаются
if [[ -z ${VPSMENU_SOURCE_ONLY:-} && $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1 && [[ -f $SELF ]]; then
    exec sudo -- bash "$SELF" "$@"
  fi
  echo "Нужны права root. Запусти через sudo: sudo bash vpsmenu.sh" >&2
  exit 1
fi

if [[ -z ${VPSMENU_SOURCE_ONLY:-} && ${1:-} != --install && ${1:-} != --watchdog && ${1:-} != --dashboard && ( ! -t 0 || ! -t 1 ) ]]; then
  echo "Скрипту нужен интерактивный терминал." >&2
  exit 1
fi

# Русский текст и рамки требуют UTF-8
if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]]; then
  export LC_ALL=C.UTF-8
fi

# ══════════════════════════ Оформление: цвета, сообщения, заголовок, пункты меню ══════════════════════════

if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-} != dumb ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null

UI_W=78
UI_COMPACT=0
UI_HOST="$(hostname 2>/dev/null || echo host)"
declare -a UI_MENU_ITEMS=()

# Названия вложенных меню для «хлебных крошек» (путь определяется по стеку вызовов)
declare -A MENU_TITLES=(
  [menu_ssh]="SSH" [menu_ufw]="UFW" [menu_nft]="nftables" [menu_f2b]="Fail2ban" [menu_docker]="Docker"
  [menu_remna]="Remnanode" [menu_watchdog]="Watchdog" [menu_maint]="Обслуживание" [menu_self]="Скрипт"
  [menu_profiles]="Профили" [menu_net]="Сеть" [menu_services]="Service Manager"
)

log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true; }

info() { printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; log INFO "$*"; }

ok()   { printf '%s[✔]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log OK "$*"; }

warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log WARN "$*"; }

err()  { printf '%s[✘]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log ERROR "$*"; }

step() { printf '\n%s%s▶ %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; log STEP "$*"; }

hint() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# ── Размеры терминала ───────────────────────────────────────────────────────
ui_refresh_size() {
  local cols
  cols="$(tput cols 2>/dev/null || echo 80)"
  [[ $cols =~ ^[0-9]+$ ]] || cols=80
  UI_W=$(( cols > 78 ? 78 : cols ))
  if (( UI_W < 40 )); then UI_W=40; fi
  if (( cols < 64 )); then UI_COMPACT=1; else UI_COMPACT=0; fi
}

trap ui_refresh_size WINCH

# ── Строки: видимая длина, отступы, обрезка ─────────────────────────────────
ui_vlen() { # видимая длина строки без ANSI-последовательностей
  local s=$1 esc=$'\e'
  while [[ $s == *"${esc}["* ]]; do
    s="${s%%"${esc}["*}${s#*"${esc}["*m}"
  done
  printf '%s' "${#s}"
}

ui_pad() { # ui_pad "текст" ширина — дополняет пробелами справа (кириллица считается по символам)
  local s=$1 w=$2 n
  n="$(ui_vlen "$s")"
  printf '%s' "$s"
  if (( n < w )); then printf '%*s' $(( w - n )) ''; fi
}

ui_trunc() { # ui_trunc "обычный текст" ширина — обрезает с «…» (только текст без цветов)
  local s=$1 w=$2
  if (( ${#s} > w )); then s="${s:0:$(( w - 1 ))}…"; fi
  printf '%s' "$s"
}

ui_rule() { # ui_rule N [символ]
  local n=$1 ch=${2:-─} s
  printf -v s '%*s' "$n" ''
  printf '%s' "${s// /$ch}"
}

hr() { printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $(( UI_W - 2 )))" "$C_RESET"; }

# ── Блоки интерфейса ────────────────────────────────────────────────────────
ui_section() { # ui_section "Название" — разделитель с заголовком
  local t=$1 n
  n=$(( UI_W - ${#t} - 6 ))
  if (( n < 3 )); then n=3; fi
  printf '\n  %s──%s %s%s%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$t" "$C_RESET" "$C_DIM" "$(ui_rule "$n")" "$C_RESET"
}

ui_kv() { # ui_kv "Метка" "значение" [ширина метки]
  printf '  %s %s\n' "$(ui_pad "${C_DIM}$1${C_RESET}" "${3:-9}")" "$2"
}

ui_line() { # ui_line ok|warn|bad|off "текст" — строка со значком состояния
  local ic col
  case $1 in
    ok)   ic="✔"; col=$C_GREEN ;;
    warn) ic="!"; col=$C_YELLOW ;;
    bad)  ic="✘"; col=$C_RED ;;
    *)    ic="·"; col=$C_DIM ;;
  esac
  printf '  %s%s%s %s\n' "$col" "$ic" "$C_RESET" "$2"
}

ui_bar() { # ui_bar ПРОЦЕНТ [ширина] — шкала: <70% зелёная, <90% жёлтая, иначе красная
  local pct=${1:-0} w=${2:-20} filled i col out=""
  [[ $pct =~ ^[0-9]+$ ]] || pct=0
  if (( pct > 100 )); then pct=100; fi
  filled=$(( (pct * w + 50) / 100 ))
  if (( pct >= 90 )); then col=$C_RED; elif (( pct >= 70 )); then col=$C_YELLOW; else col=$C_GREEN; fi
  out+="$col"
  for (( i = 0; i < filled; i++ )); do out+="█"; done
  out+="$C_DIM"
  for (( i = filled; i < w; i++ )); do out+="░"; done
  out+="$C_RESET"
  printf '%s' "$out"
}

ui_meter() { # ui_meter "Метка" ПРОЦЕНТ "текст" — строка со шкалой
  local label=$1 pct=${2:-0} text=${3:-} bw room
  [[ $pct =~ ^[0-9]+$ ]] || pct=0
  bw=$(( UI_COMPACT ? 10 : 20 ))
  room=$(( UI_W - 2 - 7 - 1 - bw - 1 - 4 - 2 ))
  if (( room < 8 )); then room=8; fi
  printf '  %s %s %s%3d%%%s  %s\n' "$(ui_pad "$label" 7)" "$(ui_bar "$pct" "$bw")" "$C_BOLD" "$pct" "$C_RESET" "$(ui_trunc "$text" "$room")"
}

ui_human_kb() { # килобайты → 340K / 512M / 1.2G
  local kb=${1:-0} t
  if (( kb >= 1048576 )); then
    t=$(( kb * 10 / 1048576 )); printf '%d.%dG' $(( t / 10 )) $(( t % 10 ))
  elif (( kb >= 1024 )); then
    printf '%dM' $(( kb / 1024 ))
  else
    printf '%dK' "$kb"
  fi
}

ui_spin() { # ui_spin "Сообщение" команда… — команда выполняется под спиннером; вывод показывается только при ошибке
  local msg=$1 out rc pid i=0 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  shift
  if [[ ! -t 1 ]]; then
    "$@"
    return $?
  fi
  out="$(mktemp)"
  "$@" >"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s' "$C_CYAN" "${frames:$(( i % 10 )):1}" "$C_RESET" "$msg"
    i=$(( i + 1 ))
    sleep 0.1
  done
  wait "$pid"
  rc=$?
  printf '\r\e[K'
  if (( rc == 0 )); then
    printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$msg"
  else
    printf '  %s✘%s %s\n' "$C_RED" "$C_RESET" "$msg"
    sed 's/^/    /' "$out"
  fi
  rm -f "$out"
  return $rc
}

# ── Заголовок экрана с «хлебными крошками» ──────────────────────────────────
header() { # header "Название экрана"
  local title=${1:-} caller=${FUNCNAME[1]:-} left right inner gap path="" i fn t leaf lastmenu=""
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then clear; fi
  UI_MENU_ITEMS=()
  ui_refresh_size

  left="VPS MENU  v${APP_VERSION}"
  right="${OS_PRETTY} · ${UI_HOST}"
  if (( UI_COMPACT )); then
    printf '\n  %s%s%s %s%s%s\n' "${C_BOLD}${C_CYAN}" "VPS MENU" "$C_RESET" "$C_DIM" "v${APP_VERSION} · ${UI_HOST}" "$C_RESET"
  else
    inner=$(( UI_W - 4 ))
    if (( ${#left} + ${#right} + 4 > inner )); then right="$(ui_trunc "$right" $(( inner - ${#left} - 4 )))"; fi
    gap=$(( inner - 2 - ${#left} - ${#right} ))
    if (( gap < 1 )); then gap=1; fi
    printf '\n  %s╭%s╮%s\n' "$C_DIM" "$(ui_rule "$inner")" "$C_RESET"
    printf '  %s│%s %s%s%s%*s%s%s%s %s│%s\n' "$C_DIM" "$C_RESET" "${C_BOLD}${C_CYAN}" "$left" "$C_RESET" "$gap" "" "$C_DIM" "$right" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s╰%s╯%s\n' "$C_DIM" "$(ui_rule "$inner")" "$C_RESET"
  fi

  # путь по вложенным меню берём из стека вызовов
  for (( i = ${#FUNCNAME[@]} - 1; i >= 1; i-- )); do
    fn=${FUNCNAME[$i]}
    t=${MENU_TITLES[$fn]:-}
    if [[ -n $t ]]; then path+=" ${C_DIM}›${C_RESET} $t"; lastmenu=$t; fi
  done
  leaf="${title#[0-9]*. }"
  if [[ -n $lastmenu ]]; then leaf="${leaf#"$lastmenu: "}"; fi   # «SSH › SSH: параметры» → «SSH › параметры»
  if [[ -n ${MENU_TITLES[$caller]:-} || $caller == main_menu || -z $leaf ]]; then leaf=""; fi
  if [[ -n $leaf ]]; then leaf=" ${C_DIM}›${C_RESET} ${C_BOLD}${leaf}${C_RESET}"; fi
  printf '  %svpsmenu%s%s%s\n' "$C_DIM" "$C_RESET" "$path" "$leaf"
  hr
}

menu_item() { # menu_item КЛЮЧ "Текст" — КЛЮЧ: цифра или буква; 0 («назад/выход») приглушён
  UI_MENU_ITEMS+=("$1")
  if [[ $1 == 0 ]]; then
    printf '  %s%2s  %s%s\n' "$C_DIM" "$1" "$2" "$C_RESET"
  else
    printf '  %s%2s%s  %s\n' "${C_BOLD}${C_CYAN}" "$1" "$C_RESET" "$2"
  fi
}

badge() { # badge ok|warn|bad|off "текст"
  case $1 in
    ok)   printf '%s●%s %s' "$C_GREEN" "$C_RESET" "$2" ;;
    warn) printf '%s●%s %s' "$C_YELLOW" "$C_RESET" "$2" ;;
    bad)  printf '%s●%s %s' "$C_RED" "$C_RESET" "$2" ;;
    *)    printf '%s○ %s%s' "$C_DIM" "$2" "$C_RESET" ;;
  esac
}

show_paged() { if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then less -R -F -X; else cat; fi; }

# ══════════════════════════ Ввод: вопросы, подтверждения, выбор пункта меню ══════════════════════════

on_interrupt() { echo; warn "Прервано (Ctrl+C)."; exit 130; }

trap on_interrupt INT

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

ui_flush_input() { # выбрасывает «залежавшиеся» нажатия (например, Enter после выбора клавишей)
  [[ -t 0 ]] || return 0
  while IFS= read -rsn1 -t 0.002 _; do :; done
}

ui_swallow_enter() { IFS= read -rsn1 -t 0.01 _ || true; }

pause() {
  ui_flush_input
  if [[ -t 0 ]]; then
    printf '  %sНажми любую клавишу…%s ' "$C_DIM" "$C_RESET"
    IFS= read -rsn1 _ || true
    ui_swallow_enter
    echo
  else
    read -r -p "  Нажми Enter, чтобы продолжить… " _ || true
  fi
}

# Выбор пункта меню одной клавишей (без Enter). Цифры 10+ — вводом двух цифр подряд;
# буквы — горячие клавиши. Esc или q во вложенных меню = «назад». Для конвейера (не терминал) читает строку.
read_choice() {
  local k k2 it multi ctx=${FUNCNAME[1]:-}
  CHOICE=""
  if [[ ! -t 0 ]]; then
    read -r -p "  ❯ " CHOICE || { echo; exit 0; }
    CHOICE="$(trim "$CHOICE")"
    return 0
  fi
  ui_flush_input
  if [[ $ctx == main_menu ]]; then
    printf '  %sклавиша — выбрать · 0 или q — выход%s\n' "$C_DIM" "$C_RESET"
  else
    printf '  %sклавиша — выбрать · 0 или Esc — назад%s\n' "$C_DIM" "$C_RESET"
  fi
  while [[ -z $CHOICE ]]; do
    printf '  %s❯%s ' "$C_CYAN" "$C_RESET"
    IFS= read -rsn1 k || { echo; exit 0; }
    case $k in
      "") ;;                                   # Enter без ввода — спросить снова
      $'\e')
        k2=""
        IFS= read -rsn2 -t 0.05 k2 || true
        while IFS= read -rsn1 -t 0.005 _; do :; done   # хвост escape-последовательности (стрелки и т.п.)
        if [[ -z $k2 ]]; then CHOICE=0; printf '0\n'; else printf '\r\e[K'; fi
        ;;
      [0-9])
        CHOICE=$k
        multi=0
        for it in "${UI_MENU_ITEMS[@]}"; do
          if [[ $it == "$k"?* ]]; then multi=1; fi
        done
        if (( multi )); then
          k2=""
          IFS= read -rsn1 -t 0.8 k2 || true
          if [[ $k2 =~ ^[0-9]$ ]]; then CHOICE+=$k2; fi
        fi
        printf '%s\n' "$CHOICE"
        ;;
      *)
        CHOICE=$k
        printf '%s\n' "$k"
        ;;
    esac
  done
  ui_swallow_enter
  if [[ $ctx != main_menu && $CHOICE == [qQ] ]]; then CHOICE=0; fi
}

ask() { # ask "Вопрос" ["по умолчанию"] → $ASK_RESULT
  local prompt=$1 default=${2:-} answer
  ui_flush_input
  if [[ -n $default ]]; then
    read -r -p "  $prompt [$default]: " answer || { echo; exit 0; }
  else
    read -r -p "  $prompt: " answer || { echo; exit 0; }
  fi
  ASK_RESULT="$(trim "${answer:-$default}")"
}

ask_re() { # ask_re "Вопрос" "по умолчанию" "regex" "текст ошибки"
  local prompt=$1 default=$2 re=$3 msg=$4
  while true; do
    ask "$prompt" "$default"
    if [[ $ASK_RESULT =~ $re ]]; then return 0; fi
    err "$msg"
  done
}

confirm() { # confirm "Вопрос" [Y|N] — одна клавиша (y/n или д/н), Enter = значение по умолчанию
  local prompt=$1 def=${2:-Y} hintstr ans
  if [[ $def == Y ]]; then hintstr='Y/n'; else hintstr='y/N'; fi
  if [[ ! -t 0 ]]; then
    while true; do
      read -r -p "  $prompt [$hintstr]: " ans || { echo; exit 0; }
      ans="${ans,,}"
      case "$ans" in
        "")          [[ $def == Y ]] && return 0 || return 1 ;;
        y|yes|д|да)  return 0 ;;
        n|no|н|нет)  return 1 ;;
        *)           warn "Ответь y/n (д/н)." ;;
      esac
    done
  fi
  ui_flush_input
  while true; do
    printf '  %s [%s]: ' "$prompt" "$hintstr"
    IFS= read -rsn1 ans || { echo; exit 0; }
    ans="${ans,,}"
    case "$ans" in
      "")      echo; [[ $def == Y ]] && return 0 || return 1 ;;
      y|д)     printf '%sда%s\n' "$C_GREEN" "$C_RESET"; ui_swallow_enter; return 0 ;;
      n|н|т)   printf '%sнет%s\n' "$C_YELLOW" "$C_RESET"; ui_swallow_enter; return 1 ;;
      *)       echo; warn "Нажми y/n (д/н) или Enter." ;;
    esac
  done
}

confirm_word() { # confirm_word "Вопрос" "слово" — для опасных действий
  local prompt=$1 word=$2 ans
  ui_flush_input
  read -r -p "  $prompt (введи «$word»): " ans || { echo; exit 0; }
  [[ "$(trim "${ans,,}")" == "$word" ]]
}

# Выполняет команду так, чтобы Ctrl+C прерывал только её, а не весь скрипт
run_interruptible() {
  local rc
  trap ':' INT
  "$@"; rc=$?
  trap on_interrupt INT
  echo
  return $rc
}

# ══════════════════════════ Системные утилиты: пакеты, службы, SSH-порты ══════════════════════════

cmd_exists()       { command -v "$1" >/dev/null 2>&1; }

is_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

service_active()   { systemctl is-active --quiet "$1" 2>/dev/null; }

service_enabled()  { systemctl is-enabled --quiet "$1" 2>/dev/null; }

ufw_c()            { LC_ALL=C ufw "$@"; }   # вывод ufw переводится — для разбора берём английский

ufw_is_active()    { cmd_exists ufw && ufw_c status 2>/dev/null | grep -q '^Status: active'; }

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

apt_update_once() {
  (( APT_UPDATED )) && return 0
  info "Обновляю списки пакетов (apt update)…"
  if apt_run update -q; then
    APT_UPDATED=1
  else
    err "apt update завершился с ошибкой. Проверь интернет и DNS."
    return 1
  fi
}

apt_install() {
  apt_update_once || return 1
  info "Устанавливаю: $*"
  if ! apt_run install -y -q "$@"; then
    err "Не удалось установить: $*"
    return 1
  fi
}

ensure_curl() {
  cmd_exists curl && return 0
  apt_install curl ca-certificates
}

download() { # download URL DEST
  curl -fsSL --retry 3 --connect-timeout 10 -o "$2" "$1"
}

ssh_service_name() { if systemctl cat ssh.service >/dev/null 2>&1; then echo ssh; else echo sshd; fi; }

sshd_effective() { # значение параметра sshd с учётом всех include-файлов
  install -d -m 0755 /run/sshd 2>/dev/null
  sshd -T 2>/dev/null | awk -v k="$1" '$1==k {print $2; exit}'
}

detect_ssh_ports() {
  install -d -m 0755 /run/sshd 2>/dev/null
  local p
  p="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -un | tr '\n' ' ')"
  p="${p% }"
  echo "${p:-22}"
}

user_in_sudo() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; }

os_pretty_init() { # название ОС для заголовка (без вопросов)
  if [[ -r /etc/os-release ]]; then OS_PRETTY="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"; fi
  return 0
}

check_os() {
  if [[ -r /etc/os-release ]]; then
    OS_PRETTY="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
    local id; id="$(. /etc/os-release; echo "${ID:-}")"
    if [[ $id != ubuntu ]]; then
      warn "Скрипт рассчитан на Ubuntu, обнаружено: $OS_PRETTY."
      confirm "Продолжить на свой риск?" N || exit 1
    fi
  fi
  if [[ ! -d /run/systemd/system ]]; then
    err "Не найден systemd — скрипт без него не работает."
    exit 1
  fi
}

apt_run() { DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=120 "$@"; }

port_in_use() { [[ -n "$(ss -H -tln "sport = :$1" 2>/dev/null)" ]]; }

ports_listening() { # ждёт до 6 секунд, пока ВСЕ перечисленные порты начнут слушаться
  local p ok_all
  for _ in 1 2 3 4 5 6; do
    ok_all=1
    for p in "$@"; do port_in_use "$p" || ok_all=0; done
    (( ok_all )) && return 0
    sleep 1
  done
  return 1
}

# ══════════════════════════ Помощники: конфиг, бэкапы, версии ══════════════════════════

conf_get() { # conf_get КЛЮЧ — значение из /etc/vpsmenu.conf
  [[ -f $CONF_FILE ]] || return 0
  awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$CONF_FILE"
}

conf_set() { # conf_set КЛЮЧ ЗНАЧЕНИЕ
  touch "$CONF_FILE" && chmod 644 "$CONF_FILE" || return 1
  if grep -q "^$1=" "$CONF_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$CONF_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >>"$CONF_FILE"
  fi
}

backup_prepare() { install -d -m 0700 "$BACKUP_DIR"; }

backup_files() { # backup_files ШАБЛОН → файлы из каталога бэкапов, свежие первыми
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "$1" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
}

backup_create() { # backup_create ПРЕФИКС путь… → $BACKUP_RESULT
  local prefix=$1 p out
  shift
  local -a rel=()
  for p in "$@"; do
    if [[ -e $p ]]; then rel+=("${p#/}"); fi
  done
  if (( ${#rel[@]} == 0 )); then
    err "Нечего сохранять — ни один из файлов не найден."
    return 1
  fi
  backup_prepare || return 1
  out="$BACKUP_DIR/${prefix}-$(date +%Y%m%d-%H%M%S).tar.gz"
  [[ -e $out ]] && out="${out%.tar.gz}-$RANDOM.tar.gz"   # две копии в одну секунду не должны затирать друг друга
  if tar -czf "$out" -C / "${rel[@]}"; then
    chmod 600 "$out"
    BACKUP_RESULT=$out
    backup_files "${prefix}-*.tar.gz" | tail -n +11 | xargs -r rm -f
    return 0
  fi
  rm -f "$out"
  err "Не удалось создать архив."
  return 1
}

backup_pick() { # backup_pick ШАБЛОН → $BACKUP_PICKED (интерактивный выбор из списка)
  local i=0 f
  local -a files=()
  mapfile -t files < <(backup_files "$1")
  if (( ${#files[@]} == 0 )); then
    warn "Подходящих файлов в $BACKUP_DIR нет."
    return 1
  fi
  for f in "${files[@]}"; do
    i=$((i + 1))
    printf '  %2d  %s  (%s)\n' "$i" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  done
  ask_re "Номер (Enter — отмена)" "" '^[0-9]*$' "Нужен номер из списка."
  [[ -z $ASK_RESULT ]] && return 1
  if (( 10#$ASK_RESULT < 1 || 10#$ASK_RESULT > ${#files[@]} )); then
    err "Нет такого номера."
    return 1
  fi
  BACKUP_PICKED="${files[$((10#$ASK_RESULT - 1))]}"
}

sorted_ports() { printf '%s\n' "$@" | sort -un | tr '\n' ' ' | sed 's/ $//'; }

version_gt() { [[ $1 != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }

script_version_of() { sed -n 's/^readonly APP_VERSION="\([0-9][0-9.]*\)".*/\1/p' "$1" | head -n 1; }

kv_get() { # kv_get ФАЙЛ КЛЮЧ
  [[ -f $1 ]] || return 0
  awk -F= -v k="$2" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$1"
}

kv_set() { # kv_set ФАЙЛ КЛЮЧ ЗНАЧЕНИЕ (значение без символов | & \)
  install -d -m 0755 "$(dirname "$1")" 2>/dev/null
  touch "$1" || return 1
  if grep -q "^$2=" "$1"; then
    sed -i "s|^$2=.*|$2=$3|" "$1"
  else
    printf '%s=%s\n' "$2" "$3" >>"$1"
  fi
}

kv_del() { # kv_del ФАЙЛ КЛЮЧ
  [[ -f $1 ]] && sed -i "/^$2=/d" "$1"
  return 0
}

reboot_prompt() {
  [[ -f /var/run/reboot-required ]] || return 0
  echo
  warn "Требуется перезагрузка (обновилось ядро или системные библиотеки)."
  if [[ -f /var/run/reboot-required.pkgs ]]; then sed 's/^/    /' /var/run/reboot-required.pkgs; fi
  hint "Перезагрузка прервёт SSH-сессию; контейнеры с restart: always поднимутся сами."
  if confirm "Перезагрузить сервер сейчас?" N; then
    info "Перезагружаю…"
    systemctl reboot
    sleep 5
  fi
}

# ══════════════════════════ Пользователь с sudo ══════════════════════════

mod_user() {
  header "1. Пользователь с правами sudo"
  ask_re "Имя нового пользователя" "" "$USERNAME_RE" \
    "Допустимо: a-z, 0-9, _ и -, начинать с буквы, до 32 символов."
  if ! user_setup "$ASK_RESULT" ask; then pause; return 1; fi
  echo
  warn "Дальше НЕ закрывай эту сессию. Открой второе окно терминала и проверь:"
  hint "ssh $ASK_RESULT@<IP-сервера>   — вход проходит"
  hint "sudo -v                  — sudo работает"
  hint "Только после этого переходи к пункту 2 (запрет входа root)."
  pause
}

user_setup() { # user_setup ИМЯ [copy_keys: ask|1|0]
  local user=$1 copy=${2:-ask}
  if [[ $user == root ]]; then err "root — не новый пользователь."; return 1; fi
  if [[ ! $user =~ $USERNAME_RE ]]; then err "Недопустимое имя пользователя: $user"; return 1; fi

  step "Создание пользователя"
  if id "$user" >/dev/null 2>&1; then
    warn "Пользователь '$user' уже существует — создание пропущено."
  else
    info "Сейчас adduser попросит задать пароль и данные (данные можно пропускать Enter)."
    if ! adduser "$user"; then err "adduser завершился с ошибкой."; return 1; fi
    if ! id "$user" >/dev/null 2>&1; then err "Пользователь не появился в системе."; return 1; fi
    ok "Пользователь '$user' создан."
  fi

  local pst
  pst="$(passwd -S "$user" 2>/dev/null | awk '{print $2}')"
  if [[ $pst != P ]]; then
    warn "У '$user' не задан пароль (статус: ${pst:-?}); для sudo он обычно нужен."
    if confirm "Задать пароль сейчас?" Y; then passwd "$user"; fi
  fi

  step "Права sudo"
  if user_in_sudo "$user"; then
    ok "'$user' уже в группе sudo."
  elif usermod -aG sudo "$user"; then
    ok "'$user' добавлен в группу sudo."
  else
    err "Не удалось добавить в группу sudo."; return 1
  fi

  step "Проверка"
  id "$user"
  echo "  groups: $(groups "$user")"
  if user_in_sudo "$user"; then ok "'$user' состоит в группе sudo."; else err "'$user' НЕ в группе sudo."; fi
  if sudo -l -U "$user" 2>/dev/null | grep -q 'may run the following'; then
    ok "sudoers подтверждает права sudo."
  else
    warn "sudoers не показывает прав sudo для '$user' — проверь /etc/sudoers."
  fi

  local home grp do_copy=0
  home="$(getent passwd "$user" | cut -d: -f6)"
  grp="$(id -gn "$user")"
  if [[ -s /root/.ssh/authorized_keys && ! -s "$home/.ssh/authorized_keys" ]]; then
    case $copy in
      1) do_copy=1 ;;
      0) ;;
      *)
        echo
        info "У root есть SSH-ключи, а у '$user' их нет."
        hint "Если на сервере вход только по ключам, без копирования ты не сможешь зайти новым пользователем."
        if confirm "Скопировать ключи root пользователю '$user'?" Y; then do_copy=1; fi
        ;;
    esac
    if (( do_copy )); then
      if install -d -m 700 -o "$user" -g "$grp" "$home/.ssh" &&
         install -m 600 -o "$user" -g "$grp" /root/.ssh/authorized_keys "$home/.ssh/authorized_keys"; then
        ok "SSH-ключи root скопированы пользователю '$user'."
      else
        err "Не удалось скопировать ключи."
      fi
    fi
  fi
  return 0
}

# ══════════════════════════ SSH: root, ключи, пароль, порт ══════════════════════════

ssh_rollback() { # $1 = путь к бэкапу
  cp -a "$1" "$SSHD_CONFIG" && ok "sshd_config восстановлен из $1"
  rm -f "$SSH_DROPIN"
}

mod_ssh_disable_root() {
  header "2. SSH: запрет входа под root"
  if ! cmd_exists sshd; then
    err "OpenSSH-сервер не найден."; pause; return 1
  fi

  local cur
  cur="$(sshd_effective permitrootlogin)"
  info "Сейчас PermitRootLogin = ${cur:-неизвестно}"
  if [[ $cur == no ]]; then
    ok "Вход под root уже запрещён — менять нечего."
    pause; return 0
  fi

  step "Предварительные проверки"
  local -a admins=()
  mapfile -t admins < <(getent group sudo | cut -d: -f4 | tr ',' '\n' | sed '/^$/d')
  if (( ${#admins[@]} == 0 )); then
    err "Нет ни одного пользователя в группе sudo. Сначала выполни пункт 1."
    pause; return 1
  fi
  ok "Пользователи с sudo: ${admins[*]}"

  local pass_auth
  pass_auth="$(sshd_effective passwordauthentication)"
  info "Вход по паролю (PasswordAuthentication): ${pass_auth:-?}"
  if [[ $pass_auth == no ]]; then
    local any_key=0 u h
    for u in "${admins[@]}"; do
      h="$(getent passwd "$u" | cut -d: -f6)"
      if [[ -s "$h/.ssh/authorized_keys" ]]; then any_key=1; fi
    done
    if (( ! any_key )); then
      err "Вход по паролю выключен, и ни у одного sudo-пользователя нет SSH-ключа."
      err "После запрета root ты потеряешь доступ к серверу. Операция остановлена."
      hint "Сначала скопируй ключи пользователю (пункт 1) или добавь свой ключ в ~/.ssh/authorized_keys."
      pause; return 1
    fi
    ok "У sudo-пользователя есть SSH-ключ."
  fi

  echo
  warn "НЕ закрывай текущую SSH-сессию до конца проверки!"
  hint "В ОТДЕЛЬНОМ окне терминала убедись, что:"
  hint "  1) ssh <пользователь>@<IP> — вход проходит"
  hint "  2) sudo -v — команда sudo работает"
  if ! confirm_word "Проверил(а) вход нового пользователя и sudo?" "да"; then
    info "Отменено. Изменений не вносилось."; pause; return 0
  fi

  step "Внесение изменений"
  local bak
  bak="${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
  if ! cp -a "$SSHD_CONFIG" "$bak"; then
    err "Не удалось сделать резервную копию."; pause; return 1
  fi
  ok "Резервная копия: $bak"

  if grep -qiE '^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]]' "$SSHD_CONFIG"; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]].*$/PermitRootLogin no/I' "$SSHD_CONFIG"
  else
    sed -i '1i PermitRootLogin no' "$SSHD_CONFIG"
  fi

  local out
  if ! out="$(sshd -t 2>&1)"; then
    err "Конфиг не прошёл проверку (sshd -t):"; echo "$out"
    ssh_rollback "$bak"; pause; return 1
  fi

  # Начиная с Ubuntu 22.04 файлы из sshd_config.d читаются раньше основного и побеждают (first match wins)
  if [[ "$(sshd_effective permitrootlogin)" != no ]]; then
    warn "Значение перекрыто файлом из sshd_config.d — создаю свой drop-in с приоритетом."
    printf '# Создано %s\nPermitRootLogin no\n' "$APP_NAME" >"$SSH_DROPIN"
    chmod 644 "$SSH_DROPIN"
    if ! out="$(sshd -t 2>&1)"; then
      err "Конфиг не прошёл проверку:"; echo "$out"
      ssh_rollback "$bak"; pause; return 1
    fi
  fi

  if [[ "$(sshd_effective permitrootlogin)" != no ]]; then
    err "Не удалось добиться PermitRootLogin no. Откатываю."
    ssh_rollback "$bak"; pause; return 1
  fi
  ok "Проверка конфигурации пройдена: PermitRootLogin no"

  local svc
  svc="$(ssh_service_name)"
  if systemctl restart "$svc"; then
    ok "Служба $svc перезапущена."
  else
    err "Не удалось перезапустить $svc — откатываю изменения."
    ssh_rollback "$bak"; systemctl restart "$svc"
    pause; return 1
  fi
  if service_active "$svc"; then ok "Служба $svc работает."; else err "Служба $svc не активна!"; fi

  echo
  warn "Текущую сессию пока не закрывай: открой НОВОЕ окно и проверь вход пользователем."
  hint "Если что-то пошло не так — меню SSH → «Откатить изменения»."
  pause
}

mod_ssh_show() {
  header "SSH: текущие параметры"
  if ! cmd_exists sshd; then err "OpenSSH-сервер не найден."; pause; return 1; fi
  install -d -m 0755 /run/sshd 2>/dev/null
  local k
  for k in port permitrootlogin passwordauthentication pubkeyauthentication; do
    printf '  %-24s %s\n' "$k" "$(sshd -T 2>/dev/null | awk -v k="$k" '$1==k {printf "%s ", $2}')"
  done
  echo
  local svc; svc="$(ssh_service_name)"
  info "Служба $svc: $(systemctl is-active "$svc" 2>/dev/null)"
  [[ -f $SSH_DROPIN ]] && info "Есть drop-in: $SSH_DROPIN"
  pause
}

mod_ssh_restore() {
  header "SSH: откат изменений"
  local latest
  latest="$(ls -1t "${SSHD_CONFIG}".bak.* 2>/dev/null | head -n 1)"
  if [[ -z $latest ]]; then
    warn "Резервных копий не найдено."; pause; return 0
  fi
  info "Последняя копия: $latest"
  confirm "Восстановить sshd_config из неё?" N || { info "Отменено."; pause; return 0; }
  ssh_rollback "$latest"
  install -d -m 0755 /run/sshd 2>/dev/null
  local out
  if ! out="$(sshd -t 2>&1)"; then
    err "Восстановленный конфиг не проходит проверку:"; echo "$out"; pause; return 1
  fi
  local svc; svc="$(ssh_service_name)"
  if systemctl restart "$svc"; then ok "Служба $svc перезапущена."; else err "Не удалось перезапустить $svc."; fi
  pause
}

menu_ssh() {
  while true; do
    header "2. SSH"
    menu_item 1 "Запретить вход под root"
    menu_item 2 "Добавить публичный SSH-ключ пользователю"
    menu_item 3 "Вход только по ключам (отключить пароль)"
    menu_item 4 "Вернуть вход по паролю"
    menu_item 5 "Добавить новый порт SSH (старый пока остаётся)"
    menu_item 6 "Закрыть старый порт SSH"
    menu_item 7 "Показать текущие параметры SSH"
    menu_item 8 "Откатить запрет root (из резервной копии)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_ssh_disable_root ;;
      2) mod_ssh_addkey ;;
      3) mod_ssh_keys_only ;;
      4) mod_ssh_password_on ;;
      5) mod_ssh_port_add ;;
      6) mod_ssh_port_close_old ;;
      7) mod_ssh_show ;;
      8) mod_ssh_restore ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

pubkey_fingerprint() { # печатает отпечаток, если строка — валидный публичный ключ
  local tmp out rc
  tmp="$(mktemp)"
  printf '%s\n' "$1" >"$tmp"
  out="$(ssh-keygen -l -f "$tmp" 2>/dev/null)"
  rc=$?
  rm -f "$tmp"
  [[ $rc -eq 0 && -n $out ]] || return 1
  printf '%s' "$out"
}

ssh_drop_in_ok() {
  [[ -d /etc/ssh/sshd_config.d ]] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSHD_CONFIG"
}

ssh_apply_restart() {
  local svc
  svc="$(ssh_service_name)"
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl restart ssh.socket 2>/dev/null
  fi
  systemctl restart "$svc"
}

ssh_state_ok() { # слушаются все порты из $1 и не слушается ни один из $2
  local p
  local -a want=() gone=()
  read -r -a want <<<"$1"
  read -r -a gone <<<"${2:-}"
  ports_listening "${want[@]}" || return 1
  sleep 1
  for p in "${gone[@]}"; do
    port_in_use "$p" && return 1
  done
  return 0
}

ssh_restart_verify() { # $1 = порты, которые должны слушаться; $2 = порты, которые должны закрыться
  ssh_apply_restart
  ssh_state_ok "$1" "${2:-}" && return 0
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    warn "ssh.socket не подхватил порты — перехожу на обычный режим sshd (без socket activation)."
    systemctl disable --now ssh.socket >/dev/null 2>&1
    systemctl enable "$(ssh_service_name)" >/dev/null 2>&1
    systemctl restart "$(ssh_service_name)"
    ssh_state_ok "$1" "${2:-}" && return 0
  fi
  return 1
}

ssh_write_port_dropin() { # ssh_write_port_dropin порт…
  local p
  {
    printf '# Создано %s\n' "$APP_NAME"
    for p in "$@"; do printf 'Port %s\n' "$p"; done
  } >"$SSH_DROPIN_PORT"
  chmod 644 "$SSH_DROPIN_PORT"
}

ssh_port_rollback() { # ssh_port_rollback БЭКАП_DROPIN UFW_ДОБАВЛЕН ПОРТ
  if [[ -n $1 ]]; then cp -a "$1" "$SSH_DROPIN_PORT"; else rm -f "$SSH_DROPIN_PORT"; fi
  if [[ ${2:-0} == 1 ]]; then ufw --force delete allow "${3}/tcp" >/dev/null 2>&1; fi
  ssh_apply_restart
  warn "Изменения откатены."
}

ssh_close_rollback() { # ssh_close_rollback БЭКАП_DROPIN БЭКАП_ОСНОВНОГО
  if [[ -n $1 ]]; then cp -a "$1" "$SSH_DROPIN_PORT"; else rm -f "$SSH_DROPIN_PORT"; fi
  if [[ -n ${2:-} && -f $2 ]]; then cp -a "$2" "$SSHD_CONFIG"; fi
  ssh_apply_restart
  warn "Изменения откатены."
}

ssh_auth_rollback() { # ssh_auth_rollback БЭКАП_DROPIN
  if [[ -n $1 ]]; then cp -a "$1" "$SSH_DROPIN_AUTH"; else rm -f "$SSH_DROPIN_AUTH"; fi
  warn "Изменения откатены."
}

mod_ssh_addkey() {
  header "SSH: добавить публичный ключ"
  info "Ключ добавляется в ~/.ssh/authorized_keys выбранного пользователя."
  hint "Публичный ключ — одна строка вида «ssh-ed25519 AAAA… комментарий» (файл .pub на твоём компьютере)."
  ask_re "Пользователь" "" "$USERNAME_RE" "Нужно имя существующего пользователя."
  local user=$ASK_RESULT
  if ! id "$user" >/dev/null 2>&1; then
    err "Пользователя '$user' нет (создай его в пункте 1)."; pause; return 1
  fi
  ask "Вставь публичный ключ одной строкой (Enter — отмена)"
  if [[ -z $ASK_RESULT ]]; then info "Отменено."; pause; return 0; fi
  if ssh_addkey_apply "$user" "$ASK_RESULT"; then
    hint "Проверь вход по ключу в отдельном окне, прежде чем отключать пароль."
  fi
  pause
}

mod_ssh_keys_only() {
  header "SSH: вход только по ключам"
  if ! cmd_exists sshd; then err "OpenSSH-сервер не найден."; pause; return 1; fi
  if ! ssh_drop_in_ok; then
    err "Нужен sshd_config с Include /etc/ssh/sshd_config.d (Ubuntu 22.04+)."; pause; return 1
  fi
  install -d -m 0755 /run/sshd 2>/dev/null
  local cur
  cur="$(sshd_effective passwordauthentication)"
  info "Сейчас PasswordAuthentication = ${cur:-?}"
  if [[ $cur == no ]]; then ok "Вход по паролю уже отключён."; pause; return 0; fi

  local -a admins=() withkeys=()
  local u h
  mapfile -t admins < <(getent group sudo | cut -d: -f4 | tr ',' '\n' | sed '/^$/d')
  for u in "${admins[@]}"; do
    h="$(getent passwd "$u" | cut -d: -f6)"
    if [[ -s "$h/.ssh/authorized_keys" ]]; then withkeys+=("$u"); fi
  done
  if (( ${#withkeys[@]} == 0 )); then
    err "Ни у одного пользователя с sudo нет SSH-ключа — после отключения пароля ты потеряешь доступ."
    hint "Сначала: SSH → «Добавить публичный ключ»."
    pause; return 1
  fi
  ok "Ключи есть у: ${withkeys[*]}"

  echo
  warn "НЕ закрывай текущую SSH-сессию!"
  hint "В ОТДЕЛЬНОМ окне проверь вход по ключу: ssh -i <ключ> <пользователь>@<IP>"
  if ! confirm_word "Вход по ключу проверен?" "да"; then
    info "Отменено. Изменений не вносилось."; pause; return 0
  fi

  local bak=""
  if [[ -f $SSH_DROPIN_AUTH ]]; then bak="$(mktemp)"; cp -a "$SSH_DROPIN_AUTH" "$bak"; fi
  printf '# Создано %s\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\n' "$APP_NAME" >"$SSH_DROPIN_AUTH"
  chmod 644 "$SSH_DROPIN_AUTH"

  local out
  if ! out="$(sshd -t 2>&1)"; then
    err "Конфиг не прошёл проверку (sshd -t):"; echo "$out"
    ssh_auth_rollback "$bak"; pause; return 1
  fi
  if [[ "$(sshd_effective passwordauthentication)" != no ]]; then
    err "Параметр перекрыт другим файлом конфигурации."
    ssh_auth_rollback "$bak"; pause; return 1
  fi
  local svc
  svc="$(ssh_service_name)"
  if systemctl restart "$svc"; then
    ok "Служба $svc перезапущена: вход по паролю отключён."
  else
    err "Не удалось перезапустить $svc — откатываю."
    ssh_auth_rollback "$bak"; systemctl restart "$svc"
    pause; return 1
  fi
  warn "Текущую сессию не закрывай, пока не убедишься, что новое подключение по ключу работает."
  hint "Вернуть пароль: SSH → «Вернуть вход по паролю»."
  pause
}

mod_ssh_password_on() {
  header "SSH: вернуть вход по паролю"
  if [[ ! -f $SSH_DROPIN_AUTH ]]; then
    info "Файла $SSH_DROPIN_AUTH нет — скрипт пароль не отключал."
    info "Текущее значение PasswordAuthentication: $(sshd_effective passwordauthentication)"
    pause; return 0
  fi
  confirm "Включить вход по паролю обратно?" Y || { info "Отменено."; pause; return 0; }
  rm -f "$SSH_DROPIN_AUTH"
  install -d -m 0755 /run/sshd 2>/dev/null
  local out
  if ! out="$(sshd -t 2>&1)"; then err "Конфиг не проходит проверку:"; echo "$out"; pause; return 1; fi
  local svc
  svc="$(ssh_service_name)"
  if systemctl restart "$svc"; then ok "Служба $svc перезапущена."; else err "Не удалось перезапустить $svc."; fi
  info "PasswordAuthentication = $(sshd_effective passwordauthentication)"
  pause
}

mod_ssh_port_add() {
  header "SSH: добавить новый порт"
  if ! cmd_exists sshd; then err "OpenSSH-сервер не найден."; pause; return 1; fi
  if ! ssh_drop_in_ok; then
    err "Нужен sshd_config с Include /etc/ssh/sshd_config.d (Ubuntu 22.04+)."; pause; return 1
  fi
  local cur new
  cur="$(detect_ssh_ports)"
  info "Сейчас SSH слушает порт(ы): $cur"
  hint "Безопасная схема: сначала добавляем новый порт (старый остаётся), проверяешь вход, затем закрываешь старый."
  while true; do
    ask "Новый порт SSH, 1024–65535 (Enter — отмена)" ""
    new=$ASK_RESULT
    if [[ -z $new ]]; then info "Отменено."; pause; return 0; fi
    if ! valid_port "$new" || (( 10#$new < 1024 )); then err "Нужен номер порта 1024–65535."; continue; fi
    new=$((10#$new))
    if [[ " $cur " == *" $new "* ]]; then err "Этот порт уже используется SSH."; continue; fi
    if port_in_use "$new"; then err "Порт $new занят другой службой."; continue; fi
    break
  done

  local -a all=()
  read -r -a all <<<"$cur"
  all+=("$new")
  local want
  want="$(sorted_ports "${all[@]}")"
  warn "Если у хостера есть внешний файрвол (в панели VPS) — открой порт $new и там."
  confirm "Открыть порт $new и перезапустить SSH?" Y || { info "Отменено."; pause; return 0; }

  local ufw_added=0
  if ufw_is_active; then
    if ufw allow "${new}/tcp" >/dev/null; then ufw_added=1; ok "UFW: открыт порт ${new}/tcp"; else err "Не удалось открыть порт в UFW."; pause; return 1; fi
  fi

  local dbak="" out
  if [[ -f $SSH_DROPIN_PORT ]]; then dbak="$(mktemp)"; cp -a "$SSH_DROPIN_PORT" "$dbak"; fi
  ssh_write_port_dropin "${all[@]}"

  if ! out="$(sshd -t 2>&1)"; then
    err "Конфиг не прошёл проверку (sshd -t):"; echo "$out"
    ssh_port_rollback "$dbak" "$ufw_added" "$new"; pause; return 1
  fi
  if [[ "$(detect_ssh_ports)" != "$want" ]]; then
    err "Итоговые порты не совпали с ожидаемыми ($(detect_ssh_ports) ≠ $want)."
    ssh_port_rollback "$dbak" "$ufw_added" "$new"; pause; return 1
  fi
  if ssh_restart_verify "$want" ""; then
    ok "SSH слушает порты: $want"
  else
    err "SSH не начал слушать новый порт."
    ssh_port_rollback "$dbak" "$ufw_added" "$new"; pause; return 1
  fi
  f2b_sync_ports "$want"

  echo
  warn "Старый порт пока открыт. Текущую сессию не закрывай."
  hint "В новом окне проверь: ssh -p $new <пользователь>@<IP>"
  hint "Когда убедишься, что вход работает — SSH → «Закрыть старый порт»."
  pause
}

mod_ssh_port_close_old() {
  header "SSH: закрыть старый порт"
  if ! cmd_exists sshd; then err "OpenSSH-сервер не найден."; pause; return 1; fi
  if ! ssh_drop_in_ok; then
    err "Нужен sshd_config с Include /etc/ssh/sshd_config.d (Ubuntu 22.04+)."; pause; return 1
  fi
  local cur
  cur="$(detect_ssh_ports)"
  local -a ports=() gone=()
  read -r -a ports <<<"$cur"
  if (( ${#ports[@]} < 2 )); then
    info "Сейчас открыт один порт SSH ($cur) — закрывать нечего."; pause; return 0
  fi
  info "Сейчас SSH слушает: $cur"
  local keep="${ports[-1]}" p
  ask_re "Какой порт оставить" "$keep" '^[0-9]+$' "Нужен номер порта."
  keep=$ASK_RESULT
  if [[ " $cur " != *" $keep "* ]]; then err "Порта $keep нет среди открытых."; pause; return 1; fi
  for p in "${ports[@]}"; do
    if [[ $p != "$keep" ]]; then gone+=("$p"); fi
  done

  echo
  warn "Будут закрыты порты: ${gone[*]}. Останется: $keep."
  hint "В ОТДЕЛЬНОМ окне проверь: ssh -p $keep <пользователь>@<IP> — вход проходит."
  if ! confirm_word "Вход по порту $keep проверен?" "да"; then
    info "Отменено. Изменений не вносилось."; pause; return 0
  fi

  local dbak="" mbak out
  if [[ -f $SSH_DROPIN_PORT ]]; then dbak="$(mktemp)"; cp -a "$SSH_DROPIN_PORT" "$dbak"; fi
  mbak="${SSHD_CONFIG}.portbak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$SSHD_CONFIG" "$mbak" && ok "Резервная копия: $mbak"

  ssh_write_port_dropin "$keep"
  # строки Port в основном файле добавили бы старый порт обратно — отключаем их
  sed -i -E 's/^([[:space:]]*Port[[:space:]].*)$/# \1  # отключено vpsmenu/' "$SSHD_CONFIG"

  if ! out="$(sshd -t 2>&1)"; then
    err "Конфиг не прошёл проверку (sshd -t):"; echo "$out"
    ssh_close_rollback "$dbak" "$mbak"; pause; return 1
  fi
  if [[ "$(detect_ssh_ports)" != "$keep" ]]; then
    err "Старые порты всё ещё заданы в другом файле:"
    grep -rniE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config.d/ 2>/dev/null | sed 's/^/    /'
    ssh_close_rollback "$dbak" "$mbak"; pause; return 1
  fi
  if ! ssh_restart_verify "$keep" "${gone[*]}"; then
    err "После перезапуска порты не соответствуют ожидаемым."
    ssh_close_rollback "$dbak" "$mbak"; pause; return 1
  fi
  ok "SSH слушает только порт $keep."

  if cmd_exists ufw; then
    for p in "${gone[@]}"; do
      ufw --force delete allow "${p}/tcp" >/dev/null 2>&1 && ok "UFW: правило ${p}/tcp удалено (если было)."
    done
  fi
  f2b_sync_ports "$keep"
  warn "Если у хостера есть внешний файрвол — закрой старый порт и там."
  pause
}

ssh_addkey_apply() { # ssh_addkey_apply ПОЛЬЗОВАТЕЛЬ КЛЮЧ
  local user=$1 key=$2 fp home grp file
  if ! id "$user" >/dev/null 2>&1; then err "Пользователя '$user' нет."; return 1; fi
  if [[ $key == -----* ]]; then
    err "Это ПРИВАТНЫЙ ключ. Его нельзя никуда вставлять — нужен публичный (файл .pub)."; return 1
  fi
  if ! fp="$(pubkey_fingerprint "$key")"; then
    err "Это не похоже на публичный SSH-ключ (проверка ssh-keygen не прошла)."; return 1
  fi
  home="$(getent passwd "$user" | cut -d: -f6)"
  grp="$(id -gn "$user")"
  file="$home/.ssh/authorized_keys"
  if ! install -d -m 700 -o "$user" -g "$grp" "$home/.ssh"; then err "Не удалось создать $home/.ssh"; return 1; fi
  touch "$file" && chown "$user:$grp" "$file" && chmod 600 "$file"
  if grep -qxF "$key" "$file"; then
    warn "Такой ключ у '$user' уже есть."
  elif printf '%s\n' "$key" >>"$file"; then
    ok "Ключ добавлен пользователю '$user'."
  else
    err "Не удалось записать ключ."; return 1
  fi
  info "Отпечаток: $fp"
}

# ══════════════════════════ UFW ══════════════════════════

mod_ufw_setup() {
  header "3. UFW: установка и настройка"
  if cmd_exists ufw; then
    ok "UFW уже установлен: $(ufw --version | head -n 1)"
  else
    apt_install ufw || { pause; return 1; }
    ok "UFW установлен: $(ufw --version | head -n 1)"
  fi

  if ufw_is_active; then
    ok "UFW уже включён — настройки не меняю, показываю состояние."
    echo; ufw status verbose
    echo; info "Уровень логирования: $(ufw_c status verbose | awk -F': ' '/^Logging/ {print $2}')"
    if service_active docker; then
      echo; warn "Docker публикует порты в обход UFW: порты контейнеров (-p) закрываются не ufw, а настройками контейнера."
    fi
    pause; return 0
  fi

  step "Первичная настройка"
  local detected ports p bad
  detected="$(detect_ssh_ports)"
  info "Порт(ы) SSH на этом сервере: $detected"
  warn "Порт SSH обязательно должен быть открыт, иначе после включения UFW ты потеряешь доступ."
  while true; do
    ask "Какие порты SSH открыть (через пробел)" "$detected"
    ports="$ASK_RESULT"
    bad=0
    for p in $ports; do valid_port "$p" || bad=1; done
    if [[ -n $ports ]] && (( ! bad )); then break; fi
    err "Укажи номера портов от 1 до 65535 через пробел."
  done

  echo
  info "Будет выполнено: default deny incoming / allow outgoing; allow ${ports// //tcp, }/tcp; enable; logging low"
  confirm "Включить UFW?" Y || { info "Отменено."; pause; return 0; }
  ufw_apply "$ports" "" || { pause; return 1; }
  echo
  hint "Нужные порты открывай через меню: UFW → «Открыть порт» (например, порт ноды Remnawave для IP панели)."
  pause
}

mod_ufw_status() {
  header "UFW: статус"
  if ! cmd_exists ufw; then err "UFW не установлен."; pause; return 1; fi
  ufw --version | head -n 1
  echo; ufw status verbose
  pause
}

mod_ufw_allow() {
  header "UFW: открыть порт"
  if ! cmd_exists ufw; then err "UFW не установлен (пункт 1)."; pause; return 1; fi
  ask_re "Порт или диапазон (например 443 или 10000:10100)" "" '^[0-9]{1,5}(:[0-9]{1,5})?$' \
    "Формат: 443 или 10000:10100."
  local port=$ASK_RESULT p
  for p in ${port//:/ }; do
    if ! valid_port "$p"; then err "Порт $p вне диапазона 1–65535."; pause; return 1; fi
  done
  ask_re "Протокол tcp / udp / any" "tcp" '^(tcp|udp|any)$' "Допустимо: tcp, udp, any."
  local proto=$ASK_RESULT
  if [[ $port == *:* && $proto == any ]]; then
    err "Для диапазона портов нужно указать tcp или udp."; pause; return 1
  fi
  ask_re "Только с IP/подсети (Enter — отовсюду)" "" '^$|^[0-9a-fA-F:.]+(/[0-9]{1,3})?$' \
    "Ожидается IP или подсеть, например 203.0.113.5 или 10.0.0.0/24."
  local src=$ASK_RESULT

  local -a cmd=(ufw allow)
  if [[ -n $src ]]; then
    cmd+=(from "$src" to any port "$port")
    [[ $proto != any ]] && cmd+=(proto "$proto")
  else
    if [[ $proto == any ]]; then cmd+=("$port"); else cmd+=("${port}/${proto}"); fi
  fi
  info "Выполняю: ${cmd[*]}"
  if "${cmd[@]}"; then ok "Правило добавлено."; else err "Не удалось добавить правило."; fi
  pause
}

mod_ufw_delete() {
  header "UFW: удалить правило"
  if ! cmd_exists ufw; then err "UFW не установлен."; pause; return 1; fi
  ufw status numbered
  echo
  ask_re "Номер правила для удаления (Enter — отмена)" "" '^[0-9]*$' "Нужен номер из списка."
  [[ -z $ASK_RESULT ]] && { info "Отменено."; pause; return 0; }
  local n=$ASK_RESULT
  warn "Если удалишь правило SSH-порта — потеряешь доступ при следующем подключении."
  if confirm "Удалить правило №$n?" N; then
    if ufw --force delete "$n"; then ok "Правило удалено."; else err "Не удалось удалить."; fi
  fi
  pause
}

mod_ufw_logging() {
  header "UFW: логирование"
  if ! cmd_exists ufw; then err "UFW не установлен."; pause; return 1; fi
  info "Текущий уровень: $(ufw_c status verbose | awk -F': ' '/^Logging/ {print $2}')"
  hint "По умолчанию low — для большинства случаев этого достаточно."
  ask_re "Уровень (off / low / medium / high / full)" "low" '^(off|low|medium|high|full)$' \
    "Допустимо: off, low, medium, high, full."
  if ufw logging "$ASK_RESULT" >/dev/null; then ok "Логирование: $ASK_RESULT"; else err "Не удалось изменить."; fi
  pause
}

menu_ufw() {
  while true; do
    header "3. UFW"
    menu_item 1 "Установить / первичная настройка (или показать статус)"
    menu_item 2 "Статус подробно"
    menu_item 3 "Открыть порт"
    menu_item 4 "Удалить правило"
    menu_item 5 "Уровень логирования"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_ufw_setup ;;
      2) mod_ufw_status ;;
      3) mod_ufw_allow ;;
      4) mod_ufw_delete ;;
      5) mod_ufw_logging ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

ufw_apply() { # ufw_apply "порты SSH через пробел" ["доп. порты через пробел: 443 или 443/tcp"]
  local -a sshp=() extra=()
  local p
  read -r -a sshp <<<"$1"
  read -r -a extra <<<"${2:-}"

  if ufw_is_active; then
    info "UFW уже включён — только добавляю правила."
  elif ufw default deny incoming >/dev/null && ufw default allow outgoing >/dev/null; then
    ok "Политики по умолчанию: входящие закрыты, исходящие открыты."
  else
    err "Не удалось задать политики."; return 1
  fi
  for p in "${sshp[@]}"; do
    if ufw allow "${p}/tcp" >/dev/null; then ok "Открыт порт ${p}/tcp (SSH)"; else err "Не удалось открыть ${p}/tcp"; return 1; fi
  done
  for p in "${extra[@]}"; do
    if ufw allow "$p" >/dev/null; then ok "Открыт порт $p"; else err "Не удалось открыть $p"; fi
  done
  if ! ufw_is_active; then
    if ufw --force enable >/dev/null; then ok "UFW включён."; else err "Не удалось включить UFW."; return 1; fi
    ufw logging low >/dev/null && ok "Логирование: low"
  fi
  if ufw_is_active; then ok "Проверка: UFW активен."; else err "UFW не активен!"; return 1; fi
  for p in "${sshp[@]}"; do
    if ufw_c status | grep -qE "^${p}/tcp[[:space:]]+ALLOW"; then ok "Правило для ${p}/tcp на месте."; else warn "Правило для ${p}/tcp не найдено в статусе."; fi
  done
  echo; ufw status verbose
}

# ══════════════════════════ nftables ══════════════════════════

nft_install_ordering() {
  # Штатный /etc/nftables.conf начинается с «flush ruleset» — при загрузке он сносит правила ufw/docker,
  # если отработает после них. Заставляем nftables стартовать раньше.
  local d=/etc/systemd/system/nftables.service.d f
  f="$d/10-before-ufw-docker.conf"
  [[ -f $f ]] && return 0
  install -d "$d" || return 1
  cat >"$f" <<'EOF'
[Unit]
# Создано vpsmenu: nftables.conf делает "flush ruleset", поэтому запускаем его ДО ufw и docker.
Before=ufw.service docker.service
EOF
  systemctl daemon-reload && ok "Добавлен порядок запуска: nftables → ufw → docker."
}

mod_nft_setup() {
  header "4. nftables: установка и запуск"
  if is_pkg_installed nftables; then
    ok "nftables уже установлен: $(nft --version 2>/dev/null)"
  else
    apt_install nftables || { pause; return 1; }
    ok "nftables установлен: $(nft --version 2>/dev/null)"
  fi

  nft_install_ordering

  if service_enabled nftables; then
    ok "Автозапуск уже включён."
  elif systemctl enable nftables >/dev/null 2>&1; then
    ok "Автозапуск включён."
  else
    err "Не удалось включить автозапуск."
  fi

  if service_active nftables; then
    ok "Служба nftables уже запущена."
  else
    local ufw_on=0 docker_on=0
    ufw_is_active && ufw_on=1
    service_active docker && docker_on=1
    if (( ufw_on || docker_on )); then
      echo
      warn "При запуске nftables читает /etc/nftables.conf, который начинается с «flush ruleset»."
      warn "Это на мгновение сбросит правила UFW/Docker; я перезагружу их сразу после запуска."
      confirm "Запустить nftables сейчас?" Y || { info "Запуск отложен."; pause; return 0; }
    fi
    if systemctl start nftables; then
      ok "nftables запущен."
      if (( ufw_on )); then
        if ufw reload >/dev/null; then ok "Правила UFW перезагружены."; else err "Не удалось перезагрузить UFW!"; fi
      fi
      if (( docker_on )); then
        hint "Docker нужно перезапустить, чтобы он заново создал свои правила (контейнеры с restart: always поднимутся сами)."
        if confirm "Перезапустить Docker?" Y; then
          if systemctl restart docker; then ok "Docker перезапущен."; else err "Не удалось перезапустить Docker."; fi
        fi
      fi
    else
      err "Не удалось запустить nftables. Смотри: journalctl -u nftables"
    fi
  fi

  step "Статус"
  echo "  active:  $(systemctl is-active nftables 2>/dev/null)"
  echo "  enabled: $(systemctl is-enabled nftables 2>/dev/null)"
  echo
  nft list ruleset | show_paged
  pause
}

mod_nft_ruleset() {
  header "nftables: список правил"
  if ! cmd_exists nft; then err "nftables не установлен."; pause; return 1; fi
  nft list ruleset | show_paged
  pause
}

mod_nft_check() {
  header "nftables: проверка /etc/nftables.conf"
  if ! cmd_exists nft; then err "nftables не установлен."; pause; return 1; fi
  if [[ ! -f /etc/nftables.conf ]]; then err "Файла /etc/nftables.conf нет."; pause; return 1; fi
  local out
  if out="$(nft -c -f /etc/nftables.conf 2>&1)"; then ok "Синтаксис корректен."; else err "Ошибка в конфиге:"; echo "$out"; fi
  pause
}

menu_nft() {
  while true; do
    header "4. nftables"
    menu_item 1 "Установить / включить / запустить"
    menu_item 2 "Показать список правил"
    menu_item 3 "Проверить синтаксис /etc/nftables.conf"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_nft_setup ;;
      2) mod_nft_ruleset ;;
      3) mod_nft_check ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

# ══════════════════════════ Fail2ban ══════════════════════════

f2b_get() { # текущее значение параметра из sshd.local
  [[ -f $F2B_JAIL ]] || return 0
  awk -F= -v k="$1" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$F2B_JAIL"
}

f2b_configure() {
  local time_re='^[0-9]+(s|m|h|d|w|mo|y)?$' bantime_re='^(-1|[0-9]+(s|m|h|d|w|mo|y)?)$'
  local port maxretry findtime bantime ignoreip cur

  step "Параметры защиты SSH (jail sshd)"
  hint "Enter — оставить значение в скобках."

  echo; hint "port: порт(ы) SSH через запятую."
  cur="$(f2b_get port)"
  ask_re "port" "${cur:-$(detect_ssh_ports | tr ' ' ',')}" '^[0-9]{1,5}(,[0-9]{1,5})*$' "Формат: 22 или 22,2222."
  port=$ASK_RESULT

  echo; hint "maxretry: сколько неудачных попыток входа до бана."
  cur="$(f2b_get maxretry)"
  ask_re "maxretry" "${cur:-3}" '^[1-9][0-9]*$' "Нужно целое число больше нуля."
  maxretry=$ASK_RESULT

  echo; hint "findtime: за какой период считаются попытки. Формат: число + s/m/h/d/w (10m, 1h)."
  cur="$(f2b_get findtime)"
  ask_re "findtime" "${cur:-10m}" "$time_re" "Формат: 600, 10m, 1h, 1d."
  findtime=$ASK_RESULT

  echo; hint "bantime: на сколько банить. Примеры: 1h, 2d, 1w; -1 — навсегда."
  cur="$(f2b_get bantime)"
  ask_re "bantime" "${cur:-2d}" "$bantime_re" "Формат: 3600, 12h, 2d, 1w или -1."
  bantime=$ASK_RESULT

  echo; hint "ignoreip: адреса, которые никогда не банятся (через пробел). Добавь свой IP, чтобы не забанить себя."
  cur="$(f2b_get ignoreip)"
  ask "ignoreip" "${cur:-127.0.0.1/8 ::1}"
  ignoreip=$ASK_RESULT

  f2b_write_jail "$port" "$maxretry" "$findtime" "$bantime" "$ignoreip"
}

mod_f2b_setup() {
  header "5. Fail2ban: установка и настройка"
  f2b_install_apply || { pause; return 1; }

  if [[ -f $F2B_JAIL ]]; then
    ok "Найден твой конфиг: $F2B_JAIL"
    echo; sed 's/^/    /' "$F2B_JAIL"; echo
    fail2ban-client status sshd 2>/dev/null
    echo
    confirm "Изменить настройки?" N && f2b_configure
  else
    f2b_configure
  fi
  pause
}

mod_f2b_reconfigure() {
  header "Fail2ban: параметры sshd-jail"
  if ! is_pkg_installed fail2ban; then err "fail2ban не установлен."; pause; return 1; fi
  f2b_configure
  pause
}

mod_f2b_status() {
  header "Fail2ban: статус sshd"
  if ! cmd_exists fail2ban-client; then err "fail2ban не установлен."; pause; return 1; fi
  echo "  service: $(systemctl is-active fail2ban 2>/dev/null) / $(systemctl is-enabled fail2ban 2>/dev/null)"
  echo
  if ! fail2ban-client status sshd; then warn "jail sshd недоступен — настрой его (пункт 1)."; fi
  pause
}

mod_f2b_unban() {
  header "Fail2ban: разбанить IP"
  if ! cmd_exists fail2ban-client; then err "fail2ban не установлен."; pause; return 1; fi
  fail2ban-client status sshd 2>/dev/null | grep -E 'Banned IP list|Currently banned' | sed 's/^[[:space:]]*/  /'
  echo
  ask_re "IP для разбана (Enter — отмена)" "" '^$|^[0-9a-fA-F:.]+$' "Ожидается IP-адрес."
  [[ -z $ASK_RESULT ]] && { info "Отменено."; pause; return 0; }
  if fail2ban-client set sshd unbanip "$ASK_RESULT"; then ok "Готово."; else err "Не удалось разбанить."; fi
  pause
}

mod_f2b_logs_live() {
  header "Fail2ban: лог в реальном времени (Ctrl+C — выход)"
  if [[ -f /var/log/fail2ban.log ]]; then
    run_interruptible tail -n 50 -f /var/log/fail2ban.log
  else
    run_interruptible journalctl -u fail2ban -n 50 -f
  fi
  pause
}

mod_f2b_journal() {
  header "Fail2ban: журнал systemd"
  journalctl -u fail2ban -n 200 --no-pager | show_paged
  pause
}

mod_f2b_authlog() {
  header "Лог авторизации SSH (последние записи)"
  if [[ -f /var/log/auth.log ]]; then
    tail -n 80 /var/log/auth.log | show_paged
  else
    info "Файла /var/log/auth.log нет — беру журнал systemd."
    journalctl -u "$(ssh_service_name)" -n 80 --no-pager | show_paged
  fi
  pause
}

mod_f2b_showconf() {
  header "Fail2ban: конфиг"
  if [[ -f $F2B_JAIL ]]; then sed 's/^/  /' "$F2B_JAIL"; else warn "$F2B_JAIL не найден."; fi
  echo
  hint "Основной jail.conf лучше не править — для своих настроек используй jail.d/*.local."
  pause
}

mod_f2b_restart() {
  header "Fail2ban: перезапуск"
  if ! cmd_exists fail2ban-client; then err "fail2ban не установлен."; pause; return 1; fi
  if systemctl restart fail2ban; then ok "Перезапущен."; else err "Не удалось перезапустить."; fi
  pause
}

menu_f2b() {
  while true; do
    header "5. Fail2ban"
    menu_item 1 "Установить и настроить (или показать состояние)"
    menu_item 2 "Изменить параметры sshd-jail"
    menu_item 3 "Статус sshd"
    menu_item 4 "Разбанить IP"
    menu_item 5 "Лог fail2ban в реальном времени"
    menu_item 6 "Журнал systemd (journalctl)"
    menu_item 7 "Лог авторизации SSH"
    menu_item 8 "Показать конфиг sshd.local"
    menu_item 9 "Перезапустить fail2ban"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_f2b_setup ;;
      2) mod_f2b_reconfigure ;;
      3) mod_f2b_status ;;
      4) mod_f2b_unban ;;
      5) mod_f2b_logs_live ;;
      6) mod_f2b_journal ;;
      7) mod_f2b_authlog ;;
      8) mod_f2b_showconf ;;
      9) mod_f2b_restart ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

f2b_sync_ports() { # f2b_sync_ports "22 2222" — обновляет порты в jail sshd, если он настроен
  [[ -f $F2B_JAIL ]] || return 0
  local list="${1// /,}"
  sed -i -E "s/^(port[[:space:]]*=).*/\1 ${list}/" "$F2B_JAIL"
  ok "Fail2ban: порты в $F2B_JAIL → $list"
  if service_active fail2ban; then
    if fail2ban-client -t >/dev/null 2>&1 && systemctl restart fail2ban; then
      ok "fail2ban перезапущен."
    else
      warn "Проверь fail2ban вручную: fail2ban-client -t"
    fi
  fi
}

f2b_install_apply() {
  if is_pkg_installed fail2ban; then
    ok "fail2ban уже установлен: $(fail2ban-client --version 2>/dev/null | head -n 1)"
  else
    apt_install fail2ban python3-systemd || return 1
    ok "fail2ban установлен."
  fi
  if ! service_enabled fail2ban; then systemctl enable fail2ban >/dev/null 2>&1 && ok "Автозапуск включён."; fi
  if ! service_active fail2ban; then
    if systemctl start fail2ban; then ok "fail2ban запущен."; else err "Не удалось запустить fail2ban."; return 1; fi
    sleep 2
  fi
}

f2b_write_jail() { # f2b_write_jail port maxretry findtime bantime ignoreip
  local port=$1 maxretry=$2 findtime=$3 bantime=$4 ignoreip=$5 bak="" out
  if [[ -f $F2B_JAIL ]]; then
    bak="${F2B_JAIL}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$F2B_JAIL" "$bak" && ok "Резервная копия: $bak"
  fi
  cat >"$F2B_JAIL" <<EOF
# Создано ${APP_NAME} $(date '+%F %T')
# Основной файл jail.conf не трогаем — свои настройки держим в jail.d.
[sshd]
enabled  = true
port     = ${port}
backend  = systemd
maxretry = ${maxretry}
findtime = ${findtime}
bantime  = ${bantime}
ignoreip = ${ignoreip}
EOF
  ok "Записан $F2B_JAIL"

  if ! out="$(fail2ban-client -t 2>&1)"; then
    err "Конфигурация не прошла проверку:"; echo "$out"
    if [[ -n $bak ]]; then cp -a "$bak" "$F2B_JAIL" && warn "Восстановлена предыдущая версия."; else rm -f "$F2B_JAIL"; warn "Новый файл удалён."; fi
    return 1
  fi
  ok "Проверка конфигурации (fail2ban-client -t) пройдена."

  if ! systemctl restart fail2ban; then
    err "Не удалось перезапустить fail2ban. Смотри: journalctl -u fail2ban"; return 1
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    fail2ban-client ping >/dev/null 2>&1 && break
    sleep 1
  done
  if fail2ban-client ping >/dev/null 2>&1; then ok "fail2ban перезапущен и отвечает."; else err "fail2ban не отвечает после перезапуска."; return 1; fi
  echo; fail2ban-client status sshd
}

# ══════════════════════════ Docker ══════════════════════════

mod_docker() {
  header "6. Docker"
  if cmd_exists docker; then
    ok "Docker уже установлен: $(docker --version 2>/dev/null)"
    if docker compose version >/dev/null 2>&1; then
      ok "Compose: $(docker compose version 2>/dev/null)"
    else
      warn "Плагин docker compose не найден."
    fi
    echo "  service: $(systemctl is-active docker 2>/dev/null) / $(systemctl is-enabled docker 2>/dev/null)"
    if ! service_active docker; then
      warn "Служба docker не запущена."
      if confirm "Запустить и включить автозапуск?" Y; then
        systemctl enable --now docker && ok "Docker запущен." || err "Не удалось запустить Docker."
      fi
    fi
    pause; return 0
  fi

  info "Docker не найден. Установка — официальным скриптом $DOCKER_URL."
  confirm "Установить Docker?" Y || { info "Отменено."; pause; return 0; }
  if ! docker_install_apply; then pause; return 1; fi
  if confirm "Проверить работу тестовым контейнером hello-world?" Y; then
    if docker run --rm hello-world >/dev/null 2>&1; then ok "Тестовый контейнер отработал."; else err "Тестовый контейнер не запустился."; fi
  fi
  pause
}

mod_docker_logrotate() {
  header "Docker: ротация логов"
  if ! cmd_exists docker; then err "Docker не установлен."; pause; return 1; fi
  if ! cmd_exists python3; then err "Нужен python3 для безопасного изменения daemon.json."; pause; return 1; fi
  hint "Без ротации логи контейнеров растут бесконечно и могут забить диск."
  if [[ -s $DOCKER_DAEMON_JSON ]]; then
    info "Текущий $DOCKER_DAEMON_JSON:"; sed 's/^/    /' "$DOCKER_DAEMON_JSON"; echo
  fi
  ask_re "max-size — размер одного файла лога" "10m" '^[1-9][0-9]*[kmg]$' "Формат: 10m, 100m, 1g."
  local size=$ASK_RESULT
  ask_re "max-file — сколько файлов хранить" "3" '^[1-9][0-9]*$' "Нужно целое число больше нуля."
  local nfiles=$ASK_RESULT
  echo
  warn "Для применения нужен перезапуск Docker (контейнеры с restart: always/unless-stopped поднимутся сами)."
  hint "Настройка действует только на НОВЫЕ контейнеры — после неё пересоздай их (Remnanode → «Перезапустить»)."
  confirm "Применить?" Y || { info "Отменено."; pause; return 0; }
  docker_logrotate_apply "$size" "$nfiles"
  pause
}

mod_docker_cleanup() {
  header "Docker: очистка места"
  if ! cmd_exists docker || ! service_active docker; then err "Docker не установлен или не запущен."; pause; return 1; fi
  docker system df
  echo
  menu_item 1 "Безопасная: остановленные контейнеры, неиспользуемые сети, «висячие» образы, кэш сборки"
  menu_item 2 "Глубокая: плюс ВСЕ образы, которые не используются контейнерами"
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    1)
      warn "Тома (volumes) не затрагиваются."
      if confirm "Выполнить безопасную очистку?" Y; then docker system prune -f; ok "Готово."; fi
      ;;
    2)
      warn "Удалятся все образы, не привязанные к существующим контейнерам (в т.ч. образ остановленной ноды — он скачается заново)."
      if confirm_word "Выполнить глубокую очистку?" "да"; then docker system prune -a -f; ok "Готово."; fi
      ;;
    *) return 0 ;;
  esac
  echo; docker system df
  pause
}

mod_docker_info() {
  header "Docker: контейнеры и ресурсы"
  if ! cmd_exists docker || ! service_active docker; then err "Docker не установлен или не запущен."; pause; return 1; fi
  docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  echo
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null
  echo
  docker system df
  pause
}

menu_docker() {
  while true; do
    header "6. Docker"
    menu_item 1 "Установить / показать статус"
    menu_item 2 "Ротация логов контейнеров"
    menu_item 3 "Очистка места"
    menu_item 4 "Контейнеры и ресурсы"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_docker ;;
      2) mod_docker_logrotate ;;
      3) mod_docker_cleanup ;;
      4) mod_docker_info ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

docker_install_apply() {
  if cmd_exists docker; then
    ok "Docker уже установлен: $(docker --version 2>/dev/null)"
    if ! service_active docker; then
      if systemctl enable --now docker >/dev/null 2>&1; then ok "Docker запущен."; else err "Не удалось запустить Docker."; return 1; fi
    fi
    return 0
  fi
  ensure_curl || return 1
  local tmp rc
  tmp="$(mktemp)"
  step "Скачиваю установочный скрипт"
  if ! download "$DOCKER_URL" "$tmp"; then
    err "Не удалось скачать $DOCKER_URL (проверь интернет, DNS, доступность сайта)."
    rm -f "$tmp"; return 1
  fi
  ok "Скачано."
  step "Устанавливаю Docker (это займёт пару минут)"
  sh "$tmp"; rc=$?
  rm -f "$tmp"
  if (( rc != 0 )); then err "Установка завершилась с ошибкой (код $rc). Смотри вывод выше."; return 1; fi
  systemctl enable --now docker >/dev/null 2>&1
  if cmd_exists docker && service_active docker; then
    ok "Docker установлен: $(docker --version)"
    docker compose version >/dev/null 2>&1 && ok "Compose: $(docker compose version)"
  else
    err "Docker установлен, но служба не запущена. Смотри: journalctl -u docker"; return 1
  fi
}

docker_logrotate_apply() { # docker_logrotate_apply РАЗМЕР КОЛ-ВО_ФАЙЛОВ
  local size=$1 nfiles=$2 bak=""
  if ! cmd_exists docker; then err "Docker не установлен."; return 1; fi
  if ! cmd_exists python3; then err "Нужен python3 для безопасного изменения daemon.json."; return 1; fi
  install -d -m 0755 "$(dirname "$DOCKER_DAEMON_JSON")"
  if [[ -f $DOCKER_DAEMON_JSON ]]; then
    backup_prepare
    bak="$BACKUP_DIR/daemon.json.$(date +%Y%m%d-%H%M%S)"
    cp -a "$DOCKER_DAEMON_JSON" "$bak" && ok "Резервная копия: $bak"
  fi
  if ! python3 - "$DOCKER_DAEMON_JSON" "$size" "$nfiles" <<'PY'
import json, os, sys
path, size, nfiles = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f)
data["log-driver"] = "json-file"
opts = data.get("log-opts", {})
opts.update({"max-size": size, "max-file": nfiles})
data["log-opts"] = opts
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
  then
    err "Не удалось обновить daemon.json (возможно, в нём некорректный JSON). Файл не изменён."
    return 1
  fi
  ok "daemon.json обновлён."
  if systemctl restart docker; then
    ok "Docker перезапущен."
    info "Драйвер логов: $(docker info --format '{{.LoggingDriver}}' 2>/dev/null)"
  else
    err "Docker не запустился с новой конфигурацией — возвращаю прежнюю."
    if [[ -n $bak ]]; then cp -a "$bak" "$DOCKER_DAEMON_JSON"; else rm -f "$DOCKER_DAEMON_JSON"; fi
    systemctl restart docker
    return 1
  fi
}

# ══════════════════════════ Remnanode ══════════════════════════

remna_require_docker() {
  if ! cmd_exists docker || ! docker compose version >/dev/null 2>&1; then
    err "Нужен Docker с плагином compose — сначала пункт 6."
    return 1
  fi
  if ! service_active docker; then
    err "Служба docker не запущена (systemctl start docker)."
    return 1
  fi
}

remna_require_compose() {
  remna_require_docker || return 1
  if [[ ! -s $REMNA_COMPOSE ]]; then
    err "Нет файла $REMNA_COMPOSE — сначала «Первичная настройка»."
    return 1
  fi
}

rcompose() {
  if [[ ${1:-} == up ]]; then rm -f "$REMNA_STOP_FLAG"; fi
  (cd "$REMNA_DIR" && docker compose "$@")
}

remna_edit_compose() {
  cmd_exists nano || apt_install nano || return 1
  touch "$REMNA_COMPOSE"
  nano "$REMNA_COMPOSE"
  if [[ ! -s $REMNA_COMPOSE ]]; then
    warn "Файл пуст — конфиг не вставлен."
    return 1
  fi
}

remna_validate() {
  local out
  if out="$(cd "$REMNA_DIR" && docker compose config -q 2>&1)"; then
    ok "docker-compose.yml корректен."
  else
    err "В docker-compose.yml есть ошибка:"; echo "$out"
    return 1
  fi
}

remna_offer_logs() {
  if confirm "Показать логи? (Ctrl+C — вернуться в меню)" Y; then
    run_interruptible rcompose logs -f -t --tail 100
  fi
}

mod_remna_setup() {
  header "7. Remnanode: первичная настройка"
  remna_require_docker || { pause; return 1; }

  step "Каталог $REMNA_DIR"
  if [[ -d $REMNA_DIR ]]; then
    ok "Каталог уже существует."
  elif mkdir -p "$REMNA_DIR"; then
    ok "Каталог создан."
  else
    err "Не удалось создать каталог."; pause; return 1
  fi

  step "Файл docker-compose.yml"
  if [[ -s $REMNA_COMPOSE ]]; then
    ok "Файл уже существует."
    if confirm "Открыть в nano для правки?" N; then remna_edit_compose; fi
  else
    info "Сейчас откроется nano. Вставь в него конфиг docker-compose из панели управления нодами."
    hint "Сохранить: Ctrl+O, затем Enter.  Выйти: Ctrl+X."
    pause
    remna_edit_compose || { pause; return 1; }
  fi

  remna_validate || { pause; return 1; }

  if confirm "Запустить контейнер сейчас?" Y; then
    step "Запуск"
    if rcompose up -d; then
      ok "Контейнер запущен."
      rcompose ps
      echo; remna_offer_logs
    else
      err "Не удалось запустить. Проверь конфиг и логи."
    fi
  fi
  pause
}

mod_remna_start() {
  header "Remnanode: запуск"
  remna_require_compose || { pause; return 1; }
  if rcompose up -d; then ok "Запущено."; rcompose ps; echo; remna_offer_logs; else err "Не удалось запустить."; fi
  pause
}

mod_remna_stop() {
  header "Remnanode: остановка"
  remna_require_compose || { pause; return 1; }
  warn "Контейнер будет остановлен и удалён (docker compose down). Конфиг и тома сохранятся."
  confirm "Остановить Remnanode?" N || { info "Отменено."; pause; return 0; }
  if rcompose down; then
    ok "Остановлено."
    install -d -m 0755 "$STATE_DIR" 2>/dev/null
    touch "$REMNA_STOP_FLAG"
    hint "Watchdog не будет перезапускать ноду, пока ты сам её не запустишь."
  else
    err "Не удалось остановить."
  fi
  pause
}

mod_remna_restart() {
  header "Remnanode: перезапуск"
  remna_require_compose || { pause; return 1; }
  remna_validate || { pause; return 1; }
  if rcompose down && rcompose up -d; then
    ok "Перезапущено."; rcompose ps; echo; remna_offer_logs
  else
    err "Перезапуск не удался."
  fi
  pause
}

mod_remna_update() {
  header "Remnanode: обновление и перезапуск"
  remna_require_compose || { pause; return 1; }
  remna_validate || { pause; return 1; }
  step "Загружаю свежие образы"
  if ! rcompose pull; then
    err "pull не удался — ноду НЕ останавливаю, она продолжает работать."
    pause; return 1
  fi
  step "Пересоздаю контейнер"
  if rcompose down && rcompose up -d; then
    ok "Обновлено и запущено."
    rcompose ps
    if confirm "Удалить старые неиспользуемые образы (docker image prune)?" Y; then
      docker image prune -f >/dev/null && ok "Старые образы удалены."
    fi
    echo; remna_offer_logs
  else
    err "Не удалось поднять контейнер после обновления."
  fi
  pause
}

mod_remna_logs() {
  header "Remnanode: логи (Ctrl+C — выход)"
  remna_require_compose || { pause; return 1; }
  run_interruptible rcompose logs -f -t --tail 100
  pause
}

mod_remna_status() {
  header "Remnanode: статус"
  remna_require_compose || { pause; return 1; }
  rcompose ps -a
  pause
}

mod_remna_edit() {
  header "Remnanode: правка docker-compose.yml"
  remna_require_docker || { pause; return 1; }
  [[ -d $REMNA_DIR ]] || mkdir -p "$REMNA_DIR"
  remna_edit_compose || { pause; return 1; }
  remna_validate
  hint "Чтобы изменения применились — «Перезапустить»."
  pause
}

menu_remna() {
  while true; do
    header "7. Remnanode"
    menu_item 1 "Первичная настройка (папка, compose-файл, запуск)"
    menu_item 2 "Запустить"
    menu_item 3 "Остановить"
    menu_item 4 "Перезапустить"
    menu_item 5 "Обновить (pull + перезапуск)"
    menu_item 6 "Логи контейнера (docker compose logs)"
    menu_item 7 "Логи xray (xlogs)"
    menu_item 8 "Ошибки xray (xerrors)"
    menu_item 9 "Статус"
    menu_item 10 "Править docker-compose.yml"
    menu_item 11 "Зайти в контейнер (shell)"
    menu_item 12 "Бэкап конфигов"
    menu_item 13 "Восстановить из бэкапа"
    menu_item 14 "Watchdog (контроль и автоперезапуск)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1)  mod_remna_setup ;;
      2)  mod_remna_start ;;
      3)  mod_remna_stop ;;
      4)  mod_remna_restart ;;
      5)  mod_remna_update ;;
      6)  mod_remna_logs ;;
      7)  mod_remna_xlogs ;;
      8)  mod_remna_xerrors ;;
      9)  mod_remna_status ;;
      10) mod_remna_edit ;;
      11) mod_remna_shell ;;
      12) mod_remna_backup ;;
      13) mod_remna_restore ;;
      14) menu_watchdog ;;
      0)  return 0 ;;
      *)  warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

remna_container_running() {
  local names
  names="$(docker ps --format '{{.Names}}' 2>/dev/null)"
  grep -qx "$REMNA_CONTAINER" <<<"$names"
}

remna_exec() { # remna_exec команда… — интерактивно внутри контейнера
  remna_require_docker || return 1
  if ! remna_container_running; then
    err "Контейнер $REMNA_CONTAINER не запущен."
    return 1
  fi
  local rc
  run_interruptible docker exec -it "$REMNA_CONTAINER" "$@"
  rc=$?
  if (( rc == 126 || rc == 127 )); then
    err "Команда «$1» не найдена в контейнере (возможно, другая версия образа)."
  fi
  return 0
}

mod_remna_xlogs() {
  header "Remnanode: логи xray (xlogs)"
  info "Команда: docker exec -it $REMNA_CONTAINER xlogs   (выход — Ctrl+C)"
  remna_exec xlogs
  pause
}

mod_remna_xerrors() {
  header "Remnanode: ошибки xray (xerrors)"
  info "Команда: docker exec -it $REMNA_CONTAINER xerrors   (выход — Ctrl+C)"
  remna_exec xerrors
  pause
}

mod_remna_shell() {
  header "Remnanode: консоль контейнера"
  info "Выход из консоли — exit"
  remna_exec sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'
  pause
}

mod_remna_backup() {
  header "Remnanode: бэкап конфигов"
  if [[ ! -d $REMNA_DIR ]]; then err "Каталога $REMNA_DIR нет — нечего сохранять."; pause; return 1; fi
  if backup_create remnanode "$REMNA_DIR"; then
    ok "Бэкап создан: $BACKUP_RESULT"
    warn "В архиве лежат секреты ноды (ключи из docker-compose.yml). Доступ только у root — не выкладывай файл никуда."
    hint "Хранятся последние 10 копий."
  fi
  pause
}

mod_remna_restore() {
  header "Remnanode: восстановление из бэкапа"
  backup_pick "remnanode-*.tar.gz" || { pause; return 0; }
  local f=$BACKUP_PICKED listing
  listing="$(tar -tzf "$f" 2>/dev/null)"
  if [[ -z $listing ]] || grep -qv '^opt/remnanode' <<<"$listing"; then
    err "Архив повреждён или содержит посторонние пути — восстановление отменено."
    pause; return 1
  fi
  warn "Файлы в $REMNA_DIR будут перезаписаны содержимым архива."
  confirm "Восстановить из $(basename "$f")?" N || { info "Отменено."; pause; return 0; }
  if [[ -d $REMNA_DIR ]]; then
    if backup_create prerestore-remnanode "$REMNA_DIR"; then ok "Текущее состояние сохранено: $BACKUP_RESULT"; fi
  fi
  if tar -xzf "$f" -C /; then
    ok "Файлы восстановлены."
    if cmd_exists docker && [[ -s $REMNA_COMPOSE ]] && remna_validate; then
      if confirm "Перезапустить Remnanode с восстановленным конфигом?" Y; then
        rcompose down && rcompose up -d && ok "Перезапущено." && rcompose ps
      fi
    fi
  else
    err "Не удалось распаковать архив."
  fi
  pause
}

remna_is_running() {
  service_active docker || return 1
  [[ -s $REMNA_COMPOSE ]] || return 1
  local n
  n="$(cd "$REMNA_DIR" && docker compose ps --status running -q 2>/dev/null | wc -l)"
  (( n > 0 ))
}

remna_panel_state() { # печатает «уровень|текст» для панели статусов
  if [[ ! -s $REMNA_COMPOSE ]]; then echo "off|не настроен"; return 0; fi
  if ! cmd_exists docker || ! service_active docker; then
    if [[ -f $REMNA_STOP_FLAG ]]; then echo "warn|остановлен вручную"; else echo "bad|Docker не работает — нода не запущена"; fi
    return 0
  fi
  local n since st txt
  n="$(rcompose ps --status running -q 2>/dev/null | wc -l)"
  if (( n > 0 )); then echo "ok|запущен (контейнеров: $n)"; return 0; fi
  if [[ -f $REMNA_STOP_FLAG ]]; then echo "warn|остановлен вручную"; return 0; fi
  since="$(wd_state_get down_since)"
  st="$(wd_state_get status)"
  txt="упал или не запущен"
  if [[ -n $since ]]; then txt="упал: не работает с $(date -d "@$since" '+%d.%m %H:%M')"; fi
  if [[ $st == failed ]]; then
    txt+=" · авто-перезапуск не помог"
  elif [[ $st == down ]] && wd_autorestart_on; then
    txt+=" · идёт авто-перезапуск"
  fi
  echo "bad|$txt"
}

# ══════════════════════════ Watchdog для Remnanode ══════════════════════════

wd_state_get() { kv_get "$REMNA_STATE" "$1"; }

wd_state_set() { kv_set "$REMNA_STATE" "$1" "$2"; }

wd_state_del() { kv_del "$REMNA_STATE" "$1"; }

wd_autorestart_on() { [[ "$(conf_get WATCHDOG_AUTORESTART)" == 1 ]]; }

wd_interval() {
  local v
  v="$(conf_get WATCHDOG_INTERVAL)"
  printf '%s' "${v:-1}"
}

wd_max_attempts() {
  local v
  v="$(conf_get WATCHDOG_MAX_ATTEMPTS)"
  printf '%s' "${v:-3}"
}

wd_enabled() { systemctl is-enabled --quiet "${APP_NAME}-watchdog.timer" 2>/dev/null; }

watchdog_run() { # вызывается таймером systemd: vpsmenu --watchdog
  [[ -s $REMNA_COMPOSE ]] || return 0
  install -d -m 0755 "$STATE_DIR" 2>/dev/null
  exec 9>"$STATE_DIR/watchdog.lock"
  flock -n 9 || return 0

  local now prev att max
  now="$(date +%s)"
  wd_state_set last_check "$now"

  if [[ -f $REMNA_STOP_FLAG ]]; then
    wd_state_set status stopped
    wd_state_del down_since
    return 0
  fi

  prev="$(wd_state_get status)"
  if remna_is_running; then
    if [[ $prev == down || $prev == failed ]]; then log INFO "Remnanode снова работает."; fi
    wd_state_set status up
    wd_state_del down_since
    wd_state_set attempts 0
    return 0
  fi

  if [[ $prev != down && $prev != failed ]]; then
    wd_state_set status down
    wd_state_set down_since "$now"
    wd_state_set attempts 0
    log WARN "Remnanode не работает (обнаружено watchdog)."
  fi
  wd_autorestart_on || return 0

  att="$(wd_state_get attempts)"
  att=${att:-0}
  max="$(wd_max_attempts)"
  if (( att >= max )); then
    wd_state_set status failed
    return 0
  fi
  att=$((att + 1))
  wd_state_set attempts "$att"
  log WARN "Авто-перезапуск Remnanode: попытка $att из $max."
  service_active docker || systemctl start docker
  (cd "$REMNA_DIR" && docker compose up -d >/dev/null 2>&1)
  sleep 5
  if remna_is_running; then
    wd_state_set status up
    wd_state_del down_since
    wd_state_set attempts 0
    wd_state_set last_restart "$now"
    wd_state_set restarts_total "$(( $(wd_state_get restarts_total || echo 0) + 1 ))"
    log OK "Remnanode перезапущен watchdog."
  else
    log ERROR "Авто-перезапуск Remnanode не помог (попытка $att из $max)."
  fi
}

wd_write_units() {
  if [[ ! -x $INSTALL_PATH ]]; then
    err "Скрипт не установлен в систему ($INSTALL_PATH) — watchdog запускает его по расписанию."
    hint "Сначала: Сам скрипт → «Установить эту копию в систему»."
    return 1
  fi
  cat >"$WD_SERVICE" <<EOF
[Unit]
Description=${APP_NAME}: проверка Remnanode
After=docker.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --watchdog
EOF
  cat >"$WD_TIMER" <<EOF
[Unit]
Description=${APP_NAME}: периодическая проверка Remnanode

[Timer]
OnBootSec=2min
OnUnitActiveSec=$(wd_interval)min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

watchdog_enable() { # watchdog_enable [АВТОПЕРЕЗАПУСК 0|1 | keep]
  wd_write_units || return 1
  if [[ ${1:-keep} != keep ]]; then conf_set WATCHDOG_AUTORESTART "$1"; fi
  if [[ -z "$(conf_get WATCHDOG_AUTORESTART)" ]]; then conf_set WATCHDOG_AUTORESTART 0; fi
  if systemctl enable --now "${APP_NAME}-watchdog.timer" >/dev/null 2>&1; then
    ok "Watchdog включён: проверка каждые $(wd_interval) мин."
    if wd_autorestart_on; then info "Автоперезапуск: включён."; else info "Автоперезапуск: выключен (нода только помечается в меню как упавшая)."; fi
  else
    err "Не удалось включить таймер ${APP_NAME}-watchdog.timer."; return 1
  fi
}

watchdog_disable() {
  systemctl disable --now "${APP_NAME}-watchdog.timer" >/dev/null 2>&1
  rm -f "$WD_SERVICE" "$WD_TIMER"
  systemctl daemon-reload
  ok "Watchdog выключен."
}

mod_wd_status() {
  header "Watchdog Remnanode"
  if wd_enabled; then ok "Контроль: включён (проверка каждые $(wd_interval) мин)"; else info "Контроль: выключен"; fi
  if wd_autorestart_on; then
    ok "Автоперезапуск: включён (до $(wd_max_attempts) попыток подряд)"
  else
    info "Автоперезапуск: выключен (по умолчанию)"
  fi
  echo
  local st since
  st="$(wd_state_get status)"
  since="$(wd_state_get down_since)"
  info "Состояние по данным watchdog: ${st:-нет данных}"
  if [[ -n $since ]]; then info "Не работает с: $(date -d "@$since" '+%d.%m.%Y %H:%M')"; fi
  info "Попыток в текущем сбое: $(wd_state_get attempts)/$(wd_max_attempts) · всего авто-перезапусков: $(wd_state_get restarts_total)"
  if [[ -n "$(wd_state_get last_check)" ]]; then info "Последняя проверка: $(date -d "@$(wd_state_get last_check)" '+%d.%m %H:%M:%S')"; fi
  if [[ -f $REMNA_STOP_FLAG ]]; then warn "Нода остановлена вручную — watchdog её не трогает."; fi
  echo
  hint "Последние события:"
  grep -E 'Remnanode' "$LOG_FILE" 2>/dev/null | tail -n 6 | sed 's/^/    /'
  pause
}

mod_wd_toggle() {
  header "Watchdog: включить / выключить"
  if wd_enabled; then
    info "Сейчас watchdog включён."
    confirm "Выключить?" N && watchdog_disable
  else
    info "Watchdog следит, работает ли нода, и записывает время падения."
    hint "Автоперезапуск настраивается отдельно и по умолчанию выключен."
    if confirm "Включить watchdog?" Y; then
      local ar=keep
      if [[ -z "$(conf_get WATCHDOG_AUTORESTART)" ]]; then
        if confirm "Включить автоперезапуск при падении?" N; then ar=1; else ar=0; fi
      fi
      watchdog_enable "$ar"
    fi
  fi
  pause
}

mod_wd_autorestart() {
  header "Watchdog: автоперезапуск"
  if wd_autorestart_on; then
    info "Сейчас автоперезапуск ВКЛЮЧЁН."
    if confirm "Выключить (нода будет только помечаться упавшей)?" N; then conf_set WATCHDOG_AUTORESTART 0; ok "Автоперезапуск выключен."; fi
  else
    info "Сейчас автоперезапуск ВЫКЛЮЧЕН (по умолчанию)."
    hint "При падении watchdog попробует поднять ноду, не более $(wd_max_attempts) попыток подряд."
    if confirm "Включить автоперезапуск?" N; then conf_set WATCHDOG_AUTORESTART 1; ok "Автоперезапуск включён."; fi
  fi
  if ! wd_enabled; then warn "Сам watchdog выключен — настройка заработает после его включения."; fi
  pause
}

mod_wd_interval() {
  header "Watchdog: интервал проверки"
  ask_re "Как часто проверять, минут (1–60)" "$(wd_interval)" '^([1-9]|[1-5][0-9]|60)$' "Число от 1 до 60."
  conf_set WATCHDOG_INTERVAL "$ASK_RESULT"
  ok "Интервал: $ASK_RESULT мин."
  if wd_enabled; then wd_write_units && systemctl restart "${APP_NAME}-watchdog.timer" && ok "Таймер обновлён."; fi
  pause
}

mod_wd_attempts() {
  header "Watchdog: максимум попыток"
  hint "Сколько раз подряд пытаться поднять упавшую ноду, прежде чем сдаться и пометить «авто-перезапуск не помог»."
  ask_re "Попыток подряд (1–10)" "$(wd_max_attempts)" '^([1-9]|10)$' "Число от 1 до 10."
  conf_set WATCHDOG_MAX_ATTEMPTS "$ASK_RESULT"
  ok "Максимум попыток: $ASK_RESULT"
  pause
}

mod_wd_log() {
  header "Watchdog: журнал событий"
  grep -E 'Remnanode' "$LOG_FILE" 2>/dev/null | tail -n 100 | show_paged
  pause
}

menu_watchdog() {
  while true; do
    header "Remnanode: watchdog"
    if wd_enabled; then info "Контроль включён · автоперезапуск: $(wd_autorestart_on && echo включён || echo выключен)"; else info "Контроль выключен"; fi
    echo
    menu_item 1 "Статус и события"
    menu_item 2 "Включить / выключить watchdog"
    menu_item 3 "Автоперезапуск: включить / выключить"
    menu_item 4 "Интервал проверки"
    menu_item 5 "Максимум попыток подряд"
    menu_item 6 "Журнал событий"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_wd_status ;;
      2) mod_wd_toggle ;;
      3) mod_wd_autorestart ;;
      4) mod_wd_interval ;;
      5) mod_wd_attempts ;;
      6) mod_wd_log ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

# ══════════════════════════ WARP Native ══════════════════════════

warp_detected() {
  [[ -f /etc/wireguard/warp.conf ]] ||
    ip link show warp >/dev/null 2>&1 ||
    systemctl is-enabled --quiet wg-quick@warp 2>/dev/null
}

mod_warp() {
  header "8. WARP Native"
  if warp_detected; then
    ok "Похоже, WARP Native уже установлен (найден интерфейс или конфиг warp)."
    hint "Повторный запуск установщика может изменить текущие настройки. Если нужно управление/удаление — у установщика есть своё меню."
    confirm "Всё равно запустить установщик?" N || { info "Отменено."; pause; return 0; }
  else
    info "WARP Native не обнаружен. Установщик: $WARP_URL"
    confirm "Установить?" Y || { info "Отменено."; pause; return 0; }
  fi

  ensure_curl || { pause; return 1; }

  local tmp rc
  tmp="$(mktemp)"
  step "Скачиваю установщик"
  if ! download "$WARP_URL" "$tmp"; then
    err "Не удалось скачать установщик (проверь интернет, DNS, доступность GitHub)."
    rm -f "$tmp"; pause; return 1
  fi
  ok "Скачано."

  warn "Это сторонний скрипт, он будет выполнен от root."
  if confirm "Просмотреть его перед запуском?" N; then
    show_paged <"$tmp"
    confirm "Запускать?" Y || { info "Отменено."; rm -f "$tmp"; pause; return 0; }
  fi

  step "Запускаю установщик (дальше работает его собственное меню)"
  bash "$tmp"; rc=$?
  rm -f "$tmp"
  if (( rc == 0 )); then ok "Установщик завершился без ошибок."; else err "Установщик завершился с кодом $rc."; fi
  pause
}

# ══════════════════════════ Оптимизация и обслуживание ══════════════════════════

mod_sys_update() {
  header "Обновление системы"
  info "Будет выполнено: apt update → apt upgrade → apt autoremove."
  hint "Твои изменённые конфиги (например sshd_config) при обновлении сохраняются."
  confirm "Продолжить?" Y || { info "Отменено."; pause; return 0; }
  if ! sys_update_run; then pause; return 1; fi
  reboot_prompt
  pause
}

mod_timezone_ntp() {
  header "Часовой пояс и NTP"
  timedatectl 2>/dev/null | sed 's/^/  /'
  echo
  local cur
  cur="$(timedatectl show -p Timezone --value 2>/dev/null)"
  ask "Часовой пояс (например Europe/Moscow или UTC)" "${cur:-UTC}"
  tz_ntp_apply "$ASK_RESULT"
  pause
}

mod_bbr() {
  header "Ускорение сети: BBR"
  local cc qd
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  info "Сейчас: congestion_control=${cc:-?}, qdisc=${qd:-?} · ядро $(uname -r)"
  if [[ $cc == bbr ]]; then
    ok "BBR уже включён."
    [[ -f $BBR_SYSCTL ]] || hint "Он включён не этим скриптом (файла $BBR_SYSCTL нет)."
    pause; return 0
  fi
  confirm "Включить BBR (+ fq) и сохранить после перезагрузки?" Y || { info "Отменено."; pause; return 0; }
  bbr_apply
  pause
}

swap_remove() {
  swapoff "$SWAPFILE" 2>/dev/null
  sed -i "\|^${SWAPFILE}[[:space:]]|d" /etc/fstab
  rm -f "$SWAPFILE" "$SWAP_SYSCTL"
}

mod_swap() {
  header "Swap (файл подкачки)"
  local virt active
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ $virt == openvz || $virt == lxc* ]]; then
    warn "Виртуализация: $virt — swap в таком контейнере обычно недоступен."
  fi
  info "Память: $(free -h | awk '/^Mem:/ {print $2}'), swap: $(free -h | awk '/^Swap:/ {print $2}')"
  active="$(swapon --show --noheadings 2>/dev/null)"

  if [[ -n $active ]]; then
    printf '%s\n' "$active" | sed 's/^/    /'
    echo
    if [[ $active == *"$SWAPFILE"* ]]; then
      ok "Swap уже настроен ($SWAPFILE)."
      if confirm "Удалить этот swap?" N; then
        swap_remove && ok "Swap удалён."
      fi
    else
      info "Swap уже есть (создан не этим скриптом) — не трогаю."
    fi
    pause; return 0
  fi

  if [[ -e $SWAPFILE ]]; then
    warn "Файл $SWAPFILE уже существует, но не подключён."
    confirm "Удалить его и создать заново?" N || { info "Отменено."; pause; return 0; }
    swap_remove
  fi

  local mem_mb def size
  mem_mb="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
  if (( mem_mb <= 8192 )); then def=2G; else def=1G; fi
  ask_re "Размер swap (например 512M, 1G, 2G)" "$def" '^[1-9][0-9]*[MG]$' "Формат: 512M, 1G, 2G."
  size=$ASK_RESULT
  hint "swappiness: чем меньше, тем реже система уходит в swap. Для VPS обычно 10."
  ask_re "vm.swappiness (0–100)" "10" '^([0-9]|[1-9][0-9]|100)$' "Число от 0 до 100."
  local swappiness=$ASK_RESULT
  confirm "Создать swap $size в $SWAPFILE?" Y || { info "Отменено."; pause; return 0; }
  if swap_create_apply "$size" "$swappiness"; then echo; free -h; fi
  pause
}

mod_autoupdates() {
  header "Автообновления безопасности"
  hint "Некоторые обновления (ядро) вступают в силу только после перезагрузки."
  hint "Автоперезагрузка кратко прервёт ноду, но контейнеры с restart: always поднимутся сами."
  local reboot=0
  if confirm "Разрешить автоперезагрузку ночью (04:00), когда она нужна?" N; then reboot=1; fi
  echo
  autoupdates_apply "$reboot" || { pause; return 1; }

  step "Состояние"
  echo "  служба:  $(systemctl is-active unattended-upgrades 2>/dev/null) / $(systemctl is-enabled unattended-upgrades 2>/dev/null)"
  if [[ -f /var/log/unattended-upgrades/unattended-upgrades.log ]]; then
    echo "  последние записи лога:"
    tail -n 5 /var/log/unattended-upgrades/unattended-upgrades.log | sed 's/^/    /'
  fi
  pause
}

mod_conf_backup() {
  header "Бэкап конфигов сервера"
  info "Сохраняются (если существуют): SSH, fail2ban, UFW, nftables, Docker daemon.json, Remnanode, настройки скрипта."
  if backup_create configs \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/fail2ban/jail.d /etc/ufw /etc/nftables.conf \
      /etc/docker/daemon.json "$REMNA_DIR" "$CONF_FILE" /etc/sysctl.d/99-vpsmenu-bbr.conf /etc/sysctl.d/99-vpsmenu-swap.conf; then
    ok "Бэкап создан: $BACKUP_RESULT"
    warn "В архиве могут быть ключи и секреты. Доступ только у root — не выкладывай файл никуда."
    hint "Хранятся последние 10 копий. Восстановление вручную: tar -xzf <файл> -C /"
  fi
  pause
}

mod_backup_list() {
  header "Список бэкапов"
  local f found=0
  while IFS= read -r f; do
    found=1
    printf '  %s  (%s)\n' "$f" "$(du -h "$f" | cut -f1)"
  done < <(backup_files '*')
  (( found )) || info "Бэкапов пока нет."
  echo
  hint "Каталог $BACKUP_DIR доступен только root."
  pause
}

menu_maint() {
  while true; do
    header "9. Оптимизация и обслуживание"
    menu_item 1 "Обновить систему (apt upgrade)"
    menu_item 2 "Часовой пояс и NTP"
    menu_item 3 "BBR (ускорение сети)"
    menu_item 4 "Swap"
    menu_item 5 "Автообновления безопасности"
    menu_item 6 "Бэкап конфигов сервера"
    menu_item 7 "Список бэкапов"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_sys_update ;;
      2) mod_timezone_ntp ;;
      3) mod_bbr ;;
      4) mod_swap ;;
      5) mod_autoupdates ;;
      6) mod_conf_backup ;;
      7) mod_backup_list ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

sys_update_run() {
  step "apt update"
  if ! apt_run update -q; then err "apt update завершился с ошибкой."; return 1; fi
  APT_UPDATED=1
  step "apt upgrade"
  if ! apt_run -o Dpkg::Options::=--force-confold upgrade -y -q; then
    err "apt upgrade завершился с ошибкой."; return 1
  fi
  step "apt autoremove"
  apt_run autoremove -y -q
  ok "Система обновлена."
}

tz_ntp_apply() { # tz_ntp_apply ЧАСОВОЙ_ПОЯС (пусто — не менять)
  local tz=${1:-} tzs
  if [[ -n $tz ]]; then
    tzs="$(timedatectl list-timezones 2>/dev/null)"
    if ! grep -qxF "$tz" <<<"$tzs"; then
      err "Неизвестный часовой пояс: $tz (список: timedatectl list-timezones)"; return 1
    fi
    if timedatectl set-timezone "$tz"; then ok "Часовой пояс: $tz"; else err "Не удалось задать часовой пояс."; return 1; fi
  fi

  step "Синхронизация времени (NTP)"
  if is_pkg_installed chrony; then
    info "Используется chrony — синхронизация идёт через него."
    service_active chrony || systemctl enable --now chrony >/dev/null 2>&1
  elif timedatectl set-ntp true 2>/dev/null; then
    ok "NTP включён."
  else
    warn "timedatectl не смог включить NTP — ставлю systemd-timesyncd."
    if apt_install systemd-timesyncd && systemctl enable --now systemd-timesyncd >/dev/null 2>&1 && timedatectl set-ntp true; then
      ok "systemd-timesyncd установлен, NTP включён."
    else
      err "Не удалось настроить NTP."; return 1
    fi
  fi
  sleep 2
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then
    ok "Время синхронизировано."
  else
    warn "Синхронизация пока не подтверждена (может занять до минуты). Проверь позже: timedatectl"
  fi
}

bbr_apply() {
  local virt cc avail
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ $virt == openvz || $virt == lxc* ]]; then
    warn "Виртуализация: $virt — менять сетевые параметры ядра в таком контейнере обычно нельзя."
  fi
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if [[ $cc == bbr ]]; then ok "BBR уже включён."; return 0; fi
  modprobe tcp_bbr 2>/dev/null
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
  if [[ " $avail " != *" bbr "* ]]; then err "Ядро не поддерживает BBR (доступно: ${avail:-?})."; return 1; fi
  printf '# Создано %s\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' "$APP_NAME" >"$BBR_SYSCTL"
  echo tcp_bbr >"/etc/modules-load.d/${APP_NAME}-bbr.conf"
  sysctl -p "$BBR_SYSCTL" >/dev/null 2>&1
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]]; then
    ok "BBR включён: $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
  else
    err "Не удалось применить BBR — откатываю."
    rm -f "$BBR_SYSCTL" "/etc/modules-load.d/${APP_NAME}-bbr.conf"
    return 1
  fi
}

swap_create_apply() { # swap_create_apply РАЗМЕР(512M|1G) SWAPPINESS
  local size=$1 swappiness=${2:-10} virt size_mb avail_mb fstype active
  if [[ ! $size =~ ^[1-9][0-9]*[MG]$ ]]; then err "Некорректный размер swap: $size"; return 1; fi
  active="$(swapon --show --noheadings 2>/dev/null)"
  if [[ -n $active ]]; then info "Swap уже есть — новый не создаю."; return 0; fi
  if [[ -e $SWAPFILE ]]; then err "$SWAPFILE уже существует и не подключён — удали его (Оптимизация → Swap)."; return 1; fi
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ $virt == openvz || $virt == lxc* ]]; then
    warn "Виртуализация: $virt — swap в таком контейнере обычно недоступен."
  fi
  if [[ $size == *G ]]; then size_mb=$(( ${size%G} * 1024 )); else size_mb=${size%M}; fi
  avail_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  if (( size_mb + 1024 > avail_mb )); then
    err "Мало места: свободно ${avail_mb}M, нужно ${size_mb}M плюс запас 1G."; return 1
  fi
  fstype="$(findmnt -no FSTYPE / 2>/dev/null)"
  if [[ $fstype == btrfs || $fstype == zfs ]]; then
    err "На $fstype swap-файл требует особой настройки — скрипт этого не делает."; return 1
  fi

  step "Создаю $SWAPFILE"
  if ! fallocate -l "${size_mb}M" "$SWAPFILE" 2>/dev/null; then
    info "fallocate недоступен — использую dd (дольше)."
    if ! dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size_mb" status=none; then
      err "Не удалось создать файл."; rm -f "$SWAPFILE"; return 1
    fi
  fi
  chmod 600 "$SWAPFILE"
  if ! mkswap "$SWAPFILE" >/dev/null; then err "mkswap не удался."; rm -f "$SWAPFILE"; return 1; fi
  if ! swapon "$SWAPFILE"; then
    err "swapon не удался (возможно, виртуализация запрещает swap)."
    rm -f "$SWAPFILE"; return 1
  fi
  ok "Swap подключён: $size"

  if ! grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab; then
    backup_prepare
    cp -a /etc/fstab "$BACKUP_DIR/fstab.$(date +%Y%m%d-%H%M%S)"
    printf '%s none swap sw 0 0\n' "$SWAPFILE" >>/etc/fstab
    ok "Запись добавлена в /etc/fstab (копия fstab в $BACKUP_DIR)."
  fi
  printf '# Создано %s\nvm.swappiness = %s\n' "$APP_NAME" "$swappiness" >"$SWAP_SYSCTL"
  sysctl -p "$SWAP_SYSCTL" >/dev/null 2>&1 && ok "vm.swappiness = $swappiness"
  return 0
}

autoupdates_apply() { # autoupdates_apply ПЕРЕЗАГРУЗКА(0|1)
  local reboot=${1:-0} f=/etc/apt/apt.conf.d/20auto-upgrades rf=/etc/apt/apt.conf.d/52vpsmenu-unattended.conf
  if is_pkg_installed unattended-upgrades; then
    ok "unattended-upgrades уже установлен."
  else
    apt_install unattended-upgrades || return 1
  fi
  if [[ -f $f ]] && grep -q 'Unattended-Upgrade "1"' "$f"; then
    ok "Автообновления уже включены."
  else
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$f"
    ok "Автообновления включены (ставятся только обновления безопасности Ubuntu)."
  fi
  systemctl enable --now unattended-upgrades >/dev/null 2>&1
  if [[ $reboot == 1 ]]; then
    printf 'Unattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-Time "04:00";\n' >"$rf"
    ok "Автоперезагрузка включена (04:00)."
  else
    rm -f "$rf"
    info "Автоперезагрузка выключена — перезагружай вручную, когда пишет «Требуется перезагрузка»."
  fi
}

# ══════════════════════════ Диагностика сети и Speedtest ══════════════════════════

speedtest_bin() { # печатает имя команды, если speedtest-cli (или официальный speedtest) установлен
  if cmd_exists speedtest-cli; then echo speedtest-cli
  elif cmd_exists speedtest; then echo speedtest
  fi
}

speedtest_install() {
  local b
  b="$(speedtest_bin)"
  if [[ -n $b ]]; then
    ok "Speedtest уже установлен: $(command -v "$b") ($("$b" --version 2>&1 | head -n 1))"
    return 0
  fi
  info "speedtest-cli не найден — устанавливаю из репозитория Ubuntu."
  apt_install speedtest-cli || return 1
  if cmd_exists speedtest-cli; then
    ok "Установлен: $(speedtest-cli --version 2>&1 | head -n 1)"
  else
    err "Пакет установился, но команды speedtest-cli нет."; return 1
  fi
}

mod_speedtest_status() {
  header "Speedtest: установка и статус"
  local b
  b="$(speedtest_bin)"
  if [[ -n $b ]]; then
    ok "Установлен: $(command -v "$b")"
    info "Версия: $("$b" --version 2>&1 | head -n 1)"
    if [[ $b == speedtest ]]; then hint "Это официальный клиент Ookla (команда speedtest), не python-версия speedtest-cli."; fi
  else
    warn "Speedtest не установлен."
    if confirm "Установить speedtest-cli?" Y; then speedtest_install; fi
  fi
  pause
}

mod_speedtest_run() {
  header "Тест скорости"
  local b rc
  b="$(speedtest_bin)"
  if [[ -z $b ]]; then
    warn "Speedtest не установлен."
    confirm "Установить speedtest-cli?" Y || { pause; return 0; }
    speedtest_install || { pause; return 1; }
    b="$(speedtest_bin)"
  fi
  info "Запускаю тест (до 2,5 минут, Ctrl+C — прервать)…"
  if [[ $b == speedtest-cli ]]; then
    run_interruptible timeout 150 speedtest-cli --simple
    rc=$?
    if (( rc != 0 && rc != 130 )); then
      warn "Первая попытка не удалась — пробую через HTTPS (--secure)."
      run_interruptible timeout 150 speedtest-cli --secure --simple
    fi
  else
    run_interruptible timeout 150 speedtest --accept-license --accept-gdpr
  fi
  pause
}

mod_net_ping() {
  header "Задержка до серверов"
  if ! cmd_exists ping; then apt_install iputils-ping || { pause; return 1; }; fi
  local t out loss avg
  printf '  %-14s %-14s %s\n' "Host" "Loss" "Avg"
  for t in 1.1.1.1 8.8.8.8 ya.ru github.com; do
    out="$(ping -c 4 -W 2 -q "$t" 2>&1)"
    loss="$(grep -oE '[0-9]+(\.[0-9]+)?% packet loss' <<<"$out" | head -n 1 | awk '{print $1}')"
    avg="$(awk -F'/' '/^rtt|^round-trip/ {print $5}' <<<"$out")"
    if [[ -z $loss ]]; then
      printf '  %-14s %s\n' "$t" "${C_RED}недоступен или не резолвится${C_RESET}"
    elif [[ $loss == 100% ]]; then
      printf '  %-14s %s\n' "$t" "${C_RED}100% потерь (ICMP может быть закрыт)${C_RESET}"
    else
      printf '  %-14s %-14s %s\n' "$t" "$loss" "${avg:-?} мс"
    fi
  done
  pause
}

mod_net_reach() {
  header "Доступность нужных ресурсов"
  ensure_curl || { pause; return 1; }
  local entry label url code t res
  for entry in \
    "GitHub|https://github.com" \
    "GitHub raw|https://raw.githubusercontent.com" \
    "Docker Hub|https://registry-1.docker.io/v2/" \
    "get.docker.com|https://get.docker.com" \
    "GHCR|https://ghcr.io/v2/" \
    "Ubuntu apt|http://archive.ubuntu.com"; do
    label=${entry%%|*}
    url=${entry##*|}
    res="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)"
    code=${res%% *}
    t=${res##* }
    t="${t%"${t#*.??}"}"
    case $code in
      2??|3??|401|403) printf '  %s %-15s HTTP %s · %s с\n' "${C_GREEN}●${C_RESET}" "$label" "$code" "$t" ;;
      *)               printf '  %s %-15s %s\n' "${C_RED}●${C_RESET}" "$label" "недоступен (код ${code:-000})" ;;
    esac
  done
  echo
  hint "401/403 у Docker Hub и GHCR — нормально: сервис отвечает, просто просит авторизацию."
  pause
}

mod_net_ip() {
  header "Внешний IP"
  ensure_curl || { pause; return 1; }
  local ip4 ip6 u
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip4="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null)" && [[ -n $ip4 ]] && break
    ip4=""
  done
  for u in https://api64.ipify.org https://ifconfig.co; do
    ip6="$(curl -6 -fsS --max-time 6 "$u" 2>/dev/null)" && [[ -n $ip6 ]] && break
    ip6=""
  done
  printf '  %-6s %s\n' "IPv4" "${ip4:-не определён}"
  printf '  %-6s %s\n' "IPv6" "${ip6:-нет или не определён}"
  info "Локальные адреса: $(hostname -I 2>/dev/null)"
  pause
}

mod_net_ports() {
  header "Какие порты слушает сервер"
  hint "Это то, что слушает сам сервер. Что реально доступно снаружи, решает ещё и файрвол (UFW, панель хостера)."
  echo
  ss -tulpn | show_paged
  pause
}

menu_net() {
  while true; do
    header "14. Диагностика сети"
    local b
    b="$(speedtest_bin)"
    if [[ -n $b ]]; then info "Speedtest: установлен ($b)"; else info "Speedtest: не установлен"; fi
    echo
    menu_item 1 "Тест скорости (speedtest-cli)"
    menu_item 2 "Установка / статус speedtest-cli"
    menu_item 3 "Задержка (ping до 1.1.1.1, 8.8.8.8, ya.ru, github.com)"
    menu_item 4 "Доступность ресурсов (GitHub, Docker Hub, apt…)"
    menu_item 5 "Внешний IP"
    menu_item 6 "Какие порты слушает сервер"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_speedtest_run ;;
      2) mod_speedtest_status ;;
      3) mod_net_ping ;;
      4) mod_net_reach ;;
      5) mod_net_ip ;;
      6) mod_net_ports ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

# ══════════════════════════ Профили серверов ══════════════════════════

PROFILE_KEYS=(SYSTEM_UPDATE TIMEZONE NEW_USER COPY_ROOT_KEYS USER_SSH_KEY SSH_DISABLE_ROOT SSH_KEYS_ONLY
  UFW UFW_EXTRA_PORTS NFTABLES FAIL2BAN F2B_MAXRETRY F2B_FINDTIME F2B_BANTIME F2B_IGNOREIP
  DOCKER DOCKER_LOG_SIZE DOCKER_LOG_FILES BBR SWAP_SIZE SWAPPINESS AUTOUPDATES AUTOREBOOT
  SPEEDTEST REMNANODE WATCHDOG WATCHDOG_AUTORESTART WARP)

declare -A PROFILE_DEF=(
  [SYSTEM_UPDATE]=0 [TIMEZONE]="" [NEW_USER]="" [COPY_ROOT_KEYS]=1 [USER_SSH_KEY]=""
  [SSH_DISABLE_ROOT]=0 [SSH_KEYS_ONLY]=0 [UFW]=0 [UFW_EXTRA_PORTS]="" [NFTABLES]=0
  [FAIL2BAN]=0 [F2B_MAXRETRY]=3 [F2B_FINDTIME]=10m [F2B_BANTIME]=2d [F2B_IGNOREIP]="127.0.0.1/8 ::1"
  [DOCKER]=0 [DOCKER_LOG_SIZE]="" [DOCKER_LOG_FILES]=3 [BBR]=0 [SWAP_SIZE]="" [SWAPPINESS]=10
  [AUTOUPDATES]=0 [AUTOREBOOT]=0 [SPEEDTEST]=0 [REMNANODE]=0 [WATCHDOG]=0 [WATCHDOG_AUTORESTART]=0 [WARP]=0
)

declare -A P=()
declare -a PLAN_IDS=() PLAN_TITLES=()
STEP_PAUSED=0

profile_reset() {
  local k
  P=()
  for k in "${PROFILE_KEYS[@]}"; do P[$k]="${PROFILE_DEF[$k]}"; done
}

profile_value_ok() { # profile_value_ok КЛЮЧ ЗНАЧЕНИЕ
  local k=$1 v=$2 re
  case $k in
    SYSTEM_UPDATE|COPY_ROOT_KEYS|SSH_DISABLE_ROOT|SSH_KEYS_ONLY|UFW|NFTABLES|FAIL2BAN|DOCKER|BBR|AUTOUPDATES|AUTOREBOOT|SPEEDTEST|REMNANODE|WATCHDOG|WATCHDOG_AUTORESTART|WARP)
      re='^[01]$' ;;
    TIMEZONE) re='^[A-Za-z0-9_+/-]*$' ;;
    NEW_USER)
      if [[ -z $v || $v == ASK ]]; then return 0; fi
      re=$USERNAME_RE ;;
    USER_SSH_KEY)
      if [[ -z $v || $v == ASK ]]; then return 0; fi
      re='^(ssh-|ecdsa-|sk-)[^[:space:]]+ [A-Za-z0-9+/=]+( .*)?$' ;;
    UFW_EXTRA_PORTS) re='^$|^[0-9]{1,5}(/(tcp|udp))?( [0-9]{1,5}(/(tcp|udp))?)*$' ;;
    F2B_MAXRETRY|DOCKER_LOG_FILES) re='^[1-9][0-9]*$' ;;
    F2B_FINDTIME) re='^[0-9]+(s|m|h|d|w|mo|y)?$' ;;
    F2B_BANTIME) re='^(-1|[0-9]+(s|m|h|d|w|mo|y)?)$' ;;
    F2B_IGNOREIP) re='^[0-9a-fA-F:./ ]+$' ;;
    DOCKER_LOG_SIZE) re='^([1-9][0-9]*[kmg])?$' ;;
    SWAP_SIZE) re='^([1-9][0-9]*[MG])?$' ;;
    SWAPPINESS) re='^([0-9]|[1-9][0-9]|100)$' ;;
    *) return 1 ;;
  esac
  [[ $v =~ $re ]]
}

profile_parse() { # читает КЛЮЧ=значение со stdin в массив P; ничего не исполняет
  local line k v bad=0
  profile_reset
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    if [[ $line =~ ^[[:space:]]*(#|$) ]]; then continue; fi
    if [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
      k=${BASH_REMATCH[1]}
      v="$(trim "${BASH_REMATCH[2]}")"
      v="${v#\"}"; v="${v%\"}"
      if profile_value_ok "$k" "$v"; then
        P[$k]=$v
      else
        err "Профиль: недопустимый параметр или значение: $k=$v"; bad=1
      fi
    else
      err "Профиль: не понимаю строку: $line"; bad=1
    fi
  done
  return $bad
}

profile_preset_title() {
  case $1 in
    node-full) echo "Нода: полный стек (защита, Docker, Remnanode, WARP, оптимизация)" ;;
    minimal)   echo "Минимальная защита (пользователь, запрет root, UFW, Fail2ban)" ;;
    hardened)  echo "Усиленная защита (минимум + вход по ключам, автообновления, BBR, swap)" ;;
  esac
}

profile_preset_text() {
  case $1 in
    node-full) cat <<'EOF'
SYSTEM_UPDATE=1
TIMEZONE=UTC
NEW_USER=ASK
COPY_ROOT_KEYS=1
USER_SSH_KEY=ASK
SSH_DISABLE_ROOT=1
SSH_KEYS_ONLY=0
UFW=1
UFW_EXTRA_PORTS=
NFTABLES=1
FAIL2BAN=1
F2B_MAXRETRY=3
F2B_FINDTIME=10m
F2B_BANTIME=2d
F2B_IGNOREIP=127.0.0.1/8 ::1
DOCKER=1
DOCKER_LOG_SIZE=10m
DOCKER_LOG_FILES=3
BBR=1
SWAP_SIZE=2G
SWAPPINESS=10
AUTOUPDATES=1
AUTOREBOOT=0
SPEEDTEST=0
REMNANODE=1
WATCHDOG=1
WATCHDOG_AUTORESTART=0
WARP=1
EOF
      ;;
    minimal) cat <<'EOF'
SYSTEM_UPDATE=1
NEW_USER=ASK
COPY_ROOT_KEYS=1
SSH_DISABLE_ROOT=1
UFW=1
FAIL2BAN=1
F2B_MAXRETRY=3
F2B_FINDTIME=10m
F2B_BANTIME=2d
EOF
      ;;
    hardened) cat <<'EOF'
SYSTEM_UPDATE=1
TIMEZONE=UTC
NEW_USER=ASK
COPY_ROOT_KEYS=1
USER_SSH_KEY=ASK
SSH_DISABLE_ROOT=1
SSH_KEYS_ONLY=1
UFW=1
FAIL2BAN=1
F2B_MAXRETRY=3
F2B_FINDTIME=10m
F2B_BANTIME=7d
AUTOUPDATES=1
AUTOREBOOT=0
BBR=1
SWAP_SIZE=2G
SWAPPINESS=10
EOF
      ;;
    *) return 1 ;;
  esac
}

profile_load_preset() { profile_parse < <(profile_preset_text "$1"); }

profile_add() { PLAN_IDS+=("$1"); PLAN_TITLES+=("$2"); }

profile_plan() {
  PLAN_IDS=(); PLAN_TITLES=()
  if [[ ${P[SYSTEM_UPDATE]} == 1 ]]; then profile_add update "Обновление системы"; fi
  if [[ -n ${P[TIMEZONE]} ]]; then profile_add tz "Часовой пояс ${P[TIMEZONE]} и NTP"; fi
  if [[ -n ${P[NEW_USER]} ]]; then
    local who=${P[NEW_USER]}
    if [[ $who == ASK ]]; then who="имя спросим при применении"; fi
    profile_add user "Пользователь с sudo ($who)"
  fi
  if [[ ${P[SSH_DISABLE_ROOT]} == 1 ]]; then profile_add root "SSH: запрет входа под root"; fi
  if [[ ${P[SSH_KEYS_ONLY]} == 1 ]]; then profile_add keys "SSH: вход только по ключам"; fi
  if [[ ${P[UFW]} == 1 ]]; then
    local ut="UFW (порт SSH определится сам"
    if [[ -n ${P[UFW_EXTRA_PORTS]} ]]; then ut+="; ещё: ${P[UFW_EXTRA_PORTS]}"; fi
    profile_add ufw "$ut)"
  fi
  if [[ ${P[NFTABLES]} == 1 ]]; then profile_add nft "nftables"; fi
  if [[ ${P[FAIL2BAN]} == 1 ]]; then
    profile_add f2b "Fail2ban (maxretry ${P[F2B_MAXRETRY]}, findtime ${P[F2B_FINDTIME]}, bantime ${P[F2B_BANTIME]})"
  fi
  if [[ ${P[DOCKER]} == 1 ]]; then
    local dt="Docker"
    if [[ -n ${P[DOCKER_LOG_SIZE]} ]]; then dt+=" + ротация логов ${P[DOCKER_LOG_SIZE]}×${P[DOCKER_LOG_FILES]}"; fi
    profile_add docker "$dt"
  fi
  if [[ ${P[BBR]} == 1 ]]; then profile_add bbr "BBR"; fi
  if [[ -n ${P[SWAP_SIZE]} ]]; then profile_add swap "Swap ${P[SWAP_SIZE]} (swappiness ${P[SWAPPINESS]})"; fi
  if [[ ${P[AUTOUPDATES]} == 1 ]]; then
    local at="Автообновления безопасности"
    if [[ ${P[AUTOREBOOT]} == 1 ]]; then at+=" + автоперезагрузка"; fi
    profile_add autoupd "$at"
  fi
  if [[ ${P[SPEEDTEST]} == 1 ]]; then profile_add speedtest "Speedtest-cli"; fi
  if [[ ${P[REMNANODE]} == 1 ]]; then profile_add remna "Remnanode (папка, compose-файл, запуск)"; fi
  if [[ ${P[WATCHDOG]} == 1 ]]; then
    local wt="Watchdog Remnanode"
    if [[ ${P[WATCHDOG_AUTORESTART]} == 1 ]]; then wt+=" с автоперезапуском"; else wt+=" (автоперезапуск выключен)"; fi
    profile_add watchdog "$wt"
  fi
  if [[ ${P[WARP]} == 1 ]]; then profile_add warp "WARP Native"; fi
  return 0
}

profile_step_user() {
  local name=${P[NEW_USER]} key=${P[USER_SSH_KEY]}
  if [[ $name == ASK ]]; then
    ask_re "Имя нового пользователя" "" "$USERNAME_RE" "Допустимо: a-z, 0-9, _ и -, начинать с буквы, до 32 символов."
    name=$ASK_RESULT
  fi
  user_setup "$name" "${P[COPY_ROOT_KEYS]}" || return 1
  if [[ $key == ASK ]]; then
    echo
    ask "Публичный SSH-ключ для '$name' одной строкой (Enter — пропустить)"
    key=$ASK_RESULT
  fi
  if [[ -n $key ]]; then ssh_addkey_apply "$name" "$key" || return 1; fi
  return 0
}

profile_step_ufw() {
  if ! cmd_exists ufw; then apt_install ufw || return 1; fi
  ufw_apply "$(detect_ssh_ports)" "${P[UFW_EXTRA_PORTS]}"
}

profile_step_f2b() {
  f2b_install_apply || return 1
  f2b_write_jail "$(detect_ssh_ports | tr ' ' ',')" "${P[F2B_MAXRETRY]}" "${P[F2B_FINDTIME]}" "${P[F2B_BANTIME]}" "${P[F2B_IGNOREIP]}"
}

profile_step_docker() {
  docker_install_apply || return 1
  if [[ -n ${P[DOCKER_LOG_SIZE]} ]]; then
    step "Ротация логов Docker"
    docker_logrotate_apply "${P[DOCKER_LOG_SIZE]}" "${P[DOCKER_LOG_FILES]}" || return 1
  fi
  return 0
}

profile_step() { # profile_step ШАГ; пункты с собственными подтверждениями сами делают pause
  STEP_PAUSED=0
  case $1 in
    update)    sys_update_run ;;
    tz)        tz_ntp_apply "${P[TIMEZONE]}" ;;
    user)      profile_step_user ;;
    root)      mod_ssh_disable_root; STEP_PAUSED=1 ;;
    keys)      mod_ssh_keys_only; STEP_PAUSED=1 ;;
    ufw)       profile_step_ufw ;;
    nft)       mod_nft_setup; STEP_PAUSED=1 ;;
    f2b)       profile_step_f2b ;;
    docker)    profile_step_docker ;;
    bbr)       bbr_apply ;;
    swap)      swap_create_apply "${P[SWAP_SIZE]}" "${P[SWAPPINESS]}" ;;
    autoupd)   autoupdates_apply "${P[AUTOREBOOT]}" ;;
    speedtest) speedtest_install ;;
    remna)     mod_remna_setup; STEP_PAUSED=1 ;;
    watchdog)  watchdog_enable "${P[WATCHDOG_AUTORESTART]}" ;;
    warp)      mod_warp; STEP_PAUSED=1 ;;
    *)         err "Неизвестный шаг: $1"; return 1 ;;
  esac
}

profile_apply() { # применяет профиль из массива P
  profile_plan
  local total=${#PLAN_IDS[@]} i n=0 id title
  if (( total == 0 )); then warn "В профиле нет ни одного включённого шага."; return 1; fi
  echo
  info "План ($total шагов):"
  for i in "${!PLAN_IDS[@]}"; do printf '    %2d. %s\n' "$((i + 1))" "${PLAN_TITLES[$i]}"; done
  echo
  hint "Шаги, влияющие на доступ к серверу (запрет root, вход по ключам), как всегда, потребуют подтверждения."
  confirm "Применить профиль?" Y || { info "Отменено."; return 1; }

  for i in "${!PLAN_IDS[@]}"; do
    id=${PLAN_IDS[$i]}
    title=${PLAN_TITLES[$i]}
    n=$((n + 1))
    header "Профиль: шаг $n из $total"
    printf '  %s%s%s\n\n' "$C_BOLD" "$title" "$C_RESET"
    if profile_step "$id"; then
      log INFO "Профиль: шаг «$title» выполнен"
    else
      warn "Шаг «$title» завершился с ошибкой."
      if (( ! STEP_PAUSED )); then pause; fi
      confirm "Продолжить со следующим шагом?" Y || { info "Применение остановлено."; return 1; }
      continue
    fi
    if (( ! STEP_PAUSED )); then pause; fi
  done
  header "Профиль применён"
  ok "Все шаги выполнены."
  hint "Итоговое состояние: главное меню → «Обзор системы»."
  reboot_prompt
  return 0
}

pq_bool() { # pq_bool КЛЮЧ "Вопрос"
  local def=N
  if [[ ${P[$1]} == 1 ]]; then def=Y; fi
  if confirm "$2" "$def"; then P[$1]=1; else P[$1]=0; fi
}

pq_val() { # pq_val КЛЮЧ "Вопрос" ["Подсказка"]
  if [[ -n ${3:-} ]]; then hint "$3"; fi
  while true; do
    ask "$2" "${P[$1]}"
    if [[ $ASK_RESULT == "-" ]]; then ASK_RESULT=""; fi
    if profile_value_ok "$1" "$ASK_RESULT"; then P[$1]=$ASK_RESULT; return 0; fi
    err "Недопустимое значение."
  done
}

profile_questionnaire() {
  info "Отвечай на вопросы: Enter — оставить значение в скобках, «-» — очистить поле."
  step "Система"
  pq_bool SYSTEM_UPDATE "Обновить систему (apt upgrade)?"
  pq_val TIMEZONE "Часовой пояс" "Например UTC или Europe/Moscow. Пусто — не менять."
  step "Доступ"
  pq_val NEW_USER "Создать пользователя с sudo" "Имя пользователя, ASK — спросить при применении, пусто — не создавать."
  if [[ -n ${P[NEW_USER]} ]]; then
    pq_bool COPY_ROOT_KEYS "Скопировать ему SSH-ключи root?"
    pq_val USER_SSH_KEY "Публичный SSH-ключ для него" "Строка ключа целиком, ASK — спросить при применении, пусто — не добавлять."
  fi
  pq_bool SSH_DISABLE_ROOT "Запретить вход под root?"
  pq_bool SSH_KEYS_ONLY "Вход только по ключам (отключить пароль)?"
  step "Файрвол и защита"
  pq_bool UFW "Настроить UFW?"
  if [[ ${P[UFW]} == 1 ]]; then
    pq_val UFW_EXTRA_PORTS "Дополнительные порты" "Через пробел, например: 443/tcp 2222/tcp. Порт SSH откроется сам."
  fi
  pq_bool NFTABLES "Установить nftables?"
  pq_bool FAIL2BAN "Настроить Fail2ban для SSH?"
  if [[ ${P[FAIL2BAN]} == 1 ]]; then
    pq_val F2B_MAXRETRY "maxretry — попыток до бана" "Целое число, обычно 3–5."
    pq_val F2B_FINDTIME "findtime — окно подсчёта попыток" "Число + s/m/h/d/w, например 10m."
    pq_val F2B_BANTIME "bantime — срок бана" "Например 12h, 2d, 1w; -1 — навсегда."
    pq_val F2B_IGNOREIP "ignoreip — адреса вне бана" "Через пробел; добавь свой IP, чтобы не забанить себя."
  fi
  step "Docker и сеть"
  pq_bool DOCKER "Установить Docker?"
  if [[ ${P[DOCKER]} == 1 ]]; then
    pq_val DOCKER_LOG_SIZE "Ротация логов: max-size" "Например 10m. Пусто — ротацию не настраивать."
    if [[ -n ${P[DOCKER_LOG_SIZE]} ]]; then pq_val DOCKER_LOG_FILES "Ротация логов: max-file (сколько файлов)" ""; fi
  fi
  pq_bool BBR "Включить BBR?"
  pq_val SWAP_SIZE "Swap: размер" "Например 1G или 2G. Пусто — не создавать."
  if [[ -n ${P[SWAP_SIZE]} ]]; then pq_val SWAPPINESS "Swap: swappiness (0–100)" "Для VPS обычно 10."; fi
  pq_bool AUTOUPDATES "Включить автообновления безопасности?"
  if [[ ${P[AUTOUPDATES]} == 1 ]]; then pq_bool AUTOREBOOT "Разрешить ночную автоперезагрузку (04:00)?"; fi
  pq_bool SPEEDTEST "Установить speedtest-cli?"
  step "Приложения"
  pq_bool REMNANODE "Настроить Remnanode?"
  pq_bool WATCHDOG "Включить watchdog для Remnanode?"
  if [[ ${P[WATCHDOG]} == 1 ]]; then pq_bool WATCHDOG_AUTORESTART "Автоперезапуск ноды при падении? (по умолчанию выключено)"; fi
  pq_bool WARP "Запустить установщик WARP Native?"
}

profile_save() { # сохраняет текущий P в /etc/vpsmenu/profiles/ИМЯ.conf
  local name file k
  ask_re "Имя профиля (a-z, 0-9, - и _)" "" '^[a-z0-9][a-z0-9_-]{0,30}$' "Допустимо: a-z, 0-9, - и _, до 31 символа."
  name=$ASK_RESULT
  file="$PROFILE_DIR/$name.conf"
  install -d -m 0700 "$PROFILE_DIR"
  if [[ -f $file ]]; then confirm "Профиль '$name' уже есть. Перезаписать?" N || return 1; fi
  {
    printf '# Профиль %s: %s (создан %s)\n' "$APP_NAME" "$name" "$(date '+%F %T')"
    printf '# Формат: КЛЮЧ=значение (значение до конца строки, без кавычек). 1/0 — включить/выключить шаг.\n'
    printf '# NEW_USER и USER_SSH_KEY могут быть ASK — тогда скрипт спросит при применении.\n'
    for k in "${PROFILE_KEYS[@]}"; do printf '%s=%s\n' "$k" "${P[$k]}"; done
  } >"$file"
  chmod 600 "$file"
  ok "Профиль сохранён: $file"
  hint "Чтобы взять его на другом сервере, положи файл в репозиторий: profiles/$name.conf — и скачай через «Профили → Скачать из GitHub»."
}

mod_profile_preset() {
  header "Профили: готовые наборы"
  menu_item 1 "$(profile_preset_title node-full)"
  menu_item 2 "$(profile_preset_title minimal)"
  menu_item 3 "$(profile_preset_title hardened)"
  menu_item 0 "Назад"
  echo; read_choice
  local id
  case $CHOICE in
    1) id=node-full ;;
    2) id=minimal ;;
    3) id=hardened ;;
    *) return 0 ;;
  esac
  profile_load_preset "$id" || { err "Не удалось загрузить набор."; pause; return 1; }
  header "Профиль: $(profile_preset_title "$id")"
  profile_apply
  pause
}

mod_profile_manual() {
  header "Профиль вручную"
  info "С каких значений начать? (дальше на каждый вопрос можно ответить своим)"
  menu_item 1 "$(profile_preset_title node-full)"
  menu_item 2 "$(profile_preset_title minimal)"
  menu_item 3 "$(profile_preset_title hardened)"
  menu_item 4 "С нуля (всё выключено)"
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    1) profile_load_preset node-full ;;
    2) profile_load_preset minimal ;;
    3) profile_load_preset hardened ;;
    4) profile_reset ;;
    *) return 0 ;;
  esac
  header "Профиль вручную: вопросы"
  profile_questionnaire
  profile_plan
  header "Профиль вручную: итог"
  if (( ${#PLAN_IDS[@]} == 0 )); then warn "Ничего не выбрано."; pause; return 0; fi
  local i
  for i in "${!PLAN_IDS[@]}"; do printf '    %2d. %s\n' "$((i + 1))" "${PLAN_TITLES[$i]}"; done
  echo
  menu_item 1 "Применить сейчас"
  menu_item 2 "Сохранить как профиль"
  menu_item 3 "Применить и сохранить"
  menu_item 0 "Отмена"
  echo; read_choice
  case $CHOICE in
    1) profile_apply ;;
    2) profile_save ;;
    3) profile_save && profile_apply ;;
    *) info "Отменено." ;;
  esac
  pause
}

mod_profile_saved() {
  header "Сохранённые профили"
  local -a files=()
  local i=0 f
  mapfile -t files < <(find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
  if (( ${#files[@]} == 0 )); then
    info "Сохранённых профилей пока нет (создай: «Настроить вручную» → «Сохранить»)."
    pause; return 0
  fi
  for f in "${files[@]}"; do i=$((i + 1)); printf '  %2d  %s\n' "$i" "$(basename "$f" .conf)"; done
  ask_re "Номер профиля (Enter — отмена)" "" '^[0-9]*$' "Нужен номер из списка."
  [[ -z $ASK_RESULT ]] && return 0
  if (( 10#$ASK_RESULT < 1 || 10#$ASK_RESULT > ${#files[@]} )); then err "Нет такого номера."; pause; return 1; fi
  f="${files[$((10#$ASK_RESULT - 1))]}"
  echo
  menu_item 1 "Применить"
  menu_item 2 "Показать содержимое"
  menu_item 3 "Удалить"
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    1)
      if profile_parse <"$f"; then header "Профиль: $(basename "$f" .conf)"; profile_apply; else err "В профиле есть ошибки."; fi
      pause ;;
    2) sed 's/^/  /' "$f" | show_paged; pause ;;
    3) if confirm "Удалить профиль $(basename "$f" .conf)?" N; then rm -f "$f"; ok "Удалён."; fi; pause ;;
    *) return 0 ;;
  esac
}

mod_profile_download() {
  header "Профили: скачать из GitHub"
  if ! update_repo_ok; then
    warn "GitHub-репозиторий не задан."
    update_configure_repo || { pause; return 1; }
  fi
  info "Источник: github.com/$(update_repo) (ветка $(update_branch)), папка profiles/"
  ask_re "Имя профиля (файл profiles/<имя>.conf, Enter — отмена)" "" '^$|^[a-z0-9][a-z0-9_-]{0,30}$' "Допустимо: a-z, 0-9, - и _."
  local name=$ASK_RESULT
  [[ -z $name ]] && return 0
  ensure_curl || { pause; return 1; }
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "$tmp" "$(update_url "profiles/$name.conf")"; then
    err "Не удалось скачать profiles/$name.conf (проверь имя и что файл есть в репозитории)."
    rm -f "$tmp"; pause; return 1
  fi
  if ! profile_parse <"$tmp"; then
    err "Профиль содержит ошибки — не сохраняю."
    rm -f "$tmp"; pause; return 1
  fi
  ok "Профиль прочитан и проверен."
  profile_plan
  local i
  for i in "${!PLAN_IDS[@]}"; do printf '    %2d. %s\n' "$((i + 1))" "${PLAN_TITLES[$i]}"; done
  echo
  install -d -m 0700 "$PROFILE_DIR"
  if confirm "Сохранить локально как '$name'?" Y; then
    install -m 0600 "$tmp" "$PROFILE_DIR/$name.conf" && ok "Сохранено: $PROFILE_DIR/$name.conf"
  fi
  if confirm "Применить сейчас?" N; then header "Профиль: $name"; profile_apply; fi
  rm -f "$tmp"
  pause
}

menu_profiles() {
  while true; do
    header "13. Профили серверов"
    hint "Профиль — набор ответов для настройки нового сервера: применяется почти без вопросов."
    echo
    menu_item 1 "Применить готовый профиль"
    menu_item 2 "Настроить вручную (с вопросами), применить и/или сохранить"
    menu_item 3 "Сохранённые профили"
    menu_item 4 "Скачать профиль из GitHub (profiles/<имя>.conf)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_profile_preset ;;
      2) mod_profile_manual ;;
      3) mod_profile_saved ;;
      4) mod_profile_download ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

# ══════════════════════════ Мастер быстрой настройки ══════════════════════════

mod_wizard() {
  header "Мастер быстрой настройки"
  info "Пройдём по шагам по порядку. Каждый шаг можно пропустить."
  warn "Запрет root и вход только по ключам включай лишь после проверки входа пользователем в отдельном окне."
  hint "Смена порта SSH в мастер не входит — она в меню SSH."
  pause

  local -a steps=(
    "Обновление системы|mod_sys_update"
    "Часовой пояс и NTP|mod_timezone_ntp"
    "Пользователь с sudo|mod_user"
    "SSH: добавить публичный ключ|mod_ssh_addkey"
    "SSH: запрет входа под root|mod_ssh_disable_root"
    "SSH: вход только по ключам (необязательно)|mod_ssh_keys_only"
    "UFW (файрвол)|mod_ufw_setup"
    "nftables|mod_nft_setup"
    "Fail2ban|mod_f2b_setup"
    "Docker|mod_docker"
    "Docker: ротация логов|mod_docker_logrotate"
    "BBR (ускорение сети)|mod_bbr"
    "Swap|mod_swap"
    "Автообновления безопасности|mod_autoupdates"
    "Remnanode|mod_remna_setup"
    "WARP Native|mod_warp"
  )
  local total=${#steps[@]} i=0 entry title fn ans
  for entry in "${steps[@]}"; do
    i=$((i + 1))
    title=${entry%%|*}
    fn=${entry##*|}
    header "Мастер: шаг $i из $total"
    printf '  %s%s%s\n\n' "$C_BOLD" "$title" "$C_RESET"
    read -r -p "  [Enter] выполнить · [s] пропустить · [q] выйти из мастера: " ans || { echo; exit 0; }
    case "${ans,,}" in
      s|ы) continue ;;
      q|й) info "Мастер завершён досрочно."; pause; return 0 ;;
    esac
    "$fn"
  done
  header "Мастер быстрой настройки"
  ok "Все шаги пройдены."
  hint "Итоговое состояние: главное меню → «Обзор системы»."
  pause
}

# ══════════════════════════ Самообновление и установка скрипта ══════════════════════════

self_install() {
  if [[ ! -f $SELF ]]; then
    err "Скрипт запущен не из файла — сохрани его в файл и запусти оттуда."
    return 1
  fi
  if [[ $SELF == "$INSTALL_PATH" ]]; then
    ok "Запущена уже установленная копия: $INSTALL_PATH"
    return 0
  fi
  if [[ -f $INSTALL_PATH ]] && cmp -s "$SELF" "$INSTALL_PATH"; then
    ok "Установлена актуальная версия: $INSTALL_PATH"
    return 0
  fi
  if install -m 0755 -o root -g root "$SELF" "$INSTALL_PATH"; then
    ok "Установлено: $INSTALL_PATH"
    info "Теперь запускай из любого места командой:  ${C_BOLD}${APP_NAME}${C_RESET}"
  else
    err "Не удалось скопировать скрипт в $INSTALL_PATH"
    return 1
  fi
}

self_uninstall() {
  if [[ ! -f $INSTALL_PATH ]]; then warn "Скрипт не установлен в систему."; return 0; fi
  if confirm "Удалить $INSTALL_PATH? (лог $LOG_FILE останется)" N; then
    rm -f "$INSTALL_PATH" && ok "Удалено." || err "Не удалось удалить."
  fi
}

menu_self() {
  while true; do
    header "12. Скрипт ${APP_NAME}"
    info "Версия: $APP_VERSION · источник обновлений: $(update_repo_ok && echo "github.com/$(update_repo) ($(update_branch))" || echo "не задан")"
    if [[ -f $INSTALL_PATH ]]; then info "Установлен: $INSTALL_PATH"; else info "Не установлен в систему."; fi
    echo
    menu_item 1 "Обновить скрипт из GitHub"
    menu_item 2 "Откатить на предыдущую версию"
    menu_item 3 "Репозиторий GitHub (настройка)"
    menu_item 4 "Установить эту копию в систему"
    menu_item 5 "Удалить из системы"
    menu_item 6 "Показать лог действий (последние 100 строк)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_update ;;
      2) mod_update_rollback ;;
      3) update_configure_repo; pause ;;
      4) self_install; pause ;;
      5) self_uninstall; pause ;;
      6) tail -n 100 "$LOG_FILE" | show_paged; pause ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

first_run_offer() {
  [[ -f $SELF && $SELF != "$INSTALL_PATH" ]] || return 0
  if [[ ! -f $INSTALL_PATH ]]; then
    header "Установка команды"
    info "Скрипт ещё не установлен в систему."
    if confirm "Установить как команду '${APP_NAME}' (запуск из любого места)?" Y; then
      self_install; pause
    fi
  elif ! cmp -s "$SELF" "$INSTALL_PATH"; then
    header "Обновление команды"
    info "Установленная копия ($INSTALL_PATH) отличается от этого файла."
    if confirm "Обновить установленную копию?" N; then
      self_install; pause
    fi
  fi
}

update_repo() {
  local r
  r="$(conf_get GITHUB_REPO)"
  printf '%s' "${r:-$DEFAULT_REPO}"
}

update_branch() {
  local b
  b="$(conf_get GITHUB_BRANCH)"
  printf '%s' "${b:-$DEFAULT_BRANCH}"
}

update_repo_ok() {
  local r
  r="$(update_repo)"
  [[ $r =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && $r != CHANGE_ME/* ]]
}

update_url() { printf '%s/%s/%s/%s?nocache=%s' "$RAW_BASE" "$(update_repo)" "$(update_branch)" "$1" "$(date +%s)"; }

update_state_write() { # $1 = версия в репозитории
  install -d -m 0755 "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$(date +%s)" "${1:-}" >"$STATE_DIR/update-check" 2>/dev/null || true
}

update_fetch() { # update_fetch ФАЙЛ — скачивает и проверяет скрипт из репозитория
  ensure_curl || return 1
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 -o "$1" "$(update_url vpsmenu.sh)"; then
    err "Не удалось скачать скрипт из github.com/$(update_repo) (ветка $(update_branch))."
    hint "Проверь имя репозитория и ветку (меню «Сам скрипт» → «Репозиторий GitHub»), а также что репозиторий публичный."
    return 1
  fi
  if ! head -n 1 "$1" | grep -q '^#!.*bash' || ! grep -q '^readonly APP_NAME="vpsmenu"' "$1"; then
    err "Скачанный файл не похож на vpsmenu — обновление отменено."
    return 1
  fi
  if ! bash -n "$1" 2>/dev/null; then
    err "В скачанном файле синтаксическая ошибка — обновление отменено."
    return 1
  fi
  if [[ -z "$(script_version_of "$1")" ]]; then
    err "Не удалось определить версию в скачанном файле."
    return 1
  fi
}

update_configure_repo() {
  local def=""
  update_repo_ok && def="$(update_repo)"
  info "Укажи репозиторий в формате ник/имя, например: roman/vpsmenu"
  ask_re "GitHub-репозиторий" "$def" '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' "Формат: ник/репозиторий."
  conf_set GITHUB_REPO "$ASK_RESULT" || { err "Не удалось записать $CONF_FILE"; return 1; }
  ask_re "Ветка" "$(update_branch)" '^[A-Za-z0-9._/-]+$' "Допустимы буквы, цифры, . _ - /"
  conf_set GITHUB_BRANCH "$ASK_RESULT" || { err "Не удалось записать $CONF_FILE"; return 1; }
  ok "Сохранено в $CONF_FILE: $(update_repo), ветка $(update_branch)"
}

update_show_changelog() {
  local cl
  cl="$(curl -fsSL --max-time 8 "$(update_url CHANGELOG.md)" 2>/dev/null | head -n 25)" || true
  [[ -n $cl ]] || return 0
  echo
  printf '  %sЧто нового (начало CHANGELOG.md):%s\n' "$C_BOLD" "$C_RESET"
  printf '%s\n' "$cl" | sed 's/^/    /'
  echo
}

update_apply() { # update_apply СКАЧАННЫЙ_ФАЙЛ — ставит новую версию и перезапускает скрипт
  local new_ver old_ver ts src bak
  new_ver="$(script_version_of "$1")"
  old_ver="$APP_VERSION"
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_prepare || return 1
  src="$INSTALL_PATH"
  [[ -f $src ]] || src="$SELF"
  if [[ -f $src ]]; then
    bak="$BACKUP_DIR/${APP_NAME}-v${old_ver}-${ts}.sh"
    if cp -a "$src" "$bak"; then ok "Копия текущей версии: $bak"; fi
    backup_files "${APP_NAME}-v*.sh" | tail -n +6 | xargs -r rm -f
  fi
  # запоминаем репозиторий в конфиге: новая версия не потеряет источник обновлений
  if update_repo_ok && [[ -z "$(conf_get GITHUB_REPO)" ]]; then
    conf_set GITHUB_REPO "$(update_repo)"
    conf_set GITHUB_BRANCH "$(update_branch)"
  fi
  if ! install -m 0755 -o root -g root "$1" "$INSTALL_PATH"; then
    err "Не удалось записать $INSTALL_PATH."
    return 1
  fi
  rm -f "$1"
  ok "Обновлено до версии $new_ver."
  log INFO "Обновление $old_ver → $new_ver"
  update_state_write "$new_ver"
  info "Перезапускаю новую версию…"
  sleep 1
  exec "$INSTALL_PATH"
}

mod_update() {
  header "Обновление скрипта"
  if ! update_repo_ok; then
    warn "GitHub-репозиторий для обновлений не задан."
    update_configure_repo || { pause; return 1; }
  fi
  info "Источник: github.com/$(update_repo) (ветка $(update_branch))"
  info "Установлена версия: $APP_VERSION"

  local tmp remote
  tmp="$(mktemp)"
  step "Проверяю обновления"
  if ! update_fetch "$tmp"; then rm -f "$tmp"; pause; return 1; fi
  remote="$(script_version_of "$tmp")"
  info "Версия в репозитории: $remote"
  update_state_write "$remote"

  if version_gt "$remote" "$APP_VERSION"; then
    ok "Доступна новая версия: $APP_VERSION → $remote"
    update_show_changelog
    confirm "Обновить?" Y || { info "Отменено."; rm -f "$tmp"; pause; return 0; }
  elif [[ $remote == "$APP_VERSION" ]]; then
    ok "У тебя актуальная версия."
    if { [[ -f $INSTALL_PATH ]] && cmp -s "$tmp" "$INSTALL_PATH"; } || { [[ -f $SELF ]] && cmp -s "$tmp" "$SELF"; }; then
      rm -f "$tmp"; pause; return 0
    fi
    warn "Номер версии тот же, но содержимое файла в репозитории отличается."
    confirm "Переустановить из репозитория?" N || { info "Отменено."; rm -f "$tmp"; pause; return 0; }
  else
    warn "В репозитории версия старее ($remote < $APP_VERSION)."
    confirm "Всё равно установить её (откат)?" N || { info "Отменено."; rm -f "$tmp"; pause; return 0; }
  fi

  local rc
  update_apply "$tmp"
  rc=$?
  rm -f "$tmp"
  pause
  return $rc
}

mod_update_rollback() {
  header "Откат на предыдущую версию скрипта"
  info "Копии, сохранённые при обновлениях:"
  backup_pick "${APP_NAME}-v*.sh" || { pause; return 0; }
  local f=$BACKUP_PICKED
  confirm "Установить $(basename "$f") как текущую версию?" N || { info "Отменено."; pause; return 0; }
  if install -m 0755 -o root -g root "$f" "$INSTALL_PATH"; then
    ok "Восстановлено: $(basename "$f")"
    sleep 1
    exec "$INSTALL_PATH"
  fi
  err "Не удалось восстановить."
  pause
}

update_check_cached() { # раз в сутки тихо проверяет репозиторий → $UPDATE_AVAILABLE
  UPDATE_AVAILABLE=""
  update_repo_ok || return 0
  cmd_exists curl || return 0
  install -d -m 0755 "$STATE_DIR" 2>/dev/null
  local f="$STATE_DIR/update-check" last=0 ver="" now tmp
  now="$(date +%s)"
  if [[ -f $f ]]; then read -r last ver <"$f" || true; fi
  if (( now - ${last:-0} > 86400 )); then
    tmp="$(mktemp)"
    if curl -fsSL --connect-timeout 3 --max-time 6 -o "$tmp" "$(update_url vpsmenu.sh)" 2>/dev/null &&
       grep -q '^readonly APP_NAME="vpsmenu"' "$tmp"; then
      ver="$(script_version_of "$tmp")"
    fi
    rm -f "$tmp"
    printf '%s %s\n' "$now" "${ver:-}" >"$f" 2>/dev/null || true
  fi
  if [[ -n $ver ]] && version_gt "$ver" "$APP_VERSION"; then UPDATE_AVAILABLE="$ver"; fi
}

# ══════════════════════════ Dashboard ══════════════════════════
# Моментальный снимок сервера из реальных данных (/proc, df, ip, systemctl, docker, journalctl).
# Это не постоянный мониторинг: данные собираются при открытии и по клавише r.

DASH_PREV_RX=""
DASH_PREV_TX=""
DASH_PREV_TS=0
DASH_CACHE_TS=0
DASH_UPD_ALL=""
DASH_UPD_SEC=""
DASH_SSH_FAILED=""
DASH_SSH_TOP=""
DASH_BANNED=""
DASH_BANNED_TOTAL=""

dash_meminfo_kb() { awk -v k="$1:" '$1 == k {print $2; exit}' /proc/meminfo; }

dash_uptime() {
  local up d h m
  read -r up _ </proc/uptime
  up=${up%.*}
  d=$(( up / 86400 )); h=$(( up % 86400 / 3600 )); m=$(( up % 3600 / 60 ))
  if (( d > 0 )); then printf '%d д %d ч %d мин' "$d" "$h" "$m"
  elif (( h > 0 )); then printf '%d ч %d мин' "$h" "$m"
  else printf '%d мин' "$m"; fi
}

dash_cpu_sample() { awk '/^cpu / {idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print idle, total}' /proc/stat; }

dash_cpu_pct() { # загрузка CPU за короткий интервал по /proc/stat
  local i1 t1 i2 t2 dt di
  read -r i1 t1 < <(dash_cpu_sample)
  sleep 0.25
  read -r i2 t2 < <(dash_cpu_sample)
  dt=$(( t2 - t1 )); di=$(( i2 - i1 ))
  if (( dt > 0 )); then printf '%d' $(( 100 * (dt - di) / dt )); else printf '0'; fi
}

dash_system() {
  local cores l1 l5 l15 cpu mt ma mu mp st sf su sp size used avail pct mnt shown=0
  ui_section "Система"
  ui_kv "Хост" "$UI_HOST · $OS_PRETTY"
  ui_kv "Ядро" "$(uname -r) · аптайм $(dash_uptime)"
  cores="$(nproc 2>/dev/null || echo 1)"
  read -r l1 l5 l15 _ </proc/loadavg
  cpu="$(dash_cpu_pct)"
  ui_meter "CPU" "$cpu" "load $l1 / $l5 / $l15 · ядер $cores"

  mt="$(dash_meminfo_kb MemTotal)"; ma="$(dash_meminfo_kb MemAvailable)"
  mt=${mt:-0}; ma=${ma:-0}
  mu=$(( mt - ma )); mp=0
  if (( mt > 0 )); then mp=$(( 100 * mu / mt )); fi
  ui_meter "RAM" "$mp" "$(ui_human_kb "$mu") / $(ui_human_kb "$mt")"

  st="$(dash_meminfo_kb SwapTotal)"; sf="$(dash_meminfo_kb SwapFree)"
  st=${st:-0}; sf=${sf:-0}
  if (( st > 0 )); then
    su=$(( st - sf )); sp=$(( 100 * su / st ))
    ui_meter "Swap" "$sp" "$(ui_human_kb "$su") / $(ui_human_kb "$st")"
  else
    ui_kv "Swap" "${C_DIM}нет${C_RESET}"
  fi

  while read -r _ size used avail pct mnt; do
    (( shown >= 4 )) && break
    pct=${pct%\%}
    ui_meter "$(ui_trunc "$mnt" 7)" "$pct" "$(ui_human_kb "$used") / $(ui_human_kb "$size")"
    shown=$(( shown + 1 ))
  done < <(df -P -k -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)
}

dash_network() {
  local name state addrs a1 a2 col hidden=0 iface rx tx now dt rrx rtx rate=""
  ui_section "Сеть"
  while read -r name state addrs; do
    [[ $name == lo ]] && continue
    case $name in
      docker*|br-*|veth*|virbr*|cni*|flannel*) hidden=$(( hidden + 1 )); continue ;;
    esac
    read -r a1 a2 _ <<<"$addrs"
    case $state in UP) col=$C_GREEN ;; DOWN) col=$C_RED ;; *) col=$C_DIM ;; esac
    ui_kv "$(ui_trunc "$name" 9)" "${col}${state}${C_RESET} ${a1:-—} ${a2:-}"
  done < <(ip -brief addr 2>/dev/null)
  if (( hidden > 0 )); then ui_kv "docker" "${C_DIM}интерфейсов контейнеров: $hidden${C_RESET}"; fi

  iface="$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
  if [[ -n $iface ]]; then
    read -r rx tx < <(sed 's/^ *//; s/:/ /' /proc/net/dev | awk -v i="$iface" '$1 == i {print $2, $10}')
    now="$(date +%s)"
    if [[ -n $DASH_PREV_RX && $DASH_PREV_TS -gt 0 && -n ${rx:-} ]]; then
      dt=$(( now - DASH_PREV_TS ))
      if (( dt > 0 )); then
        rrx=$(( (rx - DASH_PREV_RX) / dt / 1024 )); rtx=$(( (tx - DASH_PREV_TX) / dt / 1024 ))
        rate=" · сейчас ↓ $(ui_human_kb "$rrx")/с ↑ $(ui_human_kb "$rtx")/с"
      fi
    fi
    if [[ -n ${rx:-} ]]; then
      ui_kv "Трафик" "$iface: ↓ $(ui_human_kb $(( rx / 1024 ))) ↑ $(ui_human_kb $(( tx / 1024 ))) с загрузки${rate}"
      DASH_PREV_RX=$rx; DASH_PREV_TX=$tx; DASH_PREV_TS=$now
    fi
  fi
}

dash_services() {
  local sysstate failed n=0 u
  ui_section "Службы"
  if ! cmd_exists systemctl; then ui_line off "systemd недоступен"; return 0; fi
  sysstate="$(systemctl is-system-running 2>/dev/null)"
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
  if [[ -z $failed ]]; then
    ui_line ok "Упавших служб нет ${C_DIM}(состояние системы: ${sysstate:-?})${C_RESET}"
  else
    ui_line bad "Упавшие службы: $(wc -l <<<"$failed") ${C_DIM}(состояние системы: ${sysstate:-?})${C_RESET}"
    while read -r u; do
      n=$(( n + 1 ))
      if (( n > 5 )); then break; fi
      printf '      %s%s%s\n' "$C_RED" "$u" "$C_RESET"
    done <<<"$failed"
    printf '      %sразобраться: клавиша s в главном меню (Service Manager)%s\n' "$C_DIM" "$C_RESET"
  fi
}

dash_docker() {
  local rows name status up=0 total=0 shown=0 icon col rs
  ui_section "Docker"
  if ! cmd_exists docker; then ui_line off "Docker не установлен"; return 0; fi
  if ! service_active docker; then ui_line bad "Docker не запущен"; return 0; fi
  rows="$(timeout 5 docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null)"
  if [[ -z $rows ]]; then
    ui_line off "Контейнеров нет"
  else
    while IFS='|' read -r name status _; do
      total=$(( total + 1 ))
      case $status in
        Up*)        up=$(( up + 1 )); icon="●"; col=$C_GREEN ;;
        Exited*|Dead*) icon="●"; col=$C_RED ;;
        *)          icon="●"; col=$C_YELLOW ;;
      esac
      if (( shown < 8 )); then
        printf '  %s%s%s %s %s%s%s\n' "$col" "$icon" "$C_RESET" "$(ui_pad "$(ui_trunc "$name" 18)" 18)" "$C_DIM" "$(ui_trunc "$status" $(( UI_W - 26 )))" "$C_RESET"
        shown=$(( shown + 1 ))
      fi
    done <<<"$rows"
    if (( total > shown )); then printf '    %sи ещё контейнеров: %d%s\n' "$C_DIM" "$(( total - shown ))" "$C_RESET"; fi
    ui_kv "Итого" "запущено $up из $total"
  fi
  if [[ -s $REMNA_COMPOSE ]]; then
    rs="$(remna_panel_state)"
    ui_kv "Remnanode" "$(badge "${rs%%|*}" "${rs#*|}")"
    if wd_enabled; then
      ui_kv "Watchdog" "включён · автоперезапуск: $(wd_autorestart_on && echo включён || echo выключен)"
    else
      ui_kv "Watchdog" "${C_DIM}выключен${C_RESET}"
    fi
  fi
}

dash_security_refresh() { # тяжёлые проверки — результат кэшируется на 2 минуты
  local out logtxt
  DASH_UPD_ALL=""; DASH_UPD_SEC=""; DASH_SSH_FAILED=""; DASH_SSH_TOP=""; DASH_BANNED=""; DASH_BANNED_TOTAL=""
  if cmd_exists apt-get; then
    out="$(apt-get -s upgrade 2>/dev/null | grep '^Inst')"
    if [[ -z $out ]]; then
      DASH_UPD_ALL=0; DASH_UPD_SEC=0
    else
      DASH_UPD_ALL="$(wc -l <<<"$out")"
      DASH_UPD_SEC="$(grep -c -- '-security' <<<"$out")"
    fi
  fi
  logtxt="$(timeout 6 journalctl -u ssh -u sshd --since '24 hours ago' -o cat --no-pager -q 2>/dev/null | grep -E 'Failed password|Invalid user|authentication failure')"
  if [[ -z $logtxt && -r /var/log/auth.log ]]; then
    logtxt="$(grep -E 'Failed password|Invalid user' /var/log/auth.log | tail -n 5000)"
  fi
  if [[ -z $logtxt ]]; then
    DASH_SSH_FAILED=0
  else
    DASH_SSH_FAILED="$(wc -l <<<"$logtxt")"
    DASH_SSH_TOP="$(grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' <<<"$logtxt" | sort | uniq -c | sort -rn | head -n 3 | awk '{printf "%s (%s)  ", $2, $1}')"
  fi
  if cmd_exists fail2ban-client && service_active fail2ban; then
    out="$(fail2ban-client status sshd 2>/dev/null)"
    DASH_BANNED="$(sed -n 's/.*Currently banned:[[:space:]]*//p' <<<"$out")"
    DASH_BANNED_TOTAL="$(sed -n 's/.*Total banned:[[:space:]]*//p' <<<"$out")"
  fi
  DASH_CACHE_TS="$(date +%s)"
}

dash_security() { # dash_security [force]
  local force=${1:-0} now who_n who_list
  now="$(date +%s)"
  ui_section "Безопасность"
  if (( force )) || (( now - DASH_CACHE_TS > 120 )); then
    if [[ -t 1 ]]; then printf '  %sсобираю данные…%s' "$C_DIM" "$C_RESET"; fi
    dash_security_refresh
    if [[ -t 1 ]]; then printf '\r\e[K'; fi
  fi

  who_n="$(who 2>/dev/null | wc -l)"
  who_list="$(who 2>/dev/null | awk '{ip = $NF; gsub(/[()]/, "", ip); printf "%s%s  ", $1, (ip != $2 && ip != "" ? "@" ip : "")}')"
  ui_kv "Сессии" "$who_n ${C_DIM}${who_list}${C_RESET}"

  if [[ -n $DASH_SSH_FAILED ]]; then
    if (( DASH_SSH_FAILED == 0 )); then
      ui_line ok "Неудачных входов по SSH за 24 ч нет"
    elif (( DASH_SSH_FAILED < 50 )); then
      ui_line warn "Неудачных входов по SSH за 24 ч: $DASH_SSH_FAILED"
    else
      ui_line bad "Неудачных входов по SSH за 24 ч: $DASH_SSH_FAILED"
    fi
    if [[ -n $DASH_SSH_TOP ]]; then printf '      %sчаще всего: %s%s\n' "$C_DIM" "$DASH_SSH_TOP" "$C_RESET"; fi
  fi
  if [[ -n $DASH_BANNED ]]; then
    ui_line ok "Fail2ban: забанено сейчас $DASH_BANNED ${C_DIM}(всего ${DASH_BANNED_TOTAL:-?})${C_RESET}"
  elif cmd_exists fail2ban-client; then
    ui_line warn "Fail2ban установлен, но не запущен"
  else
    ui_line off "Fail2ban не установлен"
  fi
  if [[ -n $DASH_UPD_ALL ]]; then
    if (( DASH_UPD_SEC > 0 )); then
      ui_line warn "Обновлений безопасности: $DASH_UPD_SEC ${C_DIM}(всего пакетов: $DASH_UPD_ALL)${C_RESET}"
    elif (( DASH_UPD_ALL > 0 )); then
      ui_line off "Доступно обновлений: $DASH_UPD_ALL (безопасности — нет)"
    else
      ui_line ok "Система обновлена"
    fi
  fi
  if [[ -f /var/run/reboot-required ]]; then ui_line warn "Нужна перезагрузка (обновилось ядро или библиотеки)"; fi
}

dash_render() { # dash_render [force] — выводит весь экран один раз
  local force=${1:-0}
  header "Dashboard"
  dash_system
  dash_network
  dash_services
  dash_docker
  dash_security "$force"
  printf '\n  %s%s%s\n' "$C_DIM" "обновлено $(date '+%d.%m.%Y %H:%M:%S')" "$C_RESET"
}

mod_dashboard() {
  local auto=0 force=1 key rest rc
  if [[ ! -t 0 || ! -t 1 ]]; then dash_render 1; return 0; fi
  while true; do
    dash_render "$force"
    force=0
    printf '\n  %s[r]%s обновить   %s[a]%s авто каждые 5 с: %s   %s[q]%s назад\n' \
      "${C_BOLD}${C_CYAN}" "$C_RESET" "${C_BOLD}${C_CYAN}" "$C_RESET" "$( ((auto)) && echo "${C_GREEN}вкл${C_RESET}" || echo "выкл")" "${C_BOLD}${C_CYAN}" "$C_RESET"
    key=""
    if (( auto )); then
      IFS= read -rsn1 -t 5 key
      rc=$?
      if (( rc > 128 )); then continue; fi
    else
      IFS= read -rsn1 key || return 0
    fi
    case $key in
      r|R|к|К) force=1 ;;
      a|A|ф|Ф) auto=$(( ! auto )) ;;
      q|Q|0|й|Й) return 0 ;;
      $'\e')
        rest=""
        IFS= read -rsn2 -t 0.05 rest || true
        while IFS= read -rsn1 -t 0.005 _; do :; done
        if [[ -z $rest ]]; then return 0; fi
        ;;
    esac
  done
}

# ══════════════════════════ Service Manager (службы systemd) ══════════════════════════
# Универсальный модуль для systemd: список с фильтрами и поиском, выбор службы из списка
# (без ввода названия), карточка службы, действия, журнал. Критичные службы защищены.

declare -a SVC_NAMES=() SVC_ACTIVE=() SVC_SUB=() SVC_ENABLED=() SVC_DESC=() SVC_VIEW=()
SVC_PICKED=""
SVC_FILTERS=(all running failed inactive enabled)

svc_filter_title() {
  case $1 in
    all)      echo "все" ;;
    running)  echo "работают" ;;
    failed)   echo "упавшие" ;;
    inactive) echo "не работают" ;;
    enabled)  echo "в автозапуске" ;;
  esac
}

svc_load() { # читает все службы: файлы юнитов + текущее состояние
  SVC_NAMES=(); SVC_ACTIVE=(); SVC_SUB=(); SVC_ENABLED=(); SVC_DESC=()
  local -A en=() act=() sub=() desc=()
  local u st load a s d
  while read -r u st _; do
    if [[ $u == *.service && $u != *@.service && $st != alias ]]; then en[$u]=$st; fi
  done < <(systemctl list-unit-files --type=service --no-legend --plain --no-pager 2>/dev/null)
  while read -r u load a s d; do
    [[ $u == *.service ]] || continue
    [[ $load == not-found ]] && continue
    act[$u]=$a; sub[$u]=$s; desc[$u]=$d
    [[ -n ${en[$u]:-} ]] || en[$u]=static   # экземпляры шаблонов и временные службы
  done < <(systemctl list-units --type=service --all --no-legend --plain --no-pager 2>/dev/null)
  for u in "${!en[@]}"; do
    SVC_NAMES+=("$u")
    SVC_ACTIVE+=("${act[$u]:-inactive}")
    SVC_SUB+=("${sub[$u]:-dead}")
    SVC_ENABLED+=("${en[$u]}")
    SVC_DESC+=("${desc[$u]:-}")
  done
}

svc_build_view() { # svc_build_view ФИЛЬТР [ПОИСК] → SVC_VIEW (индексы; упавшие и работающие — выше)
  SVC_VIEW=()
  local i f=$1 q=${2:-} k hay lines=""
  q=${q,,}
  for i in "${!SVC_NAMES[@]}"; do
    case $f in
      running)  [[ ${SVC_SUB[$i]} == running ]] || continue ;;
      failed)   [[ ${SVC_ACTIVE[$i]} == failed ]] || continue ;;
      inactive) [[ ${SVC_ACTIVE[$i]} != active ]] || continue ;;
      enabled)  [[ ${SVC_ENABLED[$i]} == enabled* ]] || continue ;;
    esac
    if [[ -n $q ]]; then
      hay="${SVC_NAMES[$i],,} ${SVC_DESC[$i],,}"
      [[ $hay == *"$q"* ]] || continue
    fi
    if [[ ${SVC_ACTIVE[$i]} == failed ]]; then k=0; elif [[ ${SVC_SUB[$i]} == running ]]; then k=1; else k=2; fi
    lines+="$k|${SVC_NAMES[$i]}|$i"$'\n'
  done
  if [[ -n $lines ]]; then
    mapfile -t SVC_VIEW < <(printf '%s' "$lines" | LC_ALL=C sort -t'|' -k1,1n -k2,2 | cut -d'|' -f3)
  fi
}

svc_critical_reason() { # печатает причину, если служба критична (пусто — обычная)
  case $1 in
    ssh.service|sshd.service|ssh.socket|sshd.socket)
      echo "SSH: остановка отрежет доступ к серверу" ;;
    networking.service|systemd-networkd.service|NetworkManager.service|systemd-resolved.service|netplan-*.service)
      echo "сеть: остановка может отрезать сервер" ;;
    docker.service|docker.socket|containerd.service)
      echo "Docker: остановятся все контейнеры, включая Remnanode" ;;
    ufw.service)
      echo "файрвол: остановка откроет порты наружу" ;;
    dbus.service|systemd-logind.service|systemd-journald.service|systemd-udevd.service)
      echo "системная служба: сбой может сделать сервер нестабильным" ;;
  esac
}

svc_row() { # svc_row НОМЕР ИНДЕКС — строка списка
  local n=$1 i=$2 name=${SVC_NAMES[$2]%.service} a=${SVC_ACTIVE[$2]} s=${SVC_SUB[$2]} e=${SVC_ENABLED[$2]}
  local col ic etxt ecol nm sb ev dw
  case $a in
    failed)                            col=$C_RED;    ic="●" ;;
    active) if [[ $s == running ]]; then col=$C_GREEN; ic="●"; else col=$C_GREEN; ic="○"; fi ;;
    activating|deactivating|reloading) col=$C_YELLOW; ic="●" ;;
    *)                                 col=$C_DIM;    ic="○" ;;
  esac
  case $e in
    enabled|enabled-runtime) etxt="вкл";    ecol=$C_GREEN ;;
    disabled)                etxt="выкл";   ecol=$C_DIM ;;
    masked*)                 etxt="masked"; ecol=$C_RED ;;
    *)                       etxt=$e;       ecol=$C_DIM ;;
  esac
  nm="$(ui_pad "$(ui_trunc "$name" 26)" 26)"
  sb="$(ui_pad "$(ui_trunc "$s" 9)" 9)"
  if (( UI_COMPACT )); then
    printf '  %s%d%s %s%s%s %s %s%s%s\n' "${C_BOLD}${C_CYAN}" "$n" "$C_RESET" "$col" "$ic" "$C_RESET" "$nm" "$col" "$s" "$C_RESET"
  else
    ev="$(ui_pad "$etxt" 6)"
    dw=$(( UI_W - 51 ))
    printf '  %s%d%s %s%s%s %s %s%s%s %s%s%s %s%s%s\n' "${C_BOLD}${C_CYAN}" "$n" "$C_RESET" "$col" "$ic" "$C_RESET" "$nm" \
      "$col" "$sb" "$C_RESET" "$ecol" "$ev" "$C_RESET" "$C_DIM" "$( ((dw > 8)) && ui_trunc "${SVC_DESC[$i]}" "$dw" )" "$C_RESET"
  fi
}

svc_pick() { # svc_pick [фильтр] ["заголовок"] → $SVC_PICKED; код 1 — отмена
  local filter=${1:-all} title=${2:-Выбор службы} query="" page=0 per=9
  local total pages i idx n key rest hintline fi_idx
  SVC_PICKED=""
  if [[ ! -t 0 ]]; then err "Выбор службы требует интерактивного терминала."; return 1; fi
  svc_load
  if (( ${#SVC_NAMES[@]} == 0 )); then err "Не удалось получить список служб (systemd недоступен?)."; return 1; fi
  while true; do
    svc_build_view "$filter" "$query"
    total=${#SVC_VIEW[@]}
    pages=$(( (total + per - 1) / per ))
    if (( pages < 1 )); then pages=1; fi
    if (( page >= pages )); then page=$(( pages - 1 )); fi
    header "$title"
    printf '  %sФильтр:%s %s%s%s' "$C_DIM" "$C_RESET" "$C_BOLD" "$(svc_filter_title "$filter")" "$C_RESET"
    if [[ -n $query ]]; then printf '  %sПоиск:%s «%s»' "$C_DIM" "$C_RESET" "$query"; fi
    printf '  %s· служб: %d · стр. %d/%d%s\n\n' "$C_DIM" "$total" "$(( page + 1 ))" "$pages" "$C_RESET"
    if (( total == 0 )); then
      printf '  %sничего не найдено — смени фильтр (f) или поиск (/)%s\n' "$C_DIM" "$C_RESET"
    else
      for (( i = 0; i < per; i++ )); do
        idx=$(( page * per + i ))
        if (( idx >= total )); then break; fi
        svc_row "$(( i + 1 ))" "${SVC_VIEW[$idx]}"
      done
    fi
    if (( UI_COMPACT )); then hintline="1–9 выбор · n/p стр. · f фильтр · / поиск · q выход"
    else hintline="1–9 выбрать · n/→ дальше · p/← назад · f фильтр · / поиск · q отмена"; fi
    printf '\n  %s%s%s\n' "$C_DIM" "$hintline" "$C_RESET"
    printf '  %s❯%s ' "$C_CYAN" "$C_RESET"
    IFS= read -rsn1 key || { echo; return 1; }
    case $key in
      [1-9])
        n=$key
        idx=$(( page * per + n - 1 ))
        if (( idx < total )); then
          SVC_PICKED="${SVC_NAMES[${SVC_VIEW[$idx]}]}"
          ui_swallow_enter
          echo
          return 0
        fi
        ;;
      n|N|т|Т|">") page=$(( (page + 1) % pages )) ;;
      p|P|з|З|"<") page=$(( (page + pages - 1) % pages )) ;;
      f|F|а|А)
        for fi_idx in "${!SVC_FILTERS[@]}"; do
          if [[ ${SVC_FILTERS[$fi_idx]} == "$filter" ]]; then break; fi
        done
        filter=${SVC_FILTERS[$(( (fi_idx + 1) % ${#SVC_FILTERS[@]} ))]}
        page=0
        ;;
      "/"|s|S|ы|Ы)
        echo
        ask "Поиск по названию и описанию (Enter — сбросить)" ""
        query=$ASK_RESULT
        page=0
        ;;
      q|Q|0|й|Й) echo; return 1 ;;
      $'\e')
        rest=""
        IFS= read -rsn2 -t 0.05 rest || true
        while IFS= read -rsn1 -t 0.005 _; do :; done
        case $rest in
          "[C") page=$(( (page + 1) % pages )) ;;
          "[D") page=$(( (page + pages - 1) % pages )) ;;
          "")   echo; return 1 ;;
        esac
        ;;
    esac
  done
}

svc_show_log_tail() { # svc_show_log_tail ЮНИТ [N]
  if cmd_exists journalctl; then
    journalctl -u "$1" -n "${2:-15}" --no-pager -o short 2>/dev/null | sed 's/^/    /'
  fi
}

svc_state_line() { printf '%s / автозапуск: %s' "$(systemctl is-active "$1" 2>/dev/null)" "$(systemctl is-enabled "$1" 2>/dev/null)"; }

svc_run() { # svc_run ДЕЙСТВИЕ ЮНИТ — действие с защитой критичных служб и проверкой результата
  local action=$1 unit=$2 reason out rc st
  reason="$(svc_critical_reason "$unit")"
  case $action in
    stop|disable|mask)
      if [[ -n $reason ]]; then
        warn "$unit — $reason."
        confirm_word "Выполнить «$action» для $unit?" "да" || { info "Отменено."; return 1; }
      elif ! confirm "Выполнить «$action» для $unit?" Y; then
        info "Отменено."; return 1
      fi
      ;;
    restart)
      if [[ -n $reason ]]; then
        warn "$unit — $reason."
        confirm "Перезапустить $unit?" N || { info "Отменено."; return 1; }
      fi
      ;;
  esac
  step "systemctl $action $unit"
  out="$(systemctl "$action" "$unit" 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    err "systemctl $action не удалось: ${out:-нет сообщения}"
    hint "Последние записи журнала:"
    svc_show_log_tail "$unit" 10
    return 1
  fi
  ok "Выполнено: $action $unit"
  case $action in
    start|restart)
      sleep 1
      st="$(systemctl is-active "$unit" 2>/dev/null)"
      if [[ $st == active ]]; then
        ok "Служба работает (active)."
      else
        warn "Состояние после $action: ${st:-?}"
        hint "Последние записи журнала:"
        svc_show_log_tail "$unit" 15
      fi
      ;;
  esac
  info "Сейчас: $(svc_state_line "$unit")"
  log INFO "systemctl $action $unit"
}

svc_autostart() { # svc_autostart ЮНИТ — переключает автозапуск
  local unit=$1 st
  st="$(systemctl is-enabled "$unit" 2>/dev/null)"
  info "Автозапуск сейчас: ${st:-?}"
  case $st in
    enabled|enabled-runtime)
      if svc_run disable "$unit" && [[ "$(systemctl is-active "$unit" 2>/dev/null)" == active ]]; then
        confirm "Остановить службу сейчас?" N && svc_run stop "$unit"
      fi
      ;;
    masked*)
      warn "Служба замаскирована — сначала размаскируй её (карточка службы → m)."
      ;;
    *)
      if svc_run enable "$unit" && [[ "$(systemctl is-active "$unit" 2>/dev/null)" != active ]]; then
        confirm "Запустить службу сейчас?" Y && svc_run start "$unit"
      fi
      ;;
  esac
}

svc_logs_menu() { # svc_logs_menu ЮНИТ
  local unit=$1
  if ! cmd_exists journalctl; then err "journalctl недоступен."; pause; return 1; fi
  while true; do
    header "Журнал: $unit"
    menu_item 1 "Последние 100 записей"
    menu_item 2 "Только ошибки (priority err и выше)"
    menu_item 3 "С момента загрузки системы"
    menu_item 4 "В реальном времени (Ctrl+C — выход)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) journalctl -u "$unit" -n 100 --no-pager 2>&1 | show_paged; pause ;;
      2) journalctl -u "$unit" -p err -n 100 --no-pager 2>&1 | show_paged; pause ;;
      3) journalctl -u "$unit" -b --no-pager 2>&1 | show_paged; pause ;;
      4) run_interruptible journalctl -u "$unit" -n 50 -f; pause ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

svc_card_render() { # svc_card_render ЮНИТ — карточка службы
  local unit=$1 k v lvl txt reason mem
  local -A p=()
  header "$unit"
  while IFS='=' read -r k v; do p[$k]=$v; done < <(systemctl show "$unit" -p Description -p LoadState -p ActiveState \
    -p SubState -p UnitFileState -p MainPID -p MemoryCurrent -p ActiveEnterTimestamp -p NRestarts -p FragmentPath \
    -p Restart --no-pager 2>/dev/null)
  ui_kv "Описание" "${p[Description]:-—}" 11
  case ${p[ActiveState]:-} in
    active)
      if [[ ${p[SubState]:-} == running ]]; then lvl=ok; txt="работает (running)"; else lvl=ok; txt="выполнена (${p[SubState]:-active})"; fi ;;
    failed)  lvl=bad;  txt="упала (failed)" ;;
    activating|deactivating|reloading) lvl=warn; txt="${p[ActiveState]} (${p[SubState]:-})" ;;
    *)       lvl=off;  txt="остановлена (${p[SubState]:-inactive})" ;;
  esac
  ui_kv "Состояние" "$(badge "$lvl" "$txt")" 11
  case ${p[UnitFileState]:-} in
    enabled|enabled-runtime) ui_kv "Автозапуск" "${C_GREEN}включён${C_RESET}" 11 ;;
    masked*)                 ui_kv "Автозапуск" "${C_RED}masked (запуск запрещён)${C_RESET}" 11 ;;
    *)                       ui_kv "Автозапуск" "${p[UnitFileState]:-?}" 11 ;;
  esac
  if [[ -n ${p[MainPID]:-} && ${p[MainPID]} != 0 ]]; then ui_kv "PID" "${p[MainPID]}" 11; fi
  mem=${p[MemoryCurrent]:-}
  if [[ $mem =~ ^[0-9]+$ ]] && (( ${#mem} < 15 )); then ui_kv "Память" "$(ui_human_kb $(( mem / 1024 )))" 11; fi
  if [[ -n ${p[ActiveEnterTimestamp]:-} ]]; then ui_kv "С момента" "${p[ActiveEnterTimestamp]}" 11; fi
  if [[ -n ${p[NRestarts]:-} && ${p[NRestarts]} != 0 ]]; then ui_kv "Рестартов" "${C_YELLOW}${p[NRestarts]}${C_RESET}" 11; fi
  if [[ -n ${p[Restart]:-} ]]; then ui_kv "Restart" "${p[Restart]}" 11; fi
  if [[ -n ${p[FragmentPath]:-} ]]; then ui_kv "Юнит" "$(ui_trunc "${p[FragmentPath]}" $(( UI_W - 15 )))" 11; fi
  reason="$(svc_critical_reason "$unit")"
  if [[ -n $reason ]]; then echo; ui_line warn "Критичная служба — $reason"; fi
  if cmd_exists journalctl; then
    ui_section "Последние записи журнала"
    timeout 3 journalctl -u "$unit" -n 5 --no-pager -o short 2>/dev/null | while IFS= read -r v; do
      printf '  %s%s%s\n' "$C_DIM" "$(ui_trunc "$v" $(( UI_W - 4 )))" "$C_RESET"
    done
  fi
  echo
}

svc_card() { # svc_card ЮНИТ — карточка со всеми действиями
  local unit=$1 uf
  while true; do
    svc_card_render "$unit"
    uf="$(systemctl show "$unit" -p UnitFileState --value 2>/dev/null)"
    menu_item s "Запустить"
    menu_item x "Остановить"
    menu_item r "Перезапустить"
    menu_item e "Автозапуск: включить / отключить"
    menu_item l "Журнал"
    menu_item i "Полный вывод systemctl status"
    if [[ $uf == masked* ]]; then menu_item m "Размаскировать (unmask)"; else menu_item m "Замаскировать (mask — запретить запуск)"; fi
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      s|S|ы|Ы) svc_run start "$unit"; pause ;;
      x|X|ч|Ч) svc_run stop "$unit"; pause ;;
      r|R|к|К) svc_run restart "$unit"; pause ;;
      e|E|у|У) svc_autostart "$unit"; pause ;;
      l|L|д|Д) svc_logs_menu "$unit" ;;
      i|I|ш|Ш) systemctl status "$unit" --no-pager -l 2>&1 | show_paged; pause ;;
      m|M|ь|Ь) if [[ $uf == masked* ]]; then svc_run unmask "$unit"; else svc_run mask "$unit"; fi; pause ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

svc_browse() { # svc_browse ФИЛЬТР "Заголовок" — выбор службы и её карточка
  if svc_pick "$1" "$2"; then svc_card "$SVC_PICKED"; fi
}

svc_pick_action() { # svc_pick_action ФИЛЬТР "Заголовок" start|stop|restart|autostart|logs
  if ! svc_pick "$1" "$2"; then return 0; fi
  local unit=$SVC_PICKED
  case $3 in
    logs) svc_logs_menu "$unit"; return 0 ;;
  esac
  header "$2: $unit"
  case $3 in
    autostart) svc_autostart "$unit" ;;
    *)         svc_run "$3" "$unit" ;;
  esac
  pause
}

mod_svc_reset_failed() {
  header "Сбросить статус упавших служб"
  hint "Убирает пометку «failed» у служб (сами службы не запускаются)."
  confirm "Выполнить systemctl reset-failed?" Y || { info "Отменено."; pause; return 0; }
  if systemctl reset-failed; then ok "Статус упавших служб сброшен."; else err "Не удалось выполнить reset-failed."; fi
  pause
}

mod_svc_daemon_reload() {
  header "systemctl daemon-reload"
  hint "Перечитывает файлы юнитов — нужно после ручного редактирования unit-файлов."
  confirm "Выполнить daemon-reload?" Y || { info "Отменено."; pause; return 0; }
  if systemctl daemon-reload; then ok "daemon-reload выполнен."; else err "Не удалось выполнить daemon-reload."; fi
  pause
}

menu_services() {
  if ! cmd_exists systemctl || [[ ! -d /run/systemd/system ]]; then
    header "Service Manager"
    err "systemd недоступен на этой системе."
    pause
    return 1
  fi
  local nrun nfail
  while true; do
    header "Service Manager"
    nrun="$(systemctl list-units --type=service --state=running --no-legend --plain --no-pager 2>/dev/null | wc -l)"
    nfail="$(systemctl --failed --no-legend --plain --no-pager 2>/dev/null | wc -l)"
    ui_line ok "Работает служб: $nrun"
    if (( nfail > 0 )); then ui_line bad "Упавших служб: $nfail (пункт 3)"; else ui_line off "Упавших служб нет"; fi
    echo
    menu_item 1 "Все службы"
    menu_item 2 "Работающие"
    menu_item 3 "Упавшие"
    menu_item 4 "Запустить службу"
    menu_item 5 "Остановить службу"
    menu_item 6 "Перезапустить службу"
    menu_item 7 "Автозапуск: включить / отключить"
    menu_item 8 "Журнал службы"
    menu_item 9 "Подробности службы (карточка)"
    menu_item f "Сбросить статус упавших (reset-failed)"
    menu_item r "systemctl daemon-reload"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) svc_browse all "Все службы" ;;
      2) svc_browse running "Работающие службы" ;;
      3) svc_browse failed "Упавшие службы" ;;
      4) svc_pick_action inactive "Запустить службу" start ;;
      5) svc_pick_action running "Остановить службу" stop ;;
      6) svc_pick_action running "Перезапустить службу" restart ;;
      7) svc_pick_action all "Автозапуск службы" autostart ;;
      8) svc_pick_action all "Журнал службы" logs ;;
      9) svc_browse all "Подробности службы" ;;
      f|F|а|А) mod_svc_reset_failed ;;
      r|R|к|К) mod_svc_daemon_reload ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

# ══════════════════════════ Панель статусов и обзор системы ══════════════════════════

status_panel() {
  local s ports pass txt

  if cmd_exists sshd; then
    s="$(sshd_effective permitrootlogin)"
    ports="$(detect_ssh_ports)"
    pass="$(sshd_effective passwordauthentication)"
    if [[ $pass == yes ]]; then pass=да; elif [[ $pass == no ]]; then pass=нет; else pass="?"; fi
    txt="порт ${ports} · пароль: ${pass}"
    if [[ $s == no ]]; then printf '  %-10s %s\n' "SSH" "$(badge ok "root запрещён · $txt")"
    else printf '  %-10s %s\n' "SSH" "$(badge warn "root разрешён · $txt")"; fi
  else
    printf '  %-10s %s\n' "SSH" "$(badge off 'sshd не найден')"
  fi

  if ! cmd_exists ufw; then printf '  %-10s %s\n' "UFW" "$(badge off 'не установлен')"
  elif ufw_is_active; then printf '  %-10s %s\n' "UFW" "$(badge ok 'активен')"
  else printf '  %-10s %s\n' "UFW" "$(badge warn 'установлен, выключен')"; fi

  if ! cmd_exists nft; then printf '  %-10s %s\n' "nftables" "$(badge off 'не установлен')"
  elif service_active nftables; then printf '  %-10s %s\n' "nftables" "$(badge ok 'активен')"
  else printf '  %-10s %s\n' "nftables" "$(badge warn 'установлен, служба не запущена')"; fi

  if ! cmd_exists fail2ban-client; then printf '  %-10s %s\n' "Fail2ban" "$(badge off 'не установлен')"
  elif service_active fail2ban; then printf '  %-10s %s\n' "Fail2ban" "$(badge ok 'работает')"
  else printf '  %-10s %s\n' "Fail2ban" "$(badge warn 'установлен, не запущен')"; fi

  if ! cmd_exists docker; then printf '  %-10s %s\n' "Docker" "$(badge off 'не установлен')"
  elif service_active docker; then printf '  %-10s %s\n' "Docker" "$(badge ok 'работает')"
  else printf '  %-10s %s\n' "Docker" "$(badge warn 'установлен, не запущен')"; fi

  local rs
  rs="$(remna_panel_state)"
  printf '  %-10s %s\n' "Remnanode" "$(badge "${rs%%|*}" "${rs#*|}")"

  if warp_detected; then printf '  %-10s %s\n' "WARP" "$(badge ok 'обнаружен')"
  else printf '  %-10s %s\n' "WARP" "$(badge off 'не обнаружен')"; fi

  local cc swp lvl=ok
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  swp="$(free -h 2>/dev/null | awk '/^Swap:/ {print $2}')"
  if [[ $cc == bbr ]]; then txt="BBR вкл"; else txt="BBR выкл"; lvl=warn; fi
  if [[ -n $swp && $swp != 0B ]]; then txt+=" · swap $swp"; else txt+=" · swap нет"; lvl=warn; fi
  if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
    txt+=" · автообновл. вкл"
  else
    txt+=" · автообновл. выкл"; lvl=warn
  fi
  printf '  %-10s %s\n' "Tuning" "$(badge "$lvl" "$txt")"
}

mod_overview() {
  header "9. Обзор системы"
  printf '  %-10s %s\n' "Kernel" "$(uname -r)"
  printf '  %-10s %s\n' "Uptime" "$(uptime -p 2>/dev/null | sed 's/^up //')"
  printf '  %-10s %s\n' "IP" "$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '  %-10s %s\n' "Memory" "$(free -h | awk '/^Mem:/ {print $3 " / " $2}')"
  printf '  %-10s %s\n' "Disk /" "$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
  hr
  status_panel
  hr
  info "Лог действий скрипта: $LOG_FILE"
  pause
}

# ══════════════════════════ Главное меню и точка входа ══════════════════════════

main_menu() {
  while true; do
    header "Главное меню"
    if (( ! UI_COMPACT )); then
      status_panel
      hr
    fi
    if [[ -n $UPDATE_AVAILABLE ]]; then
      printf '  %s▲ Доступна новая версия скрипта: %s → %s (пункт 12 → 1)%s\n' "$C_YELLOW" "$APP_VERSION" "$UPDATE_AVAILABLE" "$C_RESET"
      hr
    fi
    menu_item d "Dashboard — состояние сервера"
    menu_item s "Service Manager — службы systemd"
    echo
    menu_item 1 "Пользователь с sudo"
    menu_item 2 "SSH: root, ключи, порт"
    menu_item 3 "UFW (файрвол)"
    menu_item 4 "nftables"
    menu_item 5 "Fail2ban"
    menu_item 6 "Docker"
    menu_item 7 "Remnanode"
    menu_item 8 "WARP Native"
    menu_item 9 "Оптимизация и обслуживание"
    menu_item 10 "Мастер быстрой настройки"
    menu_item 11 "Обзор системы"
    menu_item 12 "Сам скрипт (обновление, установка)"
    menu_item 13 "Профили серверов"
    menu_item 14 "Диагностика сети (speedtest, ping)"
    menu_item 0 "Выход"
    echo; read_choice
    case $CHOICE in
      d|D|в|В) mod_dashboard ;;
      s|S|ы|Ы) menu_services ;;
      1)  mod_user ;;
      2)  menu_ssh ;;
      3)  menu_ufw ;;
      4)  menu_nft ;;
      5)  menu_f2b ;;
      6)  menu_docker ;;
      7)  menu_remna ;;
      8)  mod_warp ;;
      9)  menu_maint ;;
      10) mod_wizard ;;
      11) mod_overview ;;
      12) menu_self ;;
      13) menu_profiles ;;
      14) menu_net ;;
      0|q|Q) echo; ok "Пока!"; exit 0 ;;
      *)  warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

main() {
  case "${1:-}" in
    --install)  self_install; exit $? ;;
    --update)   check_os; mod_update; exit 0 ;;
    --watchdog) watchdog_run; exit $? ;;
    --dashboard) os_pretty_init; dash_render 1; exit 0 ;;
  esac
  check_os
  log INFO "Запуск ${APP_NAME} ${APP_VERSION} (${SUDO_USER:-root})"
  first_run_offer
  update_check_cached
  main_menu
}

if [[ -z ${VPSMENU_SOURCE_ONLY:-} ]]; then
  main "$@"
fi

