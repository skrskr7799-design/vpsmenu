# ══════════════════════════ Профили серверов ══════════════════════════

PROFILE_KEYS=(SYSTEM_UPDATE TIMEZONE NEW_USER COPY_ROOT_KEYS USER_SSH_KEY SSH_DISABLE_ROOT SSH_KEYS_ONLY
  UFW UFW_EXTRA_PORTS NFTABLES FAIL2BAN F2B_MAXRETRY F2B_FINDTIME F2B_BANTIME F2B_IGNOREIP
  DOCKER DOCKER_LOG_SIZE DOCKER_LOG_FILES BBR SWAP_SIZE SWAPPINESS AUTOUPDATES AUTOREBOOT
  SPEEDTEST NETBIRD REMNANODE WATCHDOG WATCHDOG_AUTORESTART WARP)

declare -A PROFILE_DEF=(
  [SYSTEM_UPDATE]=0 [TIMEZONE]="" [NEW_USER]="" [COPY_ROOT_KEYS]=1 [USER_SSH_KEY]=""
  [SSH_DISABLE_ROOT]=0 [SSH_KEYS_ONLY]=0 [UFW]=0 [UFW_EXTRA_PORTS]="" [NFTABLES]=0
  [FAIL2BAN]=0 [F2B_MAXRETRY]=3 [F2B_FINDTIME]=10m [F2B_BANTIME]=2d [F2B_IGNOREIP]="127.0.0.1/8 ::1"
  [DOCKER]=0 [DOCKER_LOG_SIZE]="" [DOCKER_LOG_FILES]=3 [BBR]=0 [SWAP_SIZE]="" [SWAPPINESS]=10
  [AUTOUPDATES]=0 [AUTOREBOOT]=0 [SPEEDTEST]=0 [NETBIRD]=0 [REMNANODE]=0 [WATCHDOG]=0 [WATCHDOG_AUTORESTART]=0 [WARP]=0
)

declare -A P=()
declare -a PLAN_IDS=() PLAN_TITLES=()
STEP_PAUSED=0

profile_reset() {
  local k
  P=()
  for k in "${PROFILE_KEYS[@]}"; do P[$k]="${PROFILE_DEF[$k]}"; done
}

profile_value_ok() { # profile_value_ok КЛЮЧ ЗНАЧЕНИЕ
  local k=$1 v=$2 re
  case $k in
    SYSTEM_UPDATE|COPY_ROOT_KEYS|SSH_DISABLE_ROOT|SSH_KEYS_ONLY|UFW|NFTABLES|FAIL2BAN|DOCKER|BBR|AUTOUPDATES|AUTOREBOOT|SPEEDTEST|NETBIRD|REMNANODE|WATCHDOG|WATCHDOG_AUTORESTART|WARP)
      re='^[01]$' ;;
    TIMEZONE) re='^[A-Za-z0-9_+/-]*$' ;;
    NEW_USER)
      if [[ -z $v || $v == ASK ]]; then return 0; fi
      re=$USERNAME_RE ;;
    USER_SSH_KEY)
      if [[ -z $v || $v == ASK ]]; then return 0; fi
      re='^(ssh-|ecdsa-|sk-)[^[:space:]]+ [A-Za-z0-9+/=]+( .*)?$' ;;
    UFW_EXTRA_PORTS) re='^$|^[0-9]{1,5}(/(tcp|udp))?( [0-9]{1,5}(/(tcp|udp))?)*$' ;;
    F2B_MAXRETRY|DOCKER_LOG_FILES) re='^[1-9][0-9]*$' ;;
    F2B_FINDTIME) re='^[0-9]+(s|m|h|d|w|mo|y)?$' ;;
    F2B_BANTIME) re='^(-1|[0-9]+(s|m|h|d|w|mo|y)?)$' ;;
    F2B_IGNOREIP) re='^[0-9a-fA-F:./ ]+$' ;;
    DOCKER_LOG_SIZE) re='^([1-9][0-9]*[kmg])?$' ;;
    SWAP_SIZE) re='^([1-9][0-9]*[MG])?$' ;;
    SWAPPINESS) re='^([0-9]|[1-9][0-9]|100)$' ;;
    *) return 1 ;;
  esac
  [[ $v =~ $re ]]
}

