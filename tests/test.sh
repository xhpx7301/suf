#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$REPO_DIR"

echo "=== 1. Syntax checks ==="
for f in suf suf-alpine install.sh uninstall.sh setup.sh tests/test.sh; do
  bash -n "$f"
  echo "syntax ok: $f"
done

echo "=== 2. Line ending checks ==="
for f in suf suf-alpine install.sh uninstall.sh setup.sh tests/test.sh .gitattributes; do
  if grep -q $'\r' "$f"; then
    echo "FAIL: CR found in $f" >&2
    exit 1
  fi
done
echo "all LF ok"

echo "=== 3. Version & identity checks ==="
[[ $(./suf --version) == "suf 1.2.23" ]] || { echo "FAIL suf version"; exit 1; }
[[ $(./suf-alpine --version) == "suf 1.2.23" ]] || { echo "FAIL suf-alpine version"; exit 1; }
grep -q '^APP_NAME="suf"$' suf
grep -q '^APP_NAME="suf"$' suf-alpine
echo "version & identity ok"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Non-root / Windows Git Bash shims for root ownership and NTFS permission flags
if [[ ${EUID:-1} -ne 0 ]] || [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
  chown() { return 0; }
  chmod() { return 0; }
  install() {
    local is_dir=0 args=() skip_next=0 arg
    for arg in "$@"; do
      if ((skip_next)); then
        skip_next=0
        continue
      fi
      if [[ $arg == -d ]]; then
        is_dir=1
        continue
      fi
      if [[ $arg == -o || $arg == -g || $arg == -m ]]; then
        skip_next=1
        continue
      fi
      args+=("$arg")
    done
    if ((is_dir)); then
      mkdir -p "${args[@]}"
    else
      cp -f "${args[@]}"
    fi
  }
fi

echo "=== 4. Test suf-alpine functions ==="
# shellcheck source=/dev/null
source ./suf-alpine

# Test current_ssh_client_ip
SSH_CONNECTION="2404:3881:10d:1000::1234 55555 2404:3881:10d:1000::6440:f22 22"
SSH_CLIENT=""
[[ $(current_ssh_client_ip) == "2404:3881:10d:1000::1234" ]]

SSH_CONNECTION=""
SSH_CLIENT="154.49.152.15 20034 22"
[[ $(current_ssh_client_ip) == "154.49.152.15" ]]

SSH_CLIENT="::ffff:1.2.3.4 20034 22"
[[ $(current_ssh_client_ip) == "::ffff:1.2.3.4" ]]

SSH_CLIENT="[2404:3881::1%eth0] 20034 22"
[[ $(current_ssh_client_ip) == "2404:3881::1" ]]

SSH_CONNECTION=""
SSH_CLIENT=""
who() { return 1; }
[[ -z $(current_ssh_client_ip) ]]
unset -f who
echo "current_ssh_client_ip ok"

# Test valid_ip_or_cidr
valid_ip_or_cidr "1.2.3.4"
valid_ip_or_cidr "1.2.3.0/24"
valid_ip_or_cidr "2404:3881:10d:1000::6440:f22"
valid_ip_or_cidr "2404:3881::/32"
valid_ip_or_cidr "::1"
! valid_ip_or_cidr "999.1.1.1"
! valid_ip_or_cidr "1.2.3.4/33"
! valid_ip_or_cidr "2404:::/64"
! valid_ip_or_cidr "2404::1/129"
! valid_ip_or_cidr "bad-ip"
echo "valid_ip_or_cidr ok"

# Test ip_matches_source
ip_matches_source "154.49.152.15" "any"
ip_matches_source "154.49.152.15" "154.49.152.0/24"
! ip_matches_source "154.49.153.15" "154.49.152.0/24"
ip_matches_source "2404:3881:10d:1000::6440:f22" "2404:3881:10d::/48"
! ip_matches_source "2404:3881:10e::1" "2404:3881:10d::/48"
ip_matches_source "::ffff:154.49.152.15" "154.49.152.0/24"
echo "ip_matches_source ok"

# Test project_dir with DOAS_USER & SUF_HOME
user_home() { [[ $1 == alice ]] && printf '/home/alice\n'; }
SUF_HOME=""
DOAS_USER="alice"
[[ $(project_dir) == "/home/alice/suf" ]]
SUF_HOME="/opt/custom-suf"
[[ $(project_dir) == "/opt/custom-suf" ]]
SUF_HOME=""
DOAS_USER=""
echo "project_dir ok"

# Configure sandbox paths
FAIL2BAN_JAIL_DIR="$TMP/jail.d"
FAIL2BAN_JAIL_FILE="$FAIL2BAN_JAIL_DIR/suf.local"
BACKUP_ROOT="$TMP/backups"
NFT_BACKUP_DIR="$BACKUP_ROOT/nftables"
SSH_DROPIN_DIR="$TMP/sshd_config.d"
SSH_DROPIN="$SSH_DROPIN_DIR/00-suf-hardening.conf"
SSH_MAIN="$TMP/sshd_config"
NFT_CONF="$TMP/nftables.d/suf.nft"
NFT_MAIN="$TMP/nftables.nft"
NFT_RULES_FILE="$TMP/suf/nftables-rules.conf"
mkdir -p "$TMP/bin"

SSHD_BIN="$TMP/bin/sshd"
cat >"$TMP/bin/sshd" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == "-T" ]]; then
  cat <<'CONF'
