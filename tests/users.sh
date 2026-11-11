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


# Дополнительные проверки расширенного менеджера пользователей.
getent() {
  if [[ $1 == group && ${2:-} == sudo ]]; then
    printf 'sudo:x:27:\n'
    return 0
  fi
  if [[ $1 == passwd ]]; then
    case $# in
      1)
        printf 'root:x:0:0:root:/root:/bin/bash\n'
        printf 'admin:x:55000:55000::/home/admin:/bin/bash\n'
        printf 'guest:x:1001:1001::/home/guest:/bin/bash\n'
        ;;
      *)
        case $2 in
          root) printf 'root:x:0:0:root:/root:/bin/bash\n' ;;
          admin) printf 'admin:x:55000:55000::/home/admin:/bin/bash\n' ;;
          guest) printf 'guest:x:1001:1001::/home/guest:/bin/bash\n' ;;
        esac
        ;;
    esac
    return 0
  fi
  command getent "$@"
}
user_sudo_status() {
  case $1 in admin) echo yes ;; guest) echo no ;; *) echo unknown ;; esac
}
user_is_sudo_admin() { [[ $1 == admin ]]; }
user_is_current_account() { return 1; }
user_has_active_session() { return 1; }
ps() { return 0; }

TEST_PASSWD_STATE=P
TEST_UNLOCK_TO_NP=0
passwd() {
  if [[ $1 == -S ]]; then
    printf '%s %s 2026-01-01 0 99999 7 -1\n' "$2" "$TEST_PASSWD_STATE"
  elif [[ $1 == -l ]]; then
    TEST_PASSWD_STATE=L
  elif [[ $1 == -u ]]; then
    if (( TEST_UNLOCK_TO_NP )); then TEST_PASSWD_STATE=NP; else TEST_PASSWD_STATE=P; fi
  fi
  return 0
}
[[ $(user_password_status guest) == "Установлен" ]] || fail "passwd -S: P"
TEST_PASSWD_STATE=L
[[ $(user_password_status guest) == "Заблокирован" ]] || fail "passwd -S: L"
TEST_PASSWD_STATE=NP
[[ $(user_password_status guest) == "Без пароля" ]] || fail "passwd -S: NP"
TEST_PASSWD_STATE=P
pass "отображение статуса пароля P/L/NP"

if user_toggle_password_lock guest; then
  [[ $TEST_PASSWD_STATE == L ]] || fail "passwd -l должен блокировать пароль"
else
  fail "блокировка пароля должна пройти"
fi
if user_toggle_password_lock guest; then
  [[ $TEST_PASSWD_STATE == P ]] || fail "passwd -u должен разблокировать пароль"
else
  fail "разблокировка пароля должна пройти"
fi
pass "блокировка и разблокировка пароля"

TEST_UNLOCK_TO_NP=1
if user_toggle_password_lock guest; then fail "разблокировка NP не должна проходить"; fi
[[ $TEST_PASSWD_STATE == L ]] || fail "после неудачной разблокировки NP пароль должен остаться заблокированным"
TEST_UNLOCK_TO_NP=0
pass "защита от разблокировки аккаунта без пароля"

USERMOD_CALLED=0
usermod() { USERMOD_CALLED=1; [[ $1 == -aG && $2 == sudo && $3 == guest ]]; }
if user_set_sudo guest; then
  [[ $USERMOD_CALLED == 1 ]] || fail "выдача sudo должна вызвать usermod -aG"
else
  fail "выдача sudo должна пройти"
fi
pass "выдача sudo через существующую группу"

GPASSWD_CALLED=0
gpasswd() { GPASSWD_CALLED=1; return 0; }
if user_set_sudo admin; then fail "нельзя отзывать sudo у последнего администратора"; fi
[[ $GPASSWD_CALLED == 0 ]] || fail "gpasswd не должен запускаться для последнего администратора"
pass "защита последнего sudo-администратора при отзыве прав"

ask() { ASK_RESULT=2; }
if user_pick_account "Тест выбора"; then
  [[ $USER_PICKED == guest ]] || fail "выбор по номеру должен вернуть guest"
else
  fail "выбор пользователя по номеру должен пройти"
fi
pass "выбор пользователя по номеру"

DELETE_TOKEN=""
confirm() { return 1; }
confirm_word() { DELETE_TOKEN=$2; [[ $2 == delete ]]; }
deluser() { return 0; }
if user_delete_account guest; then
  [[ $DELETE_TOKEN == delete ]] || fail "удаление должно требовать ASCII-токен delete"
else
  fail "тест удаления обычного пользователя должен пройти"
fi
pass "подтверждение удаления не зависит от русской локали"
