# ══════════════════════════ Service Manager (службы systemd) ══════════════════════════
# Универсальный модуль для systemd: список с фильтрами и поиском, выбор службы из списка
# (без ввода названия), карточка службы, действия, журнал. Критичные службы защищены.

declare -a SVC_NAMES=() SVC_ACTIVE=() SVC_SUB=() SVC_ENABLED=() SVC_DESC=() SVC_VIEW=()
SVC_PICKED=""
SVC_FILTERS=(all running failed inactive enabled)

svc_filter_title() {
  case $1 in
    all)      echo "все" ;;
    running)  echo "работают" ;;
    failed)   echo "упавшие" ;;
    inactive) echo "не работают" ;;
    enabled)  echo "в автозапуске" ;;
  esac
}

svc_load() { # читает все службы: файлы юнитов + текущее состояние
  SVC_NAMES=(); SVC_ACTIVE=(); SVC_SUB=(); SVC_ENABLED=(); SVC_DESC=()
  local -A en=() act=() sub=() desc=()
  local u st load a s d
  while read -r u st _; do
    if [[ $u == *.service && $u != *@.service && $st != alias ]]; then en[$u]=$st; fi
  done < <(systemctl list-unit-files --type=service --no-legend --plain --no-pager 2>/dev/null)
  while read -r u load a s d; do
    [[ $u == *.service ]] || continue
    [[ $load == not-found ]] && continue
    act[$u]=$a; sub[$u]=$s; desc[$u]=$d
    [[ -n ${en[$u]:-} ]] || en[$u]=static   # экземпляры шаблонов и временные службы
  done < <(systemctl list-units --type=service --all --no-legend --plain --no-pager 2>/dev/null)
  for u in "${!en[@]}"; do
    SVC_NAMES+=("$u")
    SVC_ACTIVE+=("${act[$u]:-inactive}")
    SVC_SUB+=("${sub[$u]:-dead}")
    SVC_ENABLED+=("${en[$u]}")
    SVC_DESC+=("${desc[$u]:-}")
  done
}

svc_build_view() { # svc_build_view ФИЛЬТР [ПОИСК] → SVC_VIEW (индексы; упавшие и работающие — выше)
  SVC_VIEW=()
  local i f=$1 q=${2:-} k hay lines=""
  q=${q,,}
  for i in "${!SVC_NAMES[@]}"; do
    case $f in
      running)  [[ ${SVC_SUB[$i]} == running ]] || continue ;;
      failed)   [[ ${SVC_ACTIVE[$i]} == failed ]] || continue ;;
      inactive) [[ ${SVC_ACTIVE[$i]} != active ]] || continue ;;
      enabled)  [[ ${SVC_ENABLED[$i]} == enabled* ]] || continue ;;
    esac
    if [[ -n $q ]]; then
      hay="${SVC_NAMES[$i],,} ${SVC_DESC[$i],,}"
      [[ $hay == *"$q"* ]] || continue
    fi
    if [[ ${SVC_ACTIVE[$i]} == failed ]]; then k=0; elif [[ ${SVC_SUB[$i]} == running ]]; then k=1; else k=2; fi
    lines+="$k|${SVC_NAMES[$i]}|$i"$'\n'
  done
  if [[ -n $lines ]]; then
    mapfile -t SVC_VIEW < <(printf '%s' "$lines" | LC_ALL=C sort -t'|' -k1,1n -k2,2 | cut -d'|' -f3)
  fi
}

svc_critical_reason() { # печатает причину, если служба критична (пусто — обычная)
  case $1 in
    ssh.service|sshd.service|ssh.socket|sshd.socket)
      echo "SSH: остановка отрежет доступ к серверу" ;;
    networking.service|systemd-networkd.service|NetworkManager.service|systemd-resolved.service|netplan-*.service)
      echo "сеть: остановка может отрезать сервер" ;;
    docker.service|docker.socket|containerd.service)
      echo "Docker: остановятся все контейнеры, включая Remnanode" ;;
    ufw.service)
      echo "файрвол: остановка откроет порты наружу" ;;
    dbus.service|systemd-logind.service|systemd-journald.service|systemd-udevd.service)
      echo "системная служба: сбой может сделать сервер нестабильным" ;;
  esac
}

