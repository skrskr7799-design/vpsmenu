# ══════════════════════════ Мастер быстрой настройки ══════════════════════════

mod_wizard() {
  header "Мастер быстрой настройки"
  info "Пройдём по шагам по порядку. Каждый шаг можно пропустить."
  warn "Запрет root и вход только по ключам включай лишь после проверки входа пользователем в отдельном окне."
  hint "Смена порта SSH в мастер не входит — она в меню SSH."
  pause

  local -a steps=(
    "Обновление системы|mod_sys_update"
    "Часовой пояс и NTP|mod_timezone_ntp"
    "Пользователь с sudo|mod_user_create"
    "SSH: добавить публичный ключ|mod_ssh_addkey"
    "SSH: запрет входа под root|mod_ssh_disable_root"
    "SSH: вход только по ключам (необязательно)|mod_ssh_keys_only"
    "UFW (файрвол)|mod_ufw_setup"
    "nftables|mod_nft_setup"
    "Fail2ban|mod_f2b_setup"
    "Docker|mod_docker"
    "Docker: ротация логов|mod_docker_logrotate"
    "BBR (ускорение сети)|mod_bbr"
    "Swap|mod_swap"
    "Автообновления безопасности|mod_autoupdates"
    "Remnanode|mod_remna_setup"
    "WARP Native|mod_warp"
  )
  local total=${#steps[@]} i=0 entry title fn ans
  for entry in "${steps[@]}"; do
    i=$((i + 1))
    title=${entry%%|*}
    fn=${entry##*|}
    header "Мастер: шаг $i из $total"
    printf '  %s%s%s\n\n' "$C_BOLD" "$title" "$C_RESET"
    read -r -p "  [Enter] выполнить · [s] пропустить · [q] выйти из мастера: " ans || { echo; exit 0; }
    case "${ans,,}" in
      s|ы) continue ;;
      q|й) info "Мастер завершён досрочно."; pause; return 0 ;;
    esac
    "$fn"
  done
  header "Мастер быстрой настройки"
  ok "Все шаги пройдены."
  hint "Итоговое состояние: главное меню → «Обзор системы»."
  pause
}
