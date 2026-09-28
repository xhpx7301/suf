#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="/usr/local/sbin/suf"
LINK="/usr/local/bin/suf"
UNINSTALL_TARGET="/usr/local/sbin/suf-uninstall"
BACKUP_DIR="/var/backups/suf/installer"
ORIGINAL_DIR="/var/backups/suf/original-state"
NO_LAUNCH=0

case "${1:-}" in
  "") ;;
  --no-launch) NO_LAUNCH=1 ;;
  *)
    printf '[FAIL] 未知参数：%s\n' "$1" >&2
    printf '用法：sudo bash install.sh [--no-launch]\n' >&2
    exit 2
    ;;
esac

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "需要 root 权限，但系统未安装 sudo。"
  exec sudo -- bash "$0" "$@"
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
fi
case "${ID:-}" in
  alpine) SOURCE="${SCRIPT_DIR}/suf-alpine" ;;
  debian|ubuntu) SOURCE="${SCRIPT_DIR}/suf" ;;
  *) die "不支持的操作系统：${ID:-unknown}。当前支持 Debian/Ubuntu 和 Alpine。" ;;
esac

[[ -f $SOURCE ]] || die "未找到主程序：${SOURCE}"
bash -n "$SOURCE" || die "suf 未通过 Bash 语法校验。"
grep -q '^APP_NAME="suf"$' "$SOURCE" || die "主程序身份校验失败。"
[[ -f ${SCRIPT_DIR}/uninstall.sh ]] || die "未找到卸载程序。"
bash -n "${SCRIPT_DIR}/uninstall.sh" || die "卸载程序未通过 Bash 语法校验。"
[[ ! -L $UNINSTALL_TARGET ]] || die "${UNINSTALL_TARGET} 是符号链接，拒绝覆盖。"
[[ ! -e $UNINSTALL_TARGET || -f $UNINSTALL_TARGET ]] || die "${UNINSTALL_TARGET} 不是普通文件，拒绝覆盖。"
if [[ -f $UNINSTALL_TARGET ]]; then
  grep -qFx '# SUF uninstaller' "$UNINSTALL_TARGET" || die "${UNINSTALL_TARGET} 不是 SUF 卸载程序，拒绝覆盖。"
fi

capture_original_state() {
  local staging
  [[ ${ID:-} == debian || ${ID:-} == ubuntu ]] || return 0
  [[ -e $TARGET || -L $TARGET || -d $ORIGINAL_DIR ]] && return 0
  if [[ -e /var/backups/suf ]]; then
    printf '[WARN] 检测到旧 SUF 备份，无法确认当前设置是首次安装前状态；不创建原始快照。\n'
    return 0
  fi

  install -d -m 700 -o root -g root /var/backups/suf
  staging=$(mktemp -d /var/backups/suf/.original-state.XXXXXX)
  chmod 700 "$staging"
  if [[ -f /etc/ssh/sshd_config && ! -L /etc/ssh/sshd_config ]]; then
    cp -a /etc/ssh/sshd_config "$staging/sshd_config"
  else
    : >"$staging/ssh-config-unavailable"
  fi
  if [[ -L /etc/ssh/sshd_config.d ]]; then
    : >"$staging/dropin-unavailable"
  elif [[ -d /etc/ssh/sshd_config.d ]]; then
    cp -a /etc/ssh/sshd_config.d "$staging/sshd_config.d"
  else
    : >"$staging/dropin-dir-was-absent"
  fi
  if [[ -L /etc/ufw ]]; then
    : >"$staging/ufw-config-unavailable"
  elif [[ -d /etc/ufw ]]; then
    cp -a /etc/ufw "$staging/ufw"
  else
    : >"$staging/ufw-config-was-absent"
  fi
  if command -v ufw >/dev/null 2>&1 &&
    ufw status 2>/dev/null | awk '$0 == "Status: active" { active = 1 } END { exit !active }'; then
    printf 'active\n' >"$staging/ufw-state"
  else
    printf 'inactive\n' >"$staging/ufw-state"
  fi
  if [[ -L /etc/fail2ban/jail.d/suf.local ]]; then
    : >"$staging/fail2ban-jail-unavailable"
  elif [[ -f /etc/fail2ban/jail.d/suf.local ]]; then
    cp -a /etc/fail2ban/jail.d/suf.local "$staging/fail2ban-suf.local"
  else
    : >"$staging/fail2ban-jail-was-absent"
  fi
  systemctl is-active fail2ban 2>/dev/null >"$staging/fail2ban-active" || true
  systemctl is-enabled fail2ban 2>/dev/null >"$staging/fail2ban-enabled" || true
  mv "$staging" "$ORIGINAL_DIR"
  printf '[INFO] 安装前配置已保存到 %s；后续更新不会覆盖此快照。\n' "$ORIGINAL_DIR"
}

install -d -m 755 -o root -g root /usr/local/sbin /usr/local/bin
capture_original_state

if [[ -e $TARGET || -L $TARGET ]]; then
  [[ -f $TARGET && ! -L $TARGET ]] || die "${TARGET} 不是普通文件，拒绝覆盖。"
  install -d -m 700 -o root -g root "$BACKUP_DIR"
  backup="${BACKUP_DIR}/suf.$(date +%Y%m%d-%H%M%S)"
  cp -a "$TARGET" "$backup"
  printf '[INFO] 旧版本已备份到 %s\n' "$backup"
fi

if [[ -L $LINK ]]; then
  current_link_target=$(readlink "$LINK")
  [[ $current_link_target == "$TARGET" ]] || die "${LINK} 已指向其他目标：${current_link_target}"
elif [[ -e $LINK ]]; then
  die "${LINK} 已存在且不是符号链接，请人工处理后重试。"
fi

staged_target=$(mktemp /usr/local/sbin/.suf.install.XXXXXX)
trap 'rm -f "$staged_target"' EXIT
install -m 755 -o root -g root "$SOURCE" "$staged_target"
bash -n "$staged_target"
mv -f "$staged_target" "$TARGET"
trap - EXIT
ln -sfn "$TARGET" "$LINK"
staged_uninstaller=$(mktemp /usr/local/sbin/.suf-uninstall.install.XXXXXX)
trap 'rm -f "$staged_uninstaller"' EXIT
install -m 755 -o root -g root "${SCRIPT_DIR}/uninstall.sh" "$staged_uninstaller"
bash -n "$staged_uninstaller"
mv -f "$staged_uninstaller" "$UNINSTALL_TARGET"
trap - EXIT

printf '[ OK ] 已安装 %s\n' "$($TARGET --version)"
printf '[ OK ] 现在可以执行：suf\n'

if ((NO_LAUNCH == 0)) && [[ -t 0 && -t 1 ]]; then
  printf '[INFO] 正在打开 SUF 菜单...\n'
  exec "$TARGET"
fi
