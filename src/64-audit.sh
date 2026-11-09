# ══════════════════════════ Security Audit ══════════════════════════
# Проверка настроек безопасности с прозрачной оценкой: у каждой находки есть важность и штраф.
# Quick Scan — основные проверки за пару секунд, Full Scan — всё, включая права доступа и Docker.
# Это проверка конфигурации, а не поиск взлома: оценка — ориентир, а не сертификат.

AUDIT_PASSWD="${VPSMENU_AUDIT_PASSWD:-/etc/passwd}"
AUDIT_SHADOW="${VPSMENU_AUDIT_SHADOW:-/etc/shadow}"
AUDIT_SUDOERS="${VPSMENU_AUDIT_SUDOERS:-/etc/sudoers}"
AUDIT_SUDOERS_D="${VPSMENU_AUDIT_SUDOERS_D:-/etc/sudoers.d}"
AUDIT_SSHD_CONFIG="${VPSMENU_AUDIT_SSHD_CONFIG:-$SSHD_CONFIG}"
AUDIT_ETC="${VPSMENU_AUDIT_ETC:-/etc}"
AUDIT_REBOOT_FLAG="${VPSMENU_AUDIT_REBOOT_FLAG:-/var/run/reboot-required}"
AUDIT_APT_AUTO="${VPSMENU_AUDIT_APT_AUTO:-/etc/apt/apt.conf.d/20auto-upgrades}"
AUDIT_APT_STAMP="${VPSMENU_AUDIT_APT_STAMP:-/var/lib/apt/periodic/update-success-stamp}"
AUDIT_LAST_FILE="${STATE_DIR}/audit-last"

declare -A AUD_W=([critical]=20 [high]=10 [medium]=5 [low]=2)
declare -A AUD_CAP=([ports]=15 [dports]=15)   # лимиты штрафа: открытые порты хоста и порты Docker
declare -A AUD_CATNAME=([ssh]="SSH" [firewall]="Файрвол и защита" [users]="Пользователи" [ports]="Открытые порты"
  [docker]="Docker" [system]="Система" [files]="Файлы и права")
declare -A AUD_N=()
declare -a AUD_ID=() AUD_STATUS=() AUD_SEV=() AUD_CAT=() AUD_TITLE=() AUD_HINT=() AUD_FIX=() AUD_PEN=() AUD_ACC=()
AUD_SCORE=100
AUD_MODE=quick

# ── Накопление результатов ──────────────────────────────────────────────────
audit_reset() {
  AUD_ID=(); AUD_STATUS=(); AUD_SEV=(); AUD_CAT=(); AUD_TITLE=(); AUD_HINT=(); AUD_FIX=(); AUD_PEN=(); AUD_ACC=()
  AUD_SCORE=100
  AUD_N=([critical]=0 [high]=0 [medium]=0 [low]=0 [accepted]=0 [ok]=0 [info]=0 [skip]=0)
}

audit_add() { # audit_add ID СТАТУС ВАЖНОСТЬ КАТЕГОРИЯ ЗАГОЛОВОК [ПОДСКАЗКА] [ИСПРАВЛЕНИЕ]
  AUD_ID+=("$1"); AUD_STATUS+=("$2"); AUD_SEV+=("$3"); AUD_CAT+=("$4"); AUD_TITLE+=("$5")
  AUD_HINT+=("${6:-}"); AUD_FIX+=("${7:-}"); AUD_PEN+=(0); AUD_ACC+=(0)
}

audit_ok()    { audit_add "$1" ok "" "$2" "$3"; }

audit_info()  { audit_add "$1" info "" "$2" "$3" "${4:-}"; }

audit_skip()  { audit_add "$1" skip "" "$2" "$3"; }

audit_issue() { # audit_issue ID КАТЕГОРИЯ ВАЖНОСТЬ ЗАГОЛОВОК ПОДСКАЗКА [ИСПРАВЛЕНИЕ: fn:ИМЯ | chmod:РЕЖИМ:ПУТЬ | none]
  audit_add "$1" issue "$3" "$2" "$4" "${5:-}" "${6:-}"
}

audit_is_accepted() { [[ ",$(conf_get AUDIT_ACCEPTED)," == *",$1,"* ]]; }

audit_port_expected() { # audit_port_expected ПОРТ ПРОТОКОЛ
  local e list
  list="$(conf_get AUDIT_EXPECTED_PORTS)"
  for e in ${list//,/ }; do
    if [[ $e == "$1" || $e == "$1/$2" ]]; then return 0; fi
  done
  return 1
}

audit_score() { # считает штрафы, принятые риски и итоговую оценку
  local i id pen cat cur room total=0
  local -A catsum=()
  AUD_N=([critical]=0 [high]=0 [medium]=0 [low]=0 [accepted]=0 [ok]=0 [info]=0 [skip]=0)
  for i in "${!AUD_ID[@]}"; do
    AUD_PEN[i]=0; AUD_ACC[i]=0
    case ${AUD_STATUS[$i]} in
      ok)   AUD_N[ok]=$(( AUD_N[ok] + 1 )) ;;
      info) AUD_N[info]=$(( AUD_N[info] + 1 )) ;;
      skip) AUD_N[skip]=$(( AUD_N[skip] + 1 )) ;;
      issue)
        id=${AUD_ID[$i]}
        if audit_is_accepted "$id"; then
          AUD_ACC[i]=1; AUD_N[accepted]=$(( AUD_N[accepted] + 1 )); continue
        fi
        pen=${AUD_W[${AUD_SEV[$i]}]}
        case $id in port:*) cat=ports ;; dport:*) cat=dports ;; *) cat="" ;; esac
        if [[ -n $cat && -n ${AUD_CAP[$cat]:-} ]]; then
          cur=${catsum[$cat]:-0}
          room=$(( AUD_CAP[$cat] - cur ))
          if (( room < 0 )); then room=0; fi
          if (( pen > room )); then pen=$room; fi
          catsum[$cat]=$(( cur + pen ))
        fi
        AUD_PEN[i]=$pen
        total=$(( total + pen ))
        AUD_N[${AUD_SEV[$i]}]=$(( AUD_N[${AUD_SEV[$i]}] + 1 ))
        ;;
    esac
  done
  AUD_SCORE=$(( 100 - total ))
  if (( AUD_SCORE < 0 )); then AUD_SCORE=0; fi
}

