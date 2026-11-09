# ══════════════════════════ Dashboard ══════════════════════════
# Моментальный снимок сервера из реальных данных (/proc, df, ip, systemctl, docker, journalctl).
# Это не постоянный мониторинг: данные собираются при открытии и по клавише r.

DASH_PREV_RX=""
DASH_PREV_TX=""
DASH_PREV_TS=0
DASH_CACHE_TS=0
DASH_UPD_ALL=""
DASH_UPD_SEC=""
DASH_SSH_FAILED=""
DASH_SSH_TOP=""
DASH_BANNED=""
DASH_BANNED_TOTAL=""

dash_meminfo_kb() { awk -v k="$1:" '$1 == k {print $2; exit}' /proc/meminfo; }

dash_uptime() {
  local up d h m
  read -r up _ </proc/uptime
  up=${up%.*}
  d=$(( up / 86400 )); h=$(( up % 86400 / 3600 )); m=$(( up % 3600 / 60 ))
  if (( d > 0 )); then printf '%d д %d ч %d мин' "$d" "$h" "$m"
  elif (( h > 0 )); then printf '%d ч %d мин' "$h" "$m"
  else printf '%d мин' "$m"; fi
}

dash_cpu_sample() { awk '/^cpu / {idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print idle, total}' /proc/stat; }

dash_cpu_pct() { # загрузка CPU за короткий интервал по /proc/stat
  local i1 t1 i2 t2 dt di
  read -r i1 t1 < <(dash_cpu_sample)
  sleep 0.25
  read -r i2 t2 < <(dash_cpu_sample)
  dt=$(( t2 - t1 )); di=$(( i2 - i1 ))
  if (( dt > 0 )); then printf '%d' $(( 100 * (dt - di) / dt )); else printf '0'; fi
}

dash_system() {
  local cores l1 l5 l15 cpu mt ma mu mp st sf su sp size used avail pct mnt shown=0
  ui_section "Система"
  ui_kv "Хост" "$UI_HOST · $OS_PRETTY"
  ui_kv "Ядро" "$(uname -r) · аптайм $(dash_uptime)"
  cores="$(nproc 2>/dev/null || echo 1)"
  read -r l1 l5 l15 _ </proc/loadavg
  cpu="$(dash_cpu_pct)"
  ui_meter "CPU" "$cpu" "load $l1 / $l5 / $l15 · ядер $cores"

  mt="$(dash_meminfo_kb MemTotal)"; ma="$(dash_meminfo_kb MemAvailable)"
  mt=${mt:-0}; ma=${ma:-0}
  mu=$(( mt - ma )); mp=0
  if (( mt > 0 )); then mp=$(( 100 * mu / mt )); fi
  ui_meter "RAM" "$mp" "$(ui_human_kb "$mu") / $(ui_human_kb "$mt")"

  st="$(dash_meminfo_kb SwapTotal)"; sf="$(dash_meminfo_kb SwapFree)"
  st=${st:-0}; sf=${sf:-0}
  if (( st > 0 )); then
    su=$(( st - sf )); sp=$(( 100 * su / st ))
    ui_meter "Swap" "$sp" "$(ui_human_kb "$su") / $(ui_human_kb "$st")"
  else
    ui_kv "Swap" "${C_DIM}нет${C_RESET}"
  fi

  while read -r _ size used avail pct mnt; do
    (( shown >= 4 )) && break
    pct=${pct%\%}
    ui_meter "$(ui_trunc "$mnt" 7)" "$pct" "$(ui_human_kb "$used") / $(ui_human_kb "$size")"
    shown=$(( shown + 1 ))
  done < <(df -P -k -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)
}

dash_network() {
  local name state addrs a1 a2 col hidden=0 iface rx tx now dt rrx rtx rate=""
  ui_section "Сеть"
  while read -r name state addrs; do
    [[ $name == lo ]] && continue
    case $name in
      docker*|br-*|veth*|virbr*|cni*|flannel*) hidden=$(( hidden + 1 )); continue ;;
    esac
    read -r a1 a2 _ <<<"$addrs"
    case $state in UP) col=$C_GREEN ;; DOWN) col=$C_RED ;; *) col=$C_DIM ;; esac
    ui_kv "$(ui_trunc "$name" 9)" "${col}${state}${C_RESET} ${a1:-—} ${a2:-}"
  done < <(ip -brief addr 2>/dev/null)
  if (( hidden > 0 )); then ui_kv "docker" "${C_DIM}интерфейсов контейнеров: $hidden${C_RESET}"; fi

  iface="$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
  if [[ -n $iface ]]; then
    read -r rx tx < <(sed 's/^ *//; s/:/ /' /proc/net/dev | awk -v i="$iface" '$1 == i {print $2, $10}')
    now="$(date +%s)"
    if [[ -n $DASH_PREV_RX && $DASH_PREV_TS -gt 0 && -n ${rx:-} ]]; then
      dt=$(( now - DASH_PREV_TS ))
      if (( dt > 0 )); then
        rrx=$(( (rx - DASH_PREV_RX) / dt / 1024 )); rtx=$(( (tx - DASH_PREV_TX) / dt / 1024 ))
        rate=" · сейчас ↓ $(ui_human_kb "$rrx")/с ↑ $(ui_human_kb "$rtx")/с"
      fi
    fi
    if [[ -n ${rx:-} ]]; then
      ui_kv "Трафик" "$iface: ↓ $(ui_human_kb $(( rx / 1024 ))) ↑ $(ui_human_kb $(( tx / 1024 ))) с загрузки${rate}"
      DASH_PREV_RX=$rx; DASH_PREV_TX=$tx; DASH_PREV_TS=$now
    fi
  fi
}