profile_parse() { # читает КЛЮЧ=значение со stdin в массив P; ничего не исполняет
  local line k v bad=0
  profile_reset
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    if [[ $line =~ ^[[:space:]]*(#|$) ]]; then continue; fi
    if [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
      k=${BASH_REMATCH[1]}
      v="$(trim "${BASH_REMATCH[2]}")"
      v="${v#\"}"; v="${v%\"}"
      if profile_value_ok "$k" "$v"; then
        P[$k]=$v
      else
        err "Профиль: недопустимый параметр или значение: $k=$v"; bad=1
      fi
    else
      err "Профиль: не понимаю строку: $line"; bad=1
    fi
  done
  return $bad
}

profile_preset_title() {
  case $1 in
    node-full) echo "Нода: полный стек (защита, Docker, Remnanode, WARP, оптимизация)" ;;
    minimal)   echo "Минимальная защита (пользователь, запрет root, UFW, Fail2ban)" ;;
    hardened)  echo "Усиленная защита (минимум + вход по ключам, автообновления, BBR, swap)" ;;
  esac
}

profile_preset_text() {
  case $1 in
    node-full) cat <<'EOF'
SYSTEM_UPDATE=1
TIMEZONE=UTC
NEW_USER=ASK
COPY_ROOT_KEYS=1
USER_SSH_KEY=ASK
SSH_DISABLE_ROOT=1
SSH_KEYS_ONLY=0
UFW=1
UFW_EXTRA_PORTS=
NFTABLES=1
FAIL2BAN=1
F2B_MAXRETRY=3
F2B_FINDTIME=10m
F2B_BANTIME=2d
F2B_IGNOREIP=127.0.0.1/8 ::1
DOCKER=1
DOCKER_LOG_SIZE=10m
DOCKER_LOG_FILES=3
BBR=1
SWAP_SIZE=2G
SWAPPINESS=10
AUTOUPDATES=1
AUTOREBOOT=0
SPEEDTEST=0
REMNANODE=1
WATCHDOG=1
WATCHDOG_AUTORESTART=0
WARP=1
EOF
      ;;
    minimal) cat <<'EOF'
SYSTEM_UPDATE=1
NEW_USER=ASK
COPY_ROOT_KEYS=1
SSH_DISABLE_ROOT=1
UFW=1
FAIL2BAN=1
F2B_MAXRETRY=3
F2B_FINDTIME=10m
F2B_BANTIME=2d
EOF
      ;;
    hardened) cat <<'EOF'
SYSTEM_UPDATE=1
TIMEZONE=UTC
NEW_USER=ASK
COPY_ROOT_KEYS=1
USER_SSH_KEY=ASK
SSH_DISABLE_ROOT=1
SSH_KEYS_ONLY=1
UFW=1
FAIL2BAN=1
F2B_MAXRETRY=3
F2B_FINDTIME=10m
F2B_BANTIME=7d
AUTOUPDATES=1
AUTOREBOOT=0
BBR=1
SWAP_SIZE=2G
SWAPPINESS=10
EOF
      ;;
    *) return 1 ;;
  esac
}

profile_load_preset() { profile_parse < <(profile_preset_text "$1"); }

profile_add() { PLAN_IDS+=("$1"); PLAN_TITLES+=("$2"); }

