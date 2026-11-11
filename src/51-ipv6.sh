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

ipv6_has_global() { # есть ли глобальные IPv6-адреса
  ip -6 -o addr show scope global 2>/dev/null | grep -q .
}

ipv6_addrs() { # печатает глобальные IPv6 (по одному в строке)
  ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | sed 's|/.*||'
}

ipv6_ufw_ipv6() { # yes|no|? — поддержка IPv6 в UFW
  local f=/etc/default/ufw
  if [[ ! -r $f ]]; then echo "?"; return; fi
  if grep -qE '^[[:space:]]*IPV6=yes' "$f"; then echo yes
  elif grep -qE '^[[:space:]]*IPV6=no' "$f"; then echo no
  else echo "?"; fi
}

ipv6_status_lines() { # печатает строки статуса для меню/обзора
  local ufw a
  if ipv6_is_disabled; then
    printf '  %-14s %s\n' "IPv6" "$(badge ok 'выключен (sysctl)')"
  else
    printf '  %-14s %s\n' "IPv6" "$(badge warn 'включён')"
  fi
  if [[ -f $IPV6_SYSCTL ]]; then
    printf '  %-14s %s\n' "Файл" "$IPV6_SYSCTL"
  else
    printf '  %-14s %s\n' "Файл" "${C_DIM}нет (настройка не через vpsmenu)${C_RESET}"
  fi
  if ipv6_has_global; then
    printf '  %-14s %s\n' "Адреса" "есть глобальные:"
    while read -r a; do
      [[ -n $a ]] && printf '                 %s\n' "$a"
    done < <(ipv6_addrs)
  else
    printf '  %-14s %s\n' "Адреса" "${C_DIM}глобальных IPv6 нет${C_RESET}"
  fi
  ufw="$(ipv6_ufw_ipv6)"
  case $ufw in
    yes) printf '  %-14s %s\n' "UFW IPv6" "$(badge ok 'IPV6=yes')" ;;
    no)  printf '  %-14s %s\n' "UFW IPv6" "$(badge warn 'IPV6=no')" ;;
    *)   printf '  %-14s %s\n' "UFW IPv6" "${C_DIM}не определён${C_RESET}" ;;
  esac
}

ipv6_disable_apply() {
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ $virt == openvz || $virt == lxc* ]]; then
    warn "Виртуализация: $virt — sysctl IPv6 в контейнере может не применяться."
  fi
  if ipv6_is_disabled && [[ -f $IPV6_SYSCTL ]]; then
    ok "IPv6 уже выключен через $IPV6_SYSCTL."
    return 0
  fi
  printf '# Создано %s — отключение IPv6\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' \
    "$APP_NAME" >"$IPV6_SYSCTL"
  if ! sysctl -p "$IPV6_SYSCTL" >/dev/null 2>&1; then
    err "Не удалось применить sysctl."; return 1
  fi
  if ipv6_is_disabled; then
    ok "IPv6 выключен (net.ipv6.conf.all.disable_ipv6=1)."
    if ipv6_has_global; then
      warn "Глобальные IPv6-адреса ещё видны — полный эффект после перезагрузки."
      hint "Перезагрузка снимет уже выданные адреса. Без неё новые соединения по IPv6 уже не поднимутся."
    fi
  else
    err "sysctl применился, но disable_ipv6 всё ещё не 1. Проверь: sysctl net.ipv6.conf.all.disable_ipv6"
    return 1
  fi
  return 0
}

ipv6_enable_apply() {
  if [[ -f $IPV6_SYSCTL ]]; then
    rm -f "$IPV6_SYSCTL"
    ok "Удалён $IPV6_SYSCTL."
  fi
  if sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1; then
    ok "IPv6 включён в текущей сессии."
  else
    warn "Не удалось выставить sysctl в 0 (возможно, права или контейнер)."
  fi
  if ipv6_is_disabled; then
    warn "IPv6 всё ещё отключён. Возможно, его глушит другой файл в /etc/sysctl.d/."
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
    menu_item 2 "Обновить статус"
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
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
