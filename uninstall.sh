#!/usr/bin/env bash
# SUF uninstaller
set -Eeuo pipefail

TARGET="/usr/local/sbin/suf"
LINK="/usr/local/bin/suf"
UNINSTALL_TARGET="/usr/local/sbin/suf-uninstall"
BACKUP_ROOT="/var/backups/suf"
ORIGINAL_DIR="${BACKUP_ROOT}/original-state"
SSH_MAIN="/etc/ssh/sshd_config"
SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
UFW_DIR="/etc/ufw"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/suf.local"
DOCKER_RULES_FILE="/etc/suf/docker-source-rules.conf"

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt=$1 answer
  while true; do
    if ! read -r -p "${prompt} [y/N，默认 N] " answer; then
      printf '\n' >&2
      return 1
    fi
    case "$answer" in
      [Yy]) return 0 ;;
      ""|[Nn]) return 1 ;;
      *) printf '[WARN] 请输入 y 或 n；直接按 Enter 默认为 n。\n' ;;
    esac
  done
}

first_ssh_snapshot() {
  if [[ -f ${ORIGINAL_DIR}/sshd_config && ! -e ${ORIGINAL_DIR}/dropin-unavailable ]]; then
    printf '%s\n' "$ORIGINAL_DIR"
    return 0
  fi
  [[ -d $BACKUP_ROOT ]] || return 0
  find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -type f -name sshd_config -printf '%h\n' 2>/dev/null |
    grep -v '/uninstall-' | sort | sed -n '1p' || true
}

can_restore_ufw() {
  [[ -f $ORIGINAL_DIR/ufw-state && ! -e $ORIGINAL_DIR/ufw-config-unavailable ]]
}

can_restore_fail2ban() {
  [[ -f $ORIGINAL_DIR/fail2ban-active && -f $ORIGINAL_DIR/fail2ban-enabled &&
    ! -e $ORIGINAL_DIR/fail2ban-jail-unavailable ]]
}

ssh_service() {
  if systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q '^ssh\.service'; then
    printf 'ssh\n'
  elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q '^sshd\.service'; then
    printf 'sshd\n'
  else
    return 1
  fi
}

sshd_binary() {
  if [[ -x /usr/sbin/sshd ]]; then printf '/usr/sbin/sshd\n'; else command -v sshd; fi
}

save_current_state() {
  local backup_dir
  install -d -m 700 -o root -g root "$BACKUP_ROOT"
  backup_dir=$(mktemp -d "${BACKUP_ROOT}/uninstall-$(date +%Y%m%d-%H%M%S).XXXXXX")
  chmod 700 "$backup_dir"
  if [[ -f $SSH_MAIN ]]; then cp -a "$SSH_MAIN" "$backup_dir/sshd_config" || die "备份当前 SSH 失败。"; fi
  if [[ -d $SSH_DROPIN_DIR ]]; then cp -a "$SSH_DROPIN_DIR" "$backup_dir/sshd_config.d" || die "备份当前 SSH 附加配置失败。"; fi
  if [[ -d $UFW_DIR ]]; then cp -a "$UFW_DIR" "$backup_dir/ufw" || die "备份当前 UFW 失败。"; fi
  if [[ -f $FAIL2BAN_JAIL ]]; then cp -a "$FAIL2BAN_JAIL" "$backup_dir/fail2ban-suf.local" || die "备份当前 Fail2ban jail 失败。"; fi
  if [[ -f $DOCKER_RULES_FILE ]]; then cp -a "$DOCKER_RULES_FILE" "$backup_dir/docker-source-rules.conf" || die "备份当前 Docker 来源规则失败。"; fi
  if command -v ufw >/dev/null 2>&1 &&
    ufw status 2>/dev/null | awk '$0 == "Status: active" { active = 1 } END { exit !active }'; then
    printf 'active\n' >"$backup_dir/ufw-state"
  else
    printf 'inactive\n' >"$backup_dir/ufw-state"
  fi
  systemctl is-active fail2ban 2>/dev/null >"$backup_dir/fail2ban-active" || true
  systemctl is-enabled fail2ban 2>/dev/null >"$backup_dir/fail2ban-enabled" || true
  printf '%s\n' "$backup_dir"
}

