#!/usr/bin/env bash
# Regression tests for Log Analyzer parsing and grouping.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VPSMENU_SOURCE_ONLY=1 NO_COLOR=1
export VPSMENU_LOG_FILE="$TMP/log" VPSMENU_CONF_FILE="$TMP/conf"
export VPSMENU_BACKUP_DIR="$TMP/backups" VPSMENU_STATE_DIR="$TMP/state"
export VPSMENU_PROFILE_DIR="$TMP/profiles"
# shellcheck source=/dev/null
source ./vpsmenu.sh
PASS=0; FAIL=0
eq() {
  if [[ "$1" == "$2" ]]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL: $3 expected [$1], got [$2]"; fi
}
has() {
  if grep -Fq -- "$1" <<<"$2"; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL: $3 missing [$1] in [$2]"; fi
}

eq "1 hour ago" "$(la_since 1h)" "period 1h"
eq "6 hours ago" "$(la_since 6h)" "period 6h"
eq "24 hours ago" "$(la_since 24h)" "period 24h"
eq "3 days ago" "$(la_since 3d)" "period 3d"
eq "7 days ago" "$(la_since 7d)" "period 7d"
eq "24 hours ago" "$(la_since invalid)" "fallback for invalid period"

normalized="$(la_normalize 'sshd[1234]: Failed password for user roman from 203.0.113.9 port 55221')"
eq 'sshd[PID]: Failed password for user=<USER> from <IPV4> port=<PORT>' "$normalized" "normalize pid, user, IPv4 and port"

LA_RAW="$TMP/raw"
LA_GROUP_FILE=
cat >"$LA_RAW" <<'EOF'
SSH	sshd	2026-11-12T10:05:00+00:00	sshd[202]: Failed password for user alice from 198.51.100.7 port 45000 code=503
SSH	sshd	2026-11-12T10:00:00+00:00	sshd[101]: Failed password for user roman from 203.0.113.1 port 22001 code=503
SSH	sshd	2026-11-12T10:02:00+00:00	sshd[303]: Failed password for user bob from 203.0.113.8 port 33221 code=503
kernel	kernel	2026-11-12T10:03:00+00:00	sshd[404]: Failed password for user bob from 203.0.113.8 port 33221 code=503
SSH	sshd	2026-11-12T10:04:00+00:00	sshd[505]: Failed password for user bob from 203.0.113.8 port 33221 code=504
EOF
la_build_groups
eq "3" "$(wc -l <"$LA_GROUP_FILE" | tr -d ' ')" "group separation by source and error code"
first="$(head -n 1 "$LA_GROUP_FILE")"
eq "3" "$(cut -f1 <<<"$first")" "repeat count"
eq "2026-11-12T10:00:00+00:00" "$(cut -f4 <<<"$first")" "first timestamp independent of input order"
eq "2026-11-12T10:05:00+00:00" "$(cut -f5 <<<"$first")" "last timestamp independent of input order"
examples="$(cut -f8-10 <<<"$first")"
has "roman" "$examples" "example 1 retained"
has "alice" "$examples" "example 2 retained"
has "bob" "$examples" "example 3 retained"

echo "Log Analyzer tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