dash_services() {
  local sysstate failed n=0 u
  ui_section "Службы"
  if ! cmd_exists systemctl; then ui_line off "systemd недоступен"; return 0; fi
  sysstate="$(systemctl is-system-running 2>/dev/null)"
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
  if [[ -z $failed ]]; then
    ui_line ok "Упавших служб нет ${C_DIM}(состояние системы: ${sysstate:-?})${C_RESET}"
  else
    ui_line bad "Упавшие службы: $(wc -l <<<"$failed") ${C_DIM}(состояние системы: ${sysstate:-?})${C_RESET}"
    while read -r u; do
      n=$(( n + 1 ))
      if (( n > 5 )); then break; fi
      printf '      %s%s%s\n' "$C_RED" "$u" "$C_RESET"
    done <<<"$failed"
    printf '      %sразобраться: клавиша s в главном меню (Service Manager)%s\n' "$C_DIM" "$C_RESET"
  fi
}

dash_docker() {
  local rows name status up=0 total=0 shown=0 icon col rs
  ui_section "Docker"
  if ! cmd_exists docker; then ui_line off "Docker не установлен"; return 0; fi
  if ! service_active docker; then ui_line bad "Docker не запущен"; return 0; fi
  rows="$(timeout 5 docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null)"
  if [[ -z $rows ]]; then
    ui_line off "Контейнеров нет"
  else
    while IFS='|' read -r name status _; do
      total=$(( total + 1 ))
      case $status in
        Up*)        up=$(( up + 1 )); icon="●"; col=$C_GREEN ;;
        Exited*|Dead*) icon="●"; col=$C_RED ;;
        *)          icon="●"; col=$C_YELLOW ;;
      esac
      if (( shown < 8 )); then
        printf '  %s%s%s %s %s%s%s\n' "$col" "$icon" "$C_RESET" "$(ui_pad "$(ui_trunc "$name" 18)" 18)" "$C_DIM" "$(ui_trunc "$status" $(( UI_W - 26 )))" "$C_RESET"
        shown=$(( shown + 1 ))
      fi
    done <<<"$rows"
    if (( total > shown )); then printf '    %sи ещё контейнеров: %d%s\n' "$C_DIM" "$(( total - shown ))" "$C_RESET"; fi
    ui_kv "Итого" "запущено $up из $total"
  fi
  if [[ -s $REMNA_COMPOSE ]]; then
    rs="$(remna_panel_state)"
    ui_kv "Remnanode" "$(badge "${rs%%|*}" "${rs#*|}")"
    if wd_enabled; then
      ui_kv "Watchdog" "включён · автоперезапуск: $(wd_autorestart_on && echo включён || echo выключен)"
    else
      ui_kv "Watchdog" "${C_DIM}выключен${C_RESET}"
    fi
  fi
}

dash_security_refresh() { # тяжёлые проверки — результат кэшируется на 2 минуты
  local out logtxt
  DASH_UPD_ALL=""; DASH_UPD_SEC=""; DASH_SSH_FAILED=""; DASH_SSH_TOP=""; DASH_BANNED=""; DASH_BANNED_TOTAL=""
  if cmd_exists apt-get; then
    out="$(apt-get -s upgrade 2>/dev/null | grep '^Inst')"
    if [[ -z $out ]]; then
      DASH_UPD_ALL=0; DASH_UPD_SEC=0
    else
      DASH_UPD_ALL="$(wc -l <<<"$out")"
      DASH_UPD_SEC="$(grep -c -- '-security' <<<"$out")"
    fi
  fi
  logtxt="$(timeout 6 journalctl -u ssh -u sshd --since '24 hours ago' -o cat --no-pager -q 2>/dev/null | grep -E 'Failed password|Invalid user|authentication failure')"
  if [[ -z $logtxt && -r /var/log/auth.log ]]; then
    logtxt="$(grep -E 'Failed password|Invalid user' /var/log/auth.log | tail -n 5000)"
  fi
  if [[ -z $logtxt ]]; then
    DASH_SSH_FAILED=0
  else
    DASH_SSH_FAILED="$(wc -l <<<"$logtxt")"
    DASH_SSH_TOP="$(grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' <<<"$logtxt" | sort | uniq -c | sort -rn | head -n 3 | awk '{printf "%s (%s)  ", $2, $1}')"
  fi
  if cmd_exists fail2ban-client && service_active fail2ban; then
    out="$(fail2ban-client status sshd 2>/dev/null)"
    DASH_BANNED="$(sed -n 's/.*Currently banned:[[:space:]]*//p' <<<"$out")"
    DASH_BANNED_TOTAL="$(sed -n 's/.*Total banned:[[:space:]]*//p' <<<"$out")"
  fi
  DASH_CACHE_TS="$(date +%s)"
}