rollback_ssh() {
  local backup_dir=$1 bin=$2 service=$3
  if [[ -e $SSH_DROPIN_DIR ]]; then
    mv "$SSH_DROPIN_DIR" "$backup_dir/sshd_config.d.failed" || return 1
  fi
  if [[ -d $backup_dir/sshd_config.d.before ]]; then
    mv "$backup_dir/sshd_config.d.before" "$SSH_DROPIN_DIR" || return 1
  fi
  cp -a "$backup_dir/sshd_config" "$SSH_MAIN" || return 1
  if "$bin" -t && systemctl reload "$service"; then
    printf '[WARN] SSH 已回滚到卸载前配置。\n'
    return 0
  fi
  printf '[WARN] 回滚后的 SSH 未能重新加载；不要关闭当前会话。\n' >&2
  return 1
}

restore_ssh() {
  local source_dir=$1 backup_dir=$2 bin service effective port password kbd root_login
  [[ -f $source_dir/sshd_config && -f $backup_dir/sshd_config ]] || die "SSH 备份不完整，未恢复。"
  [[ ! -L $source_dir/sshd_config && ! -L $source_dir/sshd_config.d ]] || die "SSH 备份含符号链接，未恢复。"
  [[ -f $SSH_MAIN && ! -L $SSH_MAIN ]] || die "当前 SSH 主配置不是普通文件，未恢复。"
  [[ ( ! -e $SSH_DROPIN_DIR && ! -L $SSH_DROPIN_DIR ) ||
    ( -d $SSH_DROPIN_DIR && ! -L $SSH_DROPIN_DIR ) ]] ||
    die "当前 SSH 附加配置目录异常，未恢复。"
  bin=$(sshd_binary) || die "找不到 sshd，未恢复 SSH。"
  service=$(ssh_service) || die "找不到 SSH 服务，未恢复 SSH。"

  if [[ -d $SSH_DROPIN_DIR ]]; then mv "$SSH_DROPIN_DIR" "$backup_dir/sshd_config.d.before"; fi
  if ! cp -a "$source_dir/sshd_config" "$SSH_MAIN"; then
    rollback_ssh "$backup_dir" "$bin" "$service" || true
    die "复制 SSH 备份失败，已尝试回滚。"
  fi
  if [[ -d $source_dir/sshd_config.d ]]; then
    if ! cp -a "$source_dir/sshd_config.d" "$SSH_DROPIN_DIR"; then
      rollback_ssh "$backup_dir" "$bin" "$service" || true
      die "复制 SSH 附加配置失败，已尝试回滚。"
    fi
  fi
  if ! "$bin" -t || ! systemctl reload "$service"; then
    rollback_ssh "$backup_dir" "$bin" "$service" || true
    die "恢复后的 SSH 校验或重载失败；已尝试回滚，SUF 尚未卸载。"
  fi

  effective=$("$bin" -T -C "user=root,host=$(hostname),addr=127.0.0.1" 2>/dev/null) ||
    die "SSH 已重载，但无法读取生效配置；SUF 尚未卸载，请保持当前会话并检查。"
  port=$(awk '$1 == "port" {print $2}' <<<"$effective" | paste -sd ',' -)
  password=$(awk '$1 == "passwordauthentication" {print $2; exit}' <<<"$effective")
  kbd=$(awk '$1 == "kbdinteractiveauthentication" {print $2; exit}' <<<"$effective")
  root_login=$(awk '$1 == "permitrootlogin" {print $2; exit}' <<<"$effective")
  printf '[ OK ] SSH 生效配置：端口 %s；密码认证 %s；键盘交互 %s；Root 登录 %s。\n' \
    "${port:-未知}" "${password:-未知}" "${kbd:-未知}" "${root_login:-未知}"
  printf '[WARN] 保持当前会话，并在新终端测试恢复后的 SSH 登录。\n'
}

rollback_ufw() {
  local backup_dir=$1 current_state
  if [[ -d $backup_dir/ufw.before ]]; then
    if [[ -e $UFW_DIR ]]; then mv "$UFW_DIR" "$backup_dir/ufw.failed" || return 1; fi
    mv "$backup_dir/ufw.before" "$UFW_DIR" || return 1
  fi
  if command -v ufw >/dev/null 2>&1; then
    current_state=$(cat "$backup_dir/ufw-state")
    if [[ $current_state == active ]]; then ufw --force enable || return 1
    else ufw --force disable || return 1; fi
  fi
}