port 22
logingracetime 120
maxauthtries 6
pubkeyauthentication yes
passwordauthentication yes
kbdinteractiveauthentication yes
authenticationmethods any
permitrootlogin yes
CONF
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/sshd"

ensure_alpine_syslog() { return 0; }
rc-service() {
  case "$1:$2" in
    fail2ban:status|sshd:status|syslog:status) return 0 ;;
    fail2ban:start|fail2ban:restart|nftables:start) return 0 ;;
  esac
  return 0
}
rc-update() { return 0; }
apk_install() { return 0; }
ensure_openssh() { SSHD_BIN="$TMP/bin/sshd"; }
find_sshd() { SSHD_BIN="$TMP/bin/sshd"; }

cat >"$TMP/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
case "$1:${2:-}:${3:-}" in
  -t::) exit 0 ;;
  reload::)
    echo "RELOADED" >> "${MOCK_LOG:-/dev/null}"
    exit 0
    ;;
  status::)
    cat <<'OUT'
Status
|- Number of jail:      1
`- Jail list:           sshd
OUT
    ;;
  status:sshd:)
    cat <<'OUT'
Status for the jail: sshd
|- Filter
|  |- Currently failed: 1
|  |- Total failed:     13
|  `- File list:        /var/log/messages
`- Actions
   |- Currently banned: 0
   |- Total banned:     1
   `- Banned IP list:
OUT
    ;;
  get:sshd:ignoreip)
    cat <<'OUT'
