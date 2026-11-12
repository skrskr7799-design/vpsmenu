# ══════════════════════════ Константы и глобальные переменные ══════════════════════════

readonly APP_NAME="vpsmenu"
readonly APP_VERSION="3.4.0"
readonly INSTALL_PATH="/usr/local/bin/${APP_NAME}"
readonly LOG_FILE="${VPSMENU_LOG_FILE:-/var/log/${APP_NAME}.log}"

readonly REMNA_DIR="/opt/remnanode"
readonly REMNA_COMPOSE="${REMNA_DIR}/docker-compose.yml"

readonly DOCKER_URL="https://get.docker.com"
readonly WARP_URL="https://raw.githubusercontent.com/distillium/warp-native/main/install.sh"

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSH_DROPIN="/etc/ssh/sshd_config.d/00-disable-root-login.conf"
readonly F2B_JAIL="/etc/fail2ban/jail.d/sshd.local"
readonly USERNAME_RE='^[a-z_][a-z0-9_-]{0,31}$'

readonly CONF_FILE="${VPSMENU_CONF_FILE:-/etc/${APP_NAME}.conf}"
readonly BACKUP_DIR="${VPSMENU_BACKUP_DIR:-/var/backups/${APP_NAME}}"
readonly STATE_DIR="${VPSMENU_STATE_DIR:-/var/lib/${APP_NAME}}"
readonly SSH_DROPIN_PORT="/etc/ssh/sshd_config.d/10-${APP_NAME}-port.conf"
readonly SSH_DROPIN_AUTH="/etc/ssh/sshd_config.d/00-${APP_NAME}-auth.conf"
readonly DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
readonly REMNA_CONTAINER="remnanode"
readonly SWAPFILE="/swapfile"
readonly SWAP_SYSCTL="/etc/sysctl.d/99-${APP_NAME}-swap.conf"
readonly BBR_SYSCTL="/etc/sysctl.d/99-${APP_NAME}-bbr.conf"
readonly REMNA_STATE="${STATE_DIR}/remnanode.state"
readonly REMNA_STOP_FLAG="${STATE_DIR}/remnanode.stopped"
readonly WD_SERVICE="/etc/systemd/system/${APP_NAME}-watchdog.service"
readonly WD_TIMER="/etc/systemd/system/${APP_NAME}-watchdog.timer"
readonly PROFILE_DIR="${VPSMENU_PROFILE_DIR:-/etc/${APP_NAME}/profiles}"

# ── Самообновление ──────────────────────────────────────────────────────────
# Впиши сюда свой репозиторий (ник/имя). Если оставить CHANGE_ME — скрипт спросит его при первом обновлении
# и сохранит в /etc/vpsmenu.conf. Публичный репозиторий, файл vpsmenu.sh в корне.
readonly DEFAULT_REPO="skrskr7799-design/vpsmenu"
readonly DEFAULT_BRANCH="main"
RAW_BASE="${VPSMENU_RAW_BASE:-https://raw.githubusercontent.com}"

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
OS_PRETTY="Linux"
ASK_RESULT=""
CHOICE=""
APT_UPDATED=0
BACKUP_RESULT=""
BACKUP_PICKED=""
UPDATE_AVAILABLE=""
