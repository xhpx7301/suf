#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="/usr/local/sbin/suf"
LINK="/usr/local/bin/suf"
BACKUP_DIR="/var/backups/suf/installer"
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

install -d -m 755 -o root -g root /usr/local/sbin /usr/local/bin

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

printf '[ OK ] 已安装 %s\n' "$($TARGET --version)"
printf '[ OK ] 现在可以执行：suf\n'

if ((NO_LAUNCH == 0)) && [[ -t 0 && -t 1 ]]; then
  printf '[INFO] 正在打开 SUF 菜单...\n'
  exec "$TARGET"
fi
