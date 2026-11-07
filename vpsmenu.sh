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
#          мастер быстрой настройки · самообновление из GitHub
#  Лог действий:   /var/log/vpsmenu.log
#
#  Намеренно без `set -e`: в интерактивном меню каждая ошибка проверяется явно,
#  чтобы одна неудачная команда не выкидывала из скрипта целиком.

set -uo pipefail

# ══════════════════════════ Константы ══════════════════════════
readonly APP_NAME="vpsmenu"
readonly APP_VERSION="2.0.0"
readonly INSTALL_PATH="/usr/local/bin/${APP_NAME}"
readonly LOG_FILE="/var/log/${APP_NAME}.log"

readonly REMNA_DIR="/opt/remnanode"
readonly REMNA_COMPOSE="${REMNA_DIR}/docker-compose.yml"

readonly DOCKER_URL="https://get.docker.com"
readonly WARP_URL="https://raw.githubusercontent.com/distillium/warp-native/main/install.sh"

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSH_DROPIN="/etc/ssh/sshd_config.d/00-disable-root-login.conf"
readonly F2B_JAIL="/etc/fail2ban/jail.d/sshd.local"
readonly USERNAME_RE='^[a-z_][a-z0-9_-]{0,31}$'

readonly CONF_FILE="/etc/${APP_NAME}.conf"
readonly BACKUP_DIR="/var/backups/${APP_NAME}"
readonly STATE_DIR="/var/lib/${APP_NAME}"
readonly SSH_DROPIN_PORT="/etc/ssh/sshd_config.d/10-${APP_NAME}-port.conf"
readonly SSH_DROPIN_AUTH="/etc/ssh/sshd_config.d/00-${APP_NAME}-auth.conf"
readonly DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
readonly REMNA_CONTAINER="remnanode"
readonly SWAPFILE="/swapfile"
readonly SWAP_SYSCTL="/etc/sysctl.d/99-${APP_NAME}-swap.conf"
readonly BBR_SYSCTL="/etc/sysctl.d/99-${APP_NAME}-bbr.conf"

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

usage() {
  cat <<EOF
${APP_NAME} ${APP_VERSION} — меню настройки VPS (Ubuntu)

Использование:
  ${APP_NAME}              запустить меню
  ${APP_NAME} --install    установить скрипт в ${INSTALL_PATH}
  ${APP_NAME} --update     обновить скрипт из GitHub
  ${APP_NAME} --version    показать версию
  ${APP_NAME} --help       эта справка
EOF
}

case "${1:-}" in
  -h|--help)    usage; exit 0 ;;
  -v|--version) echo "${APP_NAME} ${APP_VERSION}"; exit 0 ;;
esac

# ══════════════════════════ Root / sudo ══════════════════════════
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1 && [[ -f $SELF ]]; then
    exec sudo -- bash "$SELF" "$@"
  fi
  echo "Нужны права root. Запусти через sudo: sudo bash vpsmenu.sh" >&2
  exit 1
fi

if [[ ${1:-} != --install && ( ! -t 0 || ! -t 1 ) ]]; then
  echo "Скрипту нужен интерактивный терминал." >&2
  exit 1
fi

# Русский текст и рамки требуют UTF-8
if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]]; then
  export LC_ALL=C.UTF-8
fi

# ══════════════════════════ Оформление ══════════════════════════
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null

log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true; }
info() { printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; log INFO "$*"; }
ok()   { printf '%s[✔]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log OK "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log WARN "$*"; }
err()  { printf '%s[✘]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log ERROR "$*"; }
step() { printf '\n%s%s▶ %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; log STEP "$*"; }
hint() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

hr() { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────" "$C_RESET"; }

header() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then clear; fi
  printf '\n  %s%sVPS MENU%s %s· v%s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$APP_VERSION" "$C_RESET"
  printf '  %s%s · %s%s\n' "$C_DIM" "$OS_PRETTY" "$(hostname)" "$C_RESET"
  hr
  if [[ -n ${1:-} ]]; then
    printf '  %s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
    hr
  fi
}

menu_item() { printf '  %s%2s%s  %s\n' "${C_BOLD}${C_CYAN}" "$1" "$C_RESET" "$2"; }

badge() { # badge ok|warn|off "текст"
  case $1 in
    ok)   printf '%s●%s %s' "$C_GREEN" "$C_RESET" "$2" ;;
    warn) printf '%s●%s %s' "$C_YELLOW" "$C_RESET" "$2" ;;
    *)    printf '%s○ %s%s' "$C_DIM" "$2" "$C_RESET" ;;
  esac
}

