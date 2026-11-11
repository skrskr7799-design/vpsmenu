#!/usr/bin/env bash
# Изолированные тесты модуля IPv6 без root и изменения системных настроек.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export APP_NAME=vpsmenu IPV6_SYSCTL="$TMP/99-vpsmenu-ipv6.conf"
export C_DIM='' C_RESET=''
ALL=0 DEFAULT=0 APPLY_FAIL=0 UFW_ACTIVE=0 UFW_IPV6=yes
sysctl() {
  case "$1" in
    -n)
      case "$2" in
        net.ipv6.conf.all.disable_ipv6) echo "$ALL" ;;
        net.ipv6.conf.default.disable_ipv6) echo "$DEFAULT" ;;
        *) return 1 ;;
      esac ;;
    -p)
      [[ $APPLY_FAIL == 0 ]] || return 1
      ALL=1; DEFAULT=1 ;;
    -w)
      shift
      for kv in "$@"; do
        case "$kv" in
          net.ipv6.conf.all.disable_ipv6=*) ALL="${kv##*=}" ;;
          net.ipv6.conf.default.disable_ipv6=*) DEFAULT="${kv##*=}" ;;
        esac
      done ;;
    *) return 1 ;;
  esac
}
ip() { return 0; }
systemd-detect-virt() { echo kvm; }
cmd_exists() { [[ $1 == ufw ]]; }
ufw_is_active() { [[ $UFW_ACTIVE == 1 ]]; }
ipv6_ufw_ipv6() { echo "$UFW_IPV6"; }
ok() { :; }; warn() { :; }; err() { :; }; hint() { :; }
source "$ROOT/src/51-ipv6.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ipv6_disable_apply || fail "disable should succeed"
[[ $ALL == 1 && $DEFAULT == 1 && -f $IPV6_SYSCTL ]] || fail "disable state/config"
ipv6_enable_apply || fail "enable should succeed"
[[ $ALL == 0 && $DEFAULT == 0 && ! -f $IPV6_SYSCTL ]] || fail "enable state/config"
ALL=0 DEFAULT=0 APPLY_FAIL=1
if ipv6_disable_apply; then fail "failed sysctl apply must fail"; fi
[[ ! -f $IPV6_SYSCTL && $ALL == 0 && $DEFAULT == 0 ]] || fail "failed disable rollback"
APPLY_FAIL=0; ALL=1 DEFAULT=1; UFW_ACTIVE=1; UFW_IPV6=no
if ipv6_enable_apply; then fail "enable must refuse active UFW without IPv6 support"; fi
[[ $ALL == 1 && $DEFAULT == 1 ]] || fail "UFW refusal must not change sysctl"
UFW_IPV6=yes
ipv6_enable_apply || fail "enable with IPv6-aware UFW should succeed"
[[ $ALL == 0 && $DEFAULT == 0 ]] || fail "UFW-enabled transition"
echo "IPv6 tests: OK"