These IP addresses/networks are ignored:
|- 127.0.0.1/8
|- ::1
`- 2404:3881:10d:1000::1234
OUT
    ;;
  set:sshd:unbanip)
    echo "UNBANNED:$4" >> "${MOCK_LOG:-/dev/null}"
    exit 0
    ;;
esac
EOF
chmod +x "$TMP/bin/fail2ban-client"
export PATH="$TMP/bin:$PATH"
export MOCK_LOG="$TMP/mock.log"

SSH_CONNECTION="2404:3881:10d:1000::1234 55555 2404:3881:10d:1000::6440:f22 22"
merged=$(merge_fail2ban_ignoreip "10.0.0.1" "::1")
[[ $merged == "127.0.0.1/8 ::1 10.0.0.1 2404:3881:10d:1000::1234" ]]

SSH_CONNECTION="::ffff:1.2.3.4 55555 ::ffff:10.0.0.1 22"
merged_v4mapped=$(merge_fail2ban_ignoreip)
[[ $merged_v4mapped == "127.0.0.1/8 ::1 ::ffff:1.2.3.4 1.2.3.4" ]]

SSH_CONNECTION="2404:3881:10d:1000::1234 55555 2404:3881:10d:1000::6440:f22 22"
install_fail2ban > "$TMP/install_f2b.out"
grep -q "2404:3881:10d:1000::1234" "$FAIL2BAN_JAIL_FILE"
grep -q "enabled = true" "$FAIL2BAN_JAIL_FILE"
grep -q "UNBANNED:2404:3881:10d:1000::1234" "$MOCK_LOG"
grep -q "已封禁 IP：无" "$TMP/install_f2b.out"
grep -q "白名单 IP：127.0.0.1/8 ::1 2404:3881:10d:1000::1234" "$TMP/install_f2b.out"

cat >"$FAIL2BAN_JAIL_FILE" <<'EOF'
[sshd]
enabled = true
port = 22
maxretry = 3
bantime = 2h
ignoreip = 127.0.0.1/8 8.8.8.8
EOF
SSH_CONNECTION="154.49.152.15 20034 10.0.0.1 22"
ensure_fail2ban_client_protection > /dev/null
grep -q "maxretry = 3" "$FAIL2BAN_JAIL_FILE"
grep -q "bantime = 2h" "$FAIL2BAN_JAIL_FILE"
grep -q "ignoreip = 127.0.0.1/8 ::1 8.8.8.8 154.49.152.15" "$FAIL2BAN_JAIL_FILE"

sync_fail2ban_ssh_port 28377 > /dev/null
grep -q "^port = 28377$" "$FAIL2BAN_JAIL_FILE"
grep -q "maxretry = 3" "$FAIL2BAN_JAIL_FILE"
grep -q "RELOADED" "$MOCK_LOG"

f2b_status=$(show_fail2ban_status)
grep -q "Fail2ban 防护状态" <<<"$f2b_status"
grep -q "已启用防护规则：sshd" <<<"$f2b_status"
grep -q "累计失败次数：13" <<<"$f2b_status"
grep -q "累计封禁数量：1" <<<"$f2b_status"
grep -q "已封禁 IP：无" <<<"$f2b_status"
f2b_compat=$(fail2ban_status)
grep -q "Fail2ban 防护状态" <<<"$f2b_compat"
echo "fail2ban tests ok"

echo "=== 5. Test nftables module ==="
export NFT_STATE_FILE="$TMP/nft_active"
export NFT_FILTER_FILE="$TMP/nft_filter_active"
echo "1" > "$NFT_STATE_FILE"
echo "1" > "$NFT_FILTER_FILE"
cat >"$TMP/bin/nft" <<'EOF'
#!/usr/bin/env bash
state=$(cat "${NFT_STATE_FILE}" 2>/dev/null || echo 0)
fstate=$(cat "${NFT_FILTER_FILE}" 2>/dev/null || echo 0)
if [[ $1 == "-c" && $2 == "-f" ]]; then
  grep -q "table inet suf" "$3"
  exit $?
fi
if [[ $1 == "list" && $2 == "table" && $3 == "inet" && $4 == "suf" ]]; then
  if [[ $state == 1 && -f ${NFT_CONF:-} ]]; then
    cat "$NFT_CONF"
    exit 0
  fi
  exit 1
fi
if [[ $1 == "list" && $2 == "table" && $3 == "inet" && $4 == "filter" ]]; then
  [[ $fstate == 1 ]] && exit 0
  exit 1
fi
if [[ $1 == "delete" && $2 == "table" && $3 == "inet" && $4 == "filter" ]]; then
  echo "0" > "$NFT_FILTER_FILE"
  exit 0
fi
if [[ $1 == "delete" && $2 == "table" ]]; then
  echo "0" > "$NFT_STATE_FILE"
  exit 0
fi
if [[ $1 == "-f" ]]; then
  if [[ $2 == "-" ]]; then
    cat > /dev/null
  fi
  echo "1" > "$NFT_STATE_FILE"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/nft"
export NFT_CONF

mkdir -p "$(dirname "$NFT_CONF")"
cat >"$NFT_CONF" <<'EOF'
table inet suf {
  chain input {
    type filter hook input priority -100; policy drop;
    iifname "lo" accept
    ct state established,related accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    tcp dport 22 accept comment "SUF SSH"
    ip6 saddr 2404:3881::/32 tcp dport 8443 accept comment "IPv6限制"
    udp dport 51820 ct state new limit rate 12/minute burst 6 packets accept comment "WG"
  }
  chain output { type filter hook output priority 100; policy accept; }
}
EOF

nft_ensure_rules_file
grep -q "allow|tcp|22|any|SUF SSH" "$NFT_RULES_FILE"
grep -q "allow|tcp|8443|2404:3881::/32|IPv6限制" "$NFT_RULES_FILE"
grep -q "limit|udp|51820|any|WG" "$NFT_RULES_FILE"

nft_upsert_rule allow tcp 443 any "加密网页 HTTPS"
nft_upsert_rule allow tcp 80 any "网页 HTTP"
nft_upsert_rule allow udp 80 any "网页 HTTP"
nft_upsert_rule allow tcp 80 any "网页 HTTP新"

rendered="$TMP/rendered.nft"
nft_render_config "$rendered"
grep -q '^table inet suf$' "$rendered"
grep -q '^delete table inet suf$' "$rendered"
grep -q 'tcp dport 80 accept comment "网页 HTTP新"' "$rendered"
grep -q 'ip6 saddr 2404:3881::/32 tcp dport 8443 accept comment "IPv6限制"' "$rendered"

# Verify Alpine stock /etc/nftables.nft backup & safe takeover
cat >"$NFT_MAIN" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
  }
}
EOF
nft_persistence > /dev/null
[[ -f ${NFT_BACKUP_DIR}/nftables.nft.orig ]]
grep -q "table inet filter" "${NFT_BACKUP_DIR}/nftables.nft.orig"
grep -q "^# Managed by SUF" "$NFT_MAIN"
grep -Fq "include \"${NFT_CONF}\"" "$NFT_MAIN"
! grep -q "table inet filter" "$NFT_MAIN"

nft_disable_persistence
[[ ! -f $NFT_CONF ]]
[[ -f $NFT_RULES_FILE ]]
grep -q "# Managed by SUF - disabled" "$NFT_MAIN"
! grep -Fq "include \"${NFT_CONF}\"" "$NFT_MAIN"

echo "0" > "$NFT_STATE_FILE"
nft_status_out=$(show_nftables_status)
grep -q "nftables 防火墙状态" <<<"$nft_status_out"
grep -q "未启用" <<<"$nft_status_out"
grep -q "待应用的放行/限速规则" <<<"$nft_status_out"
grep -q "任意来源（IPv4/IPv6）" <<<"$nft_status_out"

nft_rules_out=$(show_nftables_rules)
grep -q "编号" <<<"$nft_rules_out"
grep -q "目标" <<<"$nft_rules_out"
grep -q "操作" <<<"$nft_rules_out"
grep -q "来源" <<<"$nft_rules_out"
grep -q "备注" <<<"$nft_rules_out"
grep -q "\[1\]" <<<"$nft_rules_out"
grep -q "待应用的底层 nftables 规则预览" <<<"$nft_rules_out"

comment_test=$(printf '连接限速服务\n' | prompt_rule_comment '默认')
[[ $comment_test == "连接限速服务" ]]

rm -f "$NFT_RULES_FILE"
install_nftables_service > "$TMP/inst_nft.out"
echo "0" > "$NFT_STATE_FILE"
grep -q "allow|tcp|80|any|网页 HTTP" "$NFT_RULES_FILE"
grep -q "allow|udp|443|any|加密网页 HTTPS" "$NFT_RULES_FILE"
! nft_table_exists

# Confirm enable + removing conflicting Alpine default table inet filter
printf 'y\ny\n' | enable_nftables_service > "$TMP/en_nft.out"
nft_table_exists
[[ $(cat "$NFT_FILTER_FILE") == "0" ]]
grep -q "allow|tcp|22|any|SUF SSH 管理" "$NFT_RULES_FILE"
grep -q "tcp dport 22 accept" "$NFT_CONF"

printf '22\nSSH限速\n' | nft_limit_port > /dev/null
grep -q "limit|tcp|22|any|SSH限速" "$NFT_RULES_FILE"
! grep -q "allow|tcp|22|any|" "$NFT_RULES_FILE"

printf '80\n网站HTTP\n' | nft_update_port_comment > /dev/null
grep -q "allow|tcp|80|any|网站HTTP" "$NFT_RULES_FILE"
grep -q "allow|udp|80|any|网站HTTP" "$NFT_RULES_FILE"

status_out=$(show_status)
grep -q "SSH 服务状态" <<<"$status_out"
grep -q "nftables 防火墙状态" <<<"$status_out"
grep -q "Fail2ban 防护状态" <<<"$status_out"
# Fail2ban port was synced to 28377 while mocked sshd listens on 22 -> consistency check must warn
grep -q "一致性检查：SSH 当前监听端口为 22，但 Fail2ban 配置的监控端口为 28377" <<<"$status_out"
sync_fail2ban_ssh_port 22 > /dev/null
status_ok_out=$(show_status)
grep -q "一致性检查：SSH 端口（22）与 nftables / Fail2ban 配置一致" <<<"$status_ok_out"
echo "nftables & status tests ok"

echo "=== 6. Test Debian suf Fail2ban, UFW, Docker & Runtime additions ==="
# shellcheck source=/dev/null
source ./suf
FAIL2BAN_JAIL_DIR="$TMP/deb_jail.d"
FAIL2BAN_JAIL_FILE="$FAIL2BAN_JAIL_DIR/suf.local"
BACKUP_ROOT="$TMP/deb_backups"
DOCKER_RULES_FILE="$TMP/deb_docker_rules.conf"
SSHD_BIN="$TMP/bin/sshd"
find_sshd_bin() { printf '%s\n' "$TMP/bin/sshd"; }
systemctl() {
  case "$1:${2:-}" in
    is-active:--quiet) return 0 ;;
    is-active:fail2ban) printf 'active\n'; return 0 ;;
    list-units:*)
      printf 'ssh.service loaded active running OpenBSD Secure Shell server\n'
      printf 'fail2ban.service loaded active running Fail2Ban Service\n'
      return 0
      ;;
  esac
  return 0
}
ufw() {
  case "$1:${2:-}" in
    status:) printf 'Status: active\n' ;;
    show:added)
      printf 'ufw allow 22/tcp comment '\''SUF SSH 管理'\''\n'
      printf 'ufw allow 443/tcp comment '\''HTTPS'\''\n'
      ;;
  esac
  return 0
}

SSH_CONNECTION="2404:3881:10d:1000::abcd 12345 ::1 22"
ensure_fail2ban_systemd_backend > /dev/null
grep -q "backend = systemd" "$FAIL2BAN_JAIL_FILE"
grep -q "ignoreip = 127.0.0.1/8 ::1 2404:3881:10d:1000::abcd" "$FAIL2BAN_JAIL_FILE"
sync_fail2ban_ssh_port 28377 > /dev/null
grep -q "^port = 28377$" "$FAIL2BAN_JAIL_FILE"
deb_f2b_out=$(show_fail2ban_status)
grep -q "服务状态：运行中" <<<"$deb_f2b_out"
grep -q "白名单 IP：" <<<"$deb_f2b_out"
grep -q "日志来源：systemd SSH 日志" <<<"$deb_f2b_out"

# Test UFW SSH rule detection & delete lockout warning
ufw_has_broad_ssh_rule 22
ufw_has_any_ssh_rule 22
! ufw_has_broad_ssh_rule 28377
ufw_rule_matches_ssh_port "[ 1] 22/tcp ALLOW IN Anywhere" 22
! ufw_rule_matches_ssh_port "[ 2] 443/tcp ALLOW IN Anywhere" 22
ssh_warn_out=$(ufw_warn_if_deleting_ssh_rule "ufw allow 22/tcp")
grep -q "涉及当前 SSH 端口 TCP/22" <<<"$ssh_warn_out"

# Test Debian consistency check (mismatch then match)
cons_warn=$(show_security_consistency_check)
grep -q "SSH 当前监听端口为 22，但 Fail2ban 配置的监控端口为 28377" <<<"$cons_warn"
sync_fail2ban_ssh_port 22 > /dev/null
cons_ok=$(show_security_consistency_check)
grep -q "一致性检查：SSH 端口（22）与 UFW / Fail2ban 配置一致" <<<"$cons_ok"

# Test Docker source rules viewing & deletion
printf '1.2.3.4|8080|tcp\n2404:3881::1|8080|tcp\n' > "$DOCKER_RULES_FILE"
printf '1\ny\n' | manage_docker_source_rules > /dev/null
! grep -q "1.2.3.4|8080|tcp" "$DOCKER_RULES_FILE"
grep -q "2404:3881::1|8080|tcp" "$DOCKER_RULES_FILE"
printf 'y\n' | remove_docker_source_rules_for_port 8080 "tcp" > /dev/null
! grep -q "2404:3881::1|8080|tcp" "$DOCKER_RULES_FILE"

# Test show_running_services
svc_out=$(show_running_services)
grep -q "systemd 正在运行的服务" <<<"$svc_out"
grep -q "ssh" <<<"$svc_out"
echo "Debian suf tests ok"

echo "ALL TESTS PASSED!"