profile_plan() {
  PLAN_IDS=(); PLAN_TITLES=()
  if [[ ${P[SYSTEM_UPDATE]} == 1 ]]; then profile_add update "Обновление системы"; fi
  if [[ -n ${P[TIMEZONE]} ]]; then profile_add tz "Часовой пояс ${P[TIMEZONE]} и NTP"; fi
  if [[ -n ${P[NEW_USER]} ]]; then
    local who=${P[NEW_USER]}
    if [[ $who == ASK ]]; then who="имя спросим при применении"; fi
    profile_add user "Пользователь с sudo ($who)"
  fi
  if [[ ${P[SSH_DISABLE_ROOT]} == 1 ]]; then profile_add root "SSH: запрет входа под root"; fi
  if [[ ${P[SSH_KEYS_ONLY]} == 1 ]]; then profile_add keys "SSH: вход только по ключам"; fi
  if [[ ${P[UFW]} == 1 ]]; then
    local ut="UFW (порт SSH определится сам"
    if [[ -n ${P[UFW_EXTRA_PORTS]} ]]; then ut+="; ещё: ${P[UFW_EXTRA_PORTS]}"; fi
    profile_add ufw "$ut)"
  fi
  if [[ ${P[NFTABLES]} == 1 ]]; then profile_add nft "nftables"; fi
  if [[ ${P[FAIL2BAN]} == 1 ]]; then
    profile_add f2b "Fail2ban (maxretry ${P[F2B_MAXRETRY]}, findtime ${P[F2B_FINDTIME]}, bantime ${P[F2B_BANTIME]})"
  fi
  if [[ ${P[DOCKER]} == 1 ]]; then
    local dt="Docker"
    if [[ -n ${P[DOCKER_LOG_SIZE]} ]]; then dt+=" + ротация логов ${P[DOCKER_LOG_SIZE]}×${P[DOCKER_LOG_FILES]}"; fi
    profile_add docker "$dt"
  fi
  if [[ ${P[BBR]} == 1 ]]; then profile_add bbr "BBR"; fi
  if [[ -n ${P[SWAP_SIZE]} ]]; then profile_add swap "Swap ${P[SWAP_SIZE]} (swappiness ${P[SWAPPINESS]})"; fi
  if [[ ${P[AUTOUPDATES]} == 1 ]]; then
    local at="Автообновления безопасности"
    if [[ ${P[AUTOREBOOT]} == 1 ]]; then at+=" + автоперезагрузка"; fi
    profile_add autoupd "$at"
  fi
  if [[ ${P[SPEEDTEST]} == 1 ]]; then profile_add speedtest "Speedtest-cli"; fi
  if [[ ${P[NETBIRD]} == 1 ]]; then profile_add netbird "NetBird (установка; подключение — вручную по setup-ключу)"; fi
  if [[ ${P[REMNANODE]} == 1 ]]; then profile_add remna "Remnanode (папка, compose-файл, запуск)"; fi
  if [[ ${P[WATCHDOG]} == 1 ]]; then
    local wt="Watchdog Remnanode"
    if [[ ${P[WATCHDOG_AUTORESTART]} == 1 ]]; then wt+=" с автоперезапуском"; else wt+=" (автоперезапуск выключен)"; fi
    profile_add watchdog "$wt"
  fi
  if [[ ${P[WARP]} == 1 ]]; then profile_add warp "WARP Native"; fi
  return 0
}

profile_step_user() {
  local name=${P[NEW_USER]} key=${P[USER_SSH_KEY]}
  if [[ $name == ASK ]]; then
    ask_re "Имя нового пользователя" "" "$USERNAME_RE" "Допустимо: a-z, 0-9, _ и -, начинать с буквы, до 32 символов."
    name=$ASK_RESULT
  fi
  user_setup "$name" "${P[COPY_ROOT_KEYS]}" || return 1
  if [[ $key == ASK ]]; then
    echo
    ask "Публичный SSH-ключ для '$name' одной строкой (Enter — пропустить)"
    key=$ASK_RESULT
  fi
  if [[ -n $key ]]; then ssh_addkey_apply "$name" "$key" || return 1; fi
  return 0
}

profile_step_ufw() {
  if ! cmd_exists ufw; then apt_install ufw || return 1; fi
  ufw_apply "$(detect_ssh_ports)" "${P[UFW_EXTRA_PORTS]}"
}

profile_step_f2b() {
  f2b_install_apply || return 1
  f2b_write_jail "$(detect_ssh_ports | tr ' ' ',')" "${P[F2B_MAXRETRY]}" "${P[F2B_FINDTIME]}" "${P[F2B_BANTIME]}" "${P[F2B_IGNOREIP]}"
}

profile_step_docker() {
  docker_install_apply || return 1
  if [[ -n ${P[DOCKER_LOG_SIZE]} ]]; then
    step "Ротация логов Docker"
    docker_logrotate_apply "${P[DOCKER_LOG_SIZE]}" "${P[DOCKER_LOG_FILES]}" || return 1
  fi
  return 0
}

profile_step() { # profile_step ШАГ; пункты с собственными подтверждениями сами делают pause
  STEP_PAUSED=0
  case $1 in
    update)    sys_update_run ;;
    tz)        tz_ntp_apply "${P[TIMEZONE]}" ;;
    user)      profile_step_user ;;
    root)      mod_ssh_disable_root; STEP_PAUSED=1 ;;
    keys)      mod_ssh_keys_only; STEP_PAUSED=1 ;;
    ufw)       profile_step_ufw ;;
    nft)       mod_nft_setup; STEP_PAUSED=1 ;;
    f2b)       profile_step_f2b ;;
    docker)    profile_step_docker ;;
    bbr)       bbr_apply ;;
    swap)      swap_create_apply "${P[SWAP_SIZE]}" "${P[SWAPPINESS]}" ;;
    autoupd)   autoupdates_apply "${P[AUTOREBOOT]}" ;;
    speedtest) speedtest_install ;;
    netbird)   nb_install_apply ;;
    remna)     mod_remna_setup; STEP_PAUSED=1 ;;
    watchdog)  watchdog_enable "${P[WATCHDOG_AUTORESTART]}" ;;
    warp)      mod_warp; STEP_PAUSED=1 ;;
    *)         err "Неизвестный шаг: $1"; return 1 ;;
  esac
}