# ══════════════════════════ Ввод ══════════════════════════
on_interrupt() { echo; warn "Прервано (Ctrl+C)."; exit 130; }
trap on_interrupt INT

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

pause() { read -r -p "  Нажми Enter, чтобы продолжить… " _ || true; }

read_choice() {
  read -r -p "  Выбор: " CHOICE || { echo; exit 0; }
  CHOICE="$(trim "$CHOICE")"
}

ask() { # ask "Вопрос" ["по умолчанию"] → $ASK_RESULT
  local prompt=$1 default=${2:-} answer
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

confirm() { # confirm "Вопрос" [Y|N] — Y/N по умолчанию
  local prompt=$1 def=${2:-Y} hintstr ans
  if [[ $def == Y ]]; then hintstr='Y/n'; else hintstr='y/N'; fi
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
}

confirm_word() { # confirm_word "Вопрос" "слово" — для опасных действий
  local prompt=$1 word=$2 ans
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

show_paged() { if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then less -R -F -X; else cat; fi; }

# ══════════════════════════ Утилиты системы ══════════════════════════
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

# ══════════════════════════ 1. Пользователь ══════════════════════════
mod_user() {
  header "1. Пользователь с правами sudo"
  ask_re "Имя нового пользователя" "" "$USERNAME_RE" \
    "Допустимо: a-z, 0-9, _ и -, начинать с буквы, до 32 символов."
  local user=$ASK_RESULT

  if [[ $user == root ]]; then
    err "root — не новый пользователь."; pause; return 1
  fi

  step "Создание пользователя"
  if id "$user" >/dev/null 2>&1; then
    warn "Пользователь '$user' уже существует — создание пропущено."
  else
    info "Сейчас adduser попросит задать пароль и данные (данные можно пропускать Enter)."
    if ! adduser "$user"; then
      err "adduser завершился с ошибкой."; pause; return 1
    fi
    if ! id "$user" >/dev/null 2>&1; then
      err "Пользователь не появился в системе."; pause; return 1
    fi
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
    err "Не удалось добавить в группу sudo."; pause; return 1
  fi

  step "Проверка"
  id "$user"
  echo "  groups: $(groups "$user")"
  if user_in_sudo "$user"; then
    ok "'$user' состоит в группе sudo."
  else
    err "'$user' НЕ в группе sudo."
  fi
  if sudo -l -U "$user" 2>/dev/null | grep -q 'may run the following'; then
    ok "sudoers подтверждает права sudo."
  else
    warn "sudoers не показывает прав sudo для '$user' — проверь /etc/sudoers."
  fi

  local home grp
  home="$(getent passwd "$user" | cut -d: -f6)"
  grp="$(id -gn "$user")"
  if [[ -s /root/.ssh/authorized_keys && ! -s "$home/.ssh/authorized_keys" ]]; then
    echo
    info "У root есть SSH-ключи, а у '$user' их нет."
    hint "Если на сервере вход только по ключам, без копирования ты не сможешь зайти новым пользователем."
    if confirm "Скопировать ключи root пользователю '$user'?" Y; then
      install -d -m 700 -o "$user" -g "$grp" "$home/.ssh" &&
      install -m 600 -o "$user" -g "$grp" /root/.ssh/authorized_keys "$home/.ssh/authorized_keys" &&
        ok "SSH-ключи скопированы." || err "Не удалось скопировать ключи."
    fi
  fi

  echo
  warn "Дальше НЕ закрывай эту сессию. Открой второе окно терминала и проверь:"
  hint "ssh $user@<IP-сервера>   — вход проходит"
  hint "sudo -v                  — sudo работает"
  hint "Только после этого переходи к пункту 2 (запрет входа root)."
  pause
}

# ══════════════════════════ 2. SSH ══════════════════════════
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

# ══════════════════════════ 3. UFW ══════════════════════════
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
  local detected ports p
  detected="$(detect_ssh_ports)"
  info "Порт(ы) SSH на этом сервере: $detected"
  warn "Порт SSH обязательно должен быть открыт, иначе после включения UFW ты потеряешь доступ."
  while true; do
    ask "Какие порты SSH открыть (через пробел)" "$detected"
    ports="$ASK_RESULT"
    local bad=0
    for p in $ports; do valid_port "$p" || bad=1; done
    if [[ -n $ports ]] && (( ! bad )); then break; fi
    err "Укажи номера портов от 1 до 65535 через пробел."
  done

  echo
  info "Будет выполнено: default deny incoming / allow outgoing; allow ${ports// //tcp, }/tcp; enable; logging low"
  confirm "Включить UFW?" Y || { info "Отменено."; pause; return 0; }

  ufw default deny incoming >/dev/null && ufw default allow outgoing >/dev/null &&
    ok "Политики по умолчанию: входящие закрыты, исходящие открыты." || err "Не удалось задать политики."
  for p in $ports; do
    if ufw allow "${p}/tcp" >/dev/null; then ok "Открыт порт ${p}/tcp"; else err "Не удалось открыть ${p}/tcp"; fi
  done

  if ufw --force enable >/dev/null; then ok "UFW включён."; else err "Не удалось включить UFW."; pause; return 1; fi
  ufw logging low >/dev/null && ok "Логирование: low"

  if ufw_is_active; then ok "Проверка: UFW активен."; else err "UFW не активен!"; fi
  for p in $ports; do
    if ufw_c status | grep -qE "^${p}/tcp[[:space:]]+ALLOW"; then ok "Правило для ${p}/tcp на месте."; else warn "Правило для ${p}/tcp не найдено в статусе."; fi
  done
  echo; ufw status verbose
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

# ══════════════════════════ 4. nftables ══════════════════════════
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

# ══════════════════════════ 5. Fail2ban ══════════════════════════
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

  local bak=""
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

  local out
  if ! out="$(fail2ban-client -t 2>&1)"; then
    err "Конфигурация не прошла проверку:"; echo "$out"
    if [[ -n $bak ]]; then cp -a "$bak" "$F2B_JAIL" && warn "Восстановлена предыдущая версия."; else rm -f "$F2B_JAIL"; warn "Новый файл удалён."; fi
    return 1
  fi
  ok "Проверка конфигурации (fail2ban-client -t) пройдена."

  if ! systemctl restart fail2ban; then
    err "Не удалось перезапустить fail2ban. Смотри: journalctl -u fail2ban"
    return 1
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    fail2ban-client ping >/dev/null 2>&1 && break
    sleep 1
  done
  if fail2ban-client ping >/dev/null 2>&1; then ok "fail2ban перезапущен и отвечает."; else err "fail2ban не отвечает после перезапуска."; return 1; fi

  echo; fail2ban-client status sshd
}

mod_f2b_setup() {
  header "5. Fail2ban: установка и настройка"
  if is_pkg_installed fail2ban; then
    ok "fail2ban уже установлен: $(fail2ban-client --version 2>/dev/null | head -n 1)"
  else
    apt_install fail2ban python3-systemd || { pause; return 1; }
    ok "fail2ban установлен."
  fi

  if ! service_enabled fail2ban; then systemctl enable fail2ban >/dev/null 2>&1 && ok "Автозапуск включён."; fi
  if ! service_active fail2ban; then
    systemctl start fail2ban && ok "fail2ban запущен." || { err "Не удалось запустить fail2ban."; pause; return 1; }
    sleep 2
  fi

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

# ══════════════════════════ 6. Docker ══════════════════════════
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

  ensure_curl || { pause; return 1; }

  local tmp rc
  tmp="$(mktemp)"
  step "Скачиваю установочный скрипт"
  if ! download "$DOCKER_URL" "$tmp"; then
    err "Не удалось скачать $DOCKER_URL (проверь интернет, DNS, доступность сайта)."
    rm -f "$tmp"; pause; return 1
  fi
  ok "Скачано."

  step "Устанавливаю Docker (это займёт пару минут)"
  sh "$tmp"; rc=$?
  rm -f "$tmp"
  if (( rc != 0 )); then
    err "Установка завершилась с ошибкой (код $rc). Смотри вывод выше."
    pause; return 1
  fi

  systemctl enable --now docker >/dev/null 2>&1
  if cmd_exists docker && service_active docker; then
    ok "Docker установлен: $(docker --version)"
    docker compose version >/dev/null 2>&1 && ok "Compose: $(docker compose version)"
  else
    err "Docker установлен, но служба не запущена. Смотри: journalctl -u docker"
    pause; return 1
  fi

  if confirm "Проверить работу тестовым контейнером hello-world?" Y; then
    if docker run --rm hello-world >/dev/null 2>&1; then ok "Тестовый контейнер отработал."; else err "Тестовый контейнер не запустился."; fi
  fi
  pause
}

# ══════════════════════════ 7. Remnanode ══════════════════════════
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

rcompose() { (cd "$REMNA_DIR" && docker compose "$@"); }

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
  if rcompose down; then ok "Остановлено."; else err "Не удалось остановить."; fi
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
      0)  return 0 ;;
      *)  warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

