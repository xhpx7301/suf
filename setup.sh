#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/xhpx7301/suf.git"
EXPECTED_ORIGIN="https://github.com/xhpx7301/suf.git"
SUF_DIR="${SUF_HOME:-${HOME:?HOME 未设置}/suf}"

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

validate_arguments() {
  case "${1:-}" in
    ""|--no-launch) ;;
    *) die "未知参数：$1。可用参数：--no-launch" ;;
  esac
}

prepare_repository() {
  local origin
  command -v git >/dev/null 2>&1 || die "未找到 git，请先安装 git。"
  [[ ! -L $SUF_DIR ]] || die "${SUF_DIR} 是符号链接，拒绝继续。"

  if [[ -d ${SUF_DIR}/.git ]]; then
    origin=$(git -C "$SUF_DIR" remote get-url origin 2>/dev/null || true)
    [[ $origin == "$EXPECTED_ORIGIN" ]] || die "${SUF_DIR} 的远程仓库不是 xhpx7301/suf。"
    [[ -z $(git -C "$SUF_DIR" status --porcelain) ]] || die "${SUF_DIR} 存在未提交修改，请先处理。"
    info "检测到现有 SUF 仓库，正在获取更新..."
    git -C "$SUF_DIR" pull --ff-only
    ok "SUF 仓库已更新。"
  elif [[ -e $SUF_DIR ]]; then
    die "${SUF_DIR} 已存在但不是 Git 仓库，请先改名或移走。"
  else
    info "正在克隆 SUF 仓库到 ${SUF_DIR}..."
    git clone --depth 1 "$REPO_URL" "$SUF_DIR"
    ok "SUF 仓库已克隆。"
  fi
}

main() {
  validate_arguments "${1:-}"
  prepare_repository
  [[ -f ${SUF_DIR}/install.sh ]] || die "仓库中缺少 install.sh。"
  bash "${SUF_DIR}/install.sh" "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