svc_row() { # svc_row НОМЕР ИНДЕКС — строка списка
  local n=$1 i=$2 name=${SVC_NAMES[$2]%.service} a=${SVC_ACTIVE[$2]} s=${SVC_SUB[$2]} e=${SVC_ENABLED[$2]}
  local col ic etxt ecol nm sb ev dw
  case $a in
    failed)                            col=$C_RED;    ic="●" ;;
    active) if [[ $s == running ]]; then col=$C_GREEN; ic="●"; else col=$C_GREEN; ic="○"; fi ;;
    activating|deactivating|reloading) col=$C_YELLOW; ic="●" ;;
    *)                                 col=$C_DIM;    ic="○" ;;
  esac
  case $e in
    enabled|enabled-runtime) etxt="вкл";    ecol=$C_GREEN ;;
    disabled)                etxt="выкл";   ecol=$C_DIM ;;
    masked*)                 etxt="masked"; ecol=$C_RED ;;
    *)                       etxt=$e;       ecol=$C_DIM ;;
  esac
  nm="$(ui_pad "$(ui_trunc "$name" 26)" 26)"
  sb="$(ui_pad "$(ui_trunc "$s" 9)" 9)"
  if (( UI_COMPACT )); then
    printf '  %s%d%s %s%s%s %s %s%s%s\n' "${C_BOLD}${C_CYAN}" "$n" "$C_RESET" "$col" "$ic" "$C_RESET" "$nm" "$col" "$s" "$C_RESET"
  else
    ev="$(ui_pad "$etxt" 6)"
    dw=$(( UI_W - 51 ))
    printf '  %s%d%s %s%s%s %s %s%s%s %s%s%s %s%s%s\n' "${C_BOLD}${C_CYAN}" "$n" "$C_RESET" "$col" "$ic" "$C_RESET" "$nm" \
      "$col" "$sb" "$C_RESET" "$ecol" "$ev" "$C_RESET" "$C_DIM" "$( ((dw > 8)) && ui_trunc "${SVC_DESC[$i]}" "$dw" )" "$C_RESET"
  fi
}

svc_pick() { # svc_pick [фильтр] ["заголовок"] → $SVC_PICKED; код 1 — отмена
  local filter=${1:-all} title=${2:-Выбор службы} query="" page=0 per=9
  local total pages i idx n key rest hintline fi_idx
  SVC_PICKED=""
  if [[ ! -t 0 ]]; then err "Выбор службы требует интерактивного терминала."; return 1; fi
  svc_load
  if (( ${#SVC_NAMES[@]} == 0 )); then err "Не удалось получить список служб (systemd недоступен?)."; return 1; fi
  while true; do
    svc_build_view "$filter" "$query"
    total=${#SVC_VIEW[@]}
    pages=$(( (total + per - 1) / per ))
    if (( pages < 1 )); then pages=1; fi
    if (( page >= pages )); then page=$(( pages - 1 )); fi
    header "$title"
    printf '  %sФильтр:%s %s%s%s' "$C_DIM" "$C_RESET" "$C_BOLD" "$(svc_filter_title "$filter")" "$C_RESET"
    if [[ -n $query ]]; then printf '  %sПоиск:%s «%s»' "$C_DIM" "$C_RESET" "$query"; fi
    printf '  %s· служб: %d · стр. %d/%d%s\n\n' "$C_DIM" "$total" "$(( page + 1 ))" "$pages" "$C_RESET"
    if (( total == 0 )); then
      printf '  %sничего не найдено — смени фильтр (f) или поиск (/)%s\n' "$C_DIM" "$C_RESET"
    else
      for (( i = 0; i < per; i++ )); do
        idx=$(( page * per + i ))
        if (( idx >= total )); then break; fi
        svc_row "$(( i + 1 ))" "${SVC_VIEW[$idx]}"
      done
    fi
    if (( UI_COMPACT )); then hintline="1–9 выбор · n/p стр. · f фильтр · / поиск · q выход"
    else hintline="1–9 выбрать · n/→ дальше · p/← назад · f фильтр · / поиск · q отмена"; fi
    printf '\n  %s%s%s\n' "$C_DIM" "$hintline" "$C_RESET"
    printf '  %s❯%s ' "$C_CYAN" "$C_RESET"
    IFS= read -rsn1 key || { echo; return 1; }
    case $key in
      [1-9])
        n=$key
        idx=$(( page * per + n - 1 ))
        if (( idx < total )); then
          SVC_PICKED="${SVC_NAMES[${SVC_VIEW[$idx]}]}"
          ui_swallow_enter
          echo
          return 0
        fi
        ;;
      n|N|т|Т|">") page=$(( (page + 1) % pages )) ;;
      p|P|з|З|"<") page=$(( (page + pages - 1) % pages )) ;;
      f|F|а|А)
        for fi_idx in "${!SVC_FILTERS[@]}"; do
          if [[ ${SVC_FILTERS[$fi_idx]} == "$filter" ]]; then break; fi
        done
        filter=${SVC_FILTERS[$(( (fi_idx + 1) % ${#SVC_FILTERS[@]} ))]}
        page=0
        ;;
      "/"|s|S|ы|Ы)
        echo
        ask "Поиск по названию и описанию (Enter — сбросить)" ""
        query=$ASK_RESULT
        page=0
        ;;
      q|Q|0|й|Й) echo; return 1 ;;
      $'\e')
        rest=""
        IFS= read -rsn2 -t 0.05 rest || true
        while IFS= read -rsn1 -t 0.005 _; do :; done
        case $rest in
          "[C") page=$(( (page + 1) % pages )) ;;
          "[D") page=$(( (page + pages - 1) % pages )) ;;
          "")   echo; return 1 ;;
        esac
        ;;
    esac
  done
}

