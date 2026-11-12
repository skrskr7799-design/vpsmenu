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
  sed -E -e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<IPV4>/g' \
    -e 's/([[:xdigit:]]{1,4}:){2,7}[[:xdigit:]]{0,4}/<IPV6>/g' \
    -e 's/(sshd|sudo|dockerd|containerd|systemd)\[[0-9]+\]/\1[PID]/g' \
    -e 's/(pid|PID)[=: ]+[0-9]+/\1=<PID>/g' \
    -e 's/(port|PORT)[=: ]+[0-9]+/\1=<PORT>/g' \
    -e 's/(user|username)[=: ]+[^ ,;]+/\1=<USER>/g' \
    -e 's/for (invalid user|user) [^ ]+/for \1 <USER>/Ig' <<<"$1"
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
  local tmp line ts body rc
  if ! cmd_exists journalctl; then LA_STATUS="$LA_STATUS""SSH: unavailable"$'\n'; return; fi
  tmp="$(mktemp)" || { LA_STATUS="$LA_STATUS""SSH: temp-file error"$'\n'; return; }
  timeout "$LA_TIMEOUT" journalctl --since "$(la_since "$LA_PERIOD")" --no-pager -o short-iso-precise -n 1500 -u ssh.service -u sshd.service -t sshd >"$tmp" 2>&1
  rc=$?
  if (( rc == 0 )) && ! grep -qiE 'permission denied|access denied' "$tmp"; then
    LA_SSH_OK="$(grep -Eic 'Accepted (password|publickey|keyboard-interactive)' "$tmp" || true)"
    LA_SSH_FAIL="$(grep -Eic 'Failed (password|publickey)|authentication failure|Invalid user|maximum authentication attempts' "$tmp" || true)"
    if [[ -s $tmp ]]; then
      while IFS= read -r line; do
        grep -qiE 'Accepted (password|publickey|keyboard-interactive)|Failed (password|publickey)|authentication failure|Invalid user|maximum authentication attempts' <<<"$line" || continue
        ts="$(awk '{print $1}' <<<"$line")"
        body="$(awk '{$1="";$2="";sub(/^  */,"");print}' <<<"$line")"
        body="$(printf '%s' "$body" | tr '\t|' '  ')"
        printf 'SSH\tsshd\t%s\t%s\n' "$ts" "$body" >>"$LA_RAW"
      done <"$tmp"
      LA_STATUS="$LA_STATUS""SSH: ok (успешных: $LA_SSH_OK; неудачных: $LA_SSH_FAIL)"$'\n'
    else LA_STATUS="$LA_STATUS""SSH: empty"$'\n'; fi
  elif grep -qiE 'permission denied|access denied' "$tmp"; then LA_STATUS="$LA_STATUS""SSH: permission denied"$'\n'
  elif (( rc == 124 || rc == 137 )); then LA_STATUS="$LA_STATUS""SSH: timeout"$'\n'
  else LA_STATUS="$LA_STATUS""SSH: query failed (exit $rc)"$'\n'; fi
  rm -f "$tmp"
}
la_collect_systemd() {
  local tmp units unit rc count=0
  if ! cmd_exists systemctl || [[ ! -d /run/systemd/system ]]; then LA_STATUS="$LA_STATUS""systemd: unavailable"$'\n'; return; fi
  tmp="$(mktemp)" || { LA_STATUS="$LA_STATUS""systemd: temp-file error"$'\n'; return; }
  timeout "$LA_TIMEOUT" systemctl --failed --type=service --no-legend --plain --no-pager >"$tmp" 2>&1
  rc=$?
  if (( rc != 0 )); then
    if grep -qiE 'permission denied|access denied' "$tmp"; then LA_STATUS="$LA_STATUS""systemd: permission denied"$'\n'
    elif (( rc == 124 || rc == 137 )); then LA_STATUS="$LA_STATUS""systemd: timeout"$'\n'
    else LA_STATUS="$LA_STATUS""systemd: query failed (exit $rc)"$'\n'; fi
    rm -f "$tmp"; return
  fi
  if grep -qiE 'permission denied|access denied' "$tmp"; then LA_STATUS="$LA_STATUS""systemd: permission denied"$'\n'; rm -f "$tmp"; return; fi
  units="$(awk 'NF {print $1}' "$tmp" | grep -E '^[A-Za-z0-9_.@:-]+\.service$' | head -n 20)"
  if [[ -z $units ]]; then
    LA_STATUS="$LA_STATUS""systemd failed units: none"$'\n'
  else
    while IFS= read -r unit; do
      [[ -n $unit ]] || continue
      count=$((count + 1))
      la_collect_journal systemd "$unit" "$LA_PRIORITY" -u "$unit"
    done <<<"$units"
    LA_STATUS="$LA_STATUS""systemd failed units: $count (limit 20)"$'\n'
  fi
  rm -f "$tmp"
}
la_collect_docker() {
  local tmp names name line ts body rc count=0 failed=0
  if ! cmd_exists docker; then LA_STATUS="$LA_STATUS""Docker: unavailable (docker missing)"$'\n'; return; fi
  timeout "$LA_TIMEOUT" docker info >/dev/null 2>&1
  rc=$?
  if (( rc != 0 )); then
    if (( rc == 124 || rc == 137 )); then LA_STATUS="$LA_STATUS""Docker: timeout"$'\n'
    else LA_STATUS="$LA_STATUS""Docker: unavailable (daemon unreachable)"$'\n'; fi
    return
  fi
  tmp="$(mktemp)" || { LA_STATUS="$LA_STATUS""Docker: temp-file error"$'\n'; return; }
  timeout "$LA_TIMEOUT" docker ps -a --format '{{.Names}}' >"$tmp" 2>&1
  rc=$?
  if (( rc != 0 )); then LA_STATUS="$LA_STATUS""Docker: container list failed (exit $rc)"$'\n'; rm -f "$tmp"; return; fi
  names="$(head -n 10 "$tmp")"
  if [[ -z $names ]]; then LA_STATUS="$LA_STATUS""Docker: no containers"$'\n'; rm -f "$tmp"; return; fi
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    [[ $name == "$REMNA_CONTAINER" ]] && continue
    count=$((count + 1))
    timeout "$LA_TIMEOUT" docker logs --since "$LA_PERIOD" --tail 300 --timestamps "$name" >"$tmp" 2>&1
    rc=$?
    if (( rc == 0 )); then
      while IFS= read -r line; do
        if [[ $LA_PRIORITY == 3 ]]; then
          grep -qiE 'error|fatal|panic|failed|exception|critical' <<<"$line" || continue
        else
          grep -qiE 'error|fatal|panic|failed|exception|critical|warn(ing)?' <<<"$line" || continue
        fi
        ts="$(awk '{print $1}' <<<"$line")"; body="$(cut -d' ' -f2- <<<"$line")"
        body="$(printf '%s' "$body" | tr '\t|' '  ')"
        printf 'Docker\t%s\t%s\t%s\n' "$name" "$ts" "$body" >>"$LA_RAW"
      done <"$tmp"
    else
      failed=$((failed + 1))
      if grep -qiE 'permission denied|access denied' "$tmp"; then LA_STATUS="$LA_STATUS""Docker/$name: permission denied"$'\n'
      elif (( rc == 124 || rc == 137 )); then LA_STATUS="$LA_STATUS""Docker/$name: timeout"$'\n'
      else LA_STATUS="$LA_STATUS""Docker/$name: query failed (exit $rc)"$'\n'; fi
    fi
  done <<<"$names"
  if (( failed == 0 )); then LA_STATUS="$LA_STATUS""Docker: ok (containers checked: $count)"$'\n'
  else LA_STATUS="$LA_STATUS""Docker: partial ($failed container log queries failed)"$'\n'; fi
  rm -f "$tmp"
}
la_build_groups() {
  local source unit timestamp message normalized epoch severity tmp group_tmp
  tmp="$(mktemp)" || return 1
  : >"$tmp"
  while IFS=$'\t' read -r source unit timestamp message; do
    [[ -n $source && -n $timestamp && -n $message ]] || continue
    normalized="$(la_normalize "$message")"
    epoch="$(date -d "$timestamp" +%s 2>/dev/null)" || continue
    severity=error
    grep -qiE 'warn(ing)?' <<<"$message" && severity=warning
    message="$(printf '%s' "$message" | tr '\t\r\n' '   ')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$source" "$unit" "$timestamp" "$epoch" "$severity" "$message" "$normalized" >>"$tmp"
  done <"$LA_RAW"
  group_tmp="$(mktemp)" || { rm -f "$tmp"; return 1; }
  awk -F '\t' -v OFS='\t' '
    NF >= 7 {
      key=$1 SUBSEP $2 SUBSEP $7
      count[key]++
      if (!(key in first_epoch) || $4+0 < first_epoch[key]) { first_epoch[key]=$4+0; first[key]=$3 }
      if (!(key in last_epoch) || $4+0 > last_epoch[key]) { last_epoch[key]=$4+0; last[key]=$3 }
      if ($5 == "error") has_error[key]=1
      if (!seen[key SUBSEP $6] && examples[key] < 3) { seen[key SUBSEP $6]=1; n=++examples[key]; example[key,n]=$6 }
      source[key]=$1; unit[key]=$2; normalized[key]=$7
    }
    END {
      for (key in count) {
        severity=(has_error[key] ? "error" : "warning")
        print count[key],source[key],unit[key],first[key],last[key],severity,normalized[key],example[key,1],example[key,2],example[key,3],first_epoch[key]
      }
    }' "$tmp" | sort -t "$(printf '\t')" -k1,1nr -k11,11n >"$group_tmp"
  rm -f "$tmp"
  [[ -n $LA_GROUP_FILE ]] && rm -f "$LA_GROUP_FILE"
  LA_GROUP_FILE="$group_tmp"
}
la_scan() {
  [[ -n $LA_RAW && -f $LA_RAW ]] && rm -f "$LA_RAW"
  [[ -n $LA_GROUP_FILE && -f $LA_GROUP_FILE ]] && rm -f "$LA_GROUP_FILE"
  LA_RAW="$(mktemp)" || return 1
  chmod 600 "$LA_RAW"
  LA_STATUS=; LA_SSH_OK=0; LA_SSH_FAIL=0; LA_EVENT_COUNT=0
  la_collect_journal system "" "$LA_PRIORITY"
  la_collect_journal kernel kernel "$LA_PRIORITY" -k
  la_collect_ssh
  la_collect_systemd
  la_collect_docker
  if cmd_exists docker && docker inspect "$REMNA_CONTAINER" >/dev/null 2>&1; then
    local tmp line ts body
    tmp="$(mktemp)"
    if timeout "$LA_TIMEOUT" docker logs --since "$LA_PERIOD" --tail 500 --timestamps "$REMNA_CONTAINER" >"$tmp" 2>&1; then
      while IFS= read -r line; do
        grep -qiE 'error|fatal|panic|failed|exception' <<<"$line" || continue
        ts="$(awk '{print $1}' <<<"$line")"; body="$(cut -d' ' -f2- <<<"$line")"
        printf 'Remnanode\t%s\t%s\t%s\n' "$REMNA_CONTAINER" "$ts" "$body" >>"$LA_RAW"
      done <"$tmp"
      LA_STATUS+="Remnanode: ok"$'\n'
    else LA_STATUS+="Remnanode: query failed"$'\n'; fi
    rm -f "$tmp"
  else LA_STATUS+="Remnanode: not configured"$'\n'; fi
  la_build_groups || return 1
}
la_export() {
  local stamp path count source unit first last severity normalized e1 e2 e3 epoch
  [[ -n $LA_RAW && -f $LA_RAW && -n $LA_GROUP_FILE && -f $LA_GROUP_FILE ]] || return 1
  mkdir -p "$LA_REPORT_DIR" || return 1
  chmod 700 "$LA_REPORT_DIR" 2>/dev/null || true
  umask 077
  stamp="$(date +%Y%m%d-%H%M%S)"
  path="$(mktemp "$LA_REPORT_DIR/log-analyzer-$stamp-XXXXXX.txt")" || return 1
  {
    echo "VPSMENU LOG ANALYZER"
    echo "Generated: $(date -Is)"
    echo "Period: $LA_PERIOD; priority: $LA_PRIORITY"
    echo "Events: $(wc -l <"$LA_RAW"); groups: $(wc -l <"$LA_GROUP_FILE")"
    echo; echo "[SOURCE STATUS]"; printf '%s' "$LA_STATUS"
    echo; echo "[SSH]"; printf 'Successful logins: %s\nFailed logins: %s\n' "$LA_SSH_OK" "$LA_SSH_FAIL"
    echo; echo "[GROUPED EVENTS]"
    printf 'Count\tSource\tUnit\tFirst\tLast\tSeverity\tNormalized\tExample 1\tExample 2\tExample 3\n'
    while IFS=$'\t' read -r count source unit first last severity normalized e1 e2 e3 epoch; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$count" "$source" "$unit" "$first" "$last" "$severity" "$normalized" "$e1" "$e2" "$e3"
    done <"$LA_GROUP_FILE"
    echo; echo "[RAW EVENTS: first 500]"; head -n 500 "$LA_RAW"
  } >"$path" || { rm -f "$path"; return 1; }
  chmod 600 "$path" || { rm -f "$path"; return 1; }
  printf '%s\n' "$path"
}
menu_logs() {
  local page pages index line count source unit first last severity normalized e1 e2 e3 epoch report start end idx from until
  while true; do
    header "Log Analyzer"
    printf '  Период: %s · уровень: %s\n\n' "$LA_PERIOD" "$([[ $LA_PRIORITY == 3 ]] && echo ошибки || echo ошибки + предупреждения)"
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
        printf '  Период: %s · приоритет: %s\n' "$LA_PERIOD" "$LA_PRIORITY"
        printf '  Событий: %s · групп: %s · SSH: %s успешных / %s неудачных\n\n' "$(wc -l <"$LA_RAW")" "$(wc -l <"$LA_GROUP_FILE")" "$LA_SSH_OK" "$LA_SSH_FAIL"
        printf '%s' "$LA_STATUS"
        page=1
        while true; do
          pages=$(( ( $(wc -l <"$LA_GROUP_FILE") + 14 ) / 15 ))
          (( pages > 0 )) || pages=1
          start=$(( (page - 1) * 15 + 1 )); end=$(( start + 14 ))
          (( end > $(wc -l <"$LA_GROUP_FILE") )) && end=$(wc -l <"$LA_GROUP_FILE")
          printf '\n  Группы %d–%d · страница %d/%d\n\n' "$start" "$end" "$page" "$pages"
          idx=0
          while IFS=$'\t' read -r count source unit first last severity normalized e1 e2 e3 epoch; do
            idx=$((idx + 1))
            (( idx >= start && idx <= end )) || continue
            printf '  %2d. [%s] %-7s %-10s %-22s %s\n' "$idx" "$count" "$severity" "$source" "$unit" "$(ui_trunc "$normalized" $(( UI_W - 52 )))"
          done <"$LA_GROUP_FILE"
          (( $(wc -l <"$LA_GROUP_FILE") == 0 )) && info "Событий не найдено."
          echo
          (( page > 1 )) && menu_item p "Предыдущая страница"
          (( page < pages )) && menu_item n "Следующая страница"
          (( $(wc -l <"$LA_GROUP_FILE") > 0 )) && menu_item o "Открыть группу по номеру"
          menu_item 0 "Назад к Log Analyzer"
          echo; read_choice
          case $CHOICE in
            p|P) (( page > 1 )) && page=$((page - 1)) ;;
            n|N) (( page < pages )) && page=$((page + 1)) ;;
            o|O)
              ask "Номер группы (1-$(wc -l <"$LA_GROUP_FILE"))" "1"
              index=$ASK_RESULT
              if [[ $index =~ ^[0-9]+$ ]] && (( index >= 1 && index <= $(wc -l <"$LA_GROUP_FILE") )); then
                line="$(sed -n "$index"'p' "$LA_GROUP_FILE")"
                IFS=$'\t' read -r count source unit first last severity normalized e1 e2 e3 epoch <<<"$line"
                header "Контекст события"
                printf '  Источник: %s · %s\n  Повторов: %s · первое: %s · последнее: %s\n  Шаблон: %s\n' "$source" "$unit" "$count" "$first" "$last" "$normalized"
                printf '  Примеры:\n    - %s\n    - %s\n    - %s\n' "$e1" "$e2" "$e3"
                from="$(date -d "$first - 2 minutes" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
                until="$(date -d "$first + 1 minute" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
                if [[ $source == Docker || $source == Remnanode ]]; then
                  docker logs --since "$from" --until "$until" --timestamps "$unit" 2>&1 | tail -n 100 | show_paged
                elif [[ $source == SSH ]]; then
                  journalctl -t sshd --since "$from" --until "$until" --no-pager -o short-iso-precise 2>&1 | tail -n 100 | show_paged
                elif [[ $unit == kernel ]]; then
                  journalctl -k --since "$from" --until "$until" --no-pager -o short-iso-precise 2>&1 | tail -n 100 | show_paged
                elif [[ -n $unit ]]; then
                  journalctl -u "$unit" --since "$from" --until "$until" --no-pager -o short-iso-precise 2>&1 | tail -n 100 | show_paged
                else
                  journalctl --since "$from" --until "$until" --no-pager -o short-iso-precise 2>&1 | tail -n 100 | show_paged
                fi
                pause
              else warn "Некорректный номер группы."; pause; fi ;;
            0|q|Q) break ;;
            *) warn "Нет такого пункта."; sleep 1 ;;
          esac
        done ;;
      2)
        ask "Период (1h, 6h, 24h, 3d, 7d)" "$LA_PERIOD"
        case $ASK_RESULT in 1h|6h|24h|3d|7d) LA_PERIOD=$ASK_RESULT ;; *) warn "Неизвестный период." ;; esac ;;
      3) [[ $LA_PRIORITY == 3 ]] && LA_PRIORITY=4 || LA_PRIORITY=3 ;;
      4)
        if [[ -z $LA_RAW || ! -f $LA_RAW ]]; then warn "Сначала выполни сканирование."
        elif report="$(la_export)"; then ok "Отчёт сохранён: $report"
        else err "Не удалось сохранить отчёт."; fi
        pause ;;
      0|q|Q)
        [[ -n $LA_RAW ]] && rm -f "$LA_RAW"
        [[ -n $LA_GROUP_FILE ]] && rm -f "$LA_GROUP_FILE"
        return 0 ;;
      *) warn "Нет такого пункта." ;;
    esac
  done
}
