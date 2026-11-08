# ══════════════════════════ Remnanode ══════════════════════════

remna_require_docker() {
  if ! cmd_exists docker || ! docker compose version >/dev/null 2>&1; then
    err "Нужен Docker с плагином compose — сначала пункт 6."
    return 1
  fi
  if ! service_active docker; then
    err "Служба docker не запущена (systemctl start docker)."
    return 1
  fi
}

remna_require_compose() {
  remna_require_docker || return 1
  if [[ ! -s $REMNA_COMPOSE ]]; then
    err "Нет файла $REMNA_COMPOSE — сначала «Первичная настройка»."
    return 1
  fi
}

rcompose() {
  if [[ ${1:-} == up ]]; then rm -f "$REMNA_STOP_FLAG"; fi
  (cd "$REMNA_DIR" && docker compose "$@")
}

remna_edit_compose() {
  cmd_exists nano || apt_install nano || return 1
  touch "$REMNA_COMPOSE"
  nano "$REMNA_COMPOSE"
  if [[ ! -s $REMNA_COMPOSE ]]; then
    warn "Файл пуст — конфиг не вставлен."
    return 1
  fi
}

remna_validate() {
  local out
  if out="$(cd "$REMNA_DIR" && docker compose config -q 2>&1)"; then
    ok "docker-compose.yml корректен."
  else
    err "В docker-compose.yml есть ошибка:"; echo "$out"
    return 1
  fi
}

remna_offer_logs() {
  if confirm "Показать логи? (Ctrl+C — вернуться в меню)" Y; then
    run_interruptible rcompose logs -f -t --tail 100
  fi
}

mod_remna_setup() {
  header "7. Remnanode: первичная настройка"
  remna_require_docker || { pause; return 1; }

  step "Каталог $REMNA_DIR"
  if [[ -d $REMNA_DIR ]]; then
    ok "Каталог уже существует."
  elif mkdir -p "$REMNA_DIR"; then
    ok "Каталог создан."
  else
    err "Не удалось создать каталог."; pause; return 1
  fi

  step "Файл docker-compose.yml"
  if [[ -s $REMNA_COMPOSE ]]; then
    ok "Файл уже существует."
    if confirm "Открыть в nano для правки?" N; then remna_edit_compose; fi
  else
    info "Сейчас откроется nano. Вставь в него конфиг docker-compose из панели управления нодами."
    hint "Сохранить: Ctrl+O, затем Enter.  Выйти: Ctrl+X."
    pause
    remna_edit_compose || { pause; return 1; }
  fi

  remna_validate || { pause; return 1; }

  if confirm "Запустить контейнер сейчас?" Y; then
    step "Запуск"
    if rcompose up -d; then
      ok "Контейнер запущен."
      rcompose ps
      echo; remna_offer_logs
    else
      err "Не удалось запустить. Проверь конфиг и логи."
    fi
  fi
  pause
}

mod_remna_start() {
  header "Remnanode: запуск"
  remna_require_compose || { pause; return 1; }
  if rcompose up -d; then ok "Запущено."; rcompose ps; echo; remna_offer_logs; else err "Не удалось запустить."; fi
  pause
}

mod_remna_stop() {
  header "Remnanode: остановка"
  remna_require_compose || { pause; return 1; }
  warn "Контейнер будет остановлен и удалён (docker compose down). Конфиг и тома сохранятся."
  confirm "Остановить Remnanode?" N || { info "Отменено."; pause; return 0; }
  if rcompose down; then
    ok "Остановлено."
    install -d -m 0755 "$STATE_DIR" 2>/dev/null
    touch "$REMNA_STOP_FLAG"
    hint "Watchdog не будет перезапускать ноду, пока ты сам её не запустишь."
  else
    err "Не удалось остановить."
  fi
  pause
}

