# ══════════════════════════ Системные утилиты: пакеты, службы, SSH-порты ══════════════════════════

cmd_exists()       { command -v "$1" >/dev/null 2>&1; }

is_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

service_active()   { systemctl is-active --quiet "$1" >/dev/null 2>&1; }

service_enabled()  { systemctl is-enabled --quiet "$1" >/dev/null 2>&1; }

ufw_c()            { LC_ALL=C ufw "$@"; }   # вывод ufw переводится — для разбора берём английский

ufw_is_active()    { local s; cmd_exists ufw || return 1; s="$(ufw_c status 2>/dev/null)"; grep -q '^Status: active' <<<"$s"; }   # без конвейера: grep -q при pipefail мог давать ложный отказ (SIGPIPE)

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

user_in_sudo() { local g; g="$(id -nG "$1" 2>/dev/null | tr ' ' '\n')"; grep -qx sudo <<<"$g"; }

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