audit_grade() { # печатает «уровень|слово»
  if (( AUD_SCORE >= 90 )); then echo "ok|отлично"
  elif (( AUD_SCORE >= 75 )); then echo "ok|хорошо"
  elif (( AUD_SCORE >= 50 )); then echo "warn|требует внимания"
  else echo "bad|опасно"; fi
}

# ── Источники данных (их можно подменить в тестах) ──────────────────────────
audit_apt_security_count() { # число пакетов безопасности, ждущих обновления (пусто — apt недоступен)
  cmd_exists apt-get || return 0
  local out
  out="$(apt-get -s upgrade 2>/dev/null | grep '^Inst')"
  if [[ -z $out ]]; then echo 0; else grep -c -- '-security' <<<"$out"; fi
}

audit_listen_list() { # «протокол порт процесс» для публичных слушающих портов (без loopback и частных адресов)
  ss -H -tulnp 2>/dev/null | awk '
    {
      proto = $1; loc = $5; proc = ""
      for (i = 7; i <= NF; i++) proc = proc $i
      n = split(loc, a, ":"); port = a[n]
      addr = substr(loc, 1, length(loc) - length(port) - 1)
      gsub(/[\[\]]/, "", addr); sub(/%.*/, "", addr)
      if (addr ~ /^127\./ || addr == "::1" || addr ~ /^fe80/ || addr ~ /^10\./ || addr ~ /^192\.168\./ || addr ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) next
      name = "?"
      if (match(proc, /\(\("[^"]+"/)) name = substr(proc, RSTART + 3, RLENGTH - 4)
      print proto, port, name
    }' | sort -u
}

audit_docker_published() { # «контейнер порт/протокол» для портов, опубликованных на все интерфейсы
  if ! cmd_exists docker || ! service_active docker; then return 0; fi
  timeout 8 docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | awk -F'|' '
    {
      n = split($2, e, ", ")
      for (i = 1; i <= n; i++) {
        p = index(e[i], "->"); if (p == 0) continue
        host = substr(e[i], 1, p - 1); rest = substr(e[i], p + 2)
        m = split(host, h, ":"); port = h[m]
        addr = substr(host, 1, length(host) - length(port) - 1)
        gsub(/[\[\]]/, "", addr)
        if (addr != "0.0.0.0" && addr != "::" && addr != "") continue
        split(rest, r, "/")
        print $1, port "/" r[2]
      }
    }' | sort -u
}

audit_docker_inspect() { # «имя|privileged|монтирования|сеть» по запущенным контейнерам
  if ! cmd_exists docker || ! service_active docker; then return 0; fi
  local ids
  ids="$(timeout 8 docker ps -q 2>/dev/null)"
  [[ -n $ids ]] || return 0
  # shellcheck disable=SC2086
  timeout 10 docker inspect --format '{{.Name}}|{{.HostConfig.Privileged}}|{{range .Mounts}}{{.Source}},{{end}}|{{.HostConfig.NetworkMode}}' $ids 2>/dev/null
}

audit_ufw_allows() { # audit_ufw_allows ПОРТ ПРОТОКОЛ — есть ли в UFW правило «разрешить всем» для порта
  ufw_c status 2>/dev/null | sed 's/ (v6)//g' | awk -v port="$1" -v proto="$2" '
    {
      spec = $1
      if (spec == "Anywhere") next
      if ($2 !~ /^(ALLOW|LIMIT)/) next
      if ($NF != "Anywhere") next
      p = spec; pr = ""
      if (index(spec, "/")) { split(spec, s, "/"); p = s[1]; pr = s[2] }
      if (pr != "" && pr != proto) next
      if (index(p, ":")) { split(p, r, ":"); if (port + 0 >= r[1] + 0 && port + 0 <= r[2] + 0) found = 1 }
      else if (p + 0 == port + 0) found = 1
    }
    END { exit found ? 0 : 1 }'
}

audit_mode() { stat -c '%a' "$1" 2>/dev/null; }

audit_mode_bit() { # audit_mode_bit РЕЖИМ group|other БИТ(1,2,4) — установлен ли бит у группы/остальных
  local m=$1 who=$2 bit=$3 d
  [[ $m =~ ^[0-7]{3,4}$ ]] || return 1
  if [[ $who == group ]]; then d=${m: -2:1}; else d=${m: -1}; fi
  (( (10#$d & bit) != 0 ))
}

# ── Проверки ────────────────────────────────────────────────────────────────
audit_check_ssh() {
  local v
  if ! cmd_exists sshd; then audit_skip ssh_root ssh "SSH-сервер не установлен"; return 0; fi
  v="$(sshd_effective permitrootlogin)"
  case $v in
    no) audit_ok ssh_root ssh "SSH: вход под root запрещён" ;;
    prohibit-password|without-password)
      audit_issue ssh_root ssh low "SSH: root может входить по ключу" "Запрети вход root совсем: SSH → «Запретить вход под root»" fn:mod_ssh_disable_root ;;
    yes)
      audit_issue ssh_root ssh high "SSH: вход под root разрешён" "Создай пользователя с sudo и запрети root: SSH → «Запретить вход под root»" fn:mod_ssh_disable_root ;;
    *) audit_skip ssh_root ssh "SSH: не удалось прочитать PermitRootLogin" ;;
  esac
  v="$(sshd_effective passwordauthentication)"
  case $v in
    no)  audit_ok ssh_password ssh "SSH: вход по паролю отключён" ;;
    yes) audit_issue ssh_password ssh high "SSH: вход по паролю включён" "Перейди на ключи: SSH → «Добавить ключ», затем «Вход только по ключам»" fn:mod_ssh_keys_only ;;
    *)   audit_skip ssh_password ssh "SSH: не удалось прочитать PasswordAuthentication" ;;
  esac
}

