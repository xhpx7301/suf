# SUF

SUF（Server UFW & SSH Fortress）是一个面向 Debian/Ubuntu 小型服务器的交互式安全管理脚本。

项目地址：<https://github.com/xhpx7301/suf>

SUF 本身不是常驻服务。它只在执行命令时运行，适合资源有限的服务器。私钥始终在自己的可信电脑生成，SUF 只接收和安装公钥。

## 功能

- 一级菜单按 SSH、UFW、Fail2ban 分类并显示运行状态
- 默认给 root 安装 Ed25519 公钥，也可选择普通 sudo 用户
- 允许 root 仅通过密钥登录，禁止所有 SSH 密码和键盘交互认证
- 修改 SSH 端口，应用前校验，失败自动恢复
- 安装、配置、启用、关闭和卸载 UFW
- 放行端口、限制来源 IP/CIDR、连接限速和删除规则
- 安装、配置、停止和卸载 Fail2ban
- 修改失败次数、统计窗口和封禁时间
- 查看整体状态、监听端口和封禁信息
- SSH 与 Fail2ban 配置修改前自动备份

## 支持范围

- Debian 12/13
- Ubuntu 22.04/24.04 及相近版本
- systemd + OpenSSH 服务

脚本不会修改云厂商安全组。修改 SSH 端口前，必须先在云控制台放行新端口。

## 快捷安装

首次安装和后续更新都使用同一条命令：

```bash
SUF_SETUP="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/xhpx7301/suf/main/setup.sh -o "$SUF_SETUP" && bash "$SUF_SETUP"
```

命令行为：

- `$HOME/suf` 不存在：自动克隆仓库后安装。
- `$HOME/suf` 已是正确仓库：自动执行 `git pull --ff-only` 后更新安装。
- 目录不是 SUF 仓库或存在未提交修改：停止操作，不覆盖任何文件。

安装完成后会自动进入菜单。以后随时执行 `suf` 即可重新打开。

不立即打开菜单：

```bash
SUF_SETUP="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/xhpx7301/suf/main/setup.sh -o "$SUF_SETUP" && bash "$SUF_SETUP" --no-launch
```

快捷命令先用 `mktemp` 创建唯一临时文件，再下载并执行脚本，没有使用远程内容直接管道到 root shell。

## 审查后安装

安全敏感的生产服务器建议先查看代码：

```bash
git clone --depth 1 https://github.com/xhpx7301/suf.git
cd suf
less suf
less install.sh
sudo bash ./install.sh
```

`less` 只是源码查看器，不是安装界面。按 `q` 退出后，再执行安装命令。

安装程序会：

1. 对 `suf` 执行 Bash 语法和程序身份校验。
2. 将旧版本备份到 `/var/backups/suf/installer/`。
3. 安装主程序到 `/usr/local/sbin/suf`。
4. 创建 `/usr/local/bin/suf` 命令链接。

安装后重新打开菜单：

```bash
suf
```

普通用户执行时，SUF 会通过 `sudo` 请求管理员权限，然后打开菜单。

自动化安装但不立即打开菜单：

```bash
sudo bash ./install.sh --no-launch
```

## 命令

```bash
suf                 # 打开菜单
suf menu            # 打开菜单
suf status          # 查看整体安全状态
suf --version       # 查看版本
suf --help          # 查看帮助
```

## 菜单结构

```text
SUF 1.1.4 - Server UFW & SSH Fortress

1) SSH 与密钥管理
2) UFW 防火墙管理
3) Fail2ban 防暴力破解
4) 查看整体安全状态
5) 一键安全加固流程
0) 退出
```

二级菜单提供对应服务的安装、配置、状态和卸载操作。SUF 不提供远程卸载 OpenSSH，因为这可能立即切断服务器管理通道。

### 一级菜单说明

