# ══════════════════════════ Log Analyzer ══════════════════════════
# Диагностика журналов. Модуль только читает логи и не меняет состояние сервера.

LA_REPORT_DIR=/var/backups/vpsmenu
LA_TIMEOUT=12
LA_PERIOD=24h
LA_PRIORITY=3
LA_RAW=
LA_GROUP_FILE=
LA_STATUS=
LA_SSH_OK=0
LA_SSH_FAIL=0

la_since() {
  case "$1" in
    1h) echo "1 hour ago" ;; 6h) echo "6 hours ago" ;; 24h) echo "24 hours ago" ;;
    3d) echo "3 days ago" ;; 7d) echo "7 days ago" ;; *) echo "24 hours ago" ;;
  esac
}

la_normalize() {
  sed -E -e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<IP>/g' \
    -e 's/(sshd|sudo|dockerd|containerd)\[[0-9]+\]/\1[PID]/g' \
    -e 's/(pid|PID)[=: ]+[0-9]+/\1=<PID>/g' \
    -e 's/(port|PORT)[=: ]+[0-9]+/\1=<PORT>/g' \
    -e 's/(user|username)[=: ]+[^ ,]+/\1=<USER>/g' <<<"$1"
}

la_collect_journal() {
  local src="$1" unit="$2" priority="$3" line ts body tmp rc
  shift 3
  if ! cmd_exists journalctl; then LA_STATUS="$LA_STATUS$src: unavailable"$'\n'; return 1; fi
  tmp="$(mktemp)" || return 1
  if timeout "$LA_TIMEOUT" journalctl --since "$(la_since "$LA_PERIOD")" --no-pager -o short-iso-precise -n 1500 -p "$priority" "$@" >"$tmp" 2>&1; then
    if [[ ! -s $tmp ]]; then LA_STATUS="$LA_STATUS$src: empty"$'\n'
    else
      LA_STATUS="$LA_STATUS$src: ok"$'\n'
      while IFS= read -r line; do
        [[ -n $line ]] || continue
        ts="$(awk '{print $1}' <<<"$line")"
        body="$(awk '{$1="";$2="";sub(/^  */,"");print}' <<<"$line")"
        body="$(tr '\t|' '  ' <<<"$body")"
        printf '%s\t%s\t%s\t%s\n' "$src" "$unit" "$ts" "$body" >>"$LA_RAW"
      done <"$tmp"
    fi
  else
    rc=$?
    if grep -qiE 'permission denied|access denied' "$tmp"; then LA_STATUS="$LA_STATUS$src: permission denied"$'\n'
    elif (( rc == 124 )); then LA_STATUS="$LA_STATUS$src: timeout"$'\n'
    else LA_STATUS="$LA_STATUS$src: query failed (exit $rc)"$'\n'; fi
  fi
  rm -f "$tmp"
}

la_collect_ssh() {
  local tmp line ts body
  if ! cmd_exists journalctl; then LA_STATUS="$LA_STATUS""SSH: unavailable"$'\n'; return; fi
  tmp="$(mktemp)" || return
  if timeout "$LA_TIMEOUT" journalctl --since "$(la_since "$LA_PERIOD")" --no-pager -o short-iso-precise -n 1500 -u ssh.service -u sshd.service -t sshd >"$tmp" 2>&1; then
    LA_STATUS="$LA_STATUS""SSH: ok"$'\n'
    LA_SSH_OK="$(grep -Eic 'Accepted (password|publickey|keyboard-interactive)' "$tmp" || true)"
    LA_SSH_FAIL="$(grep -Eic 'Failed (password|publickey)|authentication failure|Invalid user|maximum authentication attempts' "$tmp" || true)"
    while IFS= read -r line; do
      grep -qiE 'Failed (password|publickey)|authentication failure|Invalid user|maximum authentication attempts' <<<"$line" || continue
      ts="$(awk '{print $1}' <<<"$line")"
      body="$(awk '{$1="";$2="";sub(/^  */,"");print}' <<<"$line")"
      printf 'SSH\tsshd\t%s\t%s\n' "$ts" "$body" >>"$LA_RAW"
    done <"$tmp"
  else LA_STATUS="$LA_STATUS""SSH: query failed"$'\n'; fi
  rm -f "$tmp"
}