audit_check_ssh_extra() {
  local v ports
  cmd_exists sshd || return 0
  v="$(sshd_effective permitemptypasswords)"
  if [[ $v == yes ]]; then
    audit_issue ssh_empty_pw ssh critical "SSH: разрешены пустые пароли" "Добавь PermitEmptyPasswords no в /etc/ssh/sshd_config.d/" none
  elif [[ -n $v ]]; then
    audit_ok ssh_empty_pw ssh "SSH: пустые пароли запрещены"
  fi
  v="$(sshd_effective maxauthtries)"
  if [[ $v =~ ^[0-9]+$ ]] && (( v > 4 )); then
    audit_issue ssh_maxauth ssh low "SSH: MaxAuthTries = $v (рекомендуется 3–4)" "Добавь MaxAuthTries 3 в /etc/ssh/sshd_config.d/" none
  elif [[ -n $v ]]; then
    audit_ok ssh_maxauth ssh "SSH: MaxAuthTries = $v"
  fi
  v="$(sshd_effective x11forwarding)"
  if [[ $v == yes ]]; then
    audit_issue ssh_x11 ssh low "SSH: включён X11Forwarding" "На сервере без графики он не нужен: X11Forwarding no" none
  elif [[ -n $v ]]; then
    audit_ok ssh_x11 ssh "SSH: X11Forwarding выключен"
  fi
  ports="$(detect_ssh_ports)"
  if [[ $ports == 22 ]]; then
    audit_info ssh_port22 ssh "SSH на стандартном порту 22 (больше автоматических сканирований)" "Смена порта: SSH → «Добавить новый порт»"
  fi
}

audit_check_firewall() {
  local pol rules
  if cmd_exists ufw && ufw_is_active; then
    pol="$(ufw_c status verbose 2>/dev/null | awk -F': ' '/^Default:/ {print $2}')"
    if [[ $pol == *"deny (incoming)"* || $pol == *"reject (incoming)"* ]]; then
      audit_ok firewall firewall "Файрвол UFW включён, входящие закрыты по умолчанию"
    else
      audit_issue firewall firewall high "UFW включён, но входящие не закрыты по умолчанию" "Политика: ${pol:-неизвестна}. Выполни: ufw default deny incoming" none
    fi
    return 0
  fi
  if cmd_exists nft; then
    rules="$(nft list ruleset 2>/dev/null)"
    if grep -qE 'policy (drop|reject)' <<<"$rules"; then
      audit_ok firewall firewall "Файрвол nftables: политика drop"
      return 0
    fi
  fi
  audit_issue firewall firewall high "Файрвол выключен" "Включи UFW: пункт «UFW» → «Установить / первичная настройка»" fn:mod_ufw_setup
}

audit_check_fail2ban() {
  if cmd_exists fail2ban-client && service_active fail2ban; then
    if fail2ban-client status sshd >/dev/null 2>&1; then
      audit_ok fail2ban firewall "Fail2ban защищает SSH"
    else
      audit_issue fail2ban firewall medium "Fail2ban работает, но jail sshd не включён" "Настрой защиту SSH: пункт «Fail2ban»" fn:mod_f2b_setup
    fi
  else
    audit_issue fail2ban firewall medium "Fail2ban не установлен или не запущен" "Установи: пункт «Fail2ban» → «Установить и настроить»" fn:mod_f2b_setup
  fi
}

audit_check_users() {
  local u
  if [[ -r $AUDIT_PASSWD ]]; then
    u="$(awk -F: '$3 == 0 && $1 != "root" {print $1}' "$AUDIT_PASSWD" | tr '\n' ' ')"
    if [[ -n $u ]]; then
      audit_issue uid0 users critical "Есть пользователи с UID 0 кроме root: ${u% }" "UID 0 — это полные права root. Проверь, зачем они, и удали лишние." none
    else
      audit_ok uid0 users "Других пользователей с UID 0 нет"
    fi
  fi
  if [[ -r $AUDIT_SHADOW ]]; then
    u="$(awk -F: '$2 == "" {print $1}' "$AUDIT_SHADOW" | tr '\n' ' ')"
    if [[ -n $u ]]; then
      audit_issue empty_pw users critical "Учётки без пароля: ${u% }" "Задай пароль (passwd) или заблокируй учётку (passwd -l)." none
    else
      audit_ok empty_pw users "Учёток без пароля нет"
    fi
  else
    audit_skip empty_pw users "Пустые пароли: нет доступа к shadow"
  fi
}

