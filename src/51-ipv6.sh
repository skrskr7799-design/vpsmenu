# ══════════════════════════ IPv6 ══════════════════════════
# Управление IPv6 через sysctl. Полное отключение иногда требует перезагрузки
# (уже выданные адреса могут остаться до reboot), но для большинства VPS sysctl достаточно.

IPV6_SYSCTL="${IPV6_SYSCTL:-/etc/sysctl.d/99-${APP_NAME}-ipv6.conf}"

ipv6_sysctl_val() { # ipv6_sysctl_val КЛЮЧ — печатает значение или пусто
  sysctl -n "$1" 2>/dev/null || true
}

ipv6_is_disabled() { # 0 = IPv6 сейчас выключен
  local v
  v="$(ipv6_sysctl_val net.ipv6.conf.all.disable_ipv6)"
  [[ $v == 1 ]]
}

ipv6_has_global() { # есть ли IPv6-адреса scope global (включая ULA)
  ip -6 -o addr show scope global 2>/dev/null | grep -E . >/dev/null
}

ipv6_addrs() { # печатает IPv6 scope global (по одному в строке)
  ip -6 -o addr show scope global 2>/dev/null | awk '!/ tentative| dadfailed/ {print $4}' | sed 's|/.*||'
}

ipv6_has_public() { ipv6_addrs | grep -iE '^[23][0-9a-f]{0,3}:' >/dev/null; }
ipv6_has_default_route() { ip -6 route show default 2>/dev/null | grep -E . >/dev/null; }
ipv6_test_connectivity() {
  ipv6_is_disabled && return 1
  ipv6_has_public || return 1
  ipv6_has_default_route || return 1
  command -v curl >/dev/null 2>&1 || return 2
  curl -6 -fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org >/dev/null 2>&1
}
ipv6_local_state() {
  if ipv6_is_disabled; then echo "выключен"
  elif ipv6_has_public && ipv6_has_default_route; then echo "адрес и маршрут есть"
  elif ipv6_has_public; then echo "адрес есть, маршрута нет"
  elif ipv6_has_default_route; then echo "маршрут есть, публичного IPv6 нет"
  else echo "включён, публичный IPv6 не обнаружен"; fi
}

ipv6_ufw_ipv6() { # yes|no|? — поддержка IPv6 в UFW
  local f=/etc/default/ufw
  if [[ ! -r $f ]]; then echo "?"; return; fi
  if grep -qE '^[[:space:]]*IPV6=yes' "$f"; then echo yes
  elif grep -qE '^[[:space:]]*IPV6=no' "$f"; then echo no
  else echo "?"; fi
}

ipv6_status_lines() {
  local ufw a
  if ipv6_is_disabled; then
    printf '  %-14s %s\n' "IPv6 ядро" "$(badge ok 'выключен (sysctl)')"
  else
    printf '  %-14s %s\n' "IPv6 ядро" "$(badge warn 'включён в ядре')"
  fi
  if ipv6_has_public; then
    printf '  %-14s %s\n' "Публичный IP" "$(badge ok 'адрес обнаружен')"
    while read -r a; do
      [[ $a =~ ^[23][0-9a-fA-F]{0,3}: ]] && printf '                 %s\n' "$a"
    done < <(ipv6_addrs)
  else
    printf '  %-14s %s\n' "Публичный IP" "$(badge warn 'не обнаружен')"
  fi
  if ipv6_has_default_route; then
    printf '  %-14s %s\n' "Маршрут" "$(badge ok 'IPv6 default route есть')"
  else
    printf '  %-14s %s\n' "Маршрут" "$(badge warn 'IPv6 default route нет')"
  fi
  printf '  %-14s %s\n' "Интернет" "${C_DIM}не проверялся — нажми «Проверить связь»${C_RESET}"
  if [[ -f $IPV6_SYSCTL ]]; then
    printf '  %-14s %s\n' "Файл" "$IPV6_SYSCTL"
  else
    printf '  %-14s %s\n' "Файл" "${C_DIM}нет (настройка не через vpsmenu)${C_RESET}"
  fi
  ufw="$(ipv6_ufw_ipv6)"
  case $ufw in
    yes) printf '  %-14s %s\n' "UFW IPv6" "$(badge ok 'IPV6=yes')" ;;
    no)  printf '  %-14s %s\n' "UFW IPv6" "$(badge warn 'IPV6=no')" ;;
    *)   printf '  %-14s %s\n' "UFW IPv6" "${C_DIM}не определён${C_RESET}" ;;
  esac
}

