# ══════════════════════════ NetBird ══════════════════════════
# Приватная сеть на WireGuard. Установка официальным скриптом pkgs.netbird.io, подключение по setup-ключу
# (ключ вводится скрыто и передаётся клиенту через переменную окружения, в журнал и список процессов не попадает).
# Главная фишка для сервера: ограничить SSH интерфейсом NetBird — двумя безопасными шагами.

NETBIRD_INSTALL_URL="${VPSMENU_NETBIRD_URL:-https://pkgs.netbird.io/install.sh}"
NB_RAW=""

nb_installed() { cmd_exists netbird; }

nb_version() { timeout 5 netbird version 2>/dev/null | head -n 1; }

nb_service_active() { service_active netbird; }

nb_collect() { NB_RAW="$(timeout 8 netbird status 2>&1)"; }

nb_field() { awk -F': *' -v k="$1" '$1 == k {print $2; exit}' <<<"$NB_RAW"; }

nb_is_connected() { [[ "$(nb_field Management)" == Connected* ]]; }

nb_is_package() { dpkg -s netbird >/dev/null 2>&1; }

nb_iface() { # имя интерфейса NetBird (обычно wt0)
  local n
  if ip link show wt0 >/dev/null 2>&1; then echo wt0; return 0; fi
  n="$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^wt[0-9]+/ {print $2; exit}')"
  echo "${n%%@*}"
}

nb_ip() { # адрес NetBird без маски
  local i
  i="$(nb_iface)"
  [[ -n $i ]] || return 0
  ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1
}

nb_valid_key() { [[ $1 =~ ^[A-Za-z0-9-]{16,80}$ ]]; }

