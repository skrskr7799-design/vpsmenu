# ══════════════════════════ Оформление: цвета, сообщения, заголовок, пункты меню ══════════════════════════

if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-} != dumb ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null

UI_W=78
UI_COMPACT=0
UI_HOST="$(hostname 2>/dev/null || echo host)"
declare -a UI_MENU_ITEMS=()

# Названия вложенных меню для «хлебных крошек» (путь определяется по стеку вызовов)
declare -A MENU_TITLES=(
  [menu_ssh]="SSH" [menu_ufw]="UFW" [menu_nft]="nftables" [menu_f2b]="Fail2ban" [menu_docker]="Docker"
  [menu_remna]="Remnanode" [menu_watchdog]="Watchdog" [menu_maint]="Обслуживание" [menu_self]="Скрипт"
  [menu_profiles]="Профили" [menu_net]="Сеть"
)

log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true; }

info() { printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; log INFO "$*"; }

ok()   { printf '%s[✔]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log OK "$*"; }

warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log WARN "$*"; }

err()  { printf '%s[✘]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log ERROR "$*"; }

step() { printf '\n%s%s▶ %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; log STEP "$*"; }

hint() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# ── Размеры терминала ───────────────────────────────────────────────────────
ui_refresh_size() {
  local cols
  cols="$(tput cols 2>/dev/null || echo 80)"
  [[ $cols =~ ^[0-9]+$ ]] || cols=80
  UI_W=$(( cols > 78 ? 78 : cols ))
  if (( UI_W < 40 )); then UI_W=40; fi
  if (( cols < 64 )); then UI_COMPACT=1; else UI_COMPACT=0; fi
}

trap ui_refresh_size WINCH

# ── Строки: видимая длина, отступы, обрезка ─────────────────────────────────
ui_vlen() { # видимая длина строки без ANSI-последовательностей
  local s=$1 esc=$'\e'
  while [[ $s == *"${esc}["* ]]; do
    s="${s%%"${esc}["*}${s#*"${esc}["*m}"
  done
  printf '%s' "${#s}"
}

ui_pad() { # ui_pad "текст" ширина — дополняет пробелами справа (кириллица считается по символам)
  local s=$1 w=$2 n
  n="$(ui_vlen "$s")"
  printf '%s' "$s"
  if (( n < w )); then printf '%*s' $(( w - n )) ''; fi
}

ui_trunc() { # ui_trunc "обычный текст" ширина — обрезает с «…» (только текст без цветов)
  local s=$1 w=$2
  if (( ${#s} > w )); then s="${s:0:$(( w - 1 ))}…"; fi
  printf '%s' "$s"
}

ui_rule() { # ui_rule N [символ]
  local n=$1 ch=${2:-─} s
  printf -v s '%*s' "$n" ''
  printf '%s' "${s// /$ch}"
}

hr() { printf '  %s%s%s\n' "$C_DIM" "$(ui_rule $(( UI_W - 2 )))" "$C_RESET"; }

# ── Блоки интерфейса ────────────────────────────────────────────────────────
ui_section() { # ui_section "Название" — разделитель с заголовком
  local t=$1 n
  n=$(( UI_W - ${#t} - 6 ))
  if (( n < 3 )); then n=3; fi
  printf '\n  %s──%s %s%s%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$t" "$C_RESET" "$C_DIM" "$(ui_rule "$n")" "$C_RESET"
}

ui_kv() { # ui_kv "Метка" "значение"
  printf '  %s %s\n' "$(ui_pad "${C_DIM}$1${C_RESET}" 9)" "$2"
}

ui_line() { # ui_line ok|warn|bad|off "текст" — строка со значком состояния
  local ic col
  case $1 in
    ok)   ic="✔"; col=$C_GREEN ;;
    warn) ic="!"; col=$C_YELLOW ;;
    bad)  ic="✘"; col=$C_RED ;;
    *)    ic="·"; col=$C_DIM ;;
  esac
  printf '  %s%s%s %s\n' "$col" "$ic" "$C_RESET" "$2"
}

ui_bar() { # ui_bar ПРОЦЕНТ [ширина] — шкала: <70% зелёная, <90% жёлтая, иначе красная
  local pct=${1:-0} w=${2:-20} filled i col out=""
  [[ $pct =~ ^[0-9]+$ ]] || pct=0
  if (( pct > 100 )); then pct=100; fi
  filled=$(( (pct * w + 50) / 100 ))
  if (( pct >= 90 )); then col=$C_RED; elif (( pct >= 70 )); then col=$C_YELLOW; else col=$C_GREEN; fi
  out+="$col"
  for (( i = 0; i < filled; i++ )); do out+="█"; done
  out+="$C_DIM"
  for (( i = filled; i < w; i++ )); do out+="░"; done
  out+="$C_RESET"
  printf '%s' "$out"
}

ui_meter() { # ui_meter "Метка" ПРОЦЕНТ "текст" — строка со шкалой
  local label=$1 pct=${2:-0} text=${3:-} bw room
  [[ $pct =~ ^[0-9]+$ ]] || pct=0
  bw=$(( UI_COMPACT ? 10 : 20 ))
  room=$(( UI_W - 2 - 7 - 1 - bw - 1 - 4 - 2 ))
  if (( room < 8 )); then room=8; fi
  printf '  %s %s %s%3d%%%s  %s\n' "$(ui_pad "$label" 7)" "$(ui_bar "$pct" "$bw")" "$C_BOLD" "$pct" "$C_RESET" "$(ui_trunc "$text" "$room")"
}

ui_human_kb() { # килобайты → 340K / 512M / 1.2G
  local kb=${1:-0} t
  if (( kb >= 1048576 )); then
    t=$(( kb * 10 / 1048576 )); printf '%d.%dG' $(( t / 10 )) $(( t % 10 ))
  elif (( kb >= 1024 )); then
    printf '%dM' $(( kb / 1024 ))
  else
    printf '%dK' "$kb"
  fi
}

ui_spin() { # ui_spin "Сообщение" команда… — команда выполняется под спиннером; вывод показывается только при ошибке
  local msg=$1 out rc pid i=0 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  shift
  if [[ ! -t 1 ]]; then
    "$@"
    return $?
  fi
  out="$(mktemp)"
  "$@" >"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s' "$C_CYAN" "${frames:$(( i % 10 )):1}" "$C_RESET" "$msg"
    i=$(( i + 1 ))
    sleep 0.1
  done
  wait "$pid"
  rc=$?
  printf '\r\e[K'
  if (( rc == 0 )); then
    printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$msg"
  else
    printf '  %s✘%s %s\n' "$C_RED" "$C_RESET" "$msg"
    sed 's/^/    /' "$out"
  fi
  rm -f "$out"
  return $rc
}

# ── Заголовок экрана с «хлебными крошками» ──────────────────────────────────
header() { # header "Название экрана"
  local title=${1:-} caller=${FUNCNAME[1]:-} left right inner gap path="" i fn t leaf lastmenu=""
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then clear; fi
  UI_MENU_ITEMS=()
  ui_refresh_size

  left="VPS MENU  v${APP_VERSION}"
  right="${OS_PRETTY} · ${UI_HOST}"
  if (( UI_COMPACT )); then
    printf '\n  %s%s%s %s%s%s\n' "${C_BOLD}${C_CYAN}" "VPS MENU" "$C_RESET" "$C_DIM" "v${APP_VERSION} · ${UI_HOST}" "$C_RESET"
  else
    inner=$(( UI_W - 4 ))
    if (( ${#left} + ${#right} + 4 > inner )); then right="$(ui_trunc "$right" $(( inner - ${#left} - 4 )))"; fi
    gap=$(( inner - 2 - ${#left} - ${#right} ))
    if (( gap < 1 )); then gap=1; fi
    printf '\n  %s╭%s╮%s\n' "$C_DIM" "$(ui_rule "$inner")" "$C_RESET"
    printf '  %s│%s %s%s%s%*s%s%s%s %s│%s\n' "$C_DIM" "$C_RESET" "${C_BOLD}${C_CYAN}" "$left" "$C_RESET" "$gap" "" "$C_DIM" "$right" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s╰%s╯%s\n' "$C_DIM" "$(ui_rule "$inner")" "$C_RESET"
  fi

  # путь по вложенным меню берём из стека вызовов
  for (( i = ${#FUNCNAME[@]} - 1; i >= 1; i-- )); do
    fn=${FUNCNAME[$i]}
    t=${MENU_TITLES[$fn]:-}
    if [[ -n $t ]]; then path+=" ${C_DIM}›${C_RESET} $t"; lastmenu=$t; fi
  done
  leaf="${title#[0-9]*. }"
  if [[ -n $lastmenu ]]; then leaf="${leaf#"$lastmenu: "}"; fi   # «SSH › SSH: параметры» → «SSH › параметры»
  if [[ -n ${MENU_TITLES[$caller]:-} || $caller == main_menu || -z $leaf ]]; then leaf=""; fi
  if [[ -n $leaf ]]; then leaf=" ${C_DIM}›${C_RESET} ${C_BOLD}${leaf}${C_RESET}"; fi
  printf '  %svpsmenu%s%s%s\n' "$C_DIM" "$C_RESET" "$path" "$leaf"
  hr
}

menu_item() { # menu_item КЛЮЧ "Текст" — КЛЮЧ: цифра или буква; 0 («назад/выход») приглушён
  UI_MENU_ITEMS+=("$1")
  if [[ $1 == 0 ]]; then
    printf '  %s%2s  %s%s\n' "$C_DIM" "$1" "$2" "$C_RESET"
  else
    printf '  %s%2s%s  %s\n' "${C_BOLD}${C_CYAN}" "$1" "$C_RESET" "$2"
  fi
}

badge() { # badge ok|warn|bad|off "текст"
  case $1 in
    ok)   printf '%s●%s %s' "$C_GREEN" "$C_RESET" "$2" ;;
    warn) printf '%s●%s %s' "$C_YELLOW" "$C_RESET" "$2" ;;
    bad)  printf '%s●%s %s' "$C_RED" "$C_RESET" "$2" ;;
    *)    printf '%s○ %s%s' "$C_DIM" "$2" "$C_RESET" ;;
  esac
}

show_paged() { if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then less -R -F -X; else cat; fi; }
