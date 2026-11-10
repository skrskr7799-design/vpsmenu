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