audit_check_sudo() {
  local n
  n="$(grep -rhsE '^[[:space:]]*[^#[:space:]].*NOPASSWD' "$AUDIT_SUDOERS" "$AUDIT_SUDOERS_D" | wc -l)"
  if (( n > 0 )); then
    audit_issue sudo_nopasswd users low "sudo без пароля: правил $n" "Часто это штатная настройка облачного образа. Если не нужно — убери NOPASSWD в /etc/sudoers.d/" none
  else
    audit_ok sudo_nopasswd users "sudo везде требует пароль"
  fi
}

audit_check_ports() {
  local proto port name sshp dp found=0
  sshp=" $(detect_ssh_ports) "
  dp=" $(audit_docker_published | awk '{print $2}' | tr '\n' ' ') "
  while read -r proto port name; do
    [[ -n $proto ]] || continue
    [[ $sshp == *" $port "* ]] && continue
    [[ $proto == udp && $port == 68 ]] && continue                      # DHCP-клиент
    [[ $dp == *" $port/$proto "* || $name == docker-proxy ]] && continue # порты Docker проверяются отдельно
    audit_port_expected "$port" "$proto" && continue
    if ufw_is_active && ! audit_ufw_allows "$port" "$proto"; then continue; fi   # слушает, но закрыт UFW
    audit_issue "port:$port/$proto" ports medium "Порт $port/$proto ($name) доступен снаружи" "Закрой в UFW или отметь порт как ожидаемый (принять риск)" fn:menu_ufw
    found=1
  done < <(audit_listen_list)
  if (( ! found )); then audit_ok ports_ok ports "Лишних открытых портов нет"; fi
}

audit_check_docker() {
  local name port clean=1
  if ! cmd_exists docker || ! service_active docker; then
    audit_skip docker_ports docker "Docker не запущен — проверка портов пропущена"; return 0
  fi
  while read -r name port; do
    [[ -n $name ]] || continue
    audit_port_expected "${port%/*}" "${port#*/}" && continue
    audit_issue "dport:$port" docker medium "Docker: порт $port ($name) опубликован наружу" "UFW порты Docker НЕ закрывает. В compose укажи 127.0.0.1:ПОРТ:ПОРТ или отметь порт как ожидаемый." none
    clean=0
  done < <(audit_docker_published)
  if (( clean )); then audit_ok docker_ports docker "Docker не публикует лишних портов наружу"; fi
}