restore_ufw() {
  local backup_dir=$1 state actual_state status_output restore_failed=0
  state=$(cat "$ORIGINAL_DIR/ufw-state")
  if [[ -d $ORIGINAL_DIR/ufw ]]; then
    if [[ ( -e $UFW_DIR || -L $UFW_DIR ) && ( ! -d $UFW_DIR || -L $UFW_DIR ) ]]; then
      printf '[WARN] UFW 配置路径异常，跳过恢复。\n'
      return 1
    fi
    if [[ -d $UFW_DIR ]]; then
      mv "$UFW_DIR" "$backup_dir/ufw.before" || { printf '[WARN] 无法暂存当前 UFW 配置。\n'; return 1; }
    fi
    cp -a "$ORIGINAL_DIR/ufw" "$UFW_DIR" || restore_failed=1
  fi
  if ((restore_failed == 0)) && command -v ufw >/dev/null 2>&1; then
    if [[ $state == active ]]; then
      ufw --force enable || restore_failed=1
    else
      ufw --force disable || restore_failed=1
    fi
    if ((restore_failed == 0)); then
      status_output=$(ufw status 2>/dev/null) || restore_failed=1
      actual_state=$(awk '$1 == "Status:" {print $2; exit}' <<<"${status_output:-}")
      [[ $actual_state == "$state" ]] || restore_failed=1
    fi
  elif ((restore_failed == 0)) && [[ $state == active ]]; then
    printf '[WARN] 安装前 UFW 运行中，但当前没有 UFW 命令。\n'
    restore_failed=1
  elif ((restore_failed == 0)); then
    printf '[ OK ] UFW：安装前未启用，当前未安装。\n'
  fi
  if ((restore_failed > 0)); then
    rollback_ufw "$backup_dir" || printf '[WARN] UFW 原设置回滚失败。\n'
    printf '[WARN] UFW 未能恢复；原配置已尝试回滚，SUF 命令仍会保留。\n'
    return 1
  fi
  if command -v ufw >/dev/null 2>&1; then
    printf '[ OK ] UFW：%s。\n' "$(ufw status 2>/dev/null | sed -n '1p')"
    printf '[INFO] 恢复后已保存的 UFW 规则：\n'
    ufw show added || printf '[WARN] 无法列出 UFW 已保存规则。\n'
  fi
  if [[ -e $ORIGINAL_DIR/ufw-config-was-absent ]]; then
    printf '[WARN] 安装前无 UFW 配置目录；软件包与现有配置文件仍保留。\n'
  fi
}

rollback_fail2ban() {
  local backup_dir=$1
  if [[ -f $backup_dir/fail2ban-suf.local ]]; then
    cp -a "$backup_dir/fail2ban-suf.local" "$FAIL2BAN_JAIL" || true
  else
    rm -f "$FAIL2BAN_JAIL" || true
  fi
  if systemctl list-unit-files fail2ban.service --no-legend 2>/dev/null | grep -q '^fail2ban\.service'; then
    if [[ $(cat "$backup_dir/fail2ban-enabled") == enabled ]]; then
      systemctl enable fail2ban || true
    else
      systemctl disable fail2ban || true
    fi
    if [[ $(cat "$backup_dir/fail2ban-active") == active ]]; then
      systemctl restart fail2ban || true
    else
      systemctl stop fail2ban || true
    fi
  fi
}

