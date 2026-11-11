#!/usr/bin/env bash
# Безопасные проверки функций менеджера пользователей без изменения системы.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VPSMENU_SOURCE_ONLY=1 NO_COLOR=1
export VPSMENU_LOG_FILE="$TMP/log" VPSMENU_CONF_FILE="$TMP/conf"
export VPSMENU_BACKUP_DIR="$TMP/backups" VPSMENU_STATE_DIR="$TMP/state"
export VPSMENU_PROFILE_DIR="$TMP/profiles"
source "$ROOT/vpsmenu.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }

user_is_managed_account 1000 /bin/bash || fail "обычный интерактивный аккаунт должен отображаться"
! user_is_managed_account 999 /bin/bash || fail "системный UID не должен управляться"
! user_is_managed_account 1001 /usr/sbin/nologin || fail "nologin не должен управляться"
! user_is_managed_account 1002 /bin/false || fail "false shell не должен управляться"
pass "фильтр обычных и системных аккаунтов"

id() {
  if [[ ${1:-} == -nG ]]; then
    case ${2:-} in
      groupadmin) echo "groupadmin sudo" ;;
      customadmin|noadmin) echo "${2}" ;;
      *) echo "${2:-}" ;;
    esac
  else
    command id "$@"
  fi
}
sudo() {
  case "$*" in
    *customadmin*) echo "User customadmin may run the following commands on host:"; echo "    (ALL) ALL" ;;
    *noadmin*) echo "User noadmin is not allowed to run sudo on host." ;;
  esac
  return 0
}
[[ $(user_sudo_status groupadmin) == yes ]] || fail "sudo group membership"
[[ $(user_sudo_status customadmin) == yes ]] || fail "custom sudoers rule"
[[ $(user_sudo_status noadmin) == no ]] || fail "explicit no-sudo result"
pass "определение sudo по группе и sudoers"

# Проверяем защиту последнего администратора: никакое удаление не должно запускаться.
getent() {
  if [[ ${1:-} == passwd ]]; then
    if [[ $# -eq 1 ]]; then
      printf 'root:x:0:0:root:/root:/bin/bash\nadmin:x:55000:55000::/home/admin:/bin/bash\n'
    elif [[ ${2:-} == root ]]; then
      printf 'root:x:0:0:root:/root:/bin/bash\n'
    elif [[ ${2:-} == admin ]]; then
      printf 'admin:x:55000:55000::/home/admin:/bin/bash\n'
    fi
  else
    command getent "$@"
  fi
}
user_login_name() { echo root; }
user_is_sudo_admin() { [[ $1 == admin ]]; }
user_has_active_session() { return 1; }
deluser() { fail "deluser не должен вызываться при удалении последнего sudo-администратора"; }
err() { :; }
warn() { :; }
hint() { :; }
confirm() { return 1; }
confirm_word() { return 1; }
if user_delete_account admin; then fail "удаление последнего sudo-администратора должно блокироваться"; fi
pass "защита последнего sudo-администратора"

# UID 0 блокируется до любых попыток удаления.
if user_delete_account root; then fail "удаление root должно блокироваться"; fi
pass "защита root"
echo "User manager tests: OK"
