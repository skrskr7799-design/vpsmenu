# ══════════════════════════ Главное меню и точка входа ══════════════════════════

main_menu() {
  while true; do
    header "Главное меню"
    if (( ! UI_COMPACT )); then
      status_panel
      hr
    fi
    if [[ -n $UPDATE_AVAILABLE ]]; then
      printf '  %s▲ Доступна новая версия скрипта: %s → %s (пункт 12 → 1)%s\n' "$C_YELLOW" "$APP_VERSION" "$UPDATE_AVAILABLE" "$C_RESET"
      hr
    fi
    menu_item d "Dashboard — состояние сервера"
    echo
    menu_item 1 "Пользователь с sudo"
    menu_item 2 "SSH: root, ключи, порт"
    menu_item 3 "UFW (файрвол)"
    menu_item 4 "nftables"
    menu_item 5 "Fail2ban"
    menu_item 6 "Docker"
    menu_item 7 "Remnanode"
    menu_item 8 "WARP Native"
    menu_item 9 "Оптимизация и обслуживание"
    menu_item 10 "Мастер быстрой настройки"
    menu_item 11 "Обзор системы"
    menu_item 12 "Сам скрипт (обновление, установка)"
    menu_item 13 "Профили серверов"
    menu_item 14 "Диагностика сети (speedtest, ping)"
    menu_item 0 "Выход"
    echo; read_choice
    case $CHOICE in
      d|D|в|В) mod_dashboard ;;
      1)  mod_user ;;
      2)  menu_ssh ;;
      3)  menu_ufw ;;
      4)  menu_nft ;;
      5)  menu_f2b ;;
      6)  menu_docker ;;
      7)  menu_remna ;;
      8)  mod_warp ;;
      9)  menu_maint ;;
      10) mod_wizard ;;
      11) mod_overview ;;
      12) menu_self ;;
      13) menu_profiles ;;
      14) menu_net ;;
      0|q|Q) echo; ok "Пока!"; exit 0 ;;
      *)  warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

main() {
  case "${1:-}" in
    --install)  self_install; exit $? ;;
    --update)   check_os; mod_update; exit 0 ;;
    --watchdog) watchdog_run; exit $? ;;
    --dashboard) os_pretty_init; dash_render 1; exit 0 ;;
  esac
  check_os
  log INFO "Запуск ${APP_NAME} ${APP_VERSION} (${SUDO_USER:-root})"
  first_run_offer
  update_check_cached
  main_menu
}

if [[ -z ${VPSMENU_SOURCE_ONLY:-} ]]; then
  main "$@"
fi
