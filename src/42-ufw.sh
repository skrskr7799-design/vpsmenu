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
