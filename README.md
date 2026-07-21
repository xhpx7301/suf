# SUF

SUF（Server UFW & SSH Fortress）是一个面向 Debian/Ubuntu 小型服务器的交互式安全管理脚本。

项目地址：<https://github.com/xhpx7301/suf>

SUF 本身不是常驻服务。它只在执行命令时运行，适合资源有限的服务器。私钥始终在自己的可信电脑生成，SUF 只接收和安装公钥。

## 功能

- 一级菜单按 SSH、UFW、Fail2ban 分类并显示运行状态
- 创建非 root 运维用户并安装 Ed25519 公钥
- 禁止 root、密码和键盘交互式 SSH 登录
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
- systemd + OpenSSH Server

脚本不会修改云厂商安全组。修改 SSH 端口前，必须先在云控制台放行新端口。

## 安装

克隆仓库后先阅读脚本，再执行安装：

```bash
git clone https://github.com/xhpx7301/suf.git
cd suf
less suf install.sh
sudo bash ./install.sh
```

安装程序会：

1. 对 `suf` 执行 Bash 语法和程序身份校验。
2. 将旧版本备份到 `/var/backups/suf/installer/`。
3. 安装主程序到 `/usr/local/sbin/suf`。
4. 创建 `/usr/local/bin/suf` 命令链接。

安装完成后，直接执行：

```bash
suf
```

普通用户执行时，SUF 会通过 `sudo` 请求管理员权限，然后打开菜单。

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
SUF 1.0.0 - Server UFW & SSH Fortress

1) SSH 与密钥管理
2) UFW 防火墙管理
3) Fail2ban 防暴力破解
4) 查看整体安全状态
5) 一键安全加固流程
0) 退出
```

二级菜单提供对应服务的安装、配置、状态和卸载操作。SUF 不提供远程卸载 OpenSSH，因为这可能立即切断服务器管理通道。

## 推荐操作顺序

先在自己的电脑生成密钥：

```bash
ssh-keygen -t ed25519 -a 100
```

给私钥设置强口令。`id_ed25519` 是私钥，不能上传服务器、GitHub 或聊天工具；SUF 需要的是 `id_ed25519.pub` 内容。

1. 进入 SSH 菜单，创建非 root 用户并粘贴公钥。
2. 保持原 SSH 会话，在第二个终端测试密钥登录和 `sudo -v`。
3. 进入 UFW 菜单，安装并执行引导式初始配置。
4. 确认云安全组已放行目标 SSH 端口。
5. 返回 SSH 菜单，关闭 root 和密码登录或修改端口。
6. 保持原会话，在第三个终端测试新端口。
7. 进入 Fail2ban 菜单，安装并配置 SSH jail。
8. 新连接确认正常后，删除不需要的旧 UFW SSH 规则。

## 更新

在仓库目录检查变更后重新安装：

```bash
git pull --ff-only
git diff HEAD@{1} -- suf install.sh
sudo bash ./install.sh
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
- 关闭或卸载 UFW、停止 Fail2ban 都需要输入完整确认词。
- UFW 和 Fail2ban 使用 `apt-get remove` 卸载，保留配置且不会自动执行 `autoremove`。
- 定期安装系统安全更新、检查日志并验证异地备份。

## License

MIT
