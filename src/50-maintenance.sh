# ══════════════════════════ Оптимизация и обслуживание ══════════════════════════

mod_sys_update() {
  header "Обновление системы"
  info "Будет выполнено: apt update → apt upgrade → apt autoremove."
  hint "Твои изменённые конфиги (например sshd_config) при обновлении сохраняются."
  confirm "Продолжить?" Y || { info "Отменено."; pause; return 0; }
  if ! sys_update_run; then pause; return 1; fi
  reboot_prompt
  pause
}

mod_timezone_ntp() {
  header "Часовой пояс и NTP"
  timedatectl 2>/dev/null | sed 's/^/  /'
  echo
  local cur
  cur="$(timedatectl show -p Timezone --value 2>/dev/null)"
  ask "Часовой пояс (например Europe/Moscow или UTC)" "${cur:-UTC}"
  tz_ntp_apply "$ASK_RESULT"
  pause
}

mod_bbr() {
  header "Ускорение сети: BBR"
  local cc qd
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  info "Сейчас: congestion_control=${cc:-?}, qdisc=${qd:-?} · ядро $(uname -r)"
  if [[ $cc == bbr ]]; then
    ok "BBR уже включён."
    [[ -f $BBR_SYSCTL ]] || hint "Он включён не этим скриптом (файла $BBR_SYSCTL нет)."
    pause; return 0
  fi
  confirm "Включить BBR (+ fq) и сохранить после перезагрузки?" Y || { info "Отменено."; pause; return 0; }
  bbr_apply
  pause
}

swap_remove() {
  swapoff "$SWAPFILE" 2>/dev/null
  sed -i "\|^${SWAPFILE}[[:space:]]|d" /etc/fstab
  rm -f "$SWAPFILE" "$SWAP_SYSCTL"
}

mod_swap() {
  header "Swap (файл подкачки)"
  local virt active
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ $virt == openvz || $virt == lxc* ]]; then
    warn "Виртуализация: $virt — swap в таком контейнере обычно недоступен."
  fi
  info "Память: $(free -h | awk '/^Mem:/ {print $2}'), swap: $(free -h | awk '/^Swap:/ {print $2}')"
  active="$(swapon --show --noheadings 2>/dev/null)"

  if [[ -n $active ]]; then
    printf '%s\n' "$active" | sed 's/^/    /'
    echo
    if [[ $active == *"$SWAPFILE"* ]]; then
      ok "Swap уже настроен ($SWAPFILE)."
      if confirm "Удалить этот swap?" N; then
        swap_remove && ok "Swap удалён."
      fi
    else
      info "Swap уже есть (создан не этим скриптом) — не трогаю."
    fi
    pause; return 0
  fi

  if [[ -e $SWAPFILE ]]; then
    warn "Файл $SWAPFILE уже существует, но не подключён."
    confirm "Удалить его и создать заново?" N || { info "Отменено."; pause; return 0; }
    swap_remove
  fi

  local mem_mb def size
  mem_mb="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
  if (( mem_mb <= 8192 )); then def=2G; else def=1G; fi
  ask_re "Размер swap (например 512M, 1G, 2G)" "$def" '^[1-9][0-9]*[MG]$' "Формат: 512M, 1G, 2G."
  size=$ASK_RESULT
  hint "swappiness: чем меньше, тем реже система уходит в swap. Для VPS обычно 10."
  ask_re "vm.swappiness (0–100)" "10" '^([0-9]|[1-9][0-9]|100)$' "Число от 0 до 100."
  local swappiness=$ASK_RESULT
  confirm "Создать swap $size в $SWAPFILE?" Y || { info "Отменено."; pause; return 0; }
  if swap_create_apply "$size" "$swappiness"; then echo; free -h; fi
  pause
}

mod_autoupdates() {
  header "Автообновления безопасности"
  hint "Некоторые обновления (ядро) вступают в силу только после перезагрузки."
  hint "Автоперезагрузка кратко прервёт ноду, но контейнеры с restart: always поднимутся сами."
  local reboot=0
  if confirm "Разрешить автоперезагрузку ночью (04:00), когда она нужна?" N; then reboot=1; fi
  echo
  autoupdates_apply "$reboot" || { pause; return 1; }

  step "Состояние"
  echo "  служба:  $(systemctl is-active unattended-upgrades 2>/dev/null) / $(systemctl is-enabled unattended-upgrades 2>/dev/null)"
  if [[ -f /var/log/unattended-upgrades/unattended-upgrades.log ]]; then
    echo "  последние записи лога:"
    tail -n 5 /var/log/unattended-upgrades/unattended-upgrades.log | sed 's/^/    /'
  fi
  pause
}