audit_check_docker_deep() {
  local name priv mounts privl="" sockl="" members
  if ! cmd_exists docker || ! service_active docker; then return 0; fi
  while IFS='|' read -r name priv mounts _; do
    name=${name#/}
    [[ -n $name ]] || continue
    if [[ $priv == true ]]; then privl+="$name "; fi
    if [[ $mounts == *docker.sock* ]]; then sockl+="$name "; fi
  done < <(audit_docker_inspect)
  if [[ -n $privl ]]; then
    audit_issue docker_privileged docker medium "Docker: привилегированные контейнеры: ${privl% }" "privileged даёт контейнеру почти полный доступ к хосту. Используй точечные capabilities." none
  else
    audit_ok docker_privileged docker "Docker: привилегированных контейнеров нет"
  fi
  if [[ -n $sockl ]]; then
    audit_issue docker_sock docker high "Docker: docker.sock примонтирован в: ${sockl% }" "Доступ к сокету = root на хосте. Убери монтирование, если оно не критично." none
  else
    audit_ok docker_sock docker "Docker: docker.sock в контейнеры не монтируется"
  fi
  if audit_listen_list | awk '($2 == 2375 || $2 == 2376) {f = 1} END {exit f ? 0 : 1}'; then
    audit_issue docker_tcp docker critical "Docker API слушает TCP (2375/2376) на всех интерфейсах" "Это root-доступ для всего интернета. Отключи tcp в daemon.json / docker.service." none
  fi
  members="$(getent group docker 2>/dev/null | cut -d: -f4 | tr ',' ' ')"
  if [[ -n ${members// /} ]]; then audit_info docker_group docker "В группе docker: ${members% } (это равно root-доступу)"; fi
}

audit_check_updates() {
  local n
  n="$(audit_apt_security_count)"
  if [[ -z $n ]]; then audit_skip updates system "Обновления безопасности: apt недоступен"; return 0; fi
  if (( n == 0 )); then
    audit_ok updates system "Обновления безопасности установлены"
  elif (( n < 10 )); then
    audit_issue updates system medium "Ждут обновления безопасности: пакетов $n" "Оптимизация → «Обновить систему»" fn:mod_sys_update
  else
    audit_issue updates system high "Ждут обновления безопасности: пакетов $n" "Оптимизация → «Обновить систему»" fn:mod_sys_update
  fi
}

audit_check_reboot() {
  if [[ -f $AUDIT_REBOOT_FLAG ]]; then
    audit_issue reboot system low "Нужна перезагрузка (обновлены ядро или библиотеки)" "Перезагрузи сервер в удобное время" fn:reboot_prompt
  else
    audit_ok reboot system "Перезагрузка не требуется"
  fi
}

audit_check_services() {
  local n
  if ! cmd_exists systemctl; then audit_skip services_failed system "systemd недоступен"; return 0; fi
  n="$(systemctl --failed --no-legend --plain --no-pager 2>/dev/null | wc -l)"
  if (( n == 0 )); then
    audit_ok services_failed system "Упавших служб нет"
  else
    audit_issue services_failed system low "Упавших служб: $n" "Разберись в Service Manager (клавиша s) или сбрось статус" fn:menu_services
  fi
}

audit_check_maintenance() {
  local v n days
  if [[ -f $AUDIT_APT_AUTO ]] && grep -q 'Unattended-Upgrade "1"' "$AUDIT_APT_AUTO"; then
    audit_ok unattended system "Автообновления безопасности включены"
  else
    audit_issue unattended system medium "Автообновления безопасности выключены" "Оптимизация → «Автообновления безопасности»" fn:mod_autoupdates
  fi
  if [[ -e $AUDIT_APT_STAMP ]]; then
    days=$(( ( $(date +%s) - $(stat -c %Y "$AUDIT_APT_STAMP") ) / 86400 ))
    if (( days > 7 )); then
      audit_issue apt_stale system low "Списки пакетов не обновлялись $days дн." "Оптимизация → «Обновить систему»" fn:mod_sys_update
    else
      audit_ok apt_stale system "Списки пакетов обновлялись недавно"
    fi
  fi
  if cmd_exists timedatectl; then
    v="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    if [[ $v == yes ]]; then
      audit_ok time_sync system "Время синхронизировано (NTP)"
    elif [[ -n $v ]]; then
      audit_issue time_sync system low "Время не синхронизируется" "Оптимизация → «Часовой пояс и NTP»" fn:mod_timezone_ntp
    fi
  fi
  n=""
  v="$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)"
  if [[ -n $v && $v != 1 ]]; then n+="tcp_syncookies=$v "; fi
  v="$(sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null)"
  if [[ -n $v && $v != 0 ]]; then n+="accept_redirects=$v "; fi
  if [[ -n $n ]]; then
    audit_issue sysctl system low "Сетевые параметры ядра: ${n% }" "Нужно tcp_syncookies=1 и accept_redirects=0 (sysctl -w …)" none
  else
    audit_ok sysctl system "Сетевые параметры ядра в порядке"
  fi
  v="$(df -P / 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}')"
  if [[ $v =~ ^[0-9]+$ ]] && (( v >= 90 )); then
    audit_issue disk system low "Корневой диск заполнен на $v%" "Освободи место: Docker → «Очистка места»" fn:mod_docker_cleanup
  elif [[ -n $v ]]; then
    audit_ok disk system "Свободное место на диске в норме ($v%)"
  fi
}

audit_check_files() {
  local m u uid h sh ak f bad found=0 ww
  # критичные системные файлы
  if [[ -e $AUDIT_SHADOW ]]; then
    m="$(audit_mode "$AUDIT_SHADOW")"
    if audit_mode_bit "$m" other 7; then
      audit_issue perm_shadow files critical "$AUDIT_SHADOW доступен всем (права $m)" "Должно быть 640 (читает только root и группа shadow)" "chmod:640:$AUDIT_SHADOW"
      found=1
    fi
  fi
  if [[ -e $AUDIT_SSHD_CONFIG ]]; then
    m="$(audit_mode "$AUDIT_SSHD_CONFIG")"
    if audit_mode_bit "$m" group 2 || audit_mode_bit "$m" other 2; then
      audit_issue perm_sshd_config files high "sshd_config доступен на запись не только root (права $m)" "Должно быть 644" "chmod:644:$AUDIT_SSHD_CONFIG"
      found=1
    fi
  fi
  # ключи пользователей
  while IFS=: read -r u _ uid _ _ h sh; do
    [[ -d $h/.ssh ]] || continue
    case $sh in */nologin|*/false) continue ;; esac
    if (( uid != 0 && uid < 1000 )); then continue; fi
    ak="$h/.ssh/authorized_keys"
    if [[ -e $ak ]]; then
      m="$(audit_mode "$ak")"
      if audit_mode_bit "$m" group 2 || audit_mode_bit "$m" other 2; then
        audit_issue "perm_authkeys:$u" files medium "authorized_keys пользователя $u доступен на запись другим (права $m)" "Должно быть 600" "chmod:600:$ak"
        found=1
      fi
    fi
    for f in "$h"/.ssh/id_*; do
      [[ -f $f && $f != *.pub ]] || continue
      m="$(audit_mode "$f")"
      if audit_mode_bit "$m" group 7 || audit_mode_bit "$m" other 7; then
        audit_issue "perm_privkey:$f" files high "Приватный ключ $f доступен другим (права $m)" "Должно быть 600" "chmod:600:$f"
        found=1
      fi
    done
  done <"$AUDIT_PASSWD"
  # файлы с записью для всех в /etc
  ww="$(find "$AUDIT_ETC" -xdev -type f -perm -0002 2>/dev/null | head -n 3 | tr '\n' ' ')"
  if [[ -n $ww ]]; then
    audit_issue world_writable_etc files high "В /etc есть файлы с записью для всех: ${ww% }" "Убери лишние права: chmod o-w <файл>" none
    found=1
  fi
  # секреты vpsmenu и Remnanode
  if [[ -e $REMNA_COMPOSE ]]; then
    m="$(audit_mode "$REMNA_COMPOSE")"
    if audit_mode_bit "$m" other 4; then
      audit_issue perm_remna files medium "docker-compose.yml Remnanode читается всеми (права $m)" "В нём ключи ноды. Должно быть 600" "chmod:600:$REMNA_COMPOSE"
      found=1
    fi
  fi
  if [[ -d $BACKUP_DIR ]]; then
    m="$(audit_mode "$BACKUP_DIR")"
    if audit_mode_bit "$m" group 7 || audit_mode_bit "$m" other 7; then
      audit_issue perm_backups files low "Каталог бэкапов доступен не только root (права $m)" "В бэкапах могут быть ключи. Должно быть 700" "chmod:700:$BACKUP_DIR"
      found=1
    fi
  fi
  if [[ -e $LOG_FILE ]]; then
    m="$(audit_mode "$LOG_FILE")"
    if audit_mode_bit "$m" group 7 || audit_mode_bit "$m" other 7; then
      audit_issue perm_log files low "Журнал vpsmenu доступен не только root (права $m)" "Должно быть 600" "chmod:600:$LOG_FILE"
      found=1
    fi
  fi
  bad=$found
  if (( ! bad )); then audit_ok files_ok files "Права на ключевые файлы и секреты в порядке"; fi
}

# ── Запуск проверок ─────────────────────────────────────────────────────────
audit_progress() { if [[ -t 1 ]]; then printf '\r\e[K  %sпроверяю: %s…%s' "$C_DIM" "$1" "$C_RESET"; fi; }

audit_scan() { # audit_scan quick|full
  AUD_MODE=$1
  audit_reset
  audit_progress "SSH";           audit_check_ssh
  if [[ $AUD_MODE == full ]]; then audit_check_ssh_extra; fi
  audit_progress "файрвол";       audit_check_firewall
  audit_progress "fail2ban";      audit_check_fail2ban
  audit_progress "пользователи";  audit_check_users
  if [[ $AUD_MODE == full ]]; then audit_check_sudo; fi
  audit_progress "порты";         audit_check_ports
  audit_progress "Docker";        audit_check_docker
  if [[ $AUD_MODE == full ]]; then audit_check_docker_deep; fi
  audit_progress "обновления";    audit_check_updates
  audit_check_reboot
  audit_check_services
  if [[ $AUD_MODE == full ]]; then
    audit_progress "обслуживание"; audit_check_maintenance
    audit_progress "права файлов"; audit_check_files
  fi
  if [[ -t 1 ]]; then printf '\r\e[K'; fi
  audit_score
  audit_state_write
}

audit_state_write() {
  install -d -m 0755 "$STATE_DIR" 2>/dev/null
  printf '%s %s %s %s %s\n' "$(date +%s)" "$AUD_SCORE" "$AUD_MODE" "${AUD_N[critical]}" "${AUD_N[high]}" >"$AUDIT_LAST_FILE" 2>/dev/null || true
}

audit_last_line() { # печатает «уровень|текст» про последний аудит (для Dashboard)
  local ts score mode age lvl
  [[ -f $AUDIT_LAST_FILE ]] || return 1
  read -r ts score mode _ <"$AUDIT_LAST_FILE" || return 1
  [[ $ts =~ ^[0-9]+$ && $score =~ ^[0-9]+$ ]] || return 1
  age=$(( ( $(date +%s) - ts ) / 86400 ))
  if (( score >= 75 )); then lvl=ok; elif (( score >= 50 )); then lvl=warn; else lvl=bad; fi
  if (( age == 0 )); then age="сегодня"; else age="$age дн. назад"; fi
  echo "$lvl|${score}/100 (${mode}, ${age})"
}

# ── Отчёт ───────────────────────────────────────────────────────────────────
audit_report() { # печатает находки по категориям (без очистки экрана)
  local i last="" mark col tw pen txt
  tw=$(( UI_W - 14 ))
  for i in "${!AUD_ID[@]}"; do
    if [[ ${AUD_CAT[$i]} != "$last" ]]; then
      last=${AUD_CAT[$i]}
      ui_section "${AUD_CATNAME[$last]:-$last}"
    fi
    pen=""
    case ${AUD_STATUS[$i]} in
      ok)   mark="[ OK ]"; col=$C_GREEN ;;
      info) mark="[INFO]"; col=$C_DIM ;;
      skip) mark="[SKIP]"; col=$C_DIM ;;
      issue)
        if (( AUD_ACC[i] )); then mark="[ -- ]"; col=$C_DIM; pen="принято"
        elif [[ ${AUD_SEV[$i]} == critical || ${AUD_SEV[$i]} == high ]]; then mark="[FAIL]"; col=$C_RED; pen="-${AUD_PEN[$i]}"
        else mark="[WARN]"; col=$C_YELLOW; pen="-${AUD_PEN[$i]}"; fi
        ;;
    esac
    txt="$(ui_pad "$(ui_trunc "${AUD_TITLE[$i]}" "$tw")" "$tw")"
    printf '  %s%s%s %s %s%s%s\n' "$col" "$mark" "$C_RESET" "$txt" "$col" "$pen" "$C_RESET"
    if [[ ${AUD_STATUS[$i]} == issue && ${AUD_ACC[$i]} == 0 && -n ${AUD_HINT[$i]} ]] || [[ ${AUD_STATUS[$i]} == info && -n ${AUD_HINT[$i]} ]]; then
      printf '         %s→ %s%s\n' "$C_DIM" "$(ui_trunc "${AUD_HINT[$i]}" $(( UI_W - 12 )))" "$C_RESET"
    fi
  done
}

