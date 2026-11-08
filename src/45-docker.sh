# ══════════════════════════ Docker ══════════════════════════

mod_docker() {
  header "6. Docker"
  if cmd_exists docker; then
    ok "Docker уже установлен: $(docker --version 2>/dev/null)"
    if docker compose version >/dev/null 2>&1; then
      ok "Compose: $(docker compose version 2>/dev/null)"
    else
      warn "Плагин docker compose не найден."
    fi
    echo "  service: $(systemctl is-active docker 2>/dev/null) / $(systemctl is-enabled docker 2>/dev/null)"
    if ! service_active docker; then
      warn "Служба docker не запущена."
      if confirm "Запустить и включить автозапуск?" Y; then
        systemctl enable --now docker && ok "Docker запущен." || err "Не удалось запустить Docker."
      fi
    fi
    pause; return 0
  fi

  info "Docker не найден. Установка — официальным скриптом $DOCKER_URL."
  confirm "Установить Docker?" Y || { info "Отменено."; pause; return 0; }
  if ! docker_install_apply; then pause; return 1; fi
  if confirm "Проверить работу тестовым контейнером hello-world?" Y; then
    if docker run --rm hello-world >/dev/null 2>&1; then ok "Тестовый контейнер отработал."; else err "Тестовый контейнер не запустился."; fi
  fi
  pause
}

mod_docker_logrotate() {
  header "Docker: ротация логов"
  if ! cmd_exists docker; then err "Docker не установлен."; pause; return 1; fi
  if ! cmd_exists python3; then err "Нужен python3 для безопасного изменения daemon.json."; pause; return 1; fi
  hint "Без ротации логи контейнеров растут бесконечно и могут забить диск."
  if [[ -s $DOCKER_DAEMON_JSON ]]; then
    info "Текущий $DOCKER_DAEMON_JSON:"; sed 's/^/    /' "$DOCKER_DAEMON_JSON"; echo
  fi
  ask_re "max-size — размер одного файла лога" "10m" '^[1-9][0-9]*[kmg]$' "Формат: 10m, 100m, 1g."
  local size=$ASK_RESULT
  ask_re "max-file — сколько файлов хранить" "3" '^[1-9][0-9]*$' "Нужно целое число больше нуля."
  local nfiles=$ASK_RESULT
  echo
  warn "Для применения нужен перезапуск Docker (контейнеры с restart: always/unless-stopped поднимутся сами)."
  hint "Настройка действует только на НОВЫЕ контейнеры — после неё пересоздай их (Remnanode → «Перезапустить»)."
  confirm "Применить?" Y || { info "Отменено."; pause; return 0; }
  docker_logrotate_apply "$size" "$nfiles"
  pause
}

mod_docker_cleanup() {
  header "Docker: очистка места"
  if ! cmd_exists docker || ! service_active docker; then err "Docker не установлен или не запущен."; pause; return 1; fi
  docker system df
  echo
  menu_item 1 "Безопасная: остановленные контейнеры, неиспользуемые сети, «висячие» образы, кэш сборки"
  menu_item 2 "Глубокая: плюс ВСЕ образы, которые не используются контейнерами"
  menu_item 0 "Назад"
  echo; read_choice
  case $CHOICE in
    1)
      warn "Тома (volumes) не затрагиваются."
      if confirm "Выполнить безопасную очистку?" Y; then docker system prune -f; ok "Готово."; fi
      ;;
    2)
      warn "Удалятся все образы, не привязанные к существующим контейнерам (в т.ч. образ остановленной ноды — он скачается заново)."
      if confirm_word "Выполнить глубокую очистку?" "да"; then docker system prune -a -f; ok "Готово."; fi
      ;;
    *) return 0 ;;
  esac
  echo; docker system df
  pause
}

mod_docker_info() {
  header "Docker: контейнеры и ресурсы"
  if ! cmd_exists docker || ! service_active docker; then err "Docker не установлен или не запущен."; pause; return 1; fi
  docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  echo
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null
  echo
  docker system df
  pause
}

menu_docker() {
  while true; do
    header "6. Docker"
    menu_item 1 "Установить / показать статус"
    menu_item 2 "Ротация логов контейнеров"
    menu_item 3 "Очистка места"
    menu_item 4 "Контейнеры и ресурсы"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_docker ;;
      2) mod_docker_logrotate ;;
      3) mod_docker_cleanup ;;
      4) mod_docker_info ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

docker_install_apply() {
  if cmd_exists docker; then
    ok "Docker уже установлен: $(docker --version 2>/dev/null)"
    if ! service_active docker; then
      if systemctl enable --now docker >/dev/null 2>&1; then ok "Docker запущен."; else err "Не удалось запустить Docker."; return 1; fi
    fi
    return 0
  fi
  ensure_curl || return 1
  local tmp rc
  tmp="$(mktemp)"
  step "Скачиваю установочный скрипт"
  if ! download "$DOCKER_URL" "$tmp"; then
    err "Не удалось скачать $DOCKER_URL (проверь интернет, DNS, доступность сайта)."
    rm -f "$tmp"; return 1
  fi
  ok "Скачано."
  step "Устанавливаю Docker (это займёт пару минут)"
  sh "$tmp"; rc=$?
  rm -f "$tmp"
  if (( rc != 0 )); then err "Установка завершилась с ошибкой (код $rc). Смотри вывод выше."; return 1; fi
  systemctl enable --now docker >/dev/null 2>&1
  if cmd_exists docker && service_active docker; then
    ok "Docker установлен: $(docker --version)"
    docker compose version >/dev/null 2>&1 && ok "Compose: $(docker compose version)"
  else
    err "Docker установлен, но служба не запущена. Смотри: journalctl -u docker"; return 1
  fi
}

docker_logrotate_apply() { # docker_logrotate_apply РАЗМЕР КОЛ-ВО_ФАЙЛОВ
  local size=$1 nfiles=$2 bak=""
  if ! cmd_exists docker; then err "Docker не установлен."; return 1; fi
  if ! cmd_exists python3; then err "Нужен python3 для безопасного изменения daemon.json."; return 1; fi
  install -d -m 0755 "$(dirname "$DOCKER_DAEMON_JSON")"
  if [[ -f $DOCKER_DAEMON_JSON ]]; then
    backup_prepare
    bak="$BACKUP_DIR/daemon.json.$(date +%Y%m%d-%H%M%S)"
    cp -a "$DOCKER_DAEMON_JSON" "$bak" && ok "Резервная копия: $bak"
  fi
  if ! python3 - "$DOCKER_DAEMON_JSON" "$size" "$nfiles" <<'PY'
import json, os, sys
path, size, nfiles = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f)
data["log-driver"] = "json-file"
opts = data.get("log-opts", {})
opts.update({"max-size": size, "max-file": nfiles})
data["log-opts"] = opts
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
  then
    err "Не удалось обновить daemon.json (возможно, в нём некорректный JSON). Файл не изменён."
    return 1
  fi
  ok "daemon.json обновлён."
  if systemctl restart docker; then
    ok "Docker перезапущен."
    info "Драйвер логов: $(docker info --format '{{.LoggingDriver}}' 2>/dev/null)"
  else
    err "Docker не запустился с новой конфигурацией — возвращаю прежнюю."
    if [[ -n $bak ]]; then cp -a "$bak" "$DOCKER_DAEMON_JSON"; else rm -f "$DOCKER_DAEMON_JSON"; fi
    systemctl restart docker
    return 1
  fi
}