restore_fail2ban() {
  local backup_dir=$1 active enabled current current_enabled failed=0
  active=$(cat "$ORIGINAL_DIR/fail2ban-active")
  enabled=$(cat "$ORIGINAL_DIR/fail2ban-enabled")
  if [[ -f $ORIGINAL_DIR/fail2ban-suf.local ]]; then
    install -d -m 755 "$(dirname "$FAIL2BAN_JAIL")"
    cp -a "$ORIGINAL_DIR/fail2ban-suf.local" "$FAIL2BAN_JAIL" || failed=1
  elif [[ -e $ORIGINAL_DIR/fail2ban-jail-was-absent ]]; then
    if [[ -e $FAIL2BAN_JAIL ]]; then rm -f "$FAIL2BAN_JAIL" || failed=1; fi
  fi
  if ((failed > 0)); then
    rollback_fail2ban "$backup_dir"
    printf '[WARN] Fail2ban jail 文件恢复失败。\n'
    return 1
  fi
  if systemctl list-unit-files fail2ban.service --no-legend 2>/dev/null | grep -q '^fail2ban\.service'; then
    if [[ $enabled == enabled ]]; then systemctl enable fail2ban || failed=1
    else systemctl disable fail2ban || failed=1; fi
    if [[ $active == active ]]; then systemctl restart fail2ban || failed=1
    else systemctl stop fail2ban || failed=1; fi
    current=$(systemctl is-active fail2ban 2>/dev/null || true)
    current_enabled=$(systemctl is-enabled fail2ban 2>/dev/null || true)
    if [[ $active == active ]]; then
      [[ $current == active ]] || failed=1
    else
      [[ $current != active ]] || failed=1
    fi
    if [[ $enabled == enabled ]]; then
      [[ $current_enabled == enabled ]] || failed=1
    else
      [[ $current_enabled == disabled ]] || failed=1
    fi
    if ((failed > 0)); then
      rollback_fail2ban "$backup_dir"
      printf '[WARN] Fail2ban 服务状态恢复失败，请使用卸载前备份检查配置。\n'
      return 1
    fi
    printf '[ OK ] Fail2ban：服务 %s；开机启动 %s；SUF jail 文件 %s。\n' \
      "${current:-未知}" "${current_enabled:-未知}" \
      "$(if [[ -f $FAIL2BAN_JAIL ]]; then printf '存在'; else printf '不存在'; fi)"
  elif [[ $active == active ]]; then
    rollback_fail2ban "$backup_dir"
    printf '[WARN] 安装前 Fail2ban 运行中，但当前没有该服务。\n'
    return 1
  else
    printf '[ OK ] Fail2ban：安装前未运行，当前未安装。\n'
  fi
  printf '[INFO] Fail2ban 软件包未移除；SUF jail 文件已按快照处理。\n'
}

restore_and_uninstall() {
  local ssh_source backup_dir failures=0 bin service
  [[ -r /etc/os-release ]] || die "无法识别系统。"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == debian || ${ID:-} == ubuntu ]] || die "自动恢复目前仅支持 Debian/Ubuntu。"

  ssh_source=$(first_ssh_snapshot)
  if [[ -z $ssh_source ]] && ! can_restore_ufw && ! can_restore_fail2ban; then
    die "没有可恢复的配置快照；可使用普通卸载保留当前安全设置。"
  fi
  printf '将按可验证的备份恢复，然后卸载 SUF：\n'
  if [[ -n $ssh_source ]]; then printf '  SSH：%s\n' "$ssh_source"
  else printf '[WARN] SSH：没有可用备份，保持当前配置。\n'; fi
  if can_restore_ufw; then printf '  UFW：恢复安装前配置及启用状态。\n'
  else printf '[WARN] UFW：没有安装前快照，保持当前配置。\n'; fi
  if can_restore_fail2ban; then
    printf '  Fail2ban：恢复 SUF jail 文件及服务状态。\n'
  else printf '[WARN] Fail2ban：没有安装前快照，保持当前配置。\n'; fi
  printf '[WARN] SSH 恢复可能重新开放旧端口或密码登录；保持当前会话。\n'
  if [[ -n $ssh_source ]] && ! can_restore_ufw && command -v ufw >/dev/null 2>&1 &&
    ufw status 2>/dev/null | awk '$0 == "Status: active" { active = 1 } END { exit !active }'; then
    printf '[WARN] UFW 当前启用但没有安装前快照；恢复 SSH 后须核对恢复端口是否被 UFW 放行。\n'
  fi
  printf '[WARN] 已安装的公钥、SUF 创建的账号及 Docker 运行时规则没有可靠的原始快照，不会自动删除。\n'
  confirm "确认按上述范围恢复并卸载 SUF 吗？" || die "取消卸载。"

  backup_dir=$(save_current_state)
  printf '[INFO] 卸载前的当前配置已备份到 %s\n' "$backup_dir"
  if [[ -n $ssh_source ]]; then restore_ssh "$ssh_source" "$backup_dir"
  else printf '[WARN] SSH 未恢复，当前配置仍保留。\n'; fi
  if can_restore_ufw; then
    restore_ufw "$backup_dir" || failures=$((failures + 1))
  else
    printf '[WARN] UFW 未恢复，当前规则和运行状态保留。\n'
    if command -v ufw >/dev/null 2>&1; then
      printf '[INFO] 当前 UFW：%s。\n' "$(ufw status 2>/dev/null | sed -n '1p')"
    else
      printf '[INFO] 当前 UFW：未安装。\n'
    fi
  fi
  if can_restore_fail2ban; then
    restore_fail2ban "$backup_dir" || failures=$((failures + 1))
  else
    printf '[WARN] Fail2ban 未恢复，当前配置和运行状态保留。\n'
    printf '[INFO] 当前 Fail2ban：%s；SUF jail 文件 %s。\n' \
      "$(systemctl is-active fail2ban 2>/dev/null || true)" \
      "$(if [[ -f $FAIL2BAN_JAIL ]]; then printf '存在'; else printf '不存在'; fi)"
  fi
  if ((failures > 0)); then
    if can_restore_fail2ban; then
      rollback_fail2ban "$backup_dir"
      printf '[WARN] Fail2ban 已尝试回滚到卸载前状态。\n'
    fi
    if can_restore_ufw; then
      rollback_ufw "$backup_dir" ||
        die "其他设置恢复失败，UFW 回滚也失败；不要关闭当前会话，检查备份 ${backup_dir}。"
      printf '[WARN] UFW 已回滚到卸载前状态。\n'
    fi
    if [[ -n $ssh_source ]]; then
      bin=$(sshd_binary) || die "其他设置恢复失败，且找不到 sshd，无法回滚 SSH；不要关闭当前会话。"
      service=$(ssh_service) || die "其他设置恢复失败，且找不到 SSH 服务，无法回滚 SSH；不要关闭当前会话。"
      rollback_ssh "$backup_dir" "$bin" "$service" ||
        die "其他设置恢复失败，SSH 回滚也失败；不要关闭当前会话，检查备份 ${backup_dir}。"
    fi
    die "有 ${failures} 项未恢复，SUF 命令仍保留；请检查备份 ${backup_dir}。"
  fi
  remove_installed_files
  printf '[INFO] 已安装的公钥、SUF 创建的账号及 Docker 运行时规则保持现状；软件包未自动移除。\n'
  printf '[ OK ] SUF 命令已卸载。恢复结果如上；项目源码和备份仍保留在服务器上。备份目录：%s。\n' "$BACKUP_ROOT"
}