audit_summary() {
  local g lvl word col
  g="$(audit_grade)"; lvl=${g%%|*}; word=${g#*|}
  case $lvl in ok) col=$C_GREEN ;; warn) col=$C_YELLOW ;; *) col=$C_RED ;; esac
  ui_section "Итог"
  printf '  Оценка: %s%s%d/100%s · %s   %s\n' "$C_BOLD" "$col" "$AUD_SCORE" "$C_RESET" "$word" "$(ui_bar "$AUD_SCORE" 20 good)"
  printf '  %sкритичных %d · высоких %d · средних %d · низких %d · принято %d · пройдено %d%s\n' "$C_DIM" \
    "${AUD_N[critical]}" "${AUD_N[high]}" "${AUD_N[medium]}" "${AUD_N[low]}" "${AUD_N[accepted]}" "${AUD_N[ok]}" "$C_RESET"
}

audit_show() { # экран с отчётом
  local title="Quick Scan"
  if [[ $AUD_MODE == full ]]; then title="Full Scan"; fi
  header "$title"
  { audit_report; audit_summary; } | show_paged
}

audit_save_report() { # сохраняет отчёт в текстовый файл (только для root)
  local f
  backup_prepare || return 1
  f="$BACKUP_DIR/audit-${AUD_MODE}-$(date +%Y%m%d-%H%M%S).txt"
  (
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
    printf 'Security Audit (%s) · %s · %s\n' "$AUD_MODE" "$UI_HOST" "$(date '+%F %T')"
    audit_report
    audit_summary
  ) >"$f"
  chmod 600 "$f"
  backup_files 'audit-*.txt' | tail -n +11 | xargs -r rm -f
  ok "Отчёт сохранён: $f"
}