mod_remna_restart() {
  header "Remnanode: перезапуск"
  remna_require_compose || { pause; return 1; }
  remna_validate || { pause; return 1; }
  if rcompose down && rcompose up -d; then
    ok "Перезапущено."; rcompose ps; echo; remna_offer_logs
  else
    err "Перезапуск не удался."
  fi
  pause
}

mod_remna_update() {
  header "Remnanode: обновление и перезапуск"
  remna_require_compose || { pause; return 1; }
  remna_validate || { pause; return 1; }
  step "Загружаю свежие образы"
  if ! rcompose pull; then
    err "pull не удался — ноду НЕ останавливаю, она продолжает работать."
    pause; return 1
  fi
  step "Пересоздаю контейнер"
  if rcompose down && rcompose up -d; then
    ok "Обновлено и запущено."
    rcompose ps
    if confirm "Удалить старые неиспользуемые образы (docker image prune)?" Y; then
      docker image prune -f >/dev/null && ok "Старые образы удалены."
    fi
    echo; remna_offer_logs
  else
    err "Не удалось поднять контейнер после обновления."
  fi
  pause
}

mod_remna_logs() {
  header "Remnanode: логи (Ctrl+C — выход)"
  remna_require_compose || { pause; return 1; }
  run_interruptible rcompose logs -f -t --tail 100
  pause
}

mod_remna_status() {
  header "Remnanode: статус"
  remna_require_compose || { pause; return 1; }
  rcompose ps -a
  pause
}

mod_remna_edit() {
  header "Remnanode: правка docker-compose.yml"
  remna_require_docker || { pause; return 1; }
  [[ -d $REMNA_DIR ]] || mkdir -p "$REMNA_DIR"
  remna_edit_compose || { pause; return 1; }
  remna_validate
  hint "Чтобы изменения применились — «Перезапустить»."
  pause
}

menu_remna() {
  while true; do
    header "7. Remnanode"
    menu_item 1 "Первичная настройка (папка, compose-файл, запуск)"
    menu_item 2 "Запустить"
    menu_item 3 "Остановить"
    menu_item 4 "Перезапустить"
    menu_item 5 "Обновить (pull + перезапуск)"
    menu_item 6 "Логи контейнера (docker compose logs)"
    menu_item 7 "Логи xray (xlogs)"
    menu_item 8 "Ошибки xray (xerrors)"
    menu_item 9 "Статус"
    menu_item 10 "Править docker-compose.yml"
    menu_item 11 "Зайти в контейнер (shell)"
    menu_item 12 "Бэкап конфигов"
    menu_item 13 "Восстановить из бэкапа"
    menu_item 14 "Watchdog (контроль и автоперезапуск)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1)  mod_remna_setup ;;
      2)  mod_remna_start ;;
      3)  mod_remna_stop ;;
      4)  mod_remna_restart ;;
      5)  mod_remna_update ;;
      6)  mod_remna_logs ;;
      7)  mod_remna_xlogs ;;
      8)  mod_remna_xerrors ;;
      9)  mod_remna_status ;;
      10) mod_remna_edit ;;
      11) mod_remna_shell ;;
      12) mod_remna_backup ;;
      13) mod_remna_restore ;;
      14) menu_watchdog ;;
      0)  return 0 ;;
      *)  warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

remna_container_running() {
  local names
  names="$(docker ps --format '{{.Names}}' 2>/dev/null)"
  grep -qx "$REMNA_CONTAINER" <<<"$names"
}

remna_exec() { # remna_exec команда… — интерактивно внутри контейнера
  remna_require_docker || return 1
  if ! remna_container_running; then
    err "Контейнер $REMNA_CONTAINER не запущен."
    return 1
  fi
  local rc
  run_interruptible docker exec -it "$REMNA_CONTAINER" "$@"
  rc=$?
  if (( rc == 126 || rc == 127 )); then
    err "Команда «$1» не найдена в контейнере (возможно, другая версия образа)."
  fi
  return 0
}