nb_valid_url() { [[ $1 =~ ^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; }

nb_summary() { # печатает «уровень|текст» (для Dashboard)
  if ! nb_installed; then echo "off|не установлен"; return 0; fi
  if ! nb_service_active; then echo "warn|установлен, служба не запущена"; return 0; fi
  nb_collect
  if nb_is_connected; then
    echo "ok|подключён · $(nb_field 'NetBird IP' | cut -d/ -f1) · пиров $(nb_field 'Peers count' | awk '{print $1}')"
  else
    echo "warn|не подключён к сети (NetBird → «Подключить»)"
  fi
}

# ── SSH только через NetBird ────────────────────────────────────────────────
nb_ssh_rule_present() { # nb_ssh_rule_present ПОРТ ИНТЕРФЕЙС
  local s
  s="$(ufw_c status 2>/dev/null)"
  grep -qE "^$1/tcp on $2[[:space:]]+(ALLOW|LIMIT)" <<<"$s"
}

nb_ssh_public() { # nb_ssh_public ПОРТ — доступен ли SSH-порт всем (UFW выключен или есть правило «для всех»)
  local s
  if ! ufw_is_active; then return 0; fi
  if audit_ufw_allows "$1" tcp; then return 0; fi
  s="$(ufw_c status 2>/dev/null)"
  grep -qE '^OpenSSH[[:space:]]+(ALLOW|LIMIT)[[:space:]]+Anywhere' <<<"$s"
}

nb_ssh_step1() { # nb_ssh_step1 ИНТЕРФЕЙС IP ПОРТ…
  local iface=$1 ip=$2 p first
  shift 2
  first=$1
  for p in "$@"; do
    if nb_ssh_rule_present "$p" "$iface"; then
      ok "Правило для $p/tcp на интерфейсе $iface уже есть."
    elif ufw allow in on "$iface" to any port "$p" proto tcp >/dev/null; then
      ok "UFW: SSH $p/tcp разрешён на интерфейсе $iface"
    else
      err "Не удалось добавить правило для $p/tcp."; return 1
    fi
  done
  echo
  warn "Публичный SSH пока открыт. Проверь вход через NetBird в ОТДЕЛЬНОМ окне,"
  hint "с устройства, подключённого к твоей сети NetBird:   ssh -p $first <пользователь>@$ip"
  hint "Когда вход проходит — переходи к шагу 2."
}

nb_ssh_step2() { # nb_ssh_step2 ИНТЕРФЕЙС ПОРТ…
  local iface=$1 p missing=0 s
  shift
  for p in "$@"; do
    if ! nb_ssh_rule_present "$p" "$iface"; then err "Нет правила NetBird для $p/tcp — сначала шаг 1."; missing=1; fi
  done
  if (( missing )); then return 1; fi
  echo
  warn "После этого SSH будет доступен ТОЛЬКО через NetBird. Если NetBird отключится,"
  hint "зайти можно будет лишь через консоль хостера. Текущие сессии не оборвутся."
  hint "Если у хостера есть внешний файрвол — старый публичный доступ закрой и там."
  if ! confirm_word "Вход через NetBird проверен?" "да"; then info "Отменено. Изменений не вносилось."; return 1; fi
  for p in "$@"; do
    ufw --force delete allow "${p}/tcp" >/dev/null 2>&1
    ufw --force delete limit "${p}/tcp" >/dev/null 2>&1
  done
  s="$(ufw_c status 2>/dev/null)"
  if grep -qE '^OpenSSH[[:space:]]' <<<"$s"; then ufw --force delete allow OpenSSH >/dev/null 2>&1; fi
  missing=0
  for p in "$@"; do
    if nb_ssh_public "$p"; then warn "SSH $p/tcp всё ещё доступен всем — проверь правила: ufw status numbered"; missing=1; fi
  done
  if (( ! missing )); then ok "Публичный SSH закрыт. Вход — только через NetBird ($iface)."; fi
  log INFO "SSH ограничен интерфейсом $iface"
}

nb_ssh_rollback() { # nb_ssh_rollback ПОРТ…
  local p
  for p in "$@"; do
    if ufw allow "${p}/tcp" >/dev/null; then ok "UFW: SSH $p/tcp снова открыт для всех."; else err "Не удалось открыть $p/tcp."; fi
  done
  log INFO "Публичный SSH возвращён"
}

mod_nb_ssh() {
  local iface ip p
  local -a ports=()
  header "SSH только через NetBird"
  if ! nb_installed; then err "NetBird не установлен."; pause; return 1; fi
  nb_collect
  if ! nb_is_connected; then err "NetBird не подключён к сети — сначала «Подключить»."; pause; return 1; fi
  iface="$(nb_iface)"; ip="$(nb_ip)"
  if [[ -z $iface || -z $ip ]]; then err "Не найден интерфейс или адрес NetBird."; pause; return 1; fi
  if ! cmd_exists ufw || ! ufw_is_active; then
    err "UFW не включён — без файрвола ограничить SSH нельзя."
    if confirm "Настроить UFW сейчас?" Y; then mod_ufw_setup; fi
    if ! cmd_exists ufw || ! ufw_is_active; then return 1; fi
  fi
  read -r -a ports <<<"$(detect_ssh_ports)"
  while true; do
    header "SSH только через NetBird"
    ui_kv "NetBird" "$iface · $ip" 11
    for p in "${ports[@]}"; do
      ui_kv "SSH $p" "$(nb_ssh_public "$p" && echo "${C_YELLOW}доступен всем${C_RESET}" || echo "${C_GREEN}закрыт для интернета${C_RESET}")$(nb_ssh_rule_present "$p" "$iface" && echo " · ${C_GREEN}через NetBird: да${C_RESET}" || echo " · через NetBird: нет")" 11
    done
    echo
    hint "Безопасная схема: шаг 1 добавляет правило, ты проверяешь вход, шаг 2 закрывает публичный SSH."
    echo
    menu_item 1 "Шаг 1: разрешить SSH через NetBird (публичный доступ пока остаётся)"
    menu_item 2 "Шаг 2: закрыть публичный SSH (оставить только NetBird)"
    menu_item 3 "Откатить: снова открыть SSH для всех"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) nb_ssh_step1 "$iface" "$ip" "${ports[@]}"; pause ;;
      2) nb_ssh_step2 "$iface" "${ports[@]}"; pause ;;
      3) if confirm "Открыть SSH для всех обратно?" Y; then nb_ssh_rollback "${ports[@]}"; fi; pause ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

# ── Установка, подключение, обслуживание ────────────────────────────────────
nb_install_apply() {
  if nb_installed; then ok "NetBird уже установлен: $(nb_version)"; return 0; fi
  ensure_curl || return 1
  local tmp rc
  tmp="$(mktemp)"
  step "Скачиваю установщик NetBird"
  if ! download "$NETBIRD_INSTALL_URL" "$tmp"; then
    err "Не удалось скачать $NETBIRD_INSTALL_URL (проверь интернет, DNS, доступность сайта)."
    rm -f "$tmp"; return 1
  fi
  ok "Скачано."
  step "Устанавливаю NetBird"
  sh "$tmp"; rc=$?
  rm -f "$tmp"
  if (( rc != 0 )) || ! nb_installed; then
    err "Установка не удалась (код $rc). Смотри вывод выше."; return 1
  fi
  if ! nb_service_active; then
    info "Служба netbird не запущена — устанавливаю и запускаю."
    netbird service install >/dev/null 2>&1
    netbird service start >/dev/null 2>&1
  fi
  ok "NetBird установлен: $(nb_version)"
  log INFO "NetBird установлен"
}

