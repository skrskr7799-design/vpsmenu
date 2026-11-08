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