# ══════════════════════════ 8. WARP Native ══════════════════════════
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

# ══════════════════════════ 9. Обзор системы ══════════════════════════
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

  if [[ -s $REMNA_COMPOSE ]] && cmd_exists docker && service_active docker; then
    s="$(rcompose ps --status running -q 2>/dev/null | wc -l)"
    if (( s > 0 )); then printf '  %-10s %s\n' "Remnanode" "$(badge ok "запущен (контейнеров: $s)")"
    else printf '  %-10s %s\n' "Remnanode" "$(badge warn 'настроен, не запущен')"; fi
  elif [[ -s $REMNA_COMPOSE ]]; then
    printf '  %-10s %s\n' "Remnanode" "$(badge warn 'настроен, Docker не работает')"
  else
    printf '  %-10s %s\n' "Remnanode" "$(badge off 'не настроен')"
  fi

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

# ══════════════════════════ 10. Сам скрипт ══════════════════════════
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

# ══════════════════════════ Служебные: apt, конфиг, бэкапы, версии ══════════════════════════
apt_run() { DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=120 "$@"; }

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

# ══════════════════════════ Обновление скрипта из GitHub ══════════════════════════
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

# ══════════════════════════ SSH: ключи, пароль, порт ══════════════════════════
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
  local key=$ASK_RESULT fp
  if [[ -z $key ]]; then info "Отменено."; pause; return 0; fi
  if [[ $key == -----* ]]; then
    err "Это ПРИВАТНЫЙ ключ. Его нельзя никуда вставлять — нужен публичный (файл .pub)."
    pause; return 1
  fi
  if ! fp="$(pubkey_fingerprint "$key")"; then
    err "Это не похоже на публичный SSH-ключ (проверка ssh-keygen не прошла)."
    pause; return 1
  fi
  local home grp file
  home="$(getent passwd "$user" | cut -d: -f6)"
  grp="$(id -gn "$user")"
  file="$home/.ssh/authorized_keys"
  if ! install -d -m 700 -o "$user" -g "$grp" "$home/.ssh"; then
    err "Не удалось создать $home/.ssh"; pause; return 1
  fi
  touch "$file" && chown "$user:$grp" "$file" && chmod 600 "$file"
  if grep -qxF "$key" "$file"; then
    warn "Такой ключ у '$user' уже есть."
  elif printf '%s\n' "$key" >>"$file"; then
    ok "Ключ добавлен пользователю '$user'."
  else
    err "Не удалось записать ключ."; pause; return 1
  fi
  info "Отпечаток: $fp"
  hint "Проверь вход по ключу в отдельном окне, прежде чем отключать пароль."
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