mod_conf_backup() {
  header "Бэкап конфигов сервера"
  info "Сохраняются (если существуют): SSH, fail2ban, UFW, nftables, Docker daemon.json, Remnanode, настройки скрипта."
  if backup_create configs \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/fail2ban/jail.d /etc/ufw /etc/nftables.conf \
      /etc/docker/daemon.json "$REMNA_DIR" "$CONF_FILE" /etc/sysctl.d/99-vpsmenu-bbr.conf /etc/sysctl.d/99-vpsmenu-swap.conf; then
    ok "Бэкап создан: $BACKUP_RESULT"
    warn "В архиве могут быть ключи и секреты. Доступ только у root — не выкладывай файл никуда."
    hint "Хранятся последние 10 копий. Восстановление вручную: tar -xzf <файл> -C /"
  fi
  pause
}

mod_backup_list() {
  header "Список бэкапов"
  local f found=0
  while IFS= read -r f; do
    found=1
    printf '  %s  (%s)\n' "$f" "$(du -h "$f" | cut -f1)"
  done < <(backup_files '*')
  (( found )) || info "Бэкапов пока нет."
  echo
  hint "Каталог $BACKUP_DIR доступен только root."
  pause
}

menu_maint() {
  while true; do
    header "9. Оптимизация и обслуживание"
    menu_item 1 "Обновить систему (apt upgrade)"
    menu_item 2 "Часовой пояс и NTP"
    menu_item 3 "BBR (ускорение сети)"
    menu_item 4 "Swap"
    menu_item 5 "Автообновления безопасности"
    menu_item 6 "Бэкап конфигов сервера"
    menu_item 7 "Список бэкапов"
    menu_item 8 "IPv6 (включить / выключить)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_sys_update ;;
      2) mod_timezone_ntp ;;
      3) mod_bbr ;;
      4) mod_swap ;;
      5) mod_autoupdates ;;
      6) mod_conf_backup ;;
      7) mod_backup_list ;;
      8) mod_ipv6 ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

sys_update_run() {
  step "apt update"
  if ! apt_run update -q; then err "apt update завершился с ошибкой."; return 1; fi
  APT_UPDATED=1
  step "apt upgrade"
  if ! apt_run -o Dpkg::Options::=--force-confold upgrade -y -q; then
    err "apt upgrade завершился с ошибкой."; return 1
  fi
  step "apt autoremove"
  apt_run autoremove -y -q
  ok "Система обновлена."
}

tz_ntp_apply() { # tz_ntp_apply ЧАСОВОЙ_ПОЯС (пусто — не менять)
  local tz=${1:-} tzs
  if [[ -n $tz ]]; then
    tzs="$(timedatectl list-timezones 2>/dev/null)"
    if ! grep -qxF "$tz" <<<"$tzs"; then
      err "Неизвестный часовой пояс: $tz (список: timedatectl list-timezones)"; return 1
    fi
    if timedatectl set-timezone "$tz"; then ok "Часовой пояс: $tz"; else err "Не удалось задать часовой пояс."; return 1; fi
  fi

  step "Синхронизация времени (NTP)"
  if is_pkg_installed chrony; then
    info "Используется chrony — синхронизация идёт через него."
    service_active chrony || systemctl enable --now chrony >/dev/null 2>&1
  elif timedatectl set-ntp true 2>/dev/null; then
    ok "NTP включён."
  else
    warn "timedatectl не смог включить NTP — ставлю systemd-timesyncd."
    if apt_install systemd-timesyncd && systemctl enable --now systemd-timesyncd >/dev/null 2>&1 && timedatectl set-ntp true; then
      ok "systemd-timesyncd установлен, NTP включён."
    else
      err "Не удалось настроить NTP."; return 1
    fi
  fi
  sleep 2
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then
    ok "Время синхронизировано."
  else
    warn "Синхронизация пока не подтверждена (может занять до минуты). Проверь позже: timedatectl"
  fi
}