ipv6_disable_apply() {
  local virt old_all old_default
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ $virt == openvz || $virt == lxc* ]]; then
    warn "Виртуализация: $virt — sysctl IPv6 в контейнере может не применяться."
  fi
  if ipv6_is_disabled && [[ -f $IPV6_SYSCTL ]]; then
    ok "IPv6 уже выключен через $IPV6_SYSCTL."
    return 0
  fi
  old_all="$(ipv6_sysctl_val net.ipv6.conf.all.disable_ipv6)"
  old_default="$(ipv6_sysctl_val net.ipv6.conf.default.disable_ipv6)"
  printf '# Создано %s — отключение IPv6\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' \
    "$APP_NAME" >"$IPV6_SYSCTL"
  if ! sysctl -p "$IPV6_SYSCTL" >/dev/null 2>&1 || ! ipv6_is_disabled; then
    rm -f "$IPV6_SYSCTL"
    [[ $old_all =~ ^[01]$ ]] && sysctl -w "net.ipv6.conf.all.disable_ipv6=$old_all" >/dev/null 2>&1 || true
    [[ $old_default =~ ^[01]$ ]] && sysctl -w "net.ipv6.conf.default.disable_ipv6=$old_default" >/dev/null 2>&1 || true
    err "Не удалось отключить IPv6. Настройка отменена, исходные значения восстановлены."
    return 1
  fi
  ok "IPv6 выключен (net.ipv6.conf.all.disable_ipv6=1)."
  if ipv6_has_global; then
    warn "Глобальные IPv6-адреса ещё видны — полный эффект после перезагрузки."
    hint "Перезагрузка снимет уже выданные адреса. Без неё новые соединения по IPv6 уже не поднимутся."
  fi
  return 0
}

ipv6_enable_apply() {
  local ufw_state
  if cmd_exists ufw && ufw_is_active; then
    ufw_state="$(ipv6_ufw_ipv6)"
    if [[ $ufw_state != yes ]]; then
      err "IPv6 не включён: UFW активен, но поддержка IPv6 не подтверждена (IPV6=${ufw_state})."
      hint "Сначала настрой IPV6=yes в /etc/default/ufw, проверь правила IPv6 и перезагрузи UFW."
      return 1
    fi
  fi
  if ! sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1; then
    warn "Не удалось выставить sysctl в 0 (возможно, права или контейнер). Файл постоянной настройки не изменён."
    return 1
  fi
  if [[ -f $IPV6_SYSCTL ]]; then
    if ! rm -f "$IPV6_SYSCTL"; then
      sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
      err "Не удалось удалить $IPV6_SYSCTL. Исходное состояние восстановления предпринято."
      return 1
    fi
    ok "Удалён $IPV6_SYSCTL."
  fi
  if ipv6_is_disabled; then
    warn "IPv6 всё ещё отключён. Возможно, его глушит другой файл в /etc/sysctl.d/ или параметр ядра."
    hint "Проверь: grep -r disable_ipv6 /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null"
    return 1
  fi
  ok "IPv6 доступен. Адреса появятся, если провайдер их выдаёт (иногда нужен reboot)."
  return 0
}

mod_ipv6() {
  while true; do
    header "IPv6"
    ipv6_status_lines
    echo
    hint "Отключение через sysctl уменьшает поверхность атаки и шум сканеров по IPv6."
    hint "Уже выданные адреса могут остаться до перезагрузки — это нормально."
    echo
    if ipv6_is_disabled; then
      menu_item 1 "Включить IPv6"
    else
      menu_item 1 "Выключить IPv6"
    fi
    menu_item 2 "Обновить локальный статус"
    menu_item 3 "Проверить связь с IPv6-интернетом"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1)
        if ipv6_is_disabled; then
          header "IPv6: включение"
          confirm "Включить IPv6?" Y || { info "Отменено."; pause; continue; }
          ipv6_enable_apply
          pause
        else
          header "IPv6: отключение"
          warn "После отключения сервер перестанет принимать новые соединения по IPv6."
          if ipv6_has_global; then
            warn "Сейчас есть глобальные IPv6 — полный эффект (адреса исчезнут) после reboot."
          fi
          confirm "Выключить IPv6?" Y || { info "Отменено."; pause; continue; }
          ipv6_disable_apply
          pause
        fi
        ;;
      2) ;;
      3)
        header "Проверка IPv6-интернета"
        if ipv6_is_disabled; then
          warn "IPv6 выключен в ядре."
        elif ! ipv6_has_public; then
          warn "Не найден публичный IPv6-адрес (2000::/3)."
        elif ! ipv6_has_default_route; then
          warn "Не найден маршрут IPv6 по умолчанию."
        elif ! command -v curl >/dev/null 2>&1; then
          warn "curl не установлен — внешнюю проверку выполнить нечем."
        elif ipv6_test_connectivity; then
          ok "Внешнее IPv6-соединение работает."
        else
          warn "Не удалось подтвердить IPv6-доступ в интернет."
          hint "Причиной могут быть DNS, маршрутизация, firewall или недоступность сервиса проверки."
        fi
        pause
        ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