svc_show_log_tail() { # svc_show_log_tail ЮНИТ [N]
  if cmd_exists journalctl; then
    journalctl -u "$1" -n "${2:-15}" --no-pager -o short 2>/dev/null | sed 's/^/    /'
  fi
}

svc_state_line() { printf '%s / автозапуск: %s' "$(systemctl is-active "$1" 2>/dev/null)" "$(systemctl is-enabled "$1" 2>/dev/null)"; }

svc_run() { # svc_run ДЕЙСТВИЕ ЮНИТ — действие с защитой критичных служб и проверкой результата
  local action=$1 unit=$2 reason out rc st
  reason="$(svc_critical_reason "$unit")"
  case $action in
    stop|disable|mask)
      if [[ -n $reason ]]; then
        warn "$unit — $reason."
        confirm_word "Выполнить «$action» для $unit?" "да" || { info "Отменено."; return 1; }
      elif ! confirm "Выполнить «$action» для $unit?" Y; then
        info "Отменено."; return 1
      fi
      ;;
    restart)
      if [[ -n $reason ]]; then
        warn "$unit — $reason."
        confirm "Перезапустить $unit?" N || { info "Отменено."; return 1; }
      fi
      ;;
  esac
  step "systemctl $action $unit"
  out="$(systemctl "$action" "$unit" 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    err "systemctl $action не удалось: ${out:-нет сообщения}"
    hint "Последние записи журнала:"
    svc_show_log_tail "$unit" 10
    return 1
  fi
  ok "Выполнено: $action $unit"
  case $action in
    start|restart)
      sleep 1
      st="$(systemctl is-active "$unit" 2>/dev/null)"
      if [[ $st == active ]]; then
        ok "Служба работает (active)."
      else
        warn "Состояние после $action: ${st:-?}"
        hint "Последние записи журнала:"
        svc_show_log_tail "$unit" 15
      fi
      ;;
  esac
  info "Сейчас: $(svc_state_line "$unit")"
  log INFO "systemctl $action $unit"
}

svc_autostart() { # svc_autostart ЮНИТ — переключает автозапуск
  local unit=$1 st
  st="$(systemctl is-enabled "$unit" 2>/dev/null)"
  info "Автозапуск сейчас: ${st:-?}"
  case $st in
    enabled|enabled-runtime)
      if svc_run disable "$unit" && [[ "$(systemctl is-active "$unit" 2>/dev/null)" == active ]]; then
        confirm "Остановить службу сейчас?" N && svc_run stop "$unit"
      fi
      ;;
    masked*)
      warn "Служба замаскирована — сначала размаскируй её (карточка службы → m)."
      ;;
    *)
      if svc_run enable "$unit" && [[ "$(systemctl is-active "$unit" 2>/dev/null)" != active ]]; then
        confirm "Запустить службу сейчас?" Y && svc_run start "$unit"
      fi
      ;;
  esac
}