dash_security() { # dash_security [force]
  local force=${1:-0} now who_n who_list
  now="$(date +%s)"
  ui_section "Безопасность"
  if (( force )) || (( now - DASH_CACHE_TS > 120 )); then
    if [[ -t 1 ]]; then printf '  %sсобираю данные…%s' "$C_DIM" "$C_RESET"; fi
    dash_security_refresh
    if [[ -t 1 ]]; then printf '\r\e[K'; fi
  fi

  who_n="$(who 2>/dev/null | wc -l)"
  who_list="$(who 2>/dev/null | awk '{ip = $NF; gsub(/[()]/, "", ip); printf "%s%s  ", $1, (ip != $2 && ip != "" ? "@" ip : "")}')"
  ui_kv "Сессии" "$who_n ${C_DIM}${who_list}${C_RESET}"

  if [[ -n $DASH_SSH_FAILED ]]; then
    if (( DASH_SSH_FAILED == 0 )); then
      ui_line ok "Неудачных входов по SSH за 24 ч нет"
    elif (( DASH_SSH_FAILED < 50 )); then
      ui_line warn "Неудачных входов по SSH за 24 ч: $DASH_SSH_FAILED"
    else
      ui_line bad "Неудачных входов по SSH за 24 ч: $DASH_SSH_FAILED"
    fi
    if [[ -n $DASH_SSH_TOP ]]; then printf '      %sчаще всего: %s%s\n' "$C_DIM" "$DASH_SSH_TOP" "$C_RESET"; fi
  fi
  if [[ -n $DASH_BANNED ]]; then
    ui_line ok "Fail2ban: забанено сейчас $DASH_BANNED ${C_DIM}(всего ${DASH_BANNED_TOTAL:-?})${C_RESET}"
  elif cmd_exists fail2ban-client; then
    ui_line warn "Fail2ban установлен, но не запущен"
  else
    ui_line off "Fail2ban не установлен"
  fi
  if [[ -n $DASH_UPD_ALL ]]; then
    if (( DASH_UPD_SEC > 0 )); then
      ui_line warn "Обновлений безопасности: $DASH_UPD_SEC ${C_DIM}(всего пакетов: $DASH_UPD_ALL)${C_RESET}"
    elif (( DASH_UPD_ALL > 0 )); then
      ui_line off "Доступно обновлений: $DASH_UPD_ALL (безопасности — нет)"
    else
      ui_line ok "Система обновлена"
    fi
  fi
  if [[ -f /var/run/reboot-required ]]; then ui_line warn "Нужна перезагрузка (обновилось ядро или библиотеки)"; fi
}

dash_render() { # dash_render [force] — выводит весь экран один раз
  local force=${1:-0}
  header "Dashboard"
  dash_system
  dash_network
  dash_services
  dash_docker
  dash_security "$force"
  printf '\n  %s%s%s\n' "$C_DIM" "обновлено $(date '+%d.%m.%Y %H:%M:%S')" "$C_RESET"
}

mod_dashboard() {
  local auto=0 force=1 key rest rc
  if [[ ! -t 0 || ! -t 1 ]]; then dash_render 1; return 0; fi
  while true; do
    dash_render "$force"
    force=0
    printf '\n  %s[r]%s обновить   %s[a]%s авто каждые 5 с: %s   %s[q]%s назад\n' \
      "${C_BOLD}${C_CYAN}" "$C_RESET" "${C_BOLD}${C_CYAN}" "$C_RESET" "$( ((auto)) && echo "${C_GREEN}вкл${C_RESET}" || echo "выкл")" "${C_BOLD}${C_CYAN}" "$C_RESET"
    key=""
    if (( auto )); then
      IFS= read -rsn1 -t 5 key
      rc=$?
      if (( rc > 128 )); then continue; fi
    else
      IFS= read -rsn1 key || return 0
    fi
    case $key in
      r|R|к|К) force=1 ;;
      a|A|ф|Ф) auto=$(( ! auto )) ;;
      q|Q|0|й|Й) return 0 ;;
      $'\e')
        rest=""
        IFS= read -rsn2 -t 0.05 rest || true
        while IFS= read -rsn1 -t 0.005 _; do :; done
        if [[ -z $rest ]]; then return 0; fi
        ;;
    esac
  done
}
