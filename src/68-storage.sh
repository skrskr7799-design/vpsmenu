# ══════════════════════════ Storage Analyzer ══════════════════════════
# Не просто «диск заполнен на 87%», а «куда именно ушло место»: топ каталогов (проводник с заходом внутрь),
# журнал systemd, логи, Docker (образы, тома, логи контейнеров), старые ядра, кэш apt, snap, дампы.
# Очистка только безопасных категорий и только с предпросмотром и подтверждением. Тома Docker и
# произвольные файлы автоматически НЕ удаляются: в них может быть то, что тебе нужно.

ST_LOG_DIR="${VPSMENU_ST_LOG_DIR:-/var/log}"
ST_APT_CACHE="${VPSMENU_ST_APT_CACHE:-/var/cache/apt/archives}"
ST_DOCKER_DIR="${VPSMENU_ST_DOCKER_DIR:-/var/lib/docker/containers}"
ST_SNAP_DIR="${VPSMENU_ST_SNAP_DIR:-/var/lib/snapd/snaps}"
ST_CRASH_DIRS="${VPSMENU_ST_CRASH_DIRS:-/var/crash /var/lib/systemd/coredump}"
ST_DU_TIMEOUT="${VPSMENU_ST_DU_TIMEOUT:-60}"
ST_JOURNAL_KEEP="200M"
ST_LOG_AGE_DAYS=14
ST_CRASH_AGE_DAYS=7

declare -a ST_ROWS=() ST_PLAN_IDS=() ST_PLAN_TITLES=() ST_PLAN_EST=()
ST_TOTAL_KB=0
ST_PARTIAL=0

# ── Измерения ───────────────────────────────────────────────────────────────
st_avail_kb() { df -Pk / 2>/dev/null | awk 'NR == 2 {print $4}'; }

st_dir_kb() { # размер каталога в КБ (0, если каталога нет)
  local v
  [[ -d $1 ]] || { echo 0; return 0; }
  v="$(du -sk -x "$1" 2>/dev/null | awk '{print $1}')"
  echo "${v:-0}"
}