audit_cli() { # vpsmenu --audit [quick|full] — для скриптов; код выхода: 0 — всё в порядке, 1 — есть высокие, 2 — критичные
  local mode=${1:-quick}
  if [[ $mode != quick && $mode != full ]]; then echo "Использование: $APP_NAME --audit [quick|full]" >&2; return 64; fi
  audit_scan "$mode"
  printf 'Security Audit (%s) · %s · %s\n' "$mode" "$UI_HOST" "$(date '+%F %T')"
  audit_report
  audit_summary
  if (( AUD_N[critical] > 0 )); then return 2; fi
  if (( AUD_N[high] > 0 )); then return 1; fi
  return 0
}

# ── Исправление, исключения ─────────────────────────────────────────────────
audit_run_fix() { # audit_run_fix СПЕЦИФИКАЦИЯ — fn:ИМЯ | chmod:РЕЖИМ:ПУТЬ | none
  local spec=$1 rest mode path
  case $spec in
    fn:*) "${spec#fn:}" ;;
    chmod:*)
      rest=${spec#chmod:}; mode=${rest%%:*}; path=${rest#*:}
      header "Права доступа"
      info "$path: сейчас $(audit_mode "$path"), нужно $mode"
      if confirm "Выставить права $mode на $path?" Y; then
        if chmod "$mode" "$path"; then ok "Готово: $(audit_mode "$path")"; else err "Не удалось изменить права."; fi
      fi
      pause
      ;;
    *)
      info "Автоматического исправления нет — см. подсказку к пункту."
      pause
      ;;
  esac
}

audit_expected_add() { # audit_expected_add ПОРТ[/ПРОТОКОЛ]
  local list
  list="$(conf_get AUDIT_EXPECTED_PORTS)"
  if [[ " ${list//,/ } " == *" $1 "* ]]; then return 0; fi
  conf_set AUDIT_EXPECTED_PORTS "${list:+$list,}$1"
}

audit_accept() { # audit_accept ID — принять риск (порт — в список ожидаемых)
  local id=$1 list
  case $id in
    port:*|dport:*) audit_expected_add "${id#*:}" ;;
    *)
      list="$(conf_get AUDIT_ACCEPTED)"
      if [[ ",$list," != *",$id,"* ]]; then conf_set AUDIT_ACCEPTED "${list:+$list,}$id"; fi
      ;;
  esac
}

audit_issue_menu() { # audit_issue_menu ИНДЕКС — возвращает 0, если что-то изменилось (нужна перепроверка)
  local i=$1 fix=${AUD_FIX[$1]} id=${AUD_ID[$1]} has_fix=0 acc_txt="Принять риск (не учитывать в оценке)"
  if [[ -n $fix && $fix != none ]]; then has_fix=1; fi
  case $id in port:*|dport:*) acc_txt="Это ожидаемый порт — не считать проблемой" ;; esac
  header "${AUD_TITLE[$i]}"
  ui_kv "Важность" "${AUD_SEV[$i]} (штраф -${AUD_W[${AUD_SEV[$i]}]})" 11
  ui_kv "Причина" "${AUD_HINT[$i]:-—}" 11
  echo
  if (( has_fix )); then menu_item 1 "Исправить сейчас"; fi
  menu_item 2 "$acc_txt"
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    1) if (( has_fix )); then audit_run_fix "$fix"; return 0; fi ;;
    2) if confirm "Принять: «${AUD_TITLE[$i]}»? Оценка перестанет это учитывать." N; then audit_accept "$id"; ok "Принято."; pause; return 0; fi ;;
  esac
  return 1
}

