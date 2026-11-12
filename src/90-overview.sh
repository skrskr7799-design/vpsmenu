# ══════════════════════════ Панель статусов и обзор системы ══════════════════════════

status_panel() {
  local s ports pass txt

  if cmd_exists sshd; then
    s="$(sshd_effective permitrootlogin)"
    ports="$(detect_ssh_ports)"
    pass="$(sshd_effective passwordauthentication)"
    if [[ $pass == yes ]]; then pass=да; elif [[ $pass == no ]]; then pass=нет; else pass="?"; fi
    txt="порт ${ports} · пароль: ${pass}"
    if [[ $s == no ]]; then printf '  %-10s %s\n' "SSH" "$(badge ok "root запрещён · $txt")"
    else printf '  %-10s %s\n' "SSH" "$(badge warn "root разрешён · $txt")"; fi
  else
    printf '  %-10s %s\n' "SSH" "$(badge off 'sshd не найден')"
  fi

  if ipv6_is_disabled; then
    printf '  %-10s %s\n' "IPv6" "$(badge ok 'выключен')"
  elif ipv6_has_public && ipv6_has_default_route; then
    printf '  %-10s %s\n' "IPv6" "$(badge ok 'публичный адрес и маршрут есть')"
  elif ipv6_has_public; then
    printf '  %-10s %s\n' "IPv6" "$(badge warn 'адрес есть, маршрута нет')"
  else
    printf '  %-10s %s\n' "IPv6" "$(badge warn 'включён, публичный адрес не найден')"
  fi

  if ! cmd_exists ufw; then printf '  %-10s %s\n' "UFW" "$(badge off 'не установлен')"
  elif ufw_is_active; then printf '  %-10s %s\n' "UFW" "$(badge ok 'активен')"
  else printf '  %-10s %s\n' "UFW" "$(badge warn 'установлен, выключен')"; fi

  if ! cmd_exists nft; then printf '  %-10s %s\n' "nftables" "$(badge off 'не установлен')"
  elif service_active nftables; then printf '  %-10s %s\n' "nftables" "$(badge ok 'активен')"
  else printf '  %-10s %s\n' "nftables" "$(badge warn 'установлен, служба не запущена')"; fi

  if ! cmd_exists fail2ban-client; then printf '  %-10s %s\n' "Fail2ban" "$(badge off 'не установлен')"
  elif service_active fail2ban; then printf '  %-10s %s\n' "Fail2ban" "$(badge ok 'работает')"
  else printf '  %-10s %s\n' "Fail2ban" "$(badge warn 'установлен, не запущен')"; fi

  if ! cmd_exists docker; then printf '  %-10s %s\n' "Docker" "$(badge off 'не установлен')"
  elif service_active docker; then printf '  %-10s %s\n' "Docker" "$(badge ok 'работает')"
  else printf '  %-10s %s\n' "Docker" "$(badge warn 'установлен, не запущен')"; fi

  local rs
  rs="$(remna_panel_state)"
  printf '  %-10s %s\n' "Remnanode" "$(badge "${rs%%|*}" "${rs#*|}")"

  if warp_detected; then printf '  %-10s %s\n' "WARP" "$(badge ok 'обнаружен')"
  else printf '  %-10s %s\n' "WARP" "$(badge off 'не обнаружен')"; fi

  local cc swp lvl=ok
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  swp="$(free -h 2>/dev/null | awk '/^Swap:/ {print $2}')"
  if [[ $cc == bbr ]]; then txt="BBR вкл"; else txt="BBR выкл"; lvl=warn; fi
  if [[ -n $swp && $swp != 0B ]]; then txt+=" · swap $swp"; else txt+=" · swap нет"; lvl=warn; fi
  if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
    txt+=" · автообновл. вкл"
  else
    txt+=" · автообновл. выкл"; lvl=warn
  fi
  printf '  %-10s %s\n' "Tuning" "$(badge "$lvl" "$txt")"
}

mod_overview() {
  header "9. Обзор системы"
  printf '  %-10s %s\n' "Kernel" "$(uname -r)"
  printf '  %-10s %s\n' "Uptime" "$(uptime -p 2>/dev/null | sed 's/^up //')"
  printf '  %-10s %s\n' "IP" "$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '  %-10s %s\n' "Memory" "$(free -h | awk '/^Mem:/ {print $3 " / " $2}')"
  printf '  %-10s %s\n' "Disk /" "$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
  hr
  status_panel
  hr
  info "Лог действий скрипта: $LOG_FILE"
  pause
}
