# ══════════════════════════ Диагностика сети и Speedtest ══════════════════════════

speedtest_bin() { # печатает имя команды, если speedtest-cli (или официальный speedtest) установлен
  if cmd_exists speedtest-cli; then echo speedtest-cli
  elif cmd_exists speedtest; then echo speedtest
  fi
}

speedtest_install() {
  local b
  b="$(speedtest_bin)"
  if [[ -n $b ]]; then
    ok "Speedtest уже установлен: $(command -v "$b") ($("$b" --version 2>&1 | head -n 1))"
    return 0
  fi
  info "speedtest-cli не найден — устанавливаю из репозитория Ubuntu."
  apt_install speedtest-cli || return 1
  if cmd_exists speedtest-cli; then
    ok "Установлен: $(speedtest-cli --version 2>&1 | head -n 1)"
  else
    err "Пакет установился, но команды speedtest-cli нет."; return 1
  fi
}

mod_speedtest_status() {
  header "Speedtest: установка и статус"
  local b
  b="$(speedtest_bin)"
  if [[ -n $b ]]; then
    ok "Установлен: $(command -v "$b")"
    info "Версия: $("$b" --version 2>&1 | head -n 1)"
    if [[ $b == speedtest ]]; then hint "Это официальный клиент Ookla (команда speedtest), не python-версия speedtest-cli."; fi
  else
    warn "Speedtest не установлен."
    if confirm "Установить speedtest-cli?" Y; then speedtest_install; fi
  fi
  pause
}

mod_speedtest_run() {
  header "Тест скорости"
  local b rc
  b="$(speedtest_bin)"
  if [[ -z $b ]]; then
    warn "Speedtest не установлен."
    confirm "Установить speedtest-cli?" Y || { pause; return 0; }
    speedtest_install || { pause; return 1; }
    b="$(speedtest_bin)"
  fi
  info "Запускаю тест (до 2,5 минут, Ctrl+C — прервать)…"
  if [[ $b == speedtest-cli ]]; then
    run_interruptible timeout 150 speedtest-cli --simple
    rc=$?
    if (( rc != 0 && rc != 130 )); then
      warn "Первая попытка не удалась — пробую через HTTPS (--secure)."
      run_interruptible timeout 150 speedtest-cli --secure --simple
    fi
  else
    run_interruptible timeout 150 speedtest --accept-license --accept-gdpr
  fi
  pause
}

mod_net_ping() {
  header "Задержка до серверов"
  if ! cmd_exists ping; then apt_install iputils-ping || { pause; return 1; }; fi
  local t out loss avg
  printf '  %-14s %-14s %s\n' "Host" "Loss" "Avg"
  for t in 1.1.1.1 8.8.8.8 ya.ru github.com; do
    out="$(ping -c 4 -W 2 -q "$t" 2>&1)"
    loss="$(grep -oE '[0-9]+(\.[0-9]+)?% packet loss' <<<"$out" | head -n 1 | awk '{print $1}')"
    avg="$(awk -F'/' '/^rtt|^round-trip/ {print $5}' <<<"$out")"
    if [[ -z $loss ]]; then
      printf '  %-14s %s\n' "$t" "${C_RED}недоступен или не резолвится${C_RESET}"
    elif [[ $loss == 100% ]]; then
      printf '  %-14s %s\n' "$t" "${C_RED}100% потерь (ICMP может быть закрыт)${C_RESET}"
    else
      printf '  %-14s %-14s %s\n' "$t" "$loss" "${avg:-?} мс"
    fi
  done
  pause
}

mod_net_reach() {
  header "Доступность нужных ресурсов"
  ensure_curl || { pause; return 1; }
  local entry label url code t res
  for entry in \
    "GitHub|https://github.com" \
    "GitHub raw|https://raw.githubusercontent.com" \
    "Docker Hub|https://registry-1.docker.io/v2/" \
    "get.docker.com|https://get.docker.com" \
    "GHCR|https://ghcr.io/v2/" \
    "Ubuntu apt|http://archive.ubuntu.com"; do
    label=${entry%%|*}
    url=${entry##*|}
    res="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)"
    code=${res%% *}
    t=${res##* }
    t="${t%"${t#*.??}"}"
    case $code in
      2??|3??|401|403) printf '  %s %-15s HTTP %s · %s с\n' "${C_GREEN}●${C_RESET}" "$label" "$code" "$t" ;;
      *)               printf '  %s %-15s %s\n' "${C_RED}●${C_RESET}" "$label" "недоступен (код ${code:-000})" ;;
    esac
  done
  echo
  hint "401/403 у Docker Hub и GHCR — нормально: сервис отвечает, просто просит авторизацию."
  pause
}

mod_net_ip() {
  header "Внешний IP"
  ensure_curl || { pause; return 1; }
  local ip4 ip6 u
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip4="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null)" && [[ -n $ip4 ]] && break
    ip4=""
  done
  for u in https://api64.ipify.org https://ifconfig.co; do
    ip6="$(curl -6 -fsS --max-time 6 "$u" 2>/dev/null)" && [[ -n $ip6 ]] && break
    ip6=""
  done
  printf '  %-6s %s\n' "IPv4" "${ip4:-не определён}"
  printf '  %-6s %s\n' "IPv6" "${ip6:-нет или не определён}"
  info "Локальные адреса: $(hostname -I 2>/dev/null)"
  pause
}

mod_net_ports() {
  header "Какие порты слушает сервер"
  hint "Это то, что слушает сам сервер. Что реально доступно снаружи, решает ещё и файрвол (UFW, панель хостера)."
  echo
  ss -tulpn | show_paged
  pause
}

menu_net() {
  while true; do
    header "14. Диагностика сети"
    local b
    b="$(speedtest_bin)"
    if [[ -n $b ]]; then info "Speedtest: установлен ($b)"; else info "Speedtest: не установлен"; fi
    echo
    menu_item 1 "Тест скорости (speedtest-cli)"
    menu_item 2 "Установка / статус speedtest-cli"
    menu_item 3 "Задержка (ping до 1.1.1.1, 8.8.8.8, ya.ru, github.com)"
    menu_item 4 "Доступность ресурсов (GitHub, Docker Hub, apt…)"
    menu_item 5 "Внешний IP"
    menu_item 6 "Какие порты слушает сервер"
    menu_item 0 "Назад"
    echo; read_choice
    case $CHOICE in
      1) mod_speedtest_run ;;
      2) mod_speedtest_status ;;
      3) mod_net_ping ;;
      4) mod_net_reach ;;
      5) mod_net_ip ;;
      6) mod_net_ports ;;
      0) return 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}
