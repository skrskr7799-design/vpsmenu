#!/usr/bin/env bash
# Unit tests for Log Analyzer helpers. Run from repository root.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VPSMENU_SOURCE_ONLY=1 NO_COLOR=1
export VPSMENU_LOG_FILE="$TMP/log" VPSMENU_CONF_FILE="$TMP/conf"
export VPSMENU_BACKUP_DIR="$TMP/backups" VPSMENU_STATE_DIR="$TMP/state"
export VPSMENU_PROFILE_DIR="$TMP/profiles"
# shellcheck source=/dev/null
source ./vpsmenu.sh
PASS=0; FAIL=0
eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 expected [$1], got [$2]"; fi; }
eq "1 hour ago" "$(la_since 1h)" "period 1h"
eq "6 hours ago" "$(la_since 6h)" "period 6h"
eq "24 hours ago" "$(la_since 24h)" "period 24h"
eq "3 days ago" "$(la_since 3d)" "period 3d"
eq "7 days ago" "$(la_since 7d)" "period 7d"
normalized="$(la_normalize 'sshd[1234]: Failed password for user roman from 203.0.113.9 port 55221')"
eq 'sshd[PID]: Failed password for user=<USER> from <IP> port=<PORT>' "$normalized" "normalization of pid, user, ip and port"
echo "Log Analyzer tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
