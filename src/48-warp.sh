# ══════════════════════════ WARP Native ══════════════════════════

warp_detected() {
  [[ -f /etc/wireguard/warp.conf ]] ||
    ip link show warp >/dev/null 2>&1 ||
    systemctl is-enabled --quiet wg-quick@warp 2>/dev/null
}

mod_warp() {
  header "8. WARP Native"
  if warp_detected; then
    ok "Похоже, WARP Native уже установлен (найден интерфейс или конфиг warp)."
    hint "Повторный запуск установщика может изменить текущие настройки. Если нужно управление/удаление — у установщика есть своё меню."
    confirm "Всё равно запустить установщик?" N || { info "Отменено."; pause; return 0; }
  else
    info "WARP Native не обнаружен. Установщик: $WARP_URL"
    confirm "Установить?" Y || { info "Отменено."; pause; return 0; }
  fi

  ensure_curl || { pause; return 1; }

  local tmp rc
  tmp="$(mktemp)"
  step "Скачиваю установщик"
  if ! download "$WARP_URL" "$tmp"; then
    err "Не удалось скачать установщик (проверь интернет, DNS, доступность GitHub)."
    rm -f "$tmp"; pause; return 1
  fi
  ok "Скачано."

  warn "Это сторонний скрипт, он будет выполнен от root."
  if confirm "Просмотреть его перед запуском?" N; then
    show_paged <"$tmp"
    confirm "Запускать?" Y || { info "Отменено."; rm -f "$tmp"; pause; return 0; }
  fi

  step "Запускаю установщик (дальше работает его собственное меню)"
  bash "$tmp"; rc=$?
  rm -f "$tmp"
  if (( rc == 0 )); then ok "Установщик завершился без ошибок."; else err "Установщик завершился с кодом $rc."; fi
  pause
}