validate_installed_files() {
  if [[ -L $LINK ]]; then
    [[ $(readlink "$LINK") == "$TARGET" ]] || die "${LINK} 指向未知目标，拒绝删除。"
  elif [[ -e $LINK ]]; then
    die "${LINK} 不是符号链接，拒绝删除。"
  fi
  [[ ! -L $TARGET ]] || die "${TARGET} 是符号链接，拒绝删除。"
  [[ ! -e $TARGET || -f $TARGET ]] || die "${TARGET} 不是普通文件，拒绝删除。"
  [[ ! -L $UNINSTALL_TARGET ]] || die "${UNINSTALL_TARGET} 是符号链接，拒绝删除。"
  [[ ! -e $UNINSTALL_TARGET || -f $UNINSTALL_TARGET ]] || die "${UNINSTALL_TARGET} 不是普通文件，拒绝删除。"
  if [[ -f $UNINSTALL_TARGET ]]; then
    grep -qFx '# SUF uninstaller' "$UNINSTALL_TARGET" || die "${UNINSTALL_TARGET} 不是 SUF 卸载程序，拒绝删除。"
  fi
}

remove_installed_files() {
  if [[ -L $LINK ]]; then rm -f "$LINK"; fi
  if [[ -f $TARGET ]]; then rm -f "$TARGET"; fi
  if [[ -f $UNINSTALL_TARGET ]]; then rm -f "$UNINSTALL_TARGET"; fi
}

main() {
  local mode=${1:-}
  case "$mode" in
    ""|--restore) ;;
    *) die "未知参数：${mode}。用法：sudo bash uninstall.sh [--restore]" ;;
  esac
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "需要 root 权限，但系统未安装 sudo。"
    exec sudo -- bash "$0" "$@"
  fi
  validate_installed_files
  if [[ $mode == --restore ]]; then
    restore_and_uninstall
    return
  fi
  printf '[WARN] 这只会卸载 SUF 命令。\n'
  printf '[WARN] 不会撤销 SSH/UFW/Fail2ban 配置，也不会删除 %s。\n' "$BACKUP_ROOT"
  confirm "确认卸载 SUF 命令吗？" || die "取消卸载。"
  remove_installed_files
  printf '[ OK ] SUF 命令已卸载，安全配置和备份均已保留。\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
