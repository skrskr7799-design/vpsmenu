# ══════════════════════════ Самообновление и установка скрипта ══════════════════════════

self_install() {
  if [[ ! -f $SELF ]]; then
    err "Скрипт запущен не из файла — сохрани его в файл и запусти оттуда."
    return 1
  fi
  if [[ $SELF == "$INSTALL_PATH" ]]; then
    ok "Запущена уже установленная копия: $INSTALL_PATH"
    return 0
  fi
  if [[ -f $INSTALL_PATH ]] && cmp -s "$SELF" "$INSTALL_PATH"; then
    ok "Установлена актуальная версия: $INSTALL_PATH"
    return 0
  fi
  if install -m 0755 -o root -g root "$SELF" "$INSTALL_PATH"; then
    ok "Установлено: $INSTALL_PATH"
    info "Теперь запускай из любого места командой:  ${C_BOLD}${APP_NAME}${C_RESET}"
  else
    err "Не удалось скопировать скрипт в $INSTALL_PATH"
    return 1
  fi
}

self_uninstall() {
  if [[ ! -f $INSTALL_PATH ]]; then warn "Скрипт не установлен в систему."; return 0; fi
  if confirm "Удалить $INSTALL_PATH? (лог $LOG_FILE останется)" N; then
    rm -f "$INSTALL_PATH" && ok "Удалено." || err "Не удалось удалить."
  fi
}

menu_self() {
  while true; do
    header "12. Скрипт ${APP_NAME}"
    info "Версия: $APP_VERSION · источник обновлений: $(update_repo_ok && echo "github.com/$(update_repo) ($(update_branch))" || echo "не задан")"
    if [[ -f $INSTALL_PATH ]]; then info "Установлен: $INSTALL_PATH"; else info "Не установлен в систему."; fi
    echo
    menu_item 1 "Обновить скрипт из GitHub"
    menu_item 2 "Откатить на предыдущую версию"
    menu_item 3 "Репозиторий GitHub (настройка)"
    menu_item 4 "Установить эту копию в систему"
    menu_item 5 "Удалить из системы"
    menu_item 6 "Показать лог действий (последние 100 строк)"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_update ;;
      2) mod_update_rollback ;;
      3) update_configure_repo; pause ;;
      4) self_install; pause ;;
      5) self_uninstall; pause ;;
      6) tail -n 100 "$LOG_FILE" | show_paged; pause ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

first_run_offer() {
  [[ -f $SELF && $SELF != "$INSTALL_PATH" ]] || return 0
  if [[ ! -f $INSTALL_PATH ]]; then
    header "Установка команды"
    info "Скрипт ещё не установлен в систему."
    if confirm "Установить как команду '${APP_NAME}' (запуск из любого места)?" Y; then
      self_install; pause
    fi
  elif ! cmp -s "$SELF" "$INSTALL_PATH"; then
    header "Обновление команды"
    info "Установленная копия ($INSTALL_PATH) отличается от этого файла."
    if confirm "Обновить установленную копию?" N; then
      self_install; pause
    fi
  fi
}

update_repo() {
  local r
  r="$(conf_get GITHUB_REPO)"
  printf '%s' "${r:-$DEFAULT_REPO}"
}

update_branch() {
  local b
  b="$(conf_get GITHUB_BRANCH)"
  printf '%s' "${b:-$DEFAULT_BRANCH}"
}

