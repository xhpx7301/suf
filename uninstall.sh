#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="/usr/local/sbin/suf"
LINK="/usr/local/bin/suf"

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "需要 root 权限，但系统未安装 sudo。"
  exec sudo -- bash "$0" "$@"
fi

printf '[WARN] 这只会卸载 SUF 命令。\n'
printf '[WARN] 不会撤销 SSH/UFW/Fail2ban 配置，也不会删除 /var/backups/suf。\n'
read -r -p '确认卸载请输入 UNINSTALL-SUF：' confirmation
[[ $confirmation == UNINSTALL-SUF ]] || die "取消卸载。"

if [[ -L $LINK ]]; then
  link_target=$(readlink "$LINK")
  if [[ $link_target == "$TARGET" ]]; then
    rm -f "$LINK"
  else
    die "${LINK} 指向未知目标 ${link_target}，拒绝删除。"
  fi
elif [[ -e $LINK ]]; then
  die "${LINK} 不是符号链接，拒绝删除。"
fi

if [[ -L $TARGET ]]; then
  die "${TARGET} 是符号链接，拒绝删除。"
elif [[ -f $TARGET ]]; then
  rm -f "$TARGET"
elif [[ -e $TARGET ]]; then
  die "${TARGET} 不是普通文件，拒绝删除。"
fi

printf '[ OK ] SUF 命令已卸载，安全配置和备份均已保留。\n'