profile_apply() { # применяет профиль из массива P
  profile_plan
  local total=${#PLAN_IDS[@]} i n=0 id title
  if (( total == 0 )); then warn "В профиле нет ни одного включённого шага."; return 1; fi
  echo
  info "План ($total шагов):"
  for i in "${!PLAN_IDS[@]}"; do printf '    %2d. %s\n' "$((i + 1))" "${PLAN_TITLES[$i]}"; done
  echo
  hint "Шаги, влияющие на доступ к серверу (запрет root, вход по ключам), как всегда, потребуют подтверждения."
  confirm "Применить профиль?" Y || { info "Отменено."; return 1; }

  for i in "${!PLAN_IDS[@]}"; do
    id=${PLAN_IDS[$i]}
    title=${PLAN_TITLES[$i]}
    n=$((n + 1))
    header "Профиль: шаг $n из $total"
    printf '  %s%s%s\n\n' "$C_BOLD" "$title" "$C_RESET"
    if profile_step "$id"; then
      log INFO "Профиль: шаг «$title» выполнен"
    else
      warn "Шаг «$title» завершился с ошибкой."
      if (( ! STEP_PAUSED )); then pause; fi
      confirm "Продолжить со следующим шагом?" Y || { info "Применение остановлено."; return 1; }
      continue
    fi
    if (( ! STEP_PAUSED )); then pause; fi
  done
  header "Профиль применён"
  ok "Все шаги выполнены."
  hint "Итоговое состояние: главное меню → «Обзор системы»."
  reboot_prompt
  return 0
}

pq_bool() { # pq_bool КЛЮЧ "Вопрос"
  local def=N
  if [[ ${P[$1]} == 1 ]]; then def=Y; fi
  if confirm "$2" "$def"; then P[$1]=1; else P[$1]=0; fi
}

pq_val() { # pq_val КЛЮЧ "Вопрос" ["Подсказка"]
  if [[ -n ${3:-} ]]; then hint "$3"; fi
  while true; do
    ask "$2" "${P[$1]}"
    if [[ $ASK_RESULT == "-" ]]; then ASK_RESULT=""; fi
    if profile_value_ok "$1" "$ASK_RESULT"; then P[$1]=$ASK_RESULT; return 0; fi
    err "Недопустимое значение."
  done
}

profile_questionnaire() {
  info "Отвечай на вопросы: Enter — оставить значение в скобках, «-» — очистить поле."
  step "Система"
  pq_bool SYSTEM_UPDATE "Обновить систему (apt upgrade)?"
  pq_val TIMEZONE "Часовой пояс" "Например UTC или Europe/Moscow. Пусто — не менять."
  step "Доступ"
  pq_val NEW_USER "Создать пользователя с sudo" "Имя пользователя, ASK — спросить при применении, пусто — не создавать."
  if [[ -n ${P[NEW_USER]} ]]; then
    pq_bool COPY_ROOT_KEYS "Скопировать ему SSH-ключи root?"
    pq_val USER_SSH_KEY "Публичный SSH-ключ для него" "Строка ключа целиком, ASK — спросить при применении, пусто — не добавлять."
  fi
  pq_bool SSH_DISABLE_ROOT "Запретить вход под root?"
  pq_bool SSH_KEYS_ONLY "Вход только по ключам (отключить пароль)?"
  step "Файрвол и защита"
  pq_bool UFW "Настроить UFW?"
  if [[ ${P[UFW]} == 1 ]]; then
    pq_val UFW_EXTRA_PORTS "Дополнительные порты" "Через пробел, например: 443/tcp 2222/tcp. Порт SSH откроется сам."
  fi
  pq_bool NFTABLES "Установить nftables?"
  pq_bool FAIL2BAN "Настроить Fail2ban для SSH?"
  if [[ ${P[FAIL2BAN]} == 1 ]]; then
    pq_val F2B_MAXRETRY "maxretry — попыток до бана" "Целое число, обычно 3–5."
    pq_val F2B_FINDTIME "findtime — окно подсчёта попыток" "Число + s/m/h/d/w, например 10m."
    pq_val F2B_BANTIME "bantime — срок бана" "Например 12h, 2d, 1w; -1 — навсегда."
    pq_val F2B_IGNOREIP "ignoreip — адреса вне бана" "Через пробел; добавь свой IP, чтобы не забанить себя."
  fi
  step "Docker и сеть"
  pq_bool DOCKER "Установить Docker?"
  if [[ ${P[DOCKER]} == 1 ]]; then
    pq_val DOCKER_LOG_SIZE "Ротация логов: max-size" "Например 10m. Пусто — ротацию не настраивать."
    if [[ -n ${P[DOCKER_LOG_SIZE]} ]]; then pq_val DOCKER_LOG_FILES "Ротация логов: max-file (сколько файлов)" ""; fi
  fi
  pq_bool BBR "Включить BBR?"
  pq_val SWAP_SIZE "Swap: размер" "Например 1G или 2G. Пусто — не создавать."
  if [[ -n ${P[SWAP_SIZE]} ]]; then pq_val SWAPPINESS "Swap: swappiness (0–100)" "Для VPS обычно 10."; fi
  pq_bool AUTOUPDATES "Включить автообновления безопасности?"
  if [[ ${P[AUTOUPDATES]} == 1 ]]; then pq_bool AUTOREBOOT "Разрешить ночную автоперезагрузку (04:00)?"; fi
  pq_bool SPEEDTEST "Установить speedtest-cli?"
  pq_bool NETBIRD "Установить NetBird (приватная сеть)?"
  step "Приложения"
  pq_bool REMNANODE "Настроить Remnanode?"
  pq_bool WATCHDOG "Включить watchdog для Remnanode?"
  if [[ ${P[WATCHDOG]} == 1 ]]; then pq_bool WATCHDOG_AUTORESTART "Автоперезапуск ноды при падении? (по умолчанию выключено)"; fi
  pq_bool WARP "Запустить установщик WARP Native?"
}

profile_save() { # сохраняет текущий P в /etc/vpsmenu/profiles/ИМЯ.conf
  local name file k
  ask_re "Имя профиля (a-z, 0-9, - и _)" "" '^[a-z0-9][a-z0-9_-]{0,30}$' "Допустимо: a-z, 0-9, - и _, до 31 символа."
  name=$ASK_RESULT
  file="$PROFILE_DIR/$name.conf"
  install -d -m 0700 "$PROFILE_DIR"
  if [[ -f $file ]]; then confirm "Профиль '$name' уже есть. Перезаписать?" N || return 1; fi
  {
    printf '# Профиль %s: %s (создан %s)\n' "$APP_NAME" "$name" "$(date '+%F %T')"
    printf '# Формат: КЛЮЧ=значение (значение до конца строки, без кавычек). 1/0 — включить/выключить шаг.\n'
    printf '# NEW_USER и USER_SSH_KEY могут быть ASK — тогда скрипт спросит при применении.\n'
    for k in "${PROFILE_KEYS[@]}"; do printf '%s=%s\n' "$k" "${P[$k]}"; done
  } >"$file"
  chmod 600 "$file"
  ok "Профиль сохранён: $file"
  hint "Чтобы взять его на другом сервере, положи файл в репозиторий: profiles/$name.conf — и скачай через «Профили → Скачать из GitHub»."
}

mod_profile_preset() {
  header "Профили: готовые наборы"
  menu_item 1 "$(profile_preset_title node-full)"
  menu_item 2 "$(profile_preset_title minimal)"
  menu_item 3 "$(profile_preset_title hardened)"
  menu_item 0 "Назад"
  echo; read_choice
  local id
  case $CHOICE in
    1) id=node-full ;;
    2) id=minimal ;;
    3) id=hardened ;;
    *) return 0 ;;
  esac
  profile_load_preset "$id" || { err "Не удалось загрузить набор."; pause; return 1; }
  header "Профиль: $(profile_preset_title "$id")"
  profile_apply
  pause
}