la_collect_systemd() {
  local units unit
  if ! cmd_exists systemctl || [[ ! -d /run/systemd/system ]]; then LA_STATUS="$LA_STATUS""systemd: unavailable"$'\n'; return; fi
  units="$(timeout "$LA_TIMEOUT" systemctl --failed --type=service --no-legend --plain --no-pager 2>/dev/null | awk '{print $1}' | head -n 20)"
  if [[ -z $units ]]; then LA_STATUS="$LA_STATUS""systemd failed units: none"$'\n'; return; fi
  LA_STATUS="$LA_STATUS""systemd failed units: $(wc -l <<<"$units")"$'\n'
  while IFS= read -r unit; do
    [[ -n $unit ]] && la_collect_journal systemd "$unit" "$LA_PRIORITY" -u "$unit"
  done <<<"$units"
}

la_collect_docker() {
  local names name tmp line ts body
  if ! cmd_exists docker || ! docker info >/dev/null 2>&1; then LA_STATUS="$LA_STATUS""Docker: unavailable"$'\n'; return; fi
  names="$(docker ps -a --format '{{.Names}}' 2>/dev/null | head -n 10)"
  if [[ -z $names ]]; then LA_STATUS="$LA_STATUS""Docker: no containers"$'\n'; return; fi
  LA_STATUS="$LA_STATUS""Docker: scanning up to 10 containers"$'\n'
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    tmp="$(mktemp)" || continue
    if timeout "$LA_TIMEOUT" docker logs --since "$LA_PERIOD" --tail 300 --timestamps "$name" >"$tmp" 2>&1; then
      while IFS= read -r line; do
        grep -qiE 'error|fatal|panic|failed|exception' <<<"$line" || continue
        ts="$(awk '{print $1}' <<<"$line")"; body="$(cut -d' ' -f2- <<<"$line")"
        printf 'Docker\t%s\t%s\t%s\n' "$name" "$ts" "$body" >>"$LA_RAW"
      done <"$tmp"
    fi
    rm -f "$tmp"
  done <<<"$names"
}

la_scan() {
  LA_RAW="$(mktemp)" || return 1
  chmod 600 "$LA_RAW"
  LA_STATUS=; LA_SSH_OK=0; LA_SSH_FAIL=0
  la_collect_journal system "" "$LA_PRIORITY"
  la_collect_journal kernel kernel "$LA_PRIORITY" -k
  la_collect_ssh
  la_collect_systemd
  la_collect_docker
  if cmd_exists docker && docker inspect remnanode >/dev/null 2>&1; then
    local tmp line ts body
    tmp="$(mktemp)"
    if timeout "$LA_TIMEOUT" docker logs --since "$LA_PERIOD" --tail 500 --timestamps remnanode >"$tmp" 2>&1; then
      while IFS= read -r line; do
        grep -qiE 'error|fatal|panic|failed|exception' <<<"$line" || continue
        ts="$(awk '{print $1}' <<<"$line")"; body="$(cut -d' ' -f2- <<<"$line")"
        printf 'Remnanode\tremnanode\t%s\t%s\n' "$ts" "$body" >>"$LA_RAW"
      done <"$tmp"
      LA_STATUS="$LA_STATUS""Remnanode: ok"$'\n'
    else LA_STATUS="$LA_STATUS""Remnanode: query failed"$'\n'; fi
    rm -f "$tmp"
  else LA_STATUS="$LA_STATUS""Remnanode: not configured"$'\n'; fi
  LA_GROUP_FILE="$(mktemp)"
  awk -F '\t' '{
    msg=$4
    gsub(/[0-9][0-9]?[0-9]?[.][0-9][0-9]?[0-9]?[.][0-9][0-9]?[0-9]?[.][0-9][0-9]?[0-9]?/, "<IP>", msg)
    gsub(/sshd\\[[0-9]+\\]/, "sshd[PID]", msg)
    gsub(/pid[=: ]+[0-9]+/, "pid=<PID>", msg)
    gsub(/port[=: ]+[0-9]+/, "port=<PORT>", msg)
    key=$1 "|" $2 "|" msg
    count[key]++
    if (!(key in first) || $3 < first[key]) first[key]=$3
    if (!(key in last) || $3 > last[key]) last[key]=$3
  } END { for (k in count) print count[k] "|" k "|" first[k] "|" last[k] }' "$LA_RAW" | sort -t'|' -k1,1nr >"$LA_GROUP_FILE"
}