# ══════════════════════════ Docker: логи, очистка, ресурсы ══════════════════════════
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

  install -d -m 0755 "$(dirname "$DOCKER_DAEMON_JSON")"
  local bak=""
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
    pause; return 1
  fi
  ok "daemon.json обновлён."

  if systemctl restart docker; then
    ok "Docker перезапущен."
    info "Драйвер логов: $(docker info --format '{{.LoggingDriver}}' 2>/dev/null)"
  else
    err "Docker не запустился с новой конфигурацией — возвращаю прежнюю."
    if [[ -n $bak ]]; then cp -a "$bak" "$DOCKER_DAEMON_JSON"; else rm -f "$DOCKER_DAEMON_JSON"; fi
    systemctl restart docker
    pause; return 1
  fi
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

# ══════════════════════════ Remnanode: xlogs, shell, бэкапы ══════════════════════════
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

# ══════════════════════════ Оптимизация и обслуживание ══════════════════════════
mod_sys_update() {
  header "Обновление системы"
  info "Будет выполнено: apt update → apt upgrade → apt autoremove."
  hint "Твои изменённые конфиги (например sshd_config) при обновлении сохраняются."
  confirm "Продолжить?" Y || { info "Отменено."; pause; return 0; }

  step "apt update"
  if ! apt_run update -q; then err "apt update завершился с ошибкой."; pause; return 1; fi
  APT_UPDATED=1
  step "apt upgrade"
  if ! apt_run -o Dpkg::Options::=--force-confold upgrade -y -q; then
    err "apt upgrade завершился с ошибкой."; pause; return 1
  fi
  step "apt autoremove"
  apt_run autoremove -y -q
  ok "Система обновлена."

  if [[ -f /var/run/reboot-required ]]; then
    echo
    warn "Требуется перезагрузка (обновилось ядро или системные библиотеки)."
    if [[ -f /var/run/reboot-required.pkgs ]]; then sed 's/^/    /' /var/run/reboot-required.pkgs; fi
    hint "Перезагрузка прервёт SSH-сессию; контейнеры с restart: always поднимутся сами."
    if confirm "Перезагрузить сервер сейчас?" N; then
      info "Перезагружаю…"
      systemctl reboot
      sleep 5
    fi
  fi
  pause
}

