# ══════════════════════════ Расширенное управление пользователями ══════════════════════════
# Этот модуль загружается после 40-user.sh и расширяет его менеджер.

user_sudo_group() {
  if getent group sudo >/dev/null 2>&1; then printf '%s' sudo
  elif getent group wheel >/dev/null 2>&1; then printf '%s' wheel
  else printf '%s' sudo
  fi
}

user_password_code() {
  LC_ALL=C passwd -S "$1" 2>/dev/null | awk 'NR == 1 {print $2}'
}
user_password_status() {
  local status
  status="$(user_password_code "$1")"
  case $status in
    P) printf 'Установлен' ;;
    L|LK) printf 'Заблокирован' ;;
    NP) printf 'Без пароля' ;;
    *) printf 'Неизвестно' ;;
  esac
}

user_is_current_account() {
  local name=$1 current effective sudo_user
  current="$(user_login_name)"
  effective="$(id -un 2>/dev/null || true)"
  sudo_user="$(printenv SUDO_USER 2>/dev/null || true)"
  [[ $name == "$current" || $name == "$effective" || ( -n $sudo_user && $name == "$sudo_user" ) ]]
}

user_admin_count() {
  local candidate candidate_uid candidate_shell count=0
  while IFS=: read -r candidate _ candidate_uid _ _ _ candidate_shell; do
    user_is_managed_account "$candidate_uid" "$candidate_shell" || continue
    if user_is_sudo_admin "$candidate"; then count=$((count + 1)); fi
  done < <(getent passwd)
  printf '%s' "$count"
}

user_set_sudo() {
  local name=$1 status group groups found=0 admin_count
  status="$(user_sudo_status "$name")"
  groups="$(id -nG "$name" 2>/dev/null || true)"
  if [[ $status != yes ]]; then
    group="$(user_sudo_group)"
    if ! getent group "$group" >/dev/null 2>&1; then err "Группа $group не найдена."; return 1; fi
    if usermod -aG "$group" "$name"; then
      ok "'$name' добавлен в группу $group. Новые права вступят в силу при следующем входе."
      return 0
    fi
    err "Не удалось добавить '$name' в группу $group."
    return 1
  fi
  admin_count="$(user_admin_count)"
  if (( admin_count <= 1 )); then err "Нельзя забрать sudo у последнего обычного администратора."; return 1; fi
  for group in sudo wheel; do
    case " $groups " in
      *" $group "*)
        found=1
        if ! gpasswd -d "$name" "$group"; then err "Не удалось удалить '$name' из группы $group."; return 1; fi
        ;;
    esac
  done
  if (( ! found )); then
    warn "'$name' получает sudo не через группы. Проверь отдельные правила /etc/sudoers."
    return 1
  fi
  if user_is_sudo_admin "$name"; then
    warn "Группы sudo/wheel очищены, но у '$name' остались права через sudoers или другое правило."
  else
    ok "Права через группы sudo/wheel у '$name' отозваны."
  fi
}

user_reset_password() {
  local name=$1
  info "Пароль вводится интерактивно командой passwd и не сохраняется скриптом."
  if passwd "$name"; then ok "Пароль пользователя '$name' обновлён."
  else err "Не удалось изменить пароль '$name'."; return 1
  fi
}

user_toggle_password_lock() {
  local name=$1 status
  status="$(user_password_code "$name")"
  case $status in
    L|LK)
      if passwd -u "$name"; then
        status="$(user_password_code "$name")"
        if [[ $status == NP ]]; then
          passwd -l "$name" >/dev/null 2>&1 || true
          err "У аккаунта нет установленного пароля. Блокировка восстановлена; сначала задай пароль."
          return 1
        fi
        if [[ $status == P ]]; then ok "Парольная блокировка '$name' снята."
        else err "Не удалось подтвердить снятие блокировки (статус: $status)."; return 1
        fi
      else
        err "Не удалось разблокировать пароль. Возможно, у аккаунта нет действующего пароля."
        return 1
      fi
      ;;
    P|NP)
      if user_is_current_account "$name"; then err "Нельзя блокировать пароль текущего пользователя."; return 1; fi
      if passwd -l "$name"; then
        ok "Пароль '$name' заблокирован. Вход по SSH-ключу этим действием не отключается."
      else
        err "Не удалось заблокировать пароль '$name'."; return 1
      fi
      ;;
    *) err "Не удалось определить состояние пароля '$name' (статус: $status)."; return 1 ;;
  esac
}