| 选项 | 作用 | 适用场景 |
| --- | --- | --- |
| `1` SSH 与密钥管理 | 管理 SSH 服务、公钥、密钥登录和端口。 | 首次安装公钥、禁用密码登录或更换 SSH 端口。 |
| `2` UFW 防火墙管理 | 管理服务器本机的入站和出站防火墙规则。 | 只开放必要服务端口，例如 SSH、HTTP、HTTPS。 |
| `3` Fail2ban 防暴力破解 | 根据 SSH 失败日志自动临时封禁来源 IP。 | SSH 对公网开放时建议启用。 |
| `4` 查看整体安全状态 | 汇总 SSH、UFW、Fail2ban 的当前状态。 | 配置后检查，或排查问题前先了解现状。 |
| `5` 一键安全加固流程 | 顺序执行公钥、UFW、SSH 和 Fail2ban 的基础加固。 | 新服务器且尚未手动配置这些服务时使用。 |

### SSH 与密钥管理

| 选项 | 作用与注意事项 |
| --- | --- |
| `1` 查看 SSH 状态与安全配置 | 显示实际生效的端口、root 登录策略及密码认证状态。配置后优先用它核对。 |
| `2` 安装/修复 OpenSSH 服务 | 安装并启动 OpenSSH；不会移除现有 SSH 配置。 |
| `3` 为登录用户安装公钥 | 默认写入 `/root/.ssh/authorized_keys`。只粘贴 `id_ed25519.pub` 公钥，绝不能上传私钥。 |
| `4` 启用仅密钥登录或修改端口 | 禁用 SSH 密码和键盘交互认证，可同时修改端口。必须先在第二个终端验证密钥登录，并先在云安全组放行新端口。 |
| `5` 校验并重新加载 SSH | 对配置执行语法校验后重载 SSH。适合手动修改 SSH 配置后使用。 |
| `6` 恢复最近一次 SSH 配置备份 | 还原 SUF 保存的最新 SSH 配置。恢复后仍应保持当前会话并测试新连接。 |

### UFW 防火墙管理

| 选项 | 作用与注意事项 |
| --- | --- |
| `1` 查看状态 | 显示 UFW 是否启用、默认入站/出站策略和已生效规则。 |
| `2` 查看编号规则 | 每条规则会显示如 `[1]` 的编号，供选项 `9` 精确删除。IPv4 和 IPv6 规则常各占一个编号。 |
| `3` 查看实际监听端口并按需放行 | 先显示全部监听详情和“公网监听候选”。可选择一个正在监听的端口加入 UFW 放行；仅本机地址 `127.0.0.1` 或 `[::1]` 的服务不能通过此菜单开放。 |
| `4` 查看 UFW 已放行端口 | 列出已保存的 `allow` 和 `limit` 规则；即使 UFW 尚未启用，也可查看将在启用后生效的端口。 |
| `5` 安装 UFW | 只安装软件包，不会自动开启防火墙。 |
| `6` 引导式初始配置 | 设置“拒绝入站、允许出站”，放行当前 SSH 端口，按需放行 HTTP/HTTPS 和额外端口，确认后启用 UFW。首次配置推荐使用。 |
| `7` 放行端口 | 允许所有来源访问指定 TCP 或 UDP 端口。只用于确实需要公开的服务。 |
| `8` 仅允许指定 IP/CIDR 访问端口 | 仅向一个 IP 或网段开放端口；SUF 会检查并要求删除同端口的广泛放行规则。 |
| `9` 为端口添加连接限速 | 对 TCP 新连接施加 UFW 限速，适合 SSH 等管理端口；不能替代密钥认证或 Fail2ban。 |
| `10` 删除编号规则 | 按选项 `2` 显示的编号删除规则。删除后编号会重新排列。 |
| `11` 启用 UFW | 对已有规则启用防火墙，并优先为当前 SSH 来源保留管理入口。 |
| `12` 重新加载规则 | 重新读取已保存的 UFW 规则，通常不需要重启服务器。 |
| `13` 关闭 UFW | 停止执行防火墙规则，所有监听端口失去这层保护。 |
| `14` 卸载 UFW | 移除软件包但保留配置文件；以后重装仍可能读取旧规则。 |