svc_logs_menu() { # svc_logs_menu ЮНИТ
  local unit=$1
  if ! cmd_exists journalctl; then err "journalctl недоступен."; pause; return 1; fi
  while true; do
    header "Журнал: $unit"
    menu_item 1 "Последние 100 записей"
    menu_item 2 "Только ошибки (priority err и выше)"
    menu_item 3 "С момента загрузки системы"
    menu_item 4 "В реальном времени (Ctrl+C — выход)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) journalctl -u "$unit" -n 100 --no-pager 2>&1 | show_paged; pause ;;
      2) journalctl -u "$unit" -p err -n 100 --no-pager 2>&1 | show_paged; pause ;;
      3) journalctl -u "$unit" -b --no-pager 2>&1 | show_paged; pause ;;
      4) run_interruptible journalctl -u "$unit" -n 50 -f; pause ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

svc_card_render() { # svc_card_render ЮНИТ — карточка службы
  local unit=$1 k v lvl txt reason mem
  local -A p=()
  header "$unit"
  while IFS='=' read -r k v; do p[$k]=$v; done < <(systemctl show "$unit" -p Description -p LoadState -p ActiveState \
    -p SubState -p UnitFileState -p MainPID -p MemoryCurrent -p ActiveEnterTimestamp -p NRestarts -p FragmentPath \
    -p Restart --no-pager 2>/dev/null)
  ui_kv "Описание" "${p[Description]:-—}" 11
  case ${p[ActiveState]:-} in
    active)
      if [[ ${p[SubState]:-} == running ]]; then lvl=ok; txt="работает (running)"; else lvl=ok; txt="выполнена (${p[SubState]:-active})"; fi ;;
    failed)  lvl=bad;  txt="упала (failed)" ;;
    activating|deactivating|reloading) lvl=warn; txt="${p[ActiveState]} (${p[SubState]:-})" ;;
    *)       lvl=off;  txt="остановлена (${p[SubState]:-inactive})" ;;
  esac
  ui_kv "Состояние" "$(badge "$lvl" "$txt")" 11
  case ${p[UnitFileState]:-} in
    enabled|enabled-runtime) ui_kv "Автозапуск" "${C_GREEN}включён${C_RESET}" 11 ;;
    masked*)                 ui_kv "Автозапуск" "${C_RED}masked (запуск запрещён)${C_RESET}" 11 ;;
    *)                       ui_kv "Автозапуск" "${p[UnitFileState]:-?}" 11 ;;
  esac
  if [[ -n ${p[MainPID]:-} && ${p[MainPID]} != 0 ]]; then ui_kv "PID" "${p[MainPID]}" 11; fi
  mem=${p[MemoryCurrent]:-}
  if [[ $mem =~ ^[0-9]+$ ]] && (( ${#mem} < 15 )); then ui_kv "Память" "$(ui_human_kb $(( mem / 1024 )))" 11; fi
  if [[ -n ${p[ActiveEnterTimestamp]:-} ]]; then ui_kv "С момента" "${p[ActiveEnterTimestamp]}" 11; fi
  if [[ -n ${p[NRestarts]:-} && ${p[NRestarts]} != 0 ]]; then ui_kv "Рестартов" "${C_YELLOW}${p[NRestarts]}${C_RESET}" 11; fi
  if [[ -n ${p[Restart]:-} ]]; then ui_kv "Restart" "${p[Restart]}" 11; fi
  if [[ -n ${p[FragmentPath]:-} ]]; then ui_kv "Юнит" "$(ui_trunc "${p[FragmentPath]}" $(( UI_W - 15 )))" 11; fi
  reason="$(svc_critical_reason "$unit")"
  if [[ -n $reason ]]; then echo; ui_line warn "Критичная служба — $reason"; fi
  if cmd_exists journalctl; then
    ui_section "Последние записи журнала"
    timeout 3 journalctl -u "$unit" -n 5 --no-pager -o short 2>/dev/null | while IFS= read -r v; do
      printf '  %s%s%s\n' "$C_DIM" "$(ui_trunc "$v" $(( UI_W - 4 )))" "$C_RESET"
    done
  fi
  echo
}

svc_card() { # svc_card ЮНИТ — карточка со всеми действиями
  local unit=$1 uf
  while true; do
    svc_card_render "$unit"
    uf="$(systemctl show "$unit" -p UnitFileState --value 2>/dev/null)"
    menu_item s "Запустить"
    menu_item x "Остановить"
    menu_item r "Перезапустить"
    menu_item e "Автозапуск: включить / отключить"
    menu_item l "Журнал"
    menu_item i "Полный вывод systemctl status"
    if [[ $uf == masked* ]]; then menu_item m "Размаскировать (unmask)"; else menu_item m "Замаскировать (mask — запретить запуск)"; fi
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      s|S|ы|Ы) svc_run start "$unit"; pause ;;
      x|X|ч|Ч) svc_run stop "$unit"; pause ;;
      r|R|к|К) svc_run restart "$unit"; pause ;;
      e|E|у|У) svc_autostart "$unit"; pause ;;
      l|L|д|Д) svc_logs_menu "$unit" ;;
      i|I|ш|Ш) systemctl status "$unit" --no-pager -l 2>&1 | show_paged; pause ;;
      m|M|ь|Ь) if [[ $uf == masked* ]]; then svc_run unmask "$unit"; else svc_run mask "$unit"; fi; pause ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