user_add_ssh_key() {
  local name=$1 key
  if ! declare -F ssh_addkey_apply >/dev/null 2>&1; then err "Модуль добавления SSH-ключей недоступен."; return 1; fi
  hint "Вставь именно публичный ключ из файла .pub. Приватный ключ никогда не отправляй."
  ask "Публичный SSH-ключ одной строкой (Enter — отмена)"
  key=$ASK_RESULT
  if [[ -z $key ]]; then info "Отменено."; return 0; fi
  ssh_addkey_apply "$name" "$key"
}

user_list_accounts() {
  local name uid home shell sudo_state password_state marker current index=0
  current="$(user_login_name)"
  printf '  %-3s %-16s %-6s %-7s %-15s %s\n' "#" "Пользователь" "UID" "sudo" "Пароль" "Домашний каталог"
  printf '  %-3s %-16s %-6s %-7s %-15s %s\n' "---" "----------------" "------" "-------" "---------------" "----------------"
  while IFS=: read -r name _ uid _ _ home shell; do
    user_is_managed_account "$uid" "$shell" || continue
    index=$((index + 1))
    sudo_state="$(user_sudo_status "$name")"
    password_state="$(user_password_status "$name")"
    marker=""
    [[ $name == "$current" ]] && marker=" ← текущий"
    case $sudo_state in yes) sudo_state="да" ;; no) sudo_state="нет" ;; *) sudo_state="?" ;; esac
    printf '  %-3s %-16s %-6s %-7s %-15s %s%s\n' "$index" "$name" "$uid" "$sudo_state" "$password_state" "$home" "$marker"
  done < <(getent passwd)
  (( index > 0 ))
}

user_pick_account() {
  local title name uid home shell choice index=0 count=0
  local -a names=()
  USER_PICKED=""
  title=$1
  [[ -n $title ]] || title="Выбор пользователя"
  header "$title"
  while IFS=: read -r name _ uid _ _ home shell; do
    user_is_managed_account "$uid" "$shell" || continue
    names+=("$name")
    count=$((count + 1))
  done < <(getent passwd)
  if (( count == 0 )); then warn "Обычных интерактивных пользователей не найдено."; pause; return 1; fi
  printf '  %-3s %-18s %-8s %-15s %s\n' "#" "Пользователь" "sudo" "Пароль" "Домашний каталог"
  printf '  %-3s %-18s %-8s %-15s %s\n' "---" "------------------" "--------" "---------------" "----------------"
  while (( index < count )); do
    name=${names[$index]}
    case $(user_sudo_status "$name") in yes) choice="да" ;; no) choice="нет" ;; *) choice="?" ;; esac
    printf '  %-3s %-18s %-8s %-15s %s\n' "$((index + 1))" "$name" "$choice" "$(user_password_status "$name")" "$(getent passwd "$name" | cut -d: -f6)"
    index=$((index + 1))
  done
  echo
  ask "Номер пользователя (Enter — отмена)"
  choice=$ASK_RESULT
  if [[ -z $choice ]]; then info "Отменено."; return 1; fi
  if [[ ! $choice =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then err "Нет пользователя с таким номером."; return 1; fi
  USER_PICKED=${names[$((choice - 1))]}
}

user_delete_account() {
  local name=$1 entry uid home shell admin_count
  local remove_home=0
  entry="$(getent passwd "$name" 2>/dev/null)"
  [[ -n $entry ]] || { err "Пользователь '$name' не найден."; return 1; }
  IFS=: read -r name _ uid _ _ home shell <<<"$entry"
  if [[ $name == root || $uid == 0 ]]; then err "Удаление root и любых аккаунтов с UID 0 запрещено."; return 1; fi
  if ! user_is_managed_account "$uid" "$shell"; then err "Это системная или неинтерактивная учётная запись. Удаление запрещено."; return 1; fi
  if user_is_current_account "$name"; then err "Нельзя удалить пользователя текущей сессии или пользователя, от имени которого запущен sudo."; return 1; fi
  if user_has_active_session "$name"; then err "У '$name' есть активная сессия. Заверши её вручную и повтори попытку."; return 1; fi
  if ps -u "$uid" -o pid= 2>/dev/null | grep -E '[0-9]' >/dev/null; then
    err "У '$name' ещё работают процессы. Останови их вручную и повтори попытку."
    return 1
  fi
  admin_count="$(user_admin_count)"
  if user_is_sudo_admin "$name" && (( admin_count <= 1 )); then
    err "Это последний обычный пользователь с правами sudo. Сначала создай и проверь другого администратора."
    return 1
  fi
  echo
  warn "Будет удалена учётная запись '$name' (UID $uid)."
  hint "Файлы вне домашнего каталога автоматически удаляться не будут."
  if confirm "Также удалить домашний каталог $home?" N; then remove_home=1; fi
  if ! confirm_word "Для подтверждения удаления" "delete"; then info "Удаление отменено."; return 1; fi
  if (( remove_home )); then
    if command -v deluser >/dev/null 2>&1; then
      if deluser --remove-home "$name"; then ok "Пользователь '$name' удалён."; else err "Не удалось удалить '$name'."; return 1; fi
    else
      if userdel -r "$name"; then ok "Пользователь '$name' удалён."; else err "Не удалось удалить '$name'."; return 1; fi
    fi
  else
    if command -v deluser >/dev/null 2>&1; then
      if deluser "$name"; then ok "Пользователь '$name' удалён."; else err "Не удалось удалить '$name'."; return 1; fi
    else
      if userdel "$name"; then ok "Пользователь '$name' удалён."; else err "Не удалось удалить '$name'."; return 1; fi
    fi
  fi
}

user_show_details() {
  local name=$1 entry uid home shell sudo_state
  entry="$(getent passwd "$name" 2>/dev/null)" || return 1
  [[ -n $entry ]] || return 1
  IFS=: read -r name _ uid _ _ home shell <<<"$entry"
  sudo_state="$(user_sudo_status "$name")"
  case $sudo_state in yes) sudo_state="Да" ;; no) sudo_state="Нет" ;; *) sudo_state="Неизвестно" ;; esac
  ui_kv "Пользователь" "$name" 14
  ui_kv "UID" "$uid" 14
  ui_kv "Вход" "$(user_login_name)" 14
  ui_kv "Выполняется" "$(id -un 2>/dev/null || echo unknown)" 14
  ui_kv "sudo" "$sudo_state" 14
  ui_kv "Пароль" "$(user_password_status "$name")" 14
  ui_kv "Домашний каталог" "$home" 14
  ui_kv "Shell" "$shell" 14
}

