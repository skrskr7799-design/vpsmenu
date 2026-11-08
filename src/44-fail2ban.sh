# ══════════════════════════ Fail2ban ══════════════════════════

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

  f2b_write_jail "$port" "$maxretry" "$findtime" "$bantime" "$ignoreip"
}

mod_f2b_setup() {
  header "5. Fail2ban: установка и настройка"
  f2b_install_apply || { pause; return 1; }

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

f2b_install_apply() {
  if is_pkg_installed fail2ban; then
    ok "fail2ban уже установлен: $(fail2ban-client --version 2>/dev/null | head -n 1)"
  else
    apt_install fail2ban python3-systemd || return 1
    ok "fail2ban установлен."
  fi
  if ! service_enabled fail2ban; then systemctl enable fail2ban >/dev/null 2>&1 && ok "Автозапуск включён."; fi
  if ! service_active fail2ban; then
    if systemctl start fail2ban; then ok "fail2ban запущен."; else err "Не удалось запустить fail2ban."; return 1; fi
    sleep 2
  fi
}

f2b_write_jail() { # f2b_write_jail port maxretry findtime bantime ignoreip
  local port=$1 maxretry=$2 findtime=$3 bantime=$4 ignoreip=$5 bak="" out
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

  if ! out="$(fail2ban-client -t 2>&1)"; then
    err "Конфигурация не прошла проверку:"; echo "$out"
    if [[ -n $bak ]]; then cp -a "$bak" "$F2B_JAIL" && warn "Восстановлена предыдущая версия."; else rm -f "$F2B_JAIL"; warn "Новый файл удалён."; fi
    return 1
  fi
  ok "Проверка конфигурации (fail2ban-client -t) пройдена."

  if ! systemctl restart fail2ban; then
    err "Не удалось перезапустить fail2ban. Смотри: journalctl -u fail2ban"; return 1
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    fail2ban-client ping >/dev/null 2>&1 && break
    sleep 1
  done
  if fail2ban-client ping >/dev/null 2>&1; then ok "fail2ban перезапущен и отвечает."; else err "fail2ban не отвечает после перезапуска."; return 1; fi
  echo; fail2ban-client status sshd
}