mod_timezone_ntp() {
  header "Часовой пояс и NTP"
  timedatectl 2>/dev/null | sed 's/^/  /'
  echo
  local cur tz tzs
  cur="$(timedatectl show -p Timezone --value 2>/dev/null)"
  ask "Часовой пояс (например Europe/Moscow или UTC)" "${cur:-UTC}"
  tz=$ASK_RESULT
  tzs="$(timedatectl list-timezones 2>/dev/null)"
  if ! grep -qxF "$tz" <<<"$tzs"; then
    err "Неизвестный часовой пояс: $tz (полный список: timedatectl list-timezones)"; pause; return 1
  fi
  if timedatectl set-timezone "$tz"; then ok "Часовой пояс: $tz"; else err "Не удалось задать часовой пояс."; fi

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
      err "Не удалось настроить NTP."
    fi
  fi
  sleep 2
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then
    ok "Время синхронизировано."
  else
    warn "Синхронизация пока не подтверждена (может занять до минуты). Проверь позже: timedatectl"
  fi
  pause
}

mod_bbr() {
  header "Ускорение сети: BBR"
  local virt cc qd avail
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ $virt == openvz || $virt == lxc* ]]; then
    warn "Виртуализация: $virt — менять сетевые параметры ядра в таком контейнере обычно нельзя."
  fi
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  info "Сейчас: congestion_control=${cc:-?}, qdisc=${qd:-?} · ядро $(uname -r)"
  if [[ $cc == bbr ]]; then
    ok "BBR уже включён."
    [[ -f $BBR_SYSCTL ]] || hint "Он включён не этим скриптом (файла $BBR_SYSCTL нет)."
    pause; return 0
  fi
  modprobe tcp_bbr 2>/dev/null
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
  if [[ " $avail " != *" bbr "* ]]; then
    err "Ядро не поддерживает BBR (доступно: ${avail:-?})."; pause; return 1
  fi
  confirm "Включить BBR (+ fq) и сохранить после перезагрузки?" Y || { info "Отменено."; pause; return 0; }
  printf '# Создано %s\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' "$APP_NAME" >"$BBR_SYSCTL"
  echo tcp_bbr >"/etc/modules-load.d/${APP_NAME}-bbr.conf"
  sysctl -p "$BBR_SYSCTL" >/dev/null 2>&1
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]]; then
    ok "BBR включён: $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
  else
    err "Не удалось применить BBR — откатываю."
    rm -f "$BBR_SYSCTL" "/etc/modules-load.d/${APP_NAME}-bbr.conf"
  fi
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

  local mem_mb def avail_mb size size_mb fstype
  mem_mb="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
  if (( mem_mb <= 8192 )); then def=2G; else def=1G; fi
  ask_re "Размер swap (например 512M, 1G, 2G)" "$def" '^[1-9][0-9]*[MG]$' "Формат: 512M, 1G, 2G."
  size=$ASK_RESULT
  if [[ $size == *G ]]; then size_mb=$(( ${size%G} * 1024 )); else size_mb=${size%M}; fi

  avail_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  if (( size_mb + 1024 > avail_mb )); then
    err "Мало места: свободно ${avail_mb}M, нужно ${size_mb}M плюс запас 1G."; pause; return 1
  fi
  fstype="$(findmnt -no FSTYPE / 2>/dev/null)"
  if [[ $fstype == btrfs || $fstype == zfs ]]; then
    err "На $fstype swap-файл требует особой настройки — скрипт этого не делает."; pause; return 1
  fi
  confirm "Создать swap $size в $SWAPFILE?" Y || { info "Отменено."; pause; return 0; }

  step "Создаю $SWAPFILE"
  if ! fallocate -l "${size_mb}M" "$SWAPFILE" 2>/dev/null; then
    info "fallocate недоступен — использую dd (дольше)."
    if ! dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size_mb" status=none; then
      err "Не удалось создать файл."; rm -f "$SWAPFILE"; pause; return 1
    fi
  fi
  chmod 600 "$SWAPFILE"
  if ! mkswap "$SWAPFILE" >/dev/null; then err "mkswap не удался."; rm -f "$SWAPFILE"; pause; return 1; fi
  if ! swapon "$SWAPFILE"; then
    err "swapon не удался (возможно, виртуализация запрещает swap)."
    rm -f "$SWAPFILE"; pause; return 1
  fi
  ok "Swap подключён: $size"

  if ! grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab; then
    backup_prepare
    cp -a /etc/fstab "$BACKUP_DIR/fstab.$(date +%Y%m%d-%H%M%S)"
    printf '%s none swap sw 0 0\n' "$SWAPFILE" >>/etc/fstab
    ok "Запись добавлена в /etc/fstab (копия fstab в $BACKUP_DIR)."
  fi

  hint "swappiness: чем меньше, тем реже система уходит в swap. Для VPS обычно 10."
  ask_re "vm.swappiness (0–100)" "10" '^([0-9]|[1-9][0-9]|100)$' "Число от 0 до 100."
  printf '# Создано %s\nvm.swappiness = %s\n' "$APP_NAME" "$ASK_RESULT" >"$SWAP_SYSCTL"
  sysctl -p "$SWAP_SYSCTL" >/dev/null 2>&1 && ok "vm.swappiness = $ASK_RESULT"
  echo; free -h
  pause
}