mod_user_list() {
  header "Пользователи сервера"
  ui_kv "Вход" "$(user_login_name)" 10
  ui_kv "Выполняется" "$(id -un 2>/dev/null || echo unknown)" 10
  echo
  user_list_accounts || warn "Список пользователей пуст."
  echo
  hint "passwd -S: P — пароль установлен, L — заблокирован, NP — пароль отсутствует."
  hint "Блокировка пароля не отключает вход по SSH-ключу."
  pause
}

mod_user_account_menu() {
  local name=$1 status
  while true; do
    header "Управление пользователем"
    user_show_details "$name" || { err "Пользователь '$name' больше не существует."; pause; return 1; }
    echo
    menu_item 1 "Сбросить пароль"
    menu_item 2 "Выдать / забрать sudo"
    status="$(user_password_code "$name")"
    case $status in L|LK) menu_item 3 "Разблокировать пароль" ;; *) menu_item 3 "Заблокировать пароль" ;; esac
    menu_item 4 "Добавить SSH-ключ"
    menu_item 5 "Удалить пользователя"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) user_reset_password "$name"; pause ;;
      2) user_set_sudo "$name"; pause ;;
      3) user_toggle_password_lock "$name"; pause ;;
      4) user_add_ssh_key "$name"; pause ;;
      5) user_delete_account "$name"; pause; return 0 ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

mod_user_manager() {
  while true; do
    header "Менеджер пользователей"
    ui_kv "Текущий вход" "$(user_login_name)" 14
    ui_kv "Эффективный" "$(id -un 2>/dev/null || echo unknown)" 14
    echo
    menu_item 1 "Создать пользователя с sudo"
    menu_item 2 "Список пользователей"
    menu_item 3 "Управление пользователем"
    menu_item 4 "Удалить пользователя"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_user_create ;;
      2) mod_user_list ;;
      3) if user_pick_account "Выбор пользователя"; then mod_user_account_menu "$USER_PICKED"; fi ;;
      4) if user_pick_account "Выбор пользователя для удаления"; then user_delete_account "$USER_PICKED"; pause; fi ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
mod_user() { mod_user_manager; }