st_du_scan() { # st_du_scan КАТАЛОГ [N] → ST_TOTAL_KB, ST_ROWS («КБ|путь», крупные первыми), ST_PARTIAL=1, если du не уложился во время
  local d=${1%/} n=${2:-9} out rc kb path sum=0
  [[ -n $d ]] || d=/
  ST_ROWS=(); ST_TOTAL_KB=0; ST_PARTIAL=0
  out="$(timeout "$ST_DU_TIMEOUT" du -x -k -d 1 "$d" 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then ST_PARTIAL=1; fi
  while IFS=$'\t' read -r kb path; do
    [[ $kb =~ ^[0-9]+$ ]] || continue
    if [[ $path == "$d" ]]; then ST_TOTAL_KB=$kb; continue; fi
    ST_ROWS+=("$kb|$path")
    sum=$(( sum + kb ))
  done <<<"$out"
  if (( ${#ST_ROWS[@]} > 0 )); then
    mapfile -t ST_ROWS < <(printf '%s\n' "${ST_ROWS[@]}" | sort -t'|' -k1,1nr | head -n "$n")
  fi
  if (( ST_TOTAL_KB == 0 )); then ST_TOTAL_KB=$sum; fi
}

st_journal_kb() { # размер журнала systemd в КБ (разбор «take up 1.4G in the file system»)
  local out v u int frac tenths
  cmd_exists journalctl || { echo 0; return 0; }
  out="$(journalctl --disk-usage 2>/dev/null)"
  v="$(grep -oE '[0-9]+(\.[0-9]+)?[KMGT]' <<<"$out" | head -n 1)"
  [[ -n $v ]] || { echo 0; return 0; }
  u=${v: -1}; v=${v%?}
  int=${v%%.*}
  frac=0
  if [[ $v == *.* ]]; then frac=${v#*.}; frac=${frac:0:1}; fi
  tenths=$(( 10#$int * 10 + 10#$frac ))
  case $u in
    K) echo $(( tenths / 10 )) ;;
    M) echo $(( tenths * 1024 / 10 )) ;;
    G) echo $(( tenths * 1048576 / 10 )) ;;
    T) echo $(( tenths * 1073741824 / 10 )) ;;
  esac
}

st_logs_rotated_list() { # старые архивы журналов: «байты<TAB>путь»
  [[ -d $ST_LOG_DIR ]] || return 0
  find "$ST_LOG_DIR" -xdev -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.zst' -o -name '*.old' -o -regex '.*\.[0-9]+' \) \
    -mtime +"$ST_LOG_AGE_DAYS" -printf '%s\t%p\n' 2>/dev/null
}

st_logs_big_list() { # st_logs_big_list МИН_МБ [N] — крупные файлы в каталоге журналов: «байты<TAB>путь»
  [[ -d $ST_LOG_DIR ]] || return 0
  find "$ST_LOG_DIR" -xdev -type f -size +"${1:-50}"M -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n "${2:-9}"
}

st_sum_bytes_kb() { awk -F'\t' '{s += $1} END {printf "%d", s / 1024}'; }

st_docker_ok() { cmd_exists docker && service_active docker; }

st_docker_names() { # «ID имя» всех контейнеров (для расшифровки каталогов логов)
  timeout 8 docker ps -a --format '{{.ID}} {{.Names}}' 2>/dev/null
}

st_docker_logs_list() { # «байты<TAB>имя<TAB>путь» логов контейнеров, крупные первыми
  local f dir id size name names
  [[ -d $ST_DOCKER_DIR ]] || return 0
  names="$(st_docker_names)"
  for f in "$ST_DOCKER_DIR"/*/*-json.log; do
    [[ -f $f && ! -L $f && ! -L "$(dirname "$f")" ]] || continue
    dir="$(basename "$(dirname "$f")")"
    id=${dir:0:12}
    size="$(stat -c %s "$f" 2>/dev/null)"
    name="$(awk -v i="$id" '$1 == i {print $2; exit}' <<<"$names")"
    printf '%s\t%s\t%s\n' "${size:-0}" "${name:-$id}" "$f"
  done | sort -rn
}

st_autoremove_sim() { apt-get -s autoremove 2>/dev/null | grep '^Remv'; }

st_old_kernels() { # «КБ<TAB>пакет» для устаревших ядер и их заголовков (то, что снимет autoremove)
  local pkg
  cmd_exists apt-get || return 0
  while read -r _ pkg _; do
    [[ $pkg == linux-image-* || $pkg == linux-modules-* || $pkg == linux-headers-* || $pkg == linux-tools-* ]] || continue
    printf '%s\t%s\n' "$(dpkg-query -W -f='${Installed-Size}' "$pkg" 2>/dev/null || echo 0)" "$pkg"
  done < <(st_autoremove_sim)
}

st_snap_old_list() { # отключённые (старые) ревизии snap: «КБ<TAB>имя<TAB>ревизия»
  local name ver rev rest sz
  cmd_exists snap || return 0
  while read -r name ver rev rest; do
    [[ $rest == *disabled* ]] || continue
    sz=0
    if [[ -f $ST_SNAP_DIR/${name}_${rev}.snap ]]; then sz=$(( $(stat -c %s "$ST_SNAP_DIR/${name}_${rev}.snap") / 1024 )); fi
    printf '%s\t%s\t%s\n' "$sz" "$name" "$rev"
  done < <(snap list --all 2>/dev/null | tail -n +2)
}

st_crash_list() { # старые дампы: «байты<TAB>путь»
  local d
  for d in $ST_CRASH_DIRS; do
    [[ -d $d ]] || continue
    find "$d" -xdev -type f -mtime +"$ST_CRASH_AGE_DAYS" -printf '%s\t%p\n' 2>/dev/null
  done
}

st_hint_for() { # подсказка по известному «тяжёлому» каталогу
  case $1 in
    /var/lib/docker*|/var/lib/containerd*) echo "Docker: образы, тома, логи (раздел «Docker: образы, тома, логи»)" ;;
    /var/log*)            echo "журналы: архивы и большие файлы можно почистить" ;;
    /var/cache*)          echo "кэши (в основном apt)" ;;
    /var/lib/snapd*|/snap*) echo "snap: старые ревизии можно удалить" ;;
    /var/lib/apt*|/var/lib/dpkg*) echo "база пакетов — не трогать" ;;
    /swapfile|*/swapfile) echo "swap-файл" ;;
    /home*)               echo "домашние каталоги пользователей" ;;
    /usr*)                echo "установленные программы" ;;
    /opt*)                echo "сторонние приложения (в том числе Remnanode)" ;;
    /tmp*|/var/tmp*)      echo "временные файлы" ;;
  esac
}

st_path_under_dir() { # st_path_under_dir ФАЙЛ КАТАЛОГ — обычный файл внутри каталога после разрешения ссылок
  local file=$1 base=$2 real_file real_base
  [[ -f $file && ! -L $file && -d $base ]] || return 1
  real_file="$(readlink -f -- "$file" 2>/dev/null)" || return 1
  real_base="$(readlink -f -- "$base" 2>/dev/null)" || return 1
  [[ -n $real_file && -n $real_base && $real_file == "$real_base/"* ]]
}

