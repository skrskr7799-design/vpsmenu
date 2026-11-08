# ══════════════════════════ Помощники: конфиг, бэкапы, версии ══════════════════════════

conf_get() { # conf_get КЛЮЧ — значение из /etc/vpsmenu.conf
  [[ -f $CONF_FILE ]] || return 0
  awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$CONF_FILE"
}

conf_set() { # conf_set КЛЮЧ ЗНАЧЕНИЕ
  touch "$CONF_FILE" && chmod 644 "$CONF_FILE" || return 1
  if grep -q "^$1=" "$CONF_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$CONF_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >>"$CONF_FILE"
  fi
}

backup_prepare() { install -d -m 0700 "$BACKUP_DIR"; }

backup_files() { # backup_files ШАБЛОН → файлы из каталога бэкапов, свежие первыми
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "$1" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
}

backup_create() { # backup_create ПРЕФИКС путь… → $BACKUP_RESULT
  local prefix=$1 p out
  shift
  local -a rel=()
  for p in "$@"; do
    if [[ -e $p ]]; then rel+=("${p#/}"); fi
  done
  if (( ${#rel[@]} == 0 )); then
    err "Нечего сохранять — ни один из файлов не найден."
    return 1
  fi
  backup_prepare || return 1
  out="$BACKUP_DIR/${prefix}-$(date +%Y%m%d-%H%M%S).tar.gz"
  [[ -e $out ]] && out="${out%.tar.gz}-$RANDOM.tar.gz"   # две копии в одну секунду не должны затирать друг друга
  if tar -czf "$out" -C / "${rel[@]}"; then
    chmod 600 "$out"
    BACKUP_RESULT=$out
    backup_files "${prefix}-*.tar.gz" | tail -n +11 | xargs -r rm -f
    return 0
  fi
  rm -f "$out"
  err "Не удалось создать архив."
  return 1
}

backup_pick() { # backup_pick ШАБЛОН → $BACKUP_PICKED (интерактивный выбор из списка)
  local i=0 f
  local -a files=()
  mapfile -t files < <(backup_files "$1")
  if (( ${#files[@]} == 0 )); then
    warn "Подходящих файлов в $BACKUP_DIR нет."
    return 1
  fi
  for f in "${files[@]}"; do
    i=$((i + 1))
    printf '  %2d  %s  (%s)\n' "$i" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  done
  ask_re "Номер (Enter — отмена)" "" '^[0-9]*$' "Нужен номер из списка."
  [[ -z $ASK_RESULT ]] && return 1
  if (( 10#$ASK_RESULT < 1 || 10#$ASK_RESULT > ${#files[@]} )); then
    err "Нет такого номера."
    return 1
  fi
  BACKUP_PICKED="${files[$((10#$ASK_RESULT - 1))]}"
}

sorted_ports() { printf '%s\n' "$@" | sort -un | tr '\n' ' ' | sed 's/ $//'; }

version_gt() { [[ $1 != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }

script_version_of() { sed -n 's/^readonly APP_VERSION="\([0-9][0-9.]*\)".*/\1/p' "$1" | head -n 1; }

kv_get() { # kv_get ФАЙЛ КЛЮЧ
  [[ -f $1 ]] || return 0
  awk -F= -v k="$2" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$1"
}

kv_set() { # kv_set ФАЙЛ КЛЮЧ ЗНАЧЕНИЕ (значение без символов | & \)
  install -d -m 0755 "$(dirname "$1")" 2>/dev/null
  touch "$1" || return 1
  if grep -q "^$2=" "$1"; then
    sed -i "s|^$2=.*|$2=$3|" "$1"
  else
    printf '%s=%s\n' "$2" "$3" >>"$1"
  fi
}

kv_del() { # kv_del ФАЙЛ КЛЮЧ
  [[ -f $1 ]] && sed -i "/^$2=/d" "$1"
  return 0
}

reboot_prompt() {
  [[ -f /var/run/reboot-required ]] || return 0
  echo
  warn "Требуется перезагрузка (обновилось ядро или системные библиотеки)."
  if [[ -f /var/run/reboot-required.pkgs ]]; then sed 's/^/    /' /var/run/reboot-required.pkgs; fi
  hint "Перезагрузка прервёт SSH-сессию; контейнеры с restart: always поднимутся сами."
  if confirm "Перезагрузить сервер сейчас?" N; then
    info "Перезагружаю…"
    systemctl reboot
    sleep 5
  fi
}