mod_autoupdates() {
  header "Автообновления безопасности"
  if is_pkg_installed unattended-upgrades; then
    ok "unattended-upgrades уже установлен."
  else
    apt_install unattended-upgrades || { pause; return 1; }
  fi

  local f=/etc/apt/apt.conf.d/20auto-upgrades
  if [[ -f $f ]] && grep -q 'Unattended-Upgrade "1"' "$f"; then
    ok "Автообновления уже включены."
  else
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$f"
    ok "Автообновления включены (ставятся только обновления безопасности Ubuntu)."
  fi
  systemctl enable --now unattended-upgrades >/dev/null 2>&1

  local rf=/etc/apt/apt.conf.d/52vpsmenu-unattended.conf
  echo
  hint "Некоторые обновления (ядро) вступают в силу только после перезагрузки."
  hint "Автоперезагрузка кратко прервёт ноду, но контейнеры с restart: always поднимутся сами."
  if confirm "Разрешить автоперезагрузку ночью (04:00), когда она нужна?" N; then
    printf 'Unattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-Time "04:00";\n' >"$rf"
    ok "Автоперезагрузка включена (04:00)."
  else
    rm -f "$rf"
    info "Автоперезагрузка выключена — перезагружай вручную, когда пишет «Требуется перезагрузка»."
  fi

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

# ══════════════════════════ Главное меню ══════════════════════════
main_menu() {
  while true; do
    header "Главное меню"
    status_panel
    hr
    if [[ -n $UPDATE_AVAILABLE ]]; then
      printf '  %s▲ Доступна новая версия скрипта: %s → %s (пункт 12 → 1)%s\n' "$C_YELLOW" "$APP_VERSION" "$UPDATE_AVAILABLE" "$C_RESET"
      hr
    fi
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
    menu_item 0 "Выход"
    echo; read_choice
    case $CHOICE in
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
      0|q|Q) echo; ok "Пока!"; exit 0 ;;
      *)  warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

main() {
  case "${1:-}" in
    --install) self_install; exit $? ;;
    --update)  check_os; mod_update; exit 0 ;;
  esac
  check_os
  log INFO "Запуск ${APP_NAME} ${APP_VERSION} (${SUDO_USER:-root})"
  first_run_offer
  update_check_cached
  main_menu
}

main "$@"
