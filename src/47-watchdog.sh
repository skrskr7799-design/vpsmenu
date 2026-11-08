# ══════════════════════════ Watchdog для Remnanode ══════════════════════════

wd_state_get() { kv_get "$REMNA_STATE" "$1"; }

wd_state_set() { kv_set "$REMNA_STATE" "$1" "$2"; }

wd_state_del() { kv_del "$REMNA_STATE" "$1"; }

wd_autorestart_on() { [[ "$(conf_get WATCHDOG_AUTORESTART)" == 1 ]]; }

wd_interval() {
  local v
  v="$(conf_get WATCHDOG_INTERVAL)"
  printf '%s' "${v:-1}"
}

wd_max_attempts() {
  local v
  v="$(conf_get WATCHDOG_MAX_ATTEMPTS)"
  printf '%s' "${v:-3}"
}

wd_enabled() { systemctl is-enabled --quiet "${APP_NAME}-watchdog.timer" 2>/dev/null; }

watchdog_run() { # вызывается таймером systemd: vpsmenu --watchdog
  [[ -s $REMNA_COMPOSE ]] || return 0
  install -d -m 0755 "$STATE_DIR" 2>/dev/null
  exec 9>"$STATE_DIR/watchdog.lock"
  flock -n 9 || return 0

  local now prev att max
  now="$(date +%s)"
  wd_state_set last_check "$now"

  if [[ -f $REMNA_STOP_FLAG ]]; then
    wd_state_set status stopped
    wd_state_del down_since
    return 0
  fi

  prev="$(wd_state_get status)"
  if remna_is_running; then
    if [[ $prev == down || $prev == failed ]]; then log INFO "Remnanode снова работает."; fi
    wd_state_set status up
    wd_state_del down_since
    wd_state_set attempts 0
    return 0
  fi

  if [[ $prev != down && $prev != failed ]]; then
    wd_state_set status down
    wd_state_set down_since "$now"
    wd_state_set attempts 0
    log WARN "Remnanode не работает (обнаружено watchdog)."
  fi
  wd_autorestart_on || return 0

  att="$(wd_state_get attempts)"
  att=${att:-0}
  max="$(wd_max_attempts)"
  if (( att >= max )); then
    wd_state_set status failed
    return 0
  fi
  att=$((att + 1))
  wd_state_set attempts "$att"
  log WARN "Авто-перезапуск Remnanode: попытка $att из $max."
  service_active docker || systemctl start docker
  (cd "$REMNA_DIR" && docker compose up -d >/dev/null 2>&1)
  sleep 5
  if remna_is_running; then
    wd_state_set status up
    wd_state_del down_since
    wd_state_set attempts 0
    wd_state_set last_restart "$now"
    wd_state_set restarts_total "$(( $(wd_state_get restarts_total || echo 0) + 1 ))"
    log OK "Remnanode перезапущен watchdog."
  else
    log ERROR "Авто-перезапуск Remnanode не помог (попытка $att из $max)."
  fi
}