bbr_apply() {
  local virt cc avail
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ $virt == openvz || $virt == lxc* ]]; then
    warn "Виртуализация: $virt — менять сетевые параметры ядра в таком контейнере обычно нельзя."
  fi
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if [[ $cc == bbr ]]; then ok "BBR уже включён."; return 0; fi
  modprobe tcp_bbr 2>/dev/null
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
  if [[ " $avail " != *" bbr "* ]]; then err "Ядро не поддерживает BBR (доступно: ${avail:-?})."; return 1; fi
  printf '# Создано %s\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' "$APP_NAME" >"$BBR_SYSCTL"
  echo tcp_bbr >"/etc/modules-load.d/${APP_NAME}-bbr.conf"
  sysctl -p "$BBR_SYSCTL" >/dev/null 2>&1
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]]; then
    ok "BBR включён: $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
  else
    err "Не удалось применить BBR — откатываю."
    rm -f "$BBR_SYSCTL" "/etc/modules-load.d/${APP_NAME}-bbr.conf"
    return 1
  fi
}

swap_create_apply() { # swap_create_apply РАЗМЕР(512M|1G) SWAPPINESS
  local size=$1 swappiness=${2:-10} virt size_mb avail_mb fstype active
  if [[ ! $size =~ ^[1-9][0-9]*[MG]$ ]]; then err "Некорректный размер swap: $size"; return 1; fi
  active="$(swapon --show --noheadings 2>/dev/null)"
  if [[ -n $active ]]; then info "Swap уже есть — новый не создаю."; return 0; fi
  if [[ -e $SWAPFILE ]]; then err "$SWAPFILE уже существует и не подключён — удали его (Оптимизация → Swap)."; return 1; fi
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ $virt == openvz || $virt == lxc* ]]; then
    warn "Виртуализация: $virt — swap в таком контейнере обычно недоступен."
  fi
  if [[ $size == *G ]]; then size_mb=$(( ${size%G} * 1024 )); else size_mb=${size%M}; fi
  avail_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  if (( size_mb + 1024 > avail_mb )); then
    err "Мало места: свободно ${avail_mb}M, нужно ${size_mb}M плюс запас 1G."; return 1
  fi
  fstype="$(findmnt -no FSTYPE / 2>/dev/null)"
  if [[ $fstype == btrfs || $fstype == zfs ]]; then
    err "На $fstype swap-файл требует особой настройки — скрипт этого не делает."; return 1
  fi

  step "Создаю $SWAPFILE"
  if ! fallocate -l "${size_mb}M" "$SWAPFILE" 2>/dev/null; then
    info "fallocate недоступен — использую dd (дольше)."
    if ! dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size_mb" status=none; then
      err "Не удалось создать файл."; rm -f "$SWAPFILE"; return 1
    fi
  fi
  chmod 600 "$SWAPFILE"
  if ! mkswap "$SWAPFILE" >/dev/null; then err "mkswap не удался."; rm -f "$SWAPFILE"; return 1; fi
  if ! swapon "$SWAPFILE"; then
    err "swapon не удался (возможно, виртуализация запрещает swap)."
    rm -f "$SWAPFILE"; return 1
  fi
  ok "Swap подключён: $size"

  if ! grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab; then
    backup_prepare
    cp -a /etc/fstab "$BACKUP_DIR/fstab.$(date +%Y%m%d-%H%M%S)"
    printf '%s none swap sw 0 0\n' "$SWAPFILE" >>/etc/fstab
    ok "Запись добавлена в /etc/fstab (копия fstab в $BACKUP_DIR)."
  fi
  printf '# Создано %s\nvm.swappiness = %s\n' "$APP_NAME" "$swappiness" >"$SWAP_SYSCTL"
  sysctl -p "$SWAP_SYSCTL" >/dev/null 2>&1 && ok "vm.swappiness = $swappiness"
  return 0
}

autoupdates_apply() { # autoupdates_apply ПЕРЕЗАГРУЗКА(0|1)
  local reboot=${1:-0} f=/etc/apt/apt.conf.d/20auto-upgrades rf=/etc/apt/apt.conf.d/52vpsmenu-unattended.conf
  if is_pkg_installed unattended-upgrades; then
    ok "unattended-upgrades уже установлен."
  else
    apt_install unattended-upgrades || return 1
  fi
  if [[ -f $f ]] && grep -q 'Unattended-Upgrade "1"' "$f"; then
    ok "Автообновления уже включены."
  else
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$f"
    ok "Автообновления включены (ставятся только обновления безопасности Ubuntu)."
  fi
  systemctl enable --now unattended-upgrades >/dev/null 2>&1
  if [[ $reboot == 1 ]]; then
    printf 'Unattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-Time "04:00";\n' >"$rf"
    ok "Автоперезагрузка включена (04:00)."
  else
    rm -f "$rf"
    info "Автоперезагрузка выключена — перезагружай вручную, когда пишет «Требуется перезагрузка»."
  fi
}
