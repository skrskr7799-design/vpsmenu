# ══════════════════════════ Ввод: вопросы, подтверждения, выбор пункта меню ══════════════════════════

on_interrupt() { echo; warn "Прервано (Ctrl+C)."; exit 130; }

trap on_interrupt INT

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

ui_flush_input() { # выбрасывает «залежавшиеся» нажатия (например, Enter после выбора клавишей)
  [[ -t 0 ]] || return 0
  while IFS= read -rsn1 -t 0.002 _; do :; done
}

ui_swallow_enter() { IFS= read -rsn1 -t 0.01 _ || true; }

pause() {
  ui_flush_input
  if [[ -t 0 ]]; then
    printf '  %sНажми любую клавишу…%s ' "$C_DIM" "$C_RESET"
    IFS= read -rsn1 _ || true
    ui_swallow_enter
    echo
  else
    read -r -p "  Нажми Enter, чтобы продолжить… " _ || true
  fi
}

# Выбор пункта меню одной клавишей (без Enter). Цифры 10+ — вводом двух цифр подряд;
# буквы — горячие клавиши. Esc или q во вложенных меню = «назад». Для конвейера (не терминал) читает строку.
read_choice() {
  local k k2 it multi ctx=${FUNCNAME[1]:-}
  CHOICE=""
  if [[ ! -t 0 ]]; then
    read -r -p "  ❯ " CHOICE || { echo; exit 0; }
    CHOICE="$(trim "$CHOICE")"
    return 0
  fi
  ui_flush_input
  if [[ $ctx == main_menu ]]; then
    printf '  %sклавиша — выбрать · 0 или q — выход%s\n' "$C_DIM" "$C_RESET"
  else
    printf '  %sклавиша — выбрать · 0 или Esc — назад%s\n' "$C_DIM" "$C_RESET"
  fi
  while [[ -z $CHOICE ]]; do
    printf '  %s❯%s ' "$C_CYAN" "$C_RESET"
    IFS= read -rsn1 k || { echo; exit 0; }
    case $k in
      "") ;;                                   # Enter без ввода — спросить снова
      $'\e')
        k2=""
        IFS= read -rsn2 -t 0.05 k2 || true
        while IFS= read -rsn1 -t 0.005 _; do :; done   # хвост escape-последовательности (стрелки и т.п.)
        if [[ -z $k2 ]]; then CHOICE=0; printf '0\n'; else printf '\r\e[K'; fi
        ;;
      [0-9])
        CHOICE=$k
        multi=0
        for it in "${UI_MENU_ITEMS[@]}"; do
          if [[ $it == "$k"?* ]]; then multi=1; fi
        done
        if (( multi )); then
          k2=""
          IFS= read -rsn1 -t 0.8 k2 || true
          if [[ $k2 =~ ^[0-9]$ ]]; then CHOICE+=$k2; fi
        fi
        printf '%s\n' "$CHOICE"
        ;;
      *)
        CHOICE=$k
        printf '%s\n' "$k"
        ;;
    esac
  done
  ui_swallow_enter
  if [[ $ctx != main_menu && $CHOICE == [qQ] ]]; then CHOICE=0; fi
}

ask() { # ask "Вопрос" ["по умолчанию"] → $ASK_RESULT
  local prompt=$1 default=${2:-} answer
  ui_flush_input
  if [[ -n $default ]]; then
    read -r -p "  $prompt [$default]: " answer || { echo; exit 0; }
  else
    read -r -p "  $prompt: " answer || { echo; exit 0; }
  fi
  ASK_RESULT="$(trim "${answer:-$default}")"
}

ask_re() { # ask_re "Вопрос" "по умолчанию" "regex" "текст ошибки"
  local prompt=$1 default=$2 re=$3 msg=$4
  while true; do
    ask "$prompt" "$default"
    if [[ $ASK_RESULT =~ $re ]]; then return 0; fi
    err "$msg"
  done
}

confirm() { # confirm "Вопрос" [Y|N] — одна клавиша (y/n или д/н), Enter = значение по умолчанию
  local prompt=$1 def=${2:-Y} hintstr ans
  if [[ $def == Y ]]; then hintstr='Y/n'; else hintstr='y/N'; fi
  if [[ ! -t 0 ]]; then
    while true; do
      read -r -p "  $prompt [$hintstr]: " ans || { echo; exit 0; }
      ans="${ans,,}"
      case "$ans" in
        "")          [[ $def == Y ]] && return 0 || return 1 ;;
        y|yes|д|да)  return 0 ;;
        n|no|н|нет)  return 1 ;;
        *)           warn "Ответь y/n (д/н)." ;;
      esac
    done
  fi
  ui_flush_input
  while true; do
    printf '  %s [%s]: ' "$prompt" "$hintstr"
    IFS= read -rsn1 ans || { echo; exit 0; }
    ans="${ans,,}"
    case "$ans" in
      "")      echo; [[ $def == Y ]] && return 0 || return 1 ;;
      y|д)     printf '%sда%s\n' "$C_GREEN" "$C_RESET"; ui_swallow_enter; return 0 ;;
      n|н|т)   printf '%sнет%s\n' "$C_YELLOW" "$C_RESET"; ui_swallow_enter; return 1 ;;
      *)       echo; warn "Нажми y/n (д/н) или Enter." ;;
    esac
  done
}

confirm_word() { # confirm_word "Вопрос" "слово" — для опасных действий
  local prompt=$1 word=$2 ans
  ui_flush_input
  read -r -p "  $prompt (введи «$word»): " ans || { echo; exit 0; }
  [[ "$(trim "${ans,,}")" == "$word" ]]
}

# Выполняет команду так, чтобы Ctrl+C прерывал только её, а не весь скрипт
run_interruptible() {
  local rc
  trap ':' INT
  "$@"; rc=$?
  trap on_interrupt INT
  echo
  return $rc
}