mod_nb_install() {
  header "NetBird: установка"
  if nb_installed; then
    ok "NetBird уже установлен: $(nb_version)"
    echo "  service: $(systemctl is-active netbird 2>/dev/null) / $(systemctl is-enabled netbird 2>/dev/null)"
    hint "Подключить к сети: пункт «Подключить к сети (setup-ключ)»."
    pause; return 0
  fi
  info "Установка официальным скриптом $NETBIRD_INSTALL_URL (репозиторий NetBird через apt)."
  confirm "Установить NetBird?" Y || { info "Отменено."; pause; return 0; }
  if confirm "Сначала показать установочный скрипт?" N; then
    local tmp
    ensure_curl || { pause; return 1; }
    tmp="$(mktemp)"
    if download "$NETBIRD_INSTALL_URL" "$tmp"; then
      show_paged <"$tmp"
      confirm "Запускать?" Y || { info "Отменено."; rm -f "$tmp"; pause; return 0; }
    fi
    rm -f "$tmp"
  fi
  nb_install_apply || { pause; return 1; }
  echo
  hint "Дальше: «Подключить к сети (setup-ключ)». Ключ создаётся в панели NetBird: Setup Keys → Create Setup Key."
  pause
}

mod_nb_connect() {
  local key="" url="" rc
  header "NetBird: подключение к сети"
  if ! nb_installed; then err "NetBird не установлен (пункт «Установить»)."; pause; return 1; fi
  nb_collect
  if nb_is_connected; then
    ok "Уже подключён: $(nb_field 'NetBird IP')"
    confirm "Переподключить с другим ключом?" N || { pause; return 0; }
  fi
  hint "Setup-ключ создаётся в панели NetBird: Setup Keys → Create Setup Key. Скрипт его нигде не сохраняет."
  if confirm "Используешь свой сервер NetBird (self-hosted)?" N; then
    ask_re "Management URL (например https://netbird.example.com:443)" "" '^https?://.+' "Нужен адрес вида https://хост:порт."
    url=$ASK_RESULT
    if ! nb_valid_url "$url"; then err "Некорректный адрес Management URL."; pause; return 1; fi
  fi
  ui_flush_input
  IFS= read -r -s -p "  Setup-ключ (ввод скрыт): " key || { echo; return 1; }
  echo
  key="$(trim "$key")"
  if ! nb_valid_key "$key"; then
    err "Это не похоже на setup-ключ (нужны латиница, цифры и дефисы, 16–80 символов)."
    key=""; pause; return 1
  fi
  if ! nb_service_active; then
    info "Служба netbird не запущена — запускаю."
    netbird service install >/dev/null 2>&1
    netbird service start >/dev/null 2>&1
    sleep 2
  fi
  step "Подключаюсь (до 90 секунд)"
  ( export NB_SETUP_KEY="$key"; if [[ -n $url ]]; then export NB_MANAGEMENT_URL="$url"; fi; exec timeout 90 netbird up )
  rc=$?
  key=""
  if (( rc != 0 )); then
    err "netbird up завершился с ошибкой (код $rc). Проверь ключ (срок, лимит использований) и адрес сервера."
    log ERROR "netbird up: код $rc"
    pause; return 1
  fi
  for _ in 1 2 3 4 5 6 7 8; do
    nb_collect
    nb_is_connected && break
    sleep 1
  done
  if nb_is_connected; then
    ok "Подключено. NetBird IP: $(nb_field 'NetBird IP')"
    log INFO "NetBird подключён"
  else
    warn "Команда выполнена, но связь с Management ещё не установлена. Проверь: netbird status"
  fi
  pause
}

mod_nb_status() {
  header "NetBird: статус"
  if ! nb_installed; then warn "NetBird не установлен."; pause; return 0; fi
  nb_collect
  ui_kv "Версия" "$(nb_version)" 11
  ui_kv "Служба" "$(systemctl is-active netbird 2>/dev/null) / автозапуск: $(systemctl is-enabled netbird 2>/dev/null)" 11
  if nb_is_connected; then ui_kv "Сеть" "${C_GREEN}подключён${C_RESET}" 11; else ui_kv "Сеть" "${C_YELLOW}не подключён${C_RESET}" 11; fi
  ui_kv "Management" "$(nb_field Management)" 11
  ui_kv "Signal" "$(nb_field Signal)" 11
  ui_kv "NetBird IP" "$(nb_field 'NetBird IP')" 11
  ui_kv "Интерфейс" "$(nb_iface)" 11
  ui_kv "Пиры" "$(nb_field 'Peers count')" 11
  echo
  if confirm "Показать подробный вывод netbird status -d?" N; then timeout 10 netbird status -d 2>&1 | show_paged; fi
  pause
}