la_export() {
  local stamp path
  mkdir -p "$LA_REPORT_DIR" || return 1
  chmod 700 "$LA_REPORT_DIR" 2>/dev/null || true
  stamp="$(date +%Y%m%d-%H%M%S)"
  path="$LA_REPORT_DIR/log-analyzer-$stamp-$BASHPID.txt"
  {
    echo "VPSMENU LOG ANALYZER"
    echo "Generated: $(date -Is)"
    echo "Period: $LA_PERIOD; priority: $LA_PRIORITY"
    echo; echo "[SOURCE STATUS]"; printf '%s' "$LA_STATUS"
    echo; echo "[SSH]"; printf 'Successful logins: %s\nFailed logins: %s\n' "$LA_SSH_OK" "$LA_SSH_FAIL"
    echo; echo "[GROUPED EVENTS]"; cat "$LA_GROUP_FILE"
    echo; echo "[RAW EVENTS: first 500]"; head -n 500 "$LA_RAW"
  } >"$path" || { rm -f "$path"; return 1; }
  chmod 600 "$path" || { rm -f "$path"; return 1; }
  echo "$path"
}

menu_logs() {
  local line src unit first from until report
  while true; do
    header "Log Analyzer"
    printf '  Период: %s · приоритет: %s\n\n' "$LA_PERIOD" "$LA_PRIORITY"
    menu_item 1 "Сканировать журналы"
    menu_item 2 "Период: 1h / 6h / 24h / 3d / 7d"
    menu_item 3 "Ошибки / ошибки + предупреждения"
    menu_item 4 "Экспорт TXT-отчёта"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1)
        la_scan
        header "Log Analyzer — сводка"
        printf '  Период: %s · приоритет: %s\n\n' "$LA_PERIOD" "$LA_PRIORITY"
        printf '%s' "$LA_STATUS"
        printf '\n  SSH: успешных входов %s · неудачных %s\n' "$LA_SSH_OK" "$LA_SSH_FAIL"
        echo; printf '  Групп ошибок: %s\n' "$(wc -l <"$LA_GROUP_FILE")"
        echo
        awk -F'|' 'NR<=20 {printf "  %2d. [%s] %-9s %-22s %s\n", NR,$1,$2,$3,$4}' "$LA_GROUP_FILE"
        (( $(wc -l <"$LA_GROUP_FILE") == 0 )) && info "Событий не найдено."
        echo; menu_item 1 "Контекст первой группы"; menu_item 0 "Назад"; echo; read_choice
        if [[ $CHOICE == 1 && -s $LA_GROUP_FILE ]]; then
          line="$(head -n 1 "$LA_GROUP_FILE")"
          src="$(cut -d'|' -f2 <<<"$line")"; unit="$(cut -d'|' -f3 <<<"$line")"; first="$(cut -d'|' -f5 <<<"$line")"
          from="$(date -d "$first - 2 minutes" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
          until="$(date -d "$first + 1 minute" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
          header "Контекст события"
          if [[ $src == Docker || $src == Remnanode ]]; then
            docker logs --since "$from" --until "$until" --timestamps "$unit" 2>&1 | tail -n 100 | show_paged
          elif [[ $unit == kernel ]]; then
            journalctl -k --since "$from" --until "$until" --no-pager 2>&1 | tail -n 100 | show_paged
          elif [[ -n $unit ]]; then
            journalctl -u "$unit" --since "$from" --until "$until" --no-pager 2>&1 | tail -n 100 | show_paged
          else journalctl --since "$from" --until "$until" --no-pager 2>&1 | tail -n 100 | show_paged; fi
          pause
        fi
        ;;
      2)
        ask "Период (1h, 6h, 24h, 3d, 7d)" "$LA_PERIOD"
        case $ASK_RESULT in 1h|6h|24h|3d|7d) LA_PERIOD=$ASK_RESULT ;; *) warn "Неизвестный период." ;; esac
        ;;
      3) [[ $LA_PRIORITY == 3 ]] && LA_PRIORITY=4 || LA_PRIORITY=3 ;;
      4)
        if [[ -z $LA_GROUP_FILE || ! -f $LA_GROUP_FILE ]]; then warn "Сначала выполни сканирование."
        else report="$(la_export)" && ok "Отчёт сохранён: $report" || err "Не удалось сохранить отчёт."; fi
        pause
        ;;
      0|q|Q)
        [[ -n $LA_RAW ]] && rm -f "$LA_RAW"
        [[ -n $LA_GROUP_FILE ]] && rm -f "$LA_GROUP_FILE"
        return 0 ;;
      *) warn "Нет такого пункта." ;;
    esac
  done
}