### Fail2ban 防暴力破解

| 选项 | 作用与注意事项 |
| --- | --- |
| `1` 查看服务与 SSH 防护规则状态 | 显示 Fail2ban 是否运行、`sshd` jail 和当前封禁情况。 |
| `2` 安装并启动 Fail2ban | 同时安装 `python3-systemd`，并自动为 SSH jail 使用 systemd 日志后端，适配 Debian/Ubuntu 无 `/var/log/auth.log` 的精简系统。安装后还可使用选项 `3` 调整 SSH 防护参数。 |
| `3` 配置/修改 SSH 防护参数 | 使用 systemd 日志监控 SSH，可设置监听端口、最大失败次数、统计窗口和首次封禁时间。 |
| `4` 校验并重新加载配置 | 校验 Fail2ban 配置后重载；修改参数后使用。 |
| `5` 解封指定 IP | 将误封的 IP 从 `sshd` jail 中移除。 |
| `6` 停止 Fail2ban | 停止服务并取消开机启动，新的暴力破解不会再被自动封禁。 |
| `7` 卸载 Fail2ban | 移除软件包但保留 `/etc/fail2ban` 配置。 |

## 推荐操作顺序

先在自己的电脑生成密钥：

```bash
ssh-keygen -t ed25519 -a 100
```

给私钥设置强口令。`id_ed25519` 是私钥，不能上传服务器、GitHub 或聊天工具；SUF 需要的是 `id_ed25519.pub` 内容。

1. 进入 SSH 菜单，为默认的 root 用户粘贴 Ed25519 公钥。
2. 保持原 SSH 会话，在第二个终端测试 `ssh root@服务器IP`，并确认 `whoami` 输出 `root`。
3. 进入 UFW 菜单，安装并执行引导式初始配置。
4. 确认云安全组已放行目标 SSH 端口。
5. 返回 SSH 菜单，启用 root 仅密钥登录、禁止所有密码认证，并可修改端口。
6. 保持原会话，在第三个终端测试新端口。
7. 进入 Fail2ban 菜单，安装并配置 SSH 防护规则。
8. 新连接确认正常后，删除不需要的旧 UFW SSH 规则。

## 更新

在仓库目录检查变更后重新安装：

```bash
git pull --ff-only
git diff HEAD@{1} -- suf install.sh
sudo bash ./install.sh --no-launch
```

安装程序会先备份当前已安装版本。

## 卸载 SUF

```bash
sudo bash ./uninstall.sh
```

卸载程序只删除 SUF 命令，不会撤销 SSH、UFW 或 Fail2ban 配置，也不会删除备份。

## 配置与备份位置

```text
/usr/local/sbin/suf
/usr/local/bin/suf -> /usr/local/sbin/suf
/etc/ssh/sshd_config.d/00-suf-hardening.conf
/etc/fail2ban/jail.d/suf.local
/var/backups/suf/
```

## 注意事项

- 不推荐使用 `curl URL | sudo bash`，应先下载或克隆并审查脚本。
- UFW 无法替代云安全组，两层都要正确配置。
- Docker 发布端口可能绕过部分 UFW 入站路径，需要单独审核 Docker/iptables 规则。
- “仅允许指定 IP”会检查并要求删除同端口的广泛 `allow` 或 `limit` 规则。
- 默认 root 密钥直登能减少权限操作障碍，但私钥泄露会直接导致最高权限失陷，必须设置私钥口令并妥善备份。
- SUF 使用 `PermitRootLogin prohibit-password`，不会使用允许 root 密码登录的 `PermitRootLogin yes`。
- 关闭或卸载 UFW、停止 Fail2ban 都需要输入完整确认词。
- UFW 和 Fail2ban 使用 `apt-get remove` 卸载，保留配置且不会自动执行 `autoremove`。
- 定期安装系统安全更新、检查日志并验证异地备份。

## License

MIT