audit_fix_menu() { # возвращает 0, если нужна перепроверка
  local lines="" i n shown ord sev col
  local -a order=()
  while true; do
    lines=""
    for i in "${!AUD_ID[@]}"; do
      if [[ ${AUD_STATUS[$i]} == issue && ${AUD_ACC[$i]} == 0 ]]; then lines+="${AUD_W[${AUD_SEV[$i]}]}|$i"$'\n'; fi
    done
    header "Исправить найденное"
    if [[ -z $lines ]]; then info "Нечего исправлять — проблем не найдено."; pause; return 1; fi
    mapfile -t order < <(printf '%s' "$lines" | sort -t'|' -k1,1nr -k2,2n | cut -d'|' -f2)
    shown=0
    for ord in "${order[@]}"; do
      shown=$(( shown + 1 ))
      if (( shown > 9 )); then break; fi
      sev=${AUD_SEV[$ord]}
      case $sev in critical|high) col=$C_RED ;; *) col=$C_YELLOW ;; esac
      menu_item "$shown" "${col}[${sev}]${C_RESET} $(ui_trunc "${AUD_TITLE[$ord]}" $(( UI_W - 18 )))"
    done
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      [1-9])
        n=$(( CHOICE - 1 ))
        if (( n < ${#order[@]} && n < 9 )); then
          if audit_issue_menu "${order[$n]}"; then return 0; fi
        fi
        ;;
      0) return 1 ;;
    esac
  done
}

mod_audit_rules() {
  header "Как считается оценка"
  cat <<EOF
  Оценка начинается со 100. Из неё вычитается штраф за каждую
  найденную проблему — в отчёте виден штраф у каждой строки.

    критичная  -20   (UID 0, пустые пароли, открытый Docker API…)
    высокая    -10   (вход root или по паролю, нет файрвола…)
    средняя     -5   (нет fail2ban, лишний открытый порт…)
    низкая      -2   (мелкие улучшения)

  Лимиты, чтобы один блок не обнулил оценку:
    открытые порты хоста — не больше -15, порты Docker — не больше -15.

  Не считаются: пройденные, справочные [INFO], пропущенные [SKIP]
  и принятые вами риски ([ -- ]). Оценка не ниже 0.

  90–100 отлично · 75–89 хорошо · 50–74 требует внимания · ниже 50 опасно

  Quick и Full считаются по разным наборам проверок, поэтому
  сравнивай оценки одного режима. Это проверка настроек, а не
  поиск взлома: оценка — ориентир, а не гарантия безопасности.
EOF
  echo
  pause
}

mod_audit_exceptions() {
  local p
  while true; do
    header "Исключения аудита"
    ui_kv "Ожидаемые порты" "$(conf_get AUDIT_EXPECTED_PORTS | sed 's/^$/—/')" 17
    ui_kv "Принятые риски" "$(conf_get AUDIT_ACCEPTED | sed 's/^$/—/')" 17
    echo
    menu_item 1 "Добавить ожидаемый порт (например 443 или 2222/tcp)"
    menu_item 2 "Убрать ожидаемый порт"
    menu_item 3 "Убрать принятый риск"
    menu_item 4 "Сбросить все исключения"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1)
        ask_re "Порт или порт/протокол (Enter — отмена)" "" '^$|^[0-9]{1,5}(/(tcp|udp))?$' "Формат: 443 или 443/tcp."
        p=$ASK_RESULT
        if [[ -n $p ]]; then audit_expected_add "$p"; ok "Добавлено: $p"; sleep 1; fi
        ;;
      2)
        ask_re "Какой порт убрать (Enter — отмена)" "" '^$|^[0-9]{1,5}(/(tcp|udp))?$' "Формат: 443 или 443/tcp."
        p=$ASK_RESULT
        if [[ -n $p ]]; then
          conf_set AUDIT_EXPECTED_PORTS "$(tr ',' '\n' <<<"$(conf_get AUDIT_EXPECTED_PORTS)" | grep -vxF "$p" | paste -sd, -)"
          ok "Убрано: $p"; sleep 1
        fi
        ;;
      3)
        ask_re "Какой риск убрать (id из списка, Enter — отмена)" "" '^[a-z0-9_:/.-]*$' "Допустимы латиница, цифры и _ : / . -"
        p=$ASK_RESULT
        if [[ -n $p ]]; then
          conf_set AUDIT_ACCEPTED "$(tr ',' '\n' <<<"$(conf_get AUDIT_ACCEPTED)" | grep -vxF "$p" | paste -sd, -)"
          ok "Убрано: $p"; sleep 1
        fi
        ;;
      4)
        if confirm "Сбросить все ожидаемые порты и принятые риски?" N; then
          conf_set AUDIT_EXPECTED_PORTS ""; conf_set AUDIT_ACCEPTED ""; ok "Исключения сброшены."; sleep 1
        fi
        ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

audit_session() { # audit_session quick|full — отчёт с действиями
  local mode=$1 rescan=1
  while true; do
    if (( rescan )); then
      header "$([[ $mode == full ]] && echo "Full Scan" || echo "Quick Scan")"
      audit_scan "$mode"
    fi
    rescan=0
    audit_show
    menu_item 1 "Исправить найденное / принять риск"
    menu_item r "Перепроверить"
    menu_item m "Режим: $([[ $mode == full ]] && echo "переключить на Quick" || echo "переключить на Full")"
    menu_item s "Сохранить отчёт в файл"
    menu_item h "Как считается оценка"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) if audit_fix_menu; then rescan=1; fi ;;
      r|R|к|К) rescan=1 ;;
      m|M|ь|Ь) if [[ $mode == full ]]; then mode=quick; else mode=full; fi; rescan=1 ;;
      s|S|ы|Ы) audit_save_report; pause ;;
      h|H|р|Р) mod_audit_rules ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

menu_audit() {
  local last
  while true; do
    header "Security Audit"
    last="$(audit_last_line)"
    if [[ -n $last ]]; then ui_kv "Последний" "$(badge "${last%%|*}" "${last#*|}")" 10; echo; fi
    menu_item 1 "Quick Scan — основные проверки за пару секунд"
    menu_item 2 "Full Scan — SSH, файрвол, пользователи, права, Docker, обновления, сеть"
    menu_item 3 "Исключения (ожидаемые порты, принятые риски)"
    menu_item 4 "Как считается оценка"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) audit_session quick ;;
      2) audit_session full ;;
      3) mod_audit_exceptions ;;
      4) mod_audit_rules ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