mod_profile_manual() {
  header "Профиль вручную"
  info "С каких значений начать? (дальше на каждый вопрос можно ответить своим)"
  menu_item 1 "$(profile_preset_title node-full)"
  menu_item 2 "$(profile_preset_title minimal)"
  menu_item 3 "$(profile_preset_title hardened)"
  menu_item 4 "С нуля (всё выключено)"
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    1) profile_load_preset node-full ;;
    2) profile_load_preset minimal ;;
    3) profile_load_preset hardened ;;
    4) profile_reset ;;
    *) return 0 ;;
  esac
  header "Профиль вручную: вопросы"
  profile_questionnaire
  profile_plan
  header "Профиль вручную: итог"
  if (( ${#PLAN_IDS[@]} == 0 )); then warn "Ничего не выбрано."; pause; return 0; fi
  local i
  for i in "${!PLAN_IDS[@]}"; do printf '    %2d. %s\n' "$((i + 1))" "${PLAN_TITLES[$i]}"; done
  echo
  menu_item 1 "Применить сейчас"
  menu_item 2 "Сохранить как профиль"
  menu_item 3 "Применить и сохранить"
  menu_item 0 "Отмена"
  echo; read_choice
  case $CHOICE in
    1) profile_apply ;;
    2) profile_save ;;
    3) profile_save && profile_apply ;;
    *) info "Отменено." ;;
  esac
  pause
}