mod_remna_xlogs() {
  header "Remnanode: логи xray (xlogs)"
  info "Команда: docker exec -it $REMNA_CONTAINER xlogs   (выход — Ctrl+C)"
  remna_exec xlogs
  pause
}

mod_remna_xerrors() {
  header "Remnanode: ошибки xray (xerrors)"
  info "Команда: docker exec -it $REMNA_CONTAINER xerrors   (выход — Ctrl+C)"
  remna_exec xerrors
  pause
}

mod_remna_shell() {
  header "Remnanode: консоль контейнера"
  info "Выход из консоли — exit"
  remna_exec sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'
  pause
}

mod_remna_backup() {
  header "Remnanode: бэкап конфигов"
  if [[ ! -d $REMNA_DIR ]]; then err "Каталога $REMNA_DIR нет — нечего сохранять."; pause; return 1; fi
  if backup_create remnanode "$REMNA_DIR"; then
    ok "Бэкап создан: $BACKUP_RESULT"
    warn "В архиве лежат секреты ноды (ключи из docker-compose.yml). Доступ только у root — не выкладывай файл никуда."
    hint "Хранятся последние 10 копий."
  fi
  pause
}

mod_remna_restore() {
  header "Remnanode: восстановление из бэкапа"
  backup_pick "remnanode-*.tar.gz" || { pause; return 0; }
  local f=$BACKUP_PICKED listing
  listing="$(tar -tzf "$f" 2>/dev/null)"
  if [[ -z $listing ]] || grep -qv '^opt/remnanode' <<<"$listing"; then
    err "Архив повреждён или содержит посторонние пути — восстановление отменено."
    pause; return 1
  fi
  warn "Файлы в $REMNA_DIR будут перезаписаны содержимым архива."
  confirm "Восстановить из $(basename "$f")?" N || { info "Отменено."; pause; return 0; }
  if [[ -d $REMNA_DIR ]]; then
    if backup_create prerestore-remnanode "$REMNA_DIR"; then ok "Текущее состояние сохранено: $BACKUP_RESULT"; fi
  fi
  if tar -xzf "$f" -C /; then
    ok "Файлы восстановлены."
    if cmd_exists docker && [[ -s $REMNA_COMPOSE ]] && remna_validate; then
      if confirm "Перезапустить Remnanode с восстановленным конфигом?" Y; then
        rcompose down && rcompose up -d && ok "Перезапущено." && rcompose ps
      fi
    fi
  else
    err "Не удалось распаковать архив."
  fi
  pause
}

remna_is_running() {
  service_active docker || return 1
  [[ -s $REMNA_COMPOSE ]] || return 1
  local n
  n="$(cd "$REMNA_DIR" && docker compose ps --status running -q 2>/dev/null | wc -l)"
  (( n > 0 ))
}

remna_panel_state() { # печатает «уровень|текст» для панели статусов
  if [[ ! -s $REMNA_COMPOSE ]]; then echo "off|не настроен"; return 0; fi
  if ! cmd_exists docker || ! service_active docker; then
    if [[ -f $REMNA_STOP_FLAG ]]; then echo "warn|остановлен вручную"; else echo "bad|Docker не работает — нода не запущена"; fi
    return 0
  fi
  local n since st txt
  n="$(rcompose ps --status running -q 2>/dev/null | wc -l)"
  if (( n > 0 )); then echo "ok|запущен (контейнеров: $n)"; return 0; fi
  if [[ -f $REMNA_STOP_FLAG ]]; then echo "warn|остановлен вручную"; return 0; fi
  since="$(wd_state_get down_since)"
  st="$(wd_state_get status)"
  txt="упал или не запущен"
  if [[ -n $since ]]; then txt="упал: не работает с $(date -d "@$since" '+%d.%m %H:%M')"; fi
  if [[ $st == failed ]]; then
    txt+=" · авто-перезапуск не помог"
  elif [[ $st == down ]] && wd_autorestart_on; then
    txt+=" · идёт авто-перезапуск"
  fi
  echo "bad|$txt"
}