svc_browse() { # svc_browse ФИЛЬТР "Заголовок" — выбор службы и её карточка
  if svc_pick "$1" "$2"; then svc_card "$SVC_PICKED"; fi
}

svc_pick_action() { # svc_pick_action ФИЛЬТР "Заголовок" start|stop|restart|autostart|logs
  if ! svc_pick "$1" "$2"; then return 0; fi
  local unit=$SVC_PICKED
  case $3 in
    logs) svc_logs_menu "$unit"; return 0 ;;
  esac
  header "$2: $unit"
  case $3 in
    autostart) svc_autostart "$unit" ;;
    *)         svc_run "$3" "$unit" ;;
  esac
  pause
}

mod_svc_reset_failed() {
  header "Сбросить статус упавших служб"
  hint "Убирает пометку «failed» у служб (сами службы не запускаются)."
  confirm "Выполнить systemctl reset-failed?" Y || { info "Отменено."; pause; return 0; }
  if systemctl reset-failed; then ok "Статус упавших служб сброшен."; else err "Не удалось выполнить reset-failed."; fi
  pause
}

mod_svc_daemon_reload() {
  header "systemctl daemon-reload"
  hint "Перечитывает файлы юнитов — нужно после ручного редактирования unit-файлов."
  confirm "Выполнить daemon-reload?" Y || { info "Отменено."; pause; return 0; }
  if systemctl daemon-reload; then ok "daemon-reload выполнен."; else err "Не удалось выполнить daemon-reload."; fi
  pause
}

menu_services() {
  if ! cmd_exists systemctl || [[ ! -d /run/systemd/system ]]; then
    header "Service Manager"
    err "systemd недоступен на этой системе."
    pause
    return 1
  fi
  local nrun nfail
  while true; do
    header "Service Manager"
    nrun="$(systemctl list-units --type=service --state=running --no-legend --plain --no-pager 2>/dev/null | wc -l)"
    nfail="$(systemctl --failed --no-legend --plain --no-pager 2>/dev/null | wc -l)"
    ui_line ok "Работает служб: $nrun"
    if (( nfail > 0 )); then ui_line bad "Упавших служб: $nfail (пункт 3)"; else ui_line off "Упавших служб нет"; fi
    echo
    menu_item 1 "Все службы"
    menu_item 2 "Работающие"
    menu_item 3 "Упавшие"
    menu_item 4 "Запустить службу"
    menu_item 5 "Остановить службу"
    menu_item 6 "Перезапустить службу"
    menu_item 7 "Автозапуск: включить / отключить"
    menu_item 8 "Журнал службы"
    menu_item 9 "Подробности службы (карточка)"
    menu_item f "Сбросить статус упавших (reset-failed)"
    menu_item r "systemctl daemon-reload"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) svc_browse all "Все службы" ;;
      2) svc_browse running "Работающие службы" ;;
      3) svc_browse failed "Упавшие службы" ;;
      4) svc_pick_action inactive "Запустить службу" start ;;
      5) svc_pick_action running "Остановить службу" stop ;;
      6) svc_pick_action running "Перезапустить службу" restart ;;
      7) svc_pick_action all "Автозапуск службы" autostart ;;
      8) svc_pick_action all "Журнал службы" logs ;;
      9) svc_browse all "Подробности службы" ;;
      f|F|а|А) mod_svc_reset_failed ;;
      r|R|к|К) mod_svc_daemon_reload ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