mod_profile_saved() {
  header "Сохранённые профили"
  local -a files=()
  local i=0 f
  mapfile -t files < <(find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
  if (( ${#files[@]} == 0 )); then
    info "Сохранённых профилей пока нет (создай: «Настроить вручную» → «Сохранить»)."
    pause; return 0
  fi
  for f in "${files[@]}"; do i=$((i + 1)); printf '  %2d  %s\n' "$i" "$(basename "$f" .conf)"; done
  ask_re "Номер профиля (Enter — отмена)" "" '^[0-9]*$' "Нужен номер из списка."
  [[ -z $ASK_RESULT ]] && return 0
  if (( 10#$ASK_RESULT < 1 || 10#$ASK_RESULT > ${#files[@]} )); then err "Нет такого номера."; pause; return 1; fi
  f="${files[$((10#$ASK_RESULT - 1))]}"
  echo
  menu_item 1 "Применить"
  menu_item 2 "Показать содержимое"
  menu_item 3 "Удалить"
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    1)
      if profile_parse <"$f"; then header "Профиль: $(basename "$f" .conf)"; profile_apply; else err "В профиле есть ошибки."; fi
      pause ;;
    2) sed 's/^/  /' "$f" | show_paged; pause ;;
    3) if confirm "Удалить профиль $(basename "$f" .conf)?" N; then rm -f "$f"; ok "Удалён."; fi; pause ;;
    *) return 0 ;;
  esac
}

mod_profile_download() {
  header "Профили: скачать из GitHub"
  if ! update_repo_ok; then
    warn "GitHub-репозиторий не задан."
    update_configure_repo || { pause; return 1; }
  fi
  info "Источник: github.com/$(update_repo) (ветка $(update_branch)), папка profiles/"
  ask_re "Имя профиля (файл profiles/<имя>.conf, Enter — отмена)" "" '^$|^[a-z0-9][a-z0-9_-]{0,30}$' "Допустимо: a-z, 0-9, - и _."
  local name=$ASK_RESULT
  [[ -z $name ]] && return 0
  ensure_curl || { pause; return 1; }
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "$tmp" "$(update_url "profiles/$name.conf")"; then
    err "Не удалось скачать profiles/$name.conf (проверь имя и что файл есть в репозитории)."
    rm -f "$tmp"; pause; return 1
  fi
  if ! profile_parse <"$tmp"; then
    err "Профиль содержит ошибки — не сохраняю."
    rm -f "$tmp"; pause; return 1
  fi
  ok "Профиль прочитан и проверен."
  profile_plan
  local i
  for i in "${!PLAN_IDS[@]}"; do printf '    %2d. %s\n' "$((i + 1))" "${PLAN_TITLES[$i]}"; done
  echo
  install -d -m 0700 "$PROFILE_DIR"
  if confirm "Сохранить локально как '$name'?" Y; then
    install -m 0600 "$tmp" "$PROFILE_DIR/$name.conf" && ok "Сохранено: $PROFILE_DIR/$name.conf"
  fi
  if confirm "Применить сейчас?" N; then header "Профиль: $name"; profile_apply; fi
  rm -f "$tmp"
  pause
}

menu_profiles() {
  while true; do
    header "13. Профили серверов"
    hint "Профиль — набор ответов для настройки нового сервера: применяется почти без вопросов."
    echo
    menu_item 1 "Применить готовый профиль"
    menu_item 2 "Настроить вручную (с вопросами), применить и/или сохранить"
    menu_item 3 "Сохранённые профили"
    menu_item 4 "Скачать профиль из GitHub (profiles/<имя>.conf)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_profile_preset ;;
      2) mod_profile_manual ;;
      3) mod_profile_saved ;;
      4) mod_profile_download ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
