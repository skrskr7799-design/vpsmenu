# ══════════════════════════ nftables ══════════════════════════

nft_install_ordering() {
  # Штатный /etc/nftables.conf начинается с «flush ruleset» — при загрузке он сносит правила ufw/docker,
  # если отработает после них. Заставляем nftables стартовать раньше.
  local d=/etc/systemd/system/nftables.service.d f
  f="$d/10-before-ufw-docker.conf"
  [[ -f $f ]] && return 0
  install -d "$d" || return 1
  cat >"$f" <<'EOF'
[Unit]
# Создано vpsmenu: nftables.conf делает "flush ruleset", поэтому запускаем его ДО ufw и docker.
Before=ufw.service docker.service
EOF
  systemctl daemon-reload && ok "Добавлен порядок запуска: nftables → ufw → docker."
}

mod_nft_setup() {
  header "4. nftables: установка и запуск"
  if is_pkg_installed nftables; then
    ok "nftables уже установлен: $(nft --version 2>/dev/null)"
  else
    apt_install nftables || { pause; return 1; }
    ok "nftables установлен: $(nft --version 2>/dev/null)"
  fi

  nft_install_ordering

  if service_enabled nftables; then
    ok "Автозапуск уже включён."
  elif systemctl enable nftables >/dev/null 2>&1; then
    ok "Автозапуск включён."
  else
    err "Не удалось включить автозапуск."
  fi

  if service_active nftables; then
    ok "Служба nftables уже запущена."
  else
    local ufw_on=0 docker_on=0
    ufw_is_active && ufw_on=1
    service_active docker && docker_on=1
    if (( ufw_on || docker_on )); then
      echo
      warn "При запуске nftables читает /etc/nftables.conf, который начинается с «flush ruleset»."
      warn "Это на мгновение сбросит правила UFW/Docker; я перезагружу их сразу после запуска."
      confirm "Запустить nftables сейчас?" Y || { info "Запуск отложен."; pause; return 0; }
    fi
    if systemctl start nftables; then
      ok "nftables запущен."
      if (( ufw_on )); then
        if ufw reload >/dev/null; then ok "Правила UFW перезагружены."; else err "Не удалось перезагрузить UFW!"; fi
      fi
      if (( docker_on )); then
        hint "Docker нужно перезапустить, чтобы он заново создал свои правила (контейнеры с restart: always поднимутся сами)."
        if confirm "Перезапустить Docker?" Y; then
          if systemctl restart docker; then ok "Docker перезапущен."; else err "Не удалось перезапустить Docker."; fi
        fi
      fi
    else
      err "Не удалось запустить nftables. Смотри: journalctl -u nftables"
    fi
  fi

  step "Статус"
  echo "  active:  $(systemctl is-active nftables 2>/dev/null)"
  echo "  enabled: $(systemctl is-enabled nftables 2>/dev/null)"
  echo
  nft list ruleset | show_paged
  pause
}

mod_nft_ruleset() {
  header "nftables: список правил"
  if ! cmd_exists nft; then err "nftables не установлен."; pause; return 1; fi
  nft list ruleset | show_paged
  pause
}

mod_nft_check() {
  header "nftables: проверка /etc/nftables.conf"
  if ! cmd_exists nft; then err "nftables не установлен."; pause; return 1; fi
  if [[ ! -f /etc/nftables.conf ]]; then err "Файла /etc/nftables.conf нет."; pause; return 1; fi
  local out
  if out="$(nft -c -f /etc/nftables.conf 2>&1)"; then ok "Синтаксис корректен."; else err "Ошибка в конфиге:"; echo "$out"; fi
  pause
}

menu_nft() {
  while true; do
    header "4. nftables"
    menu_item 1 "Установить / включить / запустить"
    menu_item 2 "Показать список правил"
    menu_item 3 "Проверить синтаксис /etc/nftables.conf"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_nft_setup ;;
      2) mod_nft_ruleset ;;
      3) mod_nft_check ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