update_repo_ok() {
  local r
  r="$(update_repo)"
  [[ $r =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && $r != CHANGE_ME/* ]]
}

update_url() { printf '%s/%s/%s/%s?nocache=%s' "$RAW_BASE" "$(update_repo)" "$(update_branch)" "$1" "$(date +%s)"; }

update_state_write() { # $1 = версия в репозитории
  install -d -m 0755 "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$(date +%s)" "${1:-}" >"$STATE_DIR/update-check" 2>/dev/null || true
}

update_fetch() { # update_fetch ФАЙЛ — скачивает и проверяет скрипт из репозитория
  ensure_curl || return 1
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 -o "$1" "$(update_url vpsmenu.sh)"; then
    err "Не удалось скачать скрипт из github.com/$(update_repo) (ветка $(update_branch))."
    hint "Проверь имя репозитория и ветку (меню «Сам скрипт» → «Репозиторий GitHub»), а также что репозиторий публичный."
    return 1
  fi
  if ! head -n 1 "$1" | grep -q '^#!.*bash' || ! grep -q '^readonly APP_NAME="vpsmenu"' "$1"; then
    err "Скачанный файл не похож на vpsmenu — обновление отменено."
    return 1
  fi
  if ! bash -n "$1" 2>/dev/null; then
    err "В скачанном файле синтаксическая ошибка — обновление отменено."
    return 1
  fi
  if [[ -z "$(script_version_of "$1")" ]]; then
    err "Не удалось определить версию в скачанном файле."
    return 1
  fi
}

update_configure_repo() {
  local def=""
  update_repo_ok && def="$(update_repo)"
  info "Укажи репозиторий в формате ник/имя, например: roman/vpsmenu"
  ask_re "GitHub-репозиторий" "$def" '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' "Формат: ник/репозиторий."
  conf_set GITHUB_REPO "$ASK_RESULT" || { err "Не удалось записать $CONF_FILE"; return 1; }
  ask_re "Ветка" "$(update_branch)" '^[A-Za-z0-9._/-]+$' "Допустимы буквы, цифры, . _ - /"
  conf_set GITHUB_BRANCH "$ASK_RESULT" || { err "Не удалось записать $CONF_FILE"; return 1; }
  ok "Сохранено в $CONF_FILE: $(update_repo), ветка $(update_branch)"
}

update_show_changelog() {
  local cl
  cl="$(curl -fsSL --max-time 8 "$(update_url CHANGELOG.md)" 2>/dev/null | head -n 25)" || true
  [[ -n $cl ]] || return 0
  echo
  printf '  %sЧто нового (начало CHANGELOG.md):%s\n' "$C_BOLD" "$C_RESET"
  printf '%s\n' "$cl" | sed 's/^/    /'
  echo
}

update_apply() { # update_apply СКАЧАННЫЙ_ФАЙЛ — ставит новую версию и перезапускает скрипт
  local new_ver old_ver ts src bak
  new_ver="$(script_version_of "$1")"
  old_ver="$APP_VERSION"
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_prepare || return 1
  src="$INSTALL_PATH"
  [[ -f $src ]] || src="$SELF"
  if [[ -f $src ]]; then
    bak="$BACKUP_DIR/${APP_NAME}-v${old_ver}-${ts}.sh"
    if cp -a "$src" "$bak"; then ok "Копия текущей версии: $bak"; fi
    backup_files "${APP_NAME}-v*.sh" | tail -n +6 | xargs -r rm -f
  fi
  # запоминаем репозиторий в конфиге: новая версия не потеряет источник обновлений
  if update_repo_ok && [[ -z "$(conf_get GITHUB_REPO)" ]]; then
    conf_set GITHUB_REPO "$(update_repo)"
    conf_set GITHUB_BRANCH "$(update_branch)"
  fi
  if ! install -m 0755 -o root -g root "$1" "$INSTALL_PATH"; then
    err "Не удалось записать $INSTALL_PATH."
    return 1
  fi
  rm -f "$1"
  ok "Обновлено до версии $new_ver."
  log INFO "Обновление $old_ver → $new_ver"
  update_state_write "$new_ver"
  info "Перезапускаю новую версию…"
  sleep 1
  exec "$INSTALL_PATH"
}

mod_update() {
  header "Обновление скрипта"
  if ! update_repo_ok; then
    warn "GitHub-репозиторий для обновлений не задан."
    update_configure_repo || { pause; return 1; }
  fi
  info "Источник: github.com/$(update_repo) (ветка $(update_branch))"
  info "Установлена версия: $APP_VERSION"

  local tmp remote
  tmp="$(mktemp)"
  step "Проверяю обновления"
  if ! update_fetch "$tmp"; then rm -f "$tmp"; pause; return 1; fi
  remote="$(script_version_of "$tmp")"
  info "Версия в репозитории: $remote"
  update_state_write "$remote"

  if version_gt "$remote" "$APP_VERSION"; then
    ok "Доступна новая версия: $APP_VERSION → $remote"
    update_show_changelog
    confirm "Обновить?" Y || { info "Отменено."; rm -f "$tmp"; pause; return 0; }
  elif [[ $remote == "$APP_VERSION" ]]; then
    ok "У тебя актуальная версия."
    if { [[ -f $INSTALL_PATH ]] && cmp -s "$tmp" "$INSTALL_PATH"; } || { [[ -f $SELF ]] && cmp -s "$tmp" "$SELF"; }; then
      rm -f "$tmp"; pause; return 0
    fi
    warn "Номер версии тот же, но содержимое файла в репозитории отличается."
    confirm "Переустановить из репозитория?" N || { info "Отменено."; rm -f "$tmp"; pause; return 0; }
  else
    warn "В репозитории версия старее ($remote < $APP_VERSION)."
    confirm "Всё равно установить её (откат)?" N || { info "Отменено."; rm -f "$tmp"; pause; return 0; }
  fi

  local rc
  update_apply "$tmp"
  rc=$?
  rm -f "$tmp"
  pause
  return $rc
}

mod_update_rollback() {
  header "Откат на предыдущую версию скрипта"
  info "Копии, сохранённые при обновлениях:"
  backup_pick "${APP_NAME}-v*.sh" || { pause; return 0; }
  local f=$BACKUP_PICKED
  confirm "Установить $(basename "$f") как текущую версию?" N || { info "Отменено."; pause; return 0; }
  if install -m 0755 -o root -g root "$f" "$INSTALL_PATH"; then
    ok "Восстановлено: $(basename "$f")"
    sleep 1
    exec "$INSTALL_PATH"
  fi
  err "Не удалось восстановить."
  pause
}

update_check_cached() { # раз в сутки тихо проверяет репозиторий → $UPDATE_AVAILABLE
  UPDATE_AVAILABLE=""
  update_repo_ok || return 0
  cmd_exists curl || return 0
  install -d -m 0755 "$STATE_DIR" 2>/dev/null
  local f="$STATE_DIR/update-check" last=0 ver="" now tmp
  now="$(date +%s)"
  if [[ -f $f ]]; then read -r last ver <"$f" || true; fi
  if (( now - ${last:-0} > 86400 )); then
    tmp="$(mktemp)"
    if curl -fsSL --connect-timeout 3 --max-time 6 -o "$tmp" "$(update_url vpsmenu.sh)" 2>/dev/null &&
       grep -q '^readonly APP_NAME="vpsmenu"' "$tmp"; then
      ver="$(script_version_of "$tmp")"
    fi
    rm -f "$tmp"
    printf '%s %s\n' "$now" "${ver:-}" >"$f" 2>/dev/null || true
  fi
  if [[ -n $ver ]] && version_gt "$ver" "$APP_VERSION"; then UPDATE_AVAILABLE="$ver"; fi
}
