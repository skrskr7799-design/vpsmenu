#!/usr/bin/env bash
#
# Собирает один файл vpsmenu.sh из исходников src/*.sh (по порядку имён файлов).
# Для серверов ничего не меняется: ставится и обновляется именно собранный vpsmenu.sh.
#
# Использование:  ./build.sh           — собрать vpsmenu.sh
#                 ./build.sh --check   — проверить, что vpsmenu.sh в репозитории соответствует src/ (для CI)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

out=vpsmenu.sh
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for f in src/*.sh; do
  cat "$f"
  printf '\n'
done >"$tmp"

bash -n "$tmp"

if [[ ${1:-} == --check ]]; then
  if cmp -s "$tmp" "$out"; then
    echo "OK: $out соответствует src/"
  else
    echo "ОШИБКА: $out не соответствует src/ — запусти ./build.sh и закоммить результат" >&2
    exit 1
  fi
  exit 0
fi

install -m 0755 "$tmp" "$out"
echo "Собрано: $out ($(wc -l <"$out") строк из $(ls src/*.sh | wc -l) модулей)"
