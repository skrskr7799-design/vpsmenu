# ══════════════════════════ Пользователь с sudo ══════════════════════════

mod_user_create() {
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
  if grep -q 'may run the following' <<<"$(sudo -l -U "$user" 2>/dev/null)"; then
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

# ── Управление локальными пользователями ────────────────────────────────────
user_login_name() {
  local name="${SUDO_USER:-}"
  [[ -n $name ]] || name="$(who am i 2>/dev/null | awk 'NR==1 {print $1}')"
  [[ -n $name ]] || name="$(logname 2>/dev/null || true)"
  [[ -n $name ]] || name="$(id -un 2>/dev/null || echo root)"
  printf '%s' "$name"
}

user_is_managed_account() {
  local uid=$1 shell=$2
  [[ $uid =~ ^[0-9]+$ ]] || return 1
  (( uid >= 1000 && uid < 60000 )) || return 1
  case $shell in */nologin|*/false|/bin/sync|/usr/bin/sync|'') return 1 ;; esac
  return 0
}

user_sudo_status() {
  local name=$1 out rc
  if id -nG "$name" 2>/dev/null | tr ' ' '\n' | grep -Eq '^(sudo|wheel)$'; then
    echo yes; return 0
  fi
  command -v sudo >/dev/null 2>&1 || { echo unknown; return 0; }
  out="$(LC_ALL=C sudo -n -l -U "$name" 2>/dev/null)"; rc=$?
  if grep -qE '^User .+ may run the following commands' <<<"$out"; then echo yes
  elif grep -qiE 'not allowed to run sudo|is not allowed to run' <<<"$out"; then echo no
  elif (( rc == 0 )) && grep -qE '^\s*\([^)]*\)' <<<"$out"; then echo yes
  else echo unknown
  fi
}
user_is_sudo_admin() { [[ $(user_sudo_status "$1") == yes ]]; }

user_list_accounts() {
  local name pass uid gid gecos home shell sudo_state marker current
  current="$(user_login_name)"
  printf '  %-18s %-7s %-10s %s\n' "Пользователь" "UID" "sudo" "Домашний каталог"
  printf '  %-18s %-7s %-10s %s\n' "------------------" "-------" "----------" "----------------"
  while IFS=: read -r name pass uid gid gecos home shell; do
    user_is_managed_account "$uid" "$shell" || continue
    sudo_state="$(user_sudo_status "$name")"; marker=""
    [[ $name == "$current" ]] && marker=" ← текущий"
    case $sudo_state in yes) sudo_state="да" ;; no) sudo_state="нет" ;; *) sudo_state="неизвестно" ;; esac
    printf '  %-18s %-7s %-10s %s%s\n' "$name" "$uid" "$sudo_state" "$home" "$marker"
  done < <(getent passwd)
}

user_has_active_session() {
  local name=$1
  who 2>/dev/null | awk -v u="$name" '$1 == u {found=1} END {exit !found}' && return 0
  if command -v loginctl >/dev/null 2>&1; then
    loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$name" '$3 == u {found=1} END {exit !found}' && return 0
  fi
  return 1
}

user_delete_account() {
  local name=$1 entry uid gid gecos home shell current admin_count=0 candidate
  local remove_home=0
  entry="$(getent passwd "$name" 2>/dev/null)"
  [[ -n $entry ]] || { err "Пользователь '$name' не найден."; return 1; }
  IFS=: read -r name _ uid gid gecos home shell <<<"$entry"
  if [[ $name == root || $uid == 0 ]]; then
    err "Удаление root и любых аккаунтов с UID 0 запрещено."; return 1
  fi
  if ! user_is_managed_account "$uid" "$shell"; then
    err "Это системная или неинтерактивная учётная запись. Удаление запрещено."; return 1
  fi
  current="$(user_login_name)"
  if [[ $name == "$current" || $name == "${SUDO_USER:-}" || $name == "$(id -un 2>/dev/null)" ]]; then
    err "Нельзя удалить пользователя текущей сессии или пользователя, от имени которого запущен sudo."; return 1
  fi
  if user_has_active_session "$name"; then
    err "У '$name' есть активная сессия. Заверши её вручную и повтори попытку."; return 1
  fi
  while IFS=: read -r candidate _ uid gid gecos home shell; do
    user_is_managed_account "$uid" "$shell" || continue
    if user_is_sudo_admin "$candidate"; then admin_count=$((admin_count + 1)); fi
  done < <(getent passwd)
  if user_is_sudo_admin "$name" && (( admin_count <= 1 )); then
    err "Это последний обычный пользователь с правами sudo. Сначала создай и проверь другого администратора."; return 1
  fi
  echo
  warn "Будет удалена учётная запись '$name' (UID $uid)."
  hint "Файлы вне домашнего каталога автоматически удаляться не будут."
  if confirm "Также удалить домашний каталог $home?" N; then remove_home=1; fi
  if ! confirm_word "Для подтверждения удаления" "УДАЛИТЬ"; then info "Удаление отменено."; return 1; fi
  if (( remove_home )); then
    if command -v deluser >/dev/null 2>&1; then deluser --remove-home "$name"; else userdel -r "$name"; fi
  else
    if command -v deluser >/dev/null 2>&1; then deluser "$name"; else userdel "$name"; fi
  fi
  if [[ $? -ne 0 ]]; then err "Не удалось удалить '$name'. Проверь процессы пользователя и системные ограничения."; return 1; fi
  ok "Пользователь '$name' удалён."
}

mod_user_list() {
  header "Пользователи сервера"
  ui_kv "Вход" "$(user_login_name)" 10
  ui_kv "Выполняется" "$(id -un 2>/dev/null || echo unknown)" 10
  echo
  user_list_accounts
  echo
  hint "Права sudo определяются по группам и доступным правилам sudoers."
  pause
}

mod_user_manager() {
  while true; do
    header "Пользователи"
    ui_kv "Текущий вход" "$(user_login_name)" 14
    ui_kv "Эффективный" "$(id -un 2>/dev/null || echo unknown)" 14
    echo
    menu_item 1 "Создать пользователя с sudo"
    menu_item 2 "Список пользователей и права sudo"
    menu_item 3 "Удалить пользователя"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_user_create ;;
      2) mod_user_list ;;
      3)
        header "Удаление пользователя"
        user_list_accounts
        echo
        ask_re "Имя пользователя для удаления (Enter — отмена)" "" '^$|^[a-z_][a-z0-9_-]{0,31}$' "Недопустимое имя пользователя."
        if [[ -n $ASK_RESULT ]]; then user_delete_account "$ASK_RESULT"; pause; fi
        ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
mod_user() { mod_user_manager; }