st_path_allowed() { # путь, который можно обнулять: только обычные файлы журналов и Docker JSON-логов
  local f=$1 parent
  st_path_under_dir "$f" "$ST_LOG_DIR" && return 0

  # Docker JSON-лог должен лежать непосредственно в каталоге конкретного контейнера.
  case ${f##*/} in *-json.log) ;; *) return 1 ;; esac
  parent="$(dirname -- "$f")"
  [[ "$(dirname -- "$parent")" == "$ST_DOCKER_DIR" ]] || return 1
  st_path_under_dir "$f" "$ST_DOCKER_DIR"
}

st_freed_report() { # st_freed_report ДО_КБ — сколько места освободилось по данным df
  local before=$1 after
  after="$(st_avail_kb)"
  if [[ $after =~ ^[0-9]+$ && $before =~ ^[0-9]+$ ]]; then
    if (( after > before )); then ok "Освободилось: $(ui_human_kb $(( after - before ))) (свободно теперь $(ui_human_kb "$after"))"
    else info "Свободного места: $(ui_human_kb "$after") (заметного изменения нет — удалённые файлы могли быть заняты процессами)"; fi
  fi
}

# ── Обзор: куда ушло место ──────────────────────────────────────────────────
st_overview_render() {
  local kb path pct bw=10 shown=0 line jkb rkb rcount docker_kb ak kern_kb kcount snap_kb scount crash_kb name size used mnt t total active recl
  local -a rows=()
  ui_section "Диски"
  while read -r _ size used _ pct mnt; do
    pct=${pct%\%}
    ui_meter "$(ui_trunc "$mnt" 7)" "$pct" "$(ui_human_kb "$used") / $(ui_human_kb "$size")"
  done < <(df -P -k -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2 | head -n 4)

  ui_section "Самые большие каталоги (/)"
  st_du_scan / 10
  if (( ST_PARTIAL )); then ui_line warn "Диск большой: подсчёт остановлен по времени (${ST_DU_TIMEOUT} с), результат неполный"; fi
  for line in "${ST_ROWS[@]}"; do
    kb=${line%%|*}; path=${line#*|}
    pct=0; if (( ST_TOTAL_KB > 0 )); then pct=$(( 100 * kb / ST_TOTAL_KB )); fi
    printf '  %s %s%4d%%%s %s  %s\n' "$(ui_bar "$pct" "$bw")" "$C_BOLD" "$pct" "$C_RESET" "$(ui_pad "$(ui_human_kb "$kb")" 7)" "$(ui_trunc "$path" $(( UI_W - 28 )))"
    line="$(st_hint_for "$path")"
    if [[ -n $line && $shown -lt 4 ]]; then printf '  %s%s↳ %s%s\n' "$(ui_pad "" 19)" "$C_DIM" "$line" "$C_RESET"; shown=$(( shown + 1 )); fi
  done

  ui_section "Что можно почистить"
  jkb="$(st_journal_kb)"
  ui_kv "Журнал" "$(ui_human_kb "$jkb") ${C_DIM}systemd (journalctl)${C_RESET}" 11
  rkb="$(st_logs_rotated_list | st_sum_bytes_kb)"; rcount="$(st_logs_rotated_list | wc -l)"
  ui_kv "Логи" "архивы старше ${ST_LOG_AGE_DAYS} дн.: $(ui_human_kb "${rkb:-0}") ${C_DIM}($rcount файлов)${C_RESET}" 11
  mapfile -t rows < <(st_logs_big_list 50 3)
  for line in "${rows[@]}"; do
    [[ -n $line ]] || continue
    printf '  %s %s%s  %s%s\n' "$(ui_pad "" 11)" "$C_DIM" "$(ui_pad "$(ui_human_kb $(( ${line%%$'\t'*} / 1024 )))" 7)" "$(ui_trunc "${line#*$'\t'}" $(( UI_W - 24 )))" "$C_RESET"
  done
  if st_docker_ok; then
    timeout 15 docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null | while IFS='|' read -r t total active size recl; do
      printf '  %s %s%s шт., активных %s · %s · освобождаемо %s\n' "$(ui_pad "${C_DIM}Docker${C_RESET}" 11)" "$(ui_pad "$t" 14)" "$total" "$active" "$size" "$recl"
    done
    docker_kb="$(st_docker_logs_list | st_sum_bytes_kb)"
    if (( ${docker_kb:-0} > 0 )); then
      name="$(st_docker_logs_list | head -n 1 | cut -f2)"
      ui_kv "Docker" "логи контейнеров: $(ui_human_kb "$docker_kb") ${C_DIM}(больше всего у «$name»)${C_RESET}" 11
    fi
  else
    ui_kv "Docker" "${C_DIM}не запущен или не установлен${C_RESET}" 11
  fi
  ak="$(st_dir_kb "$ST_APT_CACHE")"
  ui_kv "Кэш apt" "$(ui_human_kb "$ak")" 11
  kern_kb="$(st_old_kernels | awk -F'\t' '{s += $1} END {printf "%d", s}')"; kcount="$(st_old_kernels | wc -l)"
  ui_kv "Ядра" "устаревших пакетов: $kcount · $(ui_human_kb "${kern_kb:-0}") ${C_DIM}(снимет autoremove)${C_RESET}" 11
  if cmd_exists snap; then
    snap_kb="$(st_snap_old_list | awk -F'\t' '{s += $1} END {printf "%d", s}')"; scount="$(st_snap_old_list | wc -l)"
    ui_kv "Snap" "старых ревизий: $scount · $(ui_human_kb "${snap_kb:-0}")" 11
  fi
  crash_kb="$(st_crash_list | st_sum_bytes_kb)"
  ui_kv "Дампы" "$(ui_human_kb "${crash_kb:-0}") ${C_DIM}(старше ${ST_CRASH_AGE_DAYS} дн.)${C_RESET}" 11
  echo
  hint "Освободить безопасно: пункт «Безопасная очистка». Тома Docker и свои файлы скрипт сам не удаляет."
}

mod_st_overview() {
  header "Куда ушло место"
  if [[ -t 1 ]]; then printf '  %sсчитаю размеры (на большом диске до минуты)…%s\n' "$C_DIM" "$C_RESET"; fi
  st_overview_render
  pause
}

# ── Проводник по размерам ───────────────────────────────────────────────────
st_explore() { # st_explore [КАТАЛОГ] — цифра: зайти, u: вверх, q: назад
  local dir=${1:-/} scan=1 key rest line kb path pct i hintt
  while true; do
    if (( scan )); then
      header "Проводник: $dir"
      if [[ -t 1 ]]; then printf '  %sсчитаю размеры…%s' "$C_DIM" "$C_RESET"; fi
      st_du_scan "$dir" 9
      if [[ -t 1 ]]; then printf '\r\e[K'; fi
      scan=0
    fi
    header "Проводник: $dir"
    printf '  %sВсего в каталоге:%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$(ui_human_kb "$ST_TOTAL_KB")" "$C_RESET"
    if (( ST_PARTIAL )); then ui_line warn "Подсчёт остановлен по времени — результат неполный"; fi
    echo
    if (( ${#ST_ROWS[@]} == 0 )); then printf '  %sвнутри нет вложенных каталогов или файлов%s\n' "$C_DIM" "$C_RESET"; fi
    for i in "${!ST_ROWS[@]}"; do
      line=${ST_ROWS[$i]}; kb=${line%%|*}; path=${line#*|}
      pct=0; if (( ST_TOTAL_KB > 0 )); then pct=$(( 100 * kb / ST_TOTAL_KB )); fi
      printf '  %s%d%s %s %s%3d%%%s %s %s\n' "${C_BOLD}${C_CYAN}" "$(( i + 1 ))" "$C_RESET" "$(ui_bar "$pct" 10)" "$C_BOLD" "$pct" "$C_RESET" \
        "$(ui_pad "$(ui_human_kb "$kb")" 7)" "$(ui_trunc "$path" $(( UI_W - 28 )))"
      hintt="$(st_hint_for "$path")"
      if [[ -n $hintt ]]; then printf '  %s%s↳ %s%s\n' "$(ui_pad "" 21)" "$C_DIM" "$hintt" "$C_RESET"; fi
    done
    printf '\n  %s1–9 зайти · u вверх · q назад%s\n  %s❯%s ' "$C_DIM" "$C_RESET" "$C_CYAN" "$C_RESET"
    IFS= read -rsn1 key || { echo; return 0; }
    case $key in
      [1-9])
        i=$(( key - 1 ))
        if (( i < ${#ST_ROWS[@]} )); then
          path=${ST_ROWS[$i]#*|}
          if [[ -d $path ]]; then dir=$path; scan=1; else echo; warn "Это файл, а не каталог: $path"; sleep 1; fi
        fi
        ;;
      u|U|г|Г)
        if [[ $dir != / ]]; then dir="$(dirname "$dir")"; scan=1; fi
        ;;
      q|Q|0|й|Й) echo; return 0 ;;
      $'\e')
        rest=""
        IFS= read -rsn2 -t 0.05 rest || true
        while IFS= read -rsn1 -t 0.005 _; do :; done
        case $rest in
          "[D") if [[ $dir != / ]]; then dir="$(dirname "$dir")"; scan=1; fi ;;
          "")   echo; return 0 ;;
        esac
        ;;
    esac
  done
}

# ── Безопасная очистка ──────────────────────────────────────────────────────
st_plan_add() { ST_PLAN_IDS+=("$1"); ST_PLAN_TITLES+=("$2"); ST_PLAN_EST+=("$3"); }

st_keep_kb() { # ST_JOURNAL_KEEP (например 200M) в КБ
  case $ST_JOURNAL_KEEP in
    *G) echo $(( ${ST_JOURNAL_KEEP%G} * 1048576 )) ;;
    *M) echo $(( ${ST_JOURNAL_KEEP%M} * 1024 )) ;;
    *K) echo "${ST_JOURNAL_KEEP%K}" ;;
    *)  echo 0 ;;
  esac
}

st_safe_plan() { # собирает план безопасной очистки с оценками (КБ; -1 — неизвестно)
  local v keep
  ST_PLAN_IDS=(); ST_PLAN_TITLES=(); ST_PLAN_EST=()
  v="$(st_dir_kb "$ST_APT_CACHE")"
  if (( v > 0 )); then st_plan_add apt "Кэш apt (apt-get clean)" "$v"; fi
  v="$(st_journal_kb)"; keep="$(st_keep_kb)"
  if (( v > keep )); then st_plan_add journal "Журнал systemd: оставить $ST_JOURNAL_KEEP" "$(( v - keep ))"; fi
  v="$(st_logs_rotated_list | st_sum_bytes_kb)"
  if (( ${v:-0} > 0 )); then st_plan_add logs "Архивы журналов старше $ST_LOG_AGE_DAYS дн. в $ST_LOG_DIR" "$v"; fi
  v="$(st_snap_old_list | awk -F'\t' '{s += $1} END {printf "%d", s}')"
  if (( ${v:-0} > 0 )); then st_plan_add snap "Старые ревизии snap" "$v"; fi
  v="$(st_crash_list | st_sum_bytes_kb)"
  if (( ${v:-0} > 0 )); then st_plan_add crash "Дампы падений старше $ST_CRASH_AGE_DAYS дн." "$v"; fi
  if st_docker_ok; then st_plan_add docker "Docker: неиспользуемые («висячие») образы и кэш сборки" "-1"; fi
}

st_do_step() { # st_do_step ИДЕНТИФИКАТОР
  local name rev
  case $1 in
    apt)     apt-get clean ;;
    journal) journalctl --vacuum-size="$ST_JOURNAL_KEEP" ;;
    logs)
      find "$ST_LOG_DIR" -xdev -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.zst' -o -name '*.old' -o -regex '.*\.[0-9]+' \) \
        -mtime +"$ST_LOG_AGE_DAYS" -delete ;;
    snap)
      while IFS=$'\t' read -r _ name rev; do
        [[ -n $name ]] && snap remove "$name" --revision="$rev"
      done < <(st_snap_old_list) ;;
    crash)
      for name in $ST_CRASH_DIRS; do
        [[ -d $name ]] && find "$name" -xdev -type f -mtime +"$ST_CRASH_AGE_DAYS" -delete
      done ;;
    docker)
      docker image prune -f && docker builder prune -f ;;
    *) return 1 ;;
  esac
}

