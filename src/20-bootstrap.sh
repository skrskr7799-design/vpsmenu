# ══════════════════════════ Запуск: справка, root/sudo, терминал, локаль ══════════════════════════

usage() {
  cat <<EOF
${APP_NAME} ${APP_VERSION} — меню настройки VPS (Ubuntu)

Использование:
  ${APP_NAME}              запустить меню
  ${APP_NAME} --install    установить скрипт в ${INSTALL_PATH}
  ${APP_NAME} --update     обновить скрипт из GitHub
  ${APP_NAME} --watchdog   разовая проверка Remnanode (вызывается таймером systemd)
  ${APP_NAME} --dashboard  показать Dashboard один раз и выйти (работает и без терминала)
  ${APP_NAME} --audit [quick|full]  проверка безопасности; код выхода 0 — порядок, 1 — есть высокие, 2 — критичные
  ${APP_NAME} --version    показать версию
  ${APP_NAME} --help       эта справка
EOF
}

case "${1:-}" in
  -h|--help)    usage; exit 0 ;;
  -v|--version) echo "${APP_NAME} ${APP_VERSION}"; exit 0 ;;
esac

# VPSMENU_SOURCE_ONLY=1 — подключить функции без запуска (для автотестов): проверки root и терминала пропускаются
if [[ -z ${VPSMENU_SOURCE_ONLY:-} && $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1 && [[ -f $SELF ]]; then
    exec sudo -- bash "$SELF" "$@"
  fi
  echo "Нужны права root. Запусти через sudo: sudo bash vpsmenu.sh" >&2
  exit 1
fi

if [[ -z ${VPSMENU_SOURCE_ONLY:-} && ${1:-} != --install && ${1:-} != --watchdog && ${1:-} != --dashboard && ${1:-} != --audit && ( ! -t 0 || ! -t 1 ) ]]; then
  echo "Скрипту нужен интерактивный терминал." >&2
  exit 1
fi

# Русский текст и рамки требуют UTF-8
if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]]; then
  export LC_ALL=C.UTF-8
fi
