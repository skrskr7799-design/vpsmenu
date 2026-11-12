#!/usr/bin/env bash
# Запускает все автотесты: bash tests/run.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
rc=0
for t in tests/unit.sh tests/netbird.sh tests/ipv6.sh tests/users.sh tests/storage.sh tests/log.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
exit $rc