wd_write_units() {
  if [[ ! -x $INSTALL_PATH ]]; then
    err "Скрипт не установлен в систему ($INSTALL_PATH) — watchdog запускает его по расписанию."
    hint "Сначала: Сам скрипт → «Установить эту копию в систему»."
    return 1
  fi
  cat >"$WD_SERVICE" <<EOF
[Unit]
Description=${APP_NAME}: проверка Remnanode
After=docker.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --watchdog
EOF
  cat >"$WD_TIMER" <<EOF
[Unit]
Description=${APP_NAME}: периодическая проверка Remnanode

[Timer]
OnBootSec=2min
OnUnitActiveSec=$(wd_interval)min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

watchdog_enable() { # watchdog_enable [АВТОПЕРЕЗАПУСК 0|1 | keep]
  wd_write_units || return 1
  if [[ ${1:-keep} != keep ]]; then conf_set WATCHDOG_AUTORESTART "$1"; fi
  if [[ -z "$(conf_get WATCHDOG_AUTORESTART)" ]]; then conf_set WATCHDOG_AUTORESTART 0; fi
  if systemctl enable --now "${APP_NAME}-watchdog.timer" >/dev/null 2>&1; then
    ok "Watchdog включён: проверка каждые $(wd_interval) мин."
    if wd_autorestart_on; then info "Автоперезапуск: включён."; else info "Автоперезапуск: выключен (нода только помечается в меню как упавшая)."; fi
  else
    err "Не удалось включить таймер ${APP_NAME}-watchdog.timer."; return 1
  fi
}

watchdog_disable() {
  systemctl disable --now "${APP_NAME}-watchdog.timer" >/dev/null 2>&1
  rm -f "$WD_SERVICE" "$WD_TIMER"
  systemctl daemon-reload
  ok "Watchdog выключен."
}

mod_wd_status() {
  header "Watchdog Remnanode"
  if wd_enabled; then ok "Контроль: включён (проверка каждые $(wd_interval) мин)"; else info "Контроль: выключен"; fi
  if wd_autorestart_on; then
    ok "Автоперезапуск: включён (до $(wd_max_attempts) попыток подряд)"
  else
    info "Автоперезапуск: выключен (по умолчанию)"
  fi
  echo
  local st since
  st="$(wd_state_get status)"
  since="$(wd_state_get down_since)"
  info "Состояние по данным watchdog: ${st:-нет данных}"
  if [[ -n $since ]]; then info "Не работает с: $(date -d "@$since" '+%d.%m.%Y %H:%M')"; fi
  info "Попыток в текущем сбое: $(wd_state_get attempts)/$(wd_max_attempts) · всего авто-перезапусков: $(wd_state_get restarts_total)"
  if [[ -n "$(wd_state_get last_check)" ]]; then info "Последняя проверка: $(date -d "@$(wd_state_get last_check)" '+%d.%m %H:%M:%S')"; fi
  if [[ -f $REMNA_STOP_FLAG ]]; then warn "Нода остановлена вручную — watchdog её не трогает."; fi
  echo
  hint "Последние события:"
  grep -E 'Remnanode' "$LOG_FILE" 2>/dev/null | tail -n 6 | sed 's/^/    /'
  pause
}

mod_wd_toggle() {
  header "Watchdog: включить / выключить"
  if wd_enabled; then
    info "Сейчас watchdog включён."
    confirm "Выключить?" N && watchdog_disable
  else
    info "Watchdog следит, работает ли нода, и записывает время падения."
    hint "Автоперезапуск настраивается отдельно и по умолчанию выключен."
    if confirm "Включить watchdog?" Y; then
      local ar=keep
      if [[ -z "$(conf_get WATCHDOG_AUTORESTART)" ]]; then
        if confirm "Включить автоперезапуск при падении?" N; then ar=1; else ar=0; fi
      fi
      watchdog_enable "$ar"
    fi
  fi
  pause
}

mod_wd_autorestart() {
  header "Watchdog: автоперезапуск"
  if wd_autorestart_on; then
    info "Сейчас автоперезапуск ВКЛЮЧЁН."
    if confirm "Выключить (нода будет только помечаться упавшей)?" N; then conf_set WATCHDOG_AUTORESTART 0; ok "Автоперезапуск выключен."; fi
  else
    info "Сейчас автоперезапуск ВЫКЛЮЧЕН (по умолчанию)."
    hint "При падении watchdog попробует поднять ноду, не более $(wd_max_attempts) попыток подряд."
    if confirm "Включить автоперезапуск?" N; then conf_set WATCHDOG_AUTORESTART 1; ok "Автоперезапуск включён."; fi
  fi
  if ! wd_enabled; then warn "Сам watchdog выключен — настройка заработает после его включения."; fi
  pause
}

mod_wd_interval() {
  header "Watchdog: интервал проверки"
  ask_re "Как часто проверять, минут (1–60)" "$(wd_interval)" '^([1-9]|[1-5][0-9]|60)$' "Число от 1 до 60."
  conf_set WATCHDOG_INTERVAL "$ASK_RESULT"
  ok "Интервал: $ASK_RESULT мин."
  if wd_enabled; then wd_write_units && systemctl restart "${APP_NAME}-watchdog.timer" && ok "Таймер обновлён."; fi
  pause
}

mod_wd_attempts() {
  header "Watchdog: максимум попыток"
  hint "Сколько раз подряд пытаться поднять упавшую ноду, прежде чем сдаться и пометить «авто-перезапуск не помог»."
  ask_re "Попыток подряд (1–10)" "$(wd_max_attempts)" '^([1-9]|10)$' "Число от 1 до 10."
  conf_set WATCHDOG_MAX_ATTEMPTS "$ASK_RESULT"
  ok "Максимум попыток: $ASK_RESULT"
  pause
}

mod_wd_log() {
  header "Watchdog: журнал событий"
  grep -E 'Remnanode' "$LOG_FILE" 2>/dev/null | tail -n 100 | show_paged
  pause
}

menu_watchdog() {
  while true; do
    header "Remnanode: watchdog"
    if wd_enabled; then info "Контроль включён · автоперезапуск: $(wd_autorestart_on && echo включён || echo выключен)"; else info "Контроль выключен"; fi
    echo
    menu_item 1 "Статус и события"
    menu_item 2 "Включить / выключить watchdog"
    menu_item 3 "Автоперезапуск: включить / выключить"
    menu_item 4 "Интервал проверки"
    menu_item 5 "Максимум попыток подряд"
    menu_item 6 "Журнал событий"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_wd_status ;;
      2) mod_wd_toggle ;;
      3) mod_wd_autorestart ;;
      4) mod_wd_interval ;;
      5) mod_wd_attempts ;;
      6) mod_wd_log ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