mod_nb_toggle() {
  header "NetBird: отключить / подключить"
  if ! nb_installed; then err "NetBird не установлен."; pause; return 1; fi
  nb_collect
  if nb_is_connected; then
    warn "Отключение разорвёт доступ к серверу через NetBird. Если SSH закрыт для интернета — ты потеряешь доступ."
    confirm "Отключить NetBird (netbird down)?" N || { info "Отменено."; pause; return 0; }
    if netbird down; then ok "NetBird отключён."; else err "Не удалось выполнить netbird down."; fi
  else
    info "Подключаю с сохранёнными данными (netbird up)."
    if timeout 60 netbird up; then ok "NetBird подключён."; else err "Не удалось подключиться — используй «Подключить к сети» с setup-ключом."; fi
  fi
  pause
}

mod_nb_update() {
  local before after
  header "NetBird: обновление"
  if ! nb_installed; then err "NetBird не установлен."; pause; return 1; fi
  before="$(nb_version)"
  info "Сейчас: $before"
  confirm "Обновить NetBird?" Y || { info "Отменено."; pause; return 0; }
  if nb_is_package; then
    apt_update_once || { pause; return 1; }
    if ! apt_run install --only-upgrade -y -q netbird; then err "Не удалось обновить пакет netbird."; pause; return 1; fi
    systemctl restart netbird 2>/dev/null
  else
    ensure_curl || { pause; return 1; }
    local tmp
    tmp="$(mktemp)"
    if ! download "$NETBIRD_INSTALL_URL" "$tmp"; then err "Не удалось скачать установщик."; rm -f "$tmp"; pause; return 1; fi
    netbird down >/dev/null 2>&1
    sh "$tmp" --update
    rm -f "$tmp"
    netbird up >/dev/null 2>&1
  fi
  after="$(nb_version)"
  if [[ $before == "$after" ]]; then ok "Установлена актуальная версия: $after"; else ok "Обновлено: $before → $after"; fi
  pause
}

mod_nb_logs() {
  header "NetBird: журнал"
  if ! cmd_exists journalctl; then err "journalctl недоступен."; pause; return 1; fi
  menu_item 1 "Последние 100 записей"
  menu_item 2 "В реальном времени (Ctrl+C — выход)"
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    1) journalctl -u netbird -n 100 --no-pager 2>&1 | show_paged; pause ;;
    2) run_interruptible journalctl -u netbird -n 50 -f; pause ;;
  esac
}

mod_nb_uninstall() {
  local iface p restricted=0
  local -a sshp=()
  header "NetBird: удаление"
  if ! nb_installed; then warn "NetBird не установлен."; pause; return 0; fi
  iface="$(nb_iface)"
  read -r -a sshp <<<"$(detect_ssh_ports)"
  if [[ -n $iface ]]; then
    for p in "${sshp[@]}"; do
      if nb_ssh_rule_present "$p" "$iface" && ! nb_ssh_public "$p"; then restricted=1; fi
    done
  fi
  if (( restricted )); then
    err "SSH сейчас закрыт для интернета и доступен только через NetBird."
    hint "Удаление NetBird отрежет тебя от сервера. Сначала: NetBird → «SSH только через NetBird» → «Откатить»."
    pause; return 1
  fi
  warn "NetBird будет остановлен и удалён вместе со службой."
  confirm_word "Удалить NetBird?" "да" || { info "Отменено."; pause; return 0; }
  netbird down >/dev/null 2>&1
  netbird service stop >/dev/null 2>&1
  netbird service uninstall >/dev/null 2>&1
  if nb_is_package; then
    apt_run remove --purge -y -q netbird || err "Не удалось удалить пакет netbird."
  else
    rm -f "$(command -v netbird)" && ok "Файл netbird удалён."
  fi
  if [[ -n $iface ]]; then
    for p in "${sshp[@]}"; do ufw --force delete allow in on "$iface" to any port "$p" proto tcp >/dev/null 2>&1; done
  fi
  if confirm "Удалить ещё и данные клиента (/etc/netbird, /var/lib/netbird)?" N; then rm -rf /etc/netbird /var/lib/netbird; ok "Данные удалены."; fi
  if nb_installed; then err "Команда netbird всё ещё найдена — проверь вручную."; else ok "NetBird удалён."; fi
  log INFO "NetBird удалён"
  pause
}

menu_netbird() {
  local s
  while true; do
    header "NetBird"
    s="$(nb_summary)"
    ui_kv "Состояние" "$(badge "${s%%|*}" "${s#*|}")" 11
    echo
    menu_item 1 "Статус"
    menu_item 2 "Установить"
    menu_item 3 "Подключить к сети (setup-ключ)"
    menu_item 4 "Отключить / подключить снова"
    menu_item 5 "SSH только через NetBird"
    menu_item 6 "Обновить"
    menu_item 7 "Журнал"
    menu_item 8 "Удалить"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_nb_status ;;
      2) mod_nb_install ;;
      3) mod_nb_connect ;;
      4) mod_nb_toggle ;;
      5) mod_nb_ssh ;;
      6) mod_nb_update ;;
      7) mod_nb_logs ;;
      8) mod_nb_uninstall ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