mod_st_safe_clean() {
  local i before total=0 est
  header "Безопасная очистка"
  st_safe_plan
  if (( ${#ST_PLAN_IDS[@]} == 0 )); then ok "Безопасно чистить пока нечего."; pause; return 0; fi
  info "Предпросмотр: что будет очищено"
  echo
  for i in "${!ST_PLAN_IDS[@]}"; do
    est=${ST_PLAN_EST[$i]}
    if (( est >= 0 )); then
      printf '   %s•%s %s %s%s%s\n' "$C_GREEN" "$C_RESET" "$(ui_pad "$(ui_trunc "${ST_PLAN_TITLES[$i]}" $(( UI_W - 16 )))" $(( UI_W - 16 )))" "$C_BOLD" "$(ui_human_kb "$est")" "$C_RESET"
      total=$(( total + est ))
    else
      printf '   %s•%s %s %sпо данным docker%s\n' "$C_GREEN" "$C_RESET" "$(ui_pad "$(ui_trunc "${ST_PLAN_TITLES[$i]}" $(( UI_W - 16 )))" $(( UI_W - 16 )))" "$C_DIM" "$C_RESET"
    fi
  done
  echo
  printf '  Ориентировочно освободится: %s%s%s и ещё сколько-то в Docker\n' "$C_BOLD" "$(ui_human_kb "$total")" "$C_RESET"
  hint "Не затрагиваются: тома Docker, остановленные контейнеры, старые ядра, ваши файлы."
  echo
  confirm "Выполнить очистку?" N || { info "Отменено."; pause; return 0; }
  before="$(st_avail_kb)"
  for i in "${!ST_PLAN_IDS[@]}"; do
    step "${ST_PLAN_TITLES[$i]}"
    if st_do_step "${ST_PLAN_IDS[$i]}" >/dev/null 2>&1; then ok "Готово."; else err "Шаг завершился с ошибкой — продолжаю со следующим."; fi
  done
  log INFO "Безопасная очистка выполнена"
  echo
  st_freed_report "$before"
  pause
}

# ── Очистка по категориям ───────────────────────────────────────────────────
st_pick_file() { # st_pick_file «байты<TAB>[имя<TAB>]путь»… → $ST_PICKED (последнее поле строки); код 1 — отмена
  local -a lines=("$@")
  local i line sz label n
  ST_PICKED=""
  if (( ${#lines[@]} == 0 )); then warn "Подходящих файлов нет."; return 1; fi
  for i in "${!lines[@]}"; do
    if (( i >= 9 )); then break; fi
    line=${lines[$i]}
    sz=${line%%$'\t'*}
    label=${line#*$'\t'}
    menu_item "$(( i + 1 ))" "$(ui_pad "$(ui_human_kb $(( sz / 1024 )))" 7) $(ui_trunc "${label//$'\t'/  }" $(( UI_W - 14 )))"
  done
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    [1-9])
      n=$(( CHOICE - 1 ))
      if (( n < ${#lines[@]} && n < 9 )); then ST_PICKED=${lines[$n]##*$'\t'}; return 0; fi
      ;;
  esac
  return 1
}

st_truncate_file() { # st_truncate_file ПУТЬ — обнуляет файл (процесс продолжает писать в него)
  local f=$1 before
  if ! st_path_allowed "$f"; then err "Этот путь нельзя обнулять автоматически: $f"; return 1; fi
  before="$(stat -c %s "$f" 2>/dev/null)"
  if truncate -s 0 "$f"; then ok "Обнулён: $f (было $(ui_human_kb $(( ${before:-0} / 1024 ))))"; log INFO "Обнулён файл $f"; else err "Не удалось обнулить $f"; return 1; fi
}

mod_st_logs() {
  local -a rows=()
  local n kb
  while true; do
    header "Логи: архивы и большие файлы"
    kb="$(st_logs_rotated_list | st_sum_bytes_kb)"; n="$(st_logs_rotated_list | wc -l)"
    ui_kv "Архивы" "старше $ST_LOG_AGE_DAYS дн.: $n файлов · $(ui_human_kb "${kb:-0}")" 11
    ui_kv "Журнал" "systemd: $(ui_human_kb "$(st_journal_kb)")" 11
    echo
    menu_item 1 "Удалить старые архивы журналов (предпросмотр → подтверждение)"
    menu_item 2 "Обнулить крупный файл журнала (выбор из списка)"
    menu_item 3 "Журнал systemd: оставить только последнее (vacuum)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_st_logs_rotated ;;
      2)
        header "Обнулить крупный файл журнала"
        hint "Файлы от 50 МБ в $ST_LOG_DIR. Содержимое будет потеряно, сам файл останется."
        mapfile -t rows < <(st_logs_big_list 50 9)
        if st_pick_file "${rows[@]}"; then
          warn "Будет обнулён: $ST_PICKED"
          if confirm "Обнулить?" N; then st_truncate_file "$ST_PICKED"; fi
        fi
        pause
        ;;
      3) mod_st_journal ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

mod_st_logs_rotated() {
  local before kb n f
  header "Старые архивы журналов"
  kb="$(st_logs_rotated_list | st_sum_bytes_kb)"; n="$(st_logs_rotated_list | wc -l)"
  if (( n == 0 )); then ok "Архивов старше $ST_LOG_AGE_DAYS дн. нет."; pause; return 0; fi
  info "Будет удалено файлов: $n, около $(ui_human_kb "${kb:-0}"). Самые крупные:"
  st_logs_rotated_list | sort -rn | head -n 5 | while IFS=$'\t' read -r f path; do
    printf '    %s%s  %s%s\n' "$C_DIM" "$(ui_pad "$(ui_human_kb $(( f / 1024 )))" 7)" "$(ui_trunc "$path" $(( UI_W - 14 )))" "$C_RESET"
  done
  hint "Текущие (активные) журналы не затрагиваются."
  confirm "Удалить эти архивы?" N || { info "Отменено."; pause; return 0; }
  before="$(st_avail_kb)"
  if st_do_step logs; then ok "Архивы удалены."; else err "Не удалось удалить часть файлов."; fi
  st_freed_report "$before"
  pause
}

mod_st_journal() {
  local cur before
  header "Журнал systemd"
  cur="$(st_journal_kb)"
  info "Сейчас журнал занимает $(ui_human_kb "$cur")."
  hint "Старые записи удаляются, самые свежие остаются. Размер можно указать, например 200M, 500M, 1G."
  ask_re "Оставить не больше" "$ST_JOURNAL_KEEP" '^[1-9][0-9]*[MG]$' "Формат: 200M или 1G."
  ST_JOURNAL_KEEP=$ASK_RESULT
  confirm "Сжать журнал до $ST_JOURNAL_KEEP?" Y || { info "Отменено."; pause; return 0; }
  before="$(st_avail_kb)"
  if st_do_step journal >/dev/null 2>&1; then ok "Журнал сжат: теперь $(ui_human_kb "$(st_journal_kb)")."; else err "Не удалось выполнить vacuum."; fi
  st_freed_report "$before"
  pause
}

mod_st_docker() {
  local -a rows=()
  while true; do
    header "Docker: образы, тома, логи"
    if ! st_docker_ok; then err "Docker не установлен или не запущен."; pause; return 1; fi
    timeout 15 docker system df 2>/dev/null | sed 's/^/  /'
    echo
    local vols
    vols="$(timeout 10 docker volume ls -qf dangling=true 2>/dev/null | wc -l)"
    if (( vols > 0 )); then ui_line warn "Томов без контейнеров: $vols — я их не удаляю: в них могут быть данные (docker volume ls -f dangling=true)"; fi
    echo
    menu_item 1 "Обнулить крупный лог контейнера (выбор из списка)"
    menu_item 2 "Очистка образов и кэша (безопасная / глубокая)"
    menu_item 3 "Настроить ротацию логов (чтобы не росли снова)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1)
        header "Обнулить лог контейнера"
        hint "Логи контейнеров от 1 МБ. Контейнер продолжит работать, история логов будет потеряна."
        mapfile -t rows < <(st_docker_logs_list | awk -F'\t' '$1 > 1048576' | head -n 9)
        if st_pick_file "${rows[@]}"; then
          warn "Будет обнулён лог: $ST_PICKED"
          if confirm "Обнулить?" N; then st_truncate_file "$ST_PICKED"; fi
        fi
        pause
        ;;
      2) mod_docker_cleanup ;;
      3) mod_docker_logrotate ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

mod_st_packages() {
  local before n kb list
  header "Пакеты: кэш apt и старые ядра"
  kb="$(st_dir_kb "$ST_APT_CACHE")"
  ui_kv "Кэш apt" "$(ui_human_kb "$kb")" 11
  list="$(st_old_kernels)"; n="$(printf '%s' "$list" | grep -c .)"
  ui_kv "Ядра" "устаревших пакетов: $n" 11
  if (( n > 0 )); then
    while IFS=$'\t' read -r kb name; do
      printf '    %s%s  %s%s\n' "$C_DIM" "$(ui_pad "$(ui_human_kb "${kb:-0}")" 7)" "$name" "$C_RESET"
    done <<<"$list"
  fi
  echo
  menu_item 1 "Очистить кэш apt (apt-get clean)"
  menu_item 2 "Удалить устаревшие ядра и ненужные пакеты (apt autoremove)"
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    1)
      if confirm "Очистить кэш apt ($(ui_human_kb "$(st_dir_kb "$ST_APT_CACHE")"))?" Y; then
        before="$(st_avail_kb)"
        if st_do_step apt; then ok "Кэш apt очищен."; else err "Не удалось очистить кэш."; fi
        st_freed_report "$before"
      fi
      pause
      ;;
    2)
      if (( n == 0 )); then ok "Устаревших ядер и ненужных пакетов нет."; pause; return 0; fi
      hint "Работающее и самое новое ядро apt сохраняет. Перезагрузка не требуется."
      if confirm "Выполнить apt autoremove --purge?" N; then
        before="$(st_avail_kb)"
        if apt_run autoremove --purge -y -q; then ok "Готово."; else err "apt autoremove завершился с ошибкой."; fi
        st_freed_report "$before"
      fi
      pause
      ;;
  esac
}

mod_st_snap_crash() {
  local sn sk cn ck before
  header "Snap и дампы падений"
  sn="$(st_snap_old_list | wc -l)"; sk="$(st_snap_old_list | awk -F'\t' '{s += $1} END {printf "%d", s}')"
  cn="$(st_crash_list | wc -l)"; ck="$(st_crash_list | st_sum_bytes_kb)"
  if cmd_exists snap; then ui_kv "Snap" "старых ревизий: $sn · $(ui_human_kb "${sk:-0}")" 11; else ui_kv "Snap" "${C_DIM}не установлен${C_RESET}" 11; fi
  ui_kv "Дампы" "файлов старше ${ST_CRASH_AGE_DAYS} дн.: $cn · $(ui_human_kb "${ck:-0}")" 11
  echo
  menu_item 1 "Удалить старые ревизии snap"
  menu_item 2 "Удалить старые дампы падений"
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    1)
      if (( sn == 0 )); then ok "Старых ревизий snap нет."; pause; return 0; fi
      if confirm "Удалить $sn старых ревизий snap ($(ui_human_kb "${sk:-0}"))?" N; then
        before="$(st_avail_kb)"
        if st_do_step snap; then ok "Готово."; else err "Часть ревизий удалить не удалось."; fi
        st_freed_report "$before"
      fi
      pause
      ;;
    2)
      if (( cn == 0 )); then ok "Старых дампов нет."; pause; return 0; fi
      if confirm "Удалить $cn файлов дампов ($(ui_human_kb "${ck:-0}"))?" N; then
        before="$(st_avail_kb)"
        if st_do_step crash; then ok "Готово."; else err "Не удалось удалить часть файлов."; fi
        st_freed_report "$before"
      fi
      pause
      ;;
  esac
}

mod_st_bigfiles() {
  local mb found
  header "Найти большие файлы"
  ask_re "Минимальный размер, МБ" "500" '^[1-9][0-9]{0,5}$' "Целое число мегабайт."
  mb=$ASK_RESULT
  if [[ -t 1 ]]; then printf '  %sищу файлы от %s МБ (до 90 с)…%s\n' "$C_DIM" "$mb" "$C_RESET"; fi
  found="$(timeout 90 find / -xdev -type f -size +"${mb}"M -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n 15)"
  if [[ -z $found ]]; then ok "Файлов от $mb МБ не найдено."; pause; return 0; fi
  echo
  while IFS=$'\t' read -r sz path; do
    printf '  %s%s%s  %s\n' "$C_BOLD" "$(ui_pad "$(ui_human_kb $(( sz / 1024 )))" 8)" "$C_RESET" "$(ui_trunc "$path" $(( UI_W - 14 )))"
  done <<<"$found"
  echo
  hint "Удалять такие файлы автоматически я не берусь: это может быть база данных или образ."
  hint "Журналы можно обнулить в разделе «Логи», логи контейнеров — в «Docker: образы, тома, логи»."
  pause
}

menu_storage() {
  local av
  while true; do
    header "Storage Analyzer"
    av="$(df -P / 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}')"
    if [[ $av =~ ^[0-9]+$ ]]; then ui_meter "Диск /" "$av" "свободно $(ui_human_kb "$(st_avail_kb)")"; echo; fi
    menu_item 1 "Куда ушло место (обзор)"
    menu_item 2 "Проводник по каталогам (заходи по цифре)"
    menu_item 3 "Безопасная очистка (предпросмотр → подтверждение)"
    menu_item 4 "Логи: архивы, большие файлы, журнал systemd"
    menu_item 5 "Docker: образы, тома, логи контейнеров"
    menu_item 6 "Пакеты: кэш apt и старые ядра"
    menu_item 7 "Snap и дампы падений"
    menu_item 8 "Найти большие файлы"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_st_overview ;;
      2) st_explore / ;;
      3) mod_st_safe_clean ;;
      4) mod_st_logs ;;
      5) mod_st_docker ;;
      6) mod_st_packages ;;
      7) mod_st_snap_crash ;;
      8) mod_st_bigfiles ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
