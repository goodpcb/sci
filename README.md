# Sing-Box + Caddy v5.2 部署套件

面向个人 VPS 的交互部署脚本：默认启用 **Caddy 网站 + VLESS Reality + Hysteria 2**，H2 和 gRPC 按需启用。通过 Cloudflare Worker `sci.zdxq.xyz` 分发安装、卸载脚本。

**v5.2 是本项目的脚本版本，不是 Sing-Box 的版本，也不是上游官方 LTS。** 默认固定 Sing-Box `1.14.3`，不自动跟随最新版。服务器上存在正常 HTTPS 网站，不代表其他端口的代理流量不会被识别或限制。

## v5.2 的主要变化

| 项目 | 当前行为 |
| --- | --- |
| 交互输入 | 分别打开终端读、写流，修复 `File or stream is not seekable` 错误 |
| 协议选择 | Reality 默认启用，HY2 默认启用但可关闭；H2/gRPC 首次安装和旧版迁移默认关闭 |
| 凭证保留 | 可识别的 v5.1 配置迁移或重复配置时，保留已有 UUID、密码、Reality 密钥和 short ID |
| 下载检查 | 仅从官方 GitHub 下载 Sing-Box，执行前校验 SHA256；不使用第三方下载镜像 |
| 证书处理 | 等待受信任正式证书约 180 秒；失败则回滚，不生成跳过 TLS 验证的链接 |
| 证书同步 | 每 30 分钟检查 Caddy 证书；验证域名、有效期、信任链和密钥匹配后同步 |
| 服务权限 | Sing-Box 使用独立非 root 账户，配置与私钥限制读取权限 |
| 部署与升级 | 配置预检、备份、启动检查；失败时恢复程序、配置和原服务状态 |
| 卸载 | 先备份，再删除可识别的本部署；保留系统包、账户、证书存储和备份 |
| 系统设置 | 不修改 SSH、防火墙、BBR；不自动安装安全补丁 |

独立 UUID 可以分别管理不同协议的凭证；服务器本身被入侵时，不能靠 UUID 分离保护所有节点。

## 支持环境

- Debian 12 / 13，Ubuntu 22.04 / 24.04。
- CPU：amd64（x86_64）或 arm64（aarch64）。
- 需要 root 权限、Python 3 和运行中的 systemd；不支持普通非 systemd 容器。
- 需要可用的 APT 源，以及访问 GitHub Releases、ACME 证书服务和所选 Reality 握手目标的网络。

安装会通过系统现有 APT 源安装 Caddy 与基础依赖，新版不添加第三方 APT 源。旧版已经添加的 Caddy 源不会被自动移除；安装或重新配置时，APT 可能升级已有软件包。**APT 包安装、升级和新建服务账户不在文件回滚范围。**

上述是脚本支持的目标环境，并不表示已经完成所有系统与架构组合的实际部署测试。

## 协议与默认端口

| 服务 / 协议 | 公网端口 | 后端监听 | 默认状态 |
| --- | --- | --- | --- |
| Caddy HTTP / HTTPS 网站 | TCP 80 / 443 | Caddy 直接监听 | 开启 |
| VLESS Reality | TCP 8443 | Sing-Box 直接监听 | 开启 |
| Hysteria 2 | UDP 8444 | Sing-Box 直接监听 | 开启，可关闭 |
| VLESS H2 | TCP 443 | 127.0.0.1:10001，经 Caddy 反代 | 可选，默认关闭 |
| VLESS gRPC | TCP 443 | 127.0.0.1:10002，经 Caddy 反代 | 可选，默认关闭 |

Reality 和 HY2 端口可在安装时修改，必须在 1024—65535 之间。H2 的公网入口使用 HTTPS/HTTP2，Caddy 与未配置 TLS 的 Sing-Box HTTP 后端使用 HTTP/1.1；gRPC 后端使用 h2c。可选协议的后端端口无需在公网防火墙中开放。

Caddy 还可能监听 UDP 443 提供 HTTP/3；它不是本部署申请证书、使用 TCP 网站入口或 H2/gRPC 的必要条件。

## 安装前准备

1. 准备一个直指 VPS 的网站/HY2 域名，配置正确的 A/AAAA 记录。此域名在 Cloudflare 使用“仅 DNS”，不要开启 CDN 代理。没有可用 IPv6 时不要保留错误的 AAAA 记录。
2. 在 VPS 防火墙与云平台安全组放行 TCP 80/443、所选 Reality TCP 端口，以及启用 HY2 时的 UDP 端口。
3. Reality 握手目标应可访问且支持 TLS 1.3；默认目标是 `addons.mozilla.org`，实际可用性需自行确认。
4. 保留 SSH 管理访问。脚本不会自动修改管理入口或防火墙规则。
5. 如果已有网站、其他 Sing-Box 配置或 systemd override，先检查兼容性。脚本不会自动合并多站点配置。

没有 Python 3 时先安装：

```bash
sudo apt-get update && sudo apt-get install -y python3
```

Worker 分发域名 `sci.zdxq.xyz` 可以绑定 Worker；它与安装时输入的 VPS 网站/HY2 域名承担不同功能。

## 安装或迁移

先完整下载，下载成功后再执行：

```bash
curl --proto '=https' --tlsv1.2 -fSL --retry 2 --connect-timeout 15 --max-time 180 https://sci.zdxq.xyz/ -o install.sh && sudo bash install.sh install
```

查看参数：

```bash
bash install.sh --help
```

从本仓库原 v5.1 迁移时，脚本会读取 `/etc/sing-box/config.json`、`domain.txt` 与 `node_info.txt`。其中的旧 Reality 公钥必须可读取；无法确认配置来源或公钥时拒绝自动迁移。原凭证保留，H2/gRPC 是否启用由交互选择决定。

没有显式指定版本时，可识别的已有稳定 `1.14.x` 核心会被保留。已有核心不是稳定 `1.14.x` 时，需要明确选择兼容版本：

```bash
sudo bash install.sh install --version 1.14.3
```

安装和迁移会短暂重启服务。证书申请失败、配置检查失败或启动检查失败时自动恢复旧文件和服务状态。

若存在未知 Caddyfile，脚本会拒绝覆盖。`--adopt-caddy` 表示允许备份后接管**整个 Caddyfile**，不是合并其他站点；仅在确认可以替换原网站配置时使用。

## 卸载

```bash
curl --proto '=https' --tlsv1.2 -fSL --retry 2 --connect-timeout 15 --max-time 180 https://sci.zdxq.xyz/uninstall -o uninstall.sh && sudo bash uninstall.sh
```

`/un` 是同一路由的别名。默认需要按提示输入 `UNINSTALL`；明确需要非交互执行时使用 `sudo bash uninstall.sh --yes`。

卸载会先创建备份，然后停用并删除本脚本管理的 Sing-Box 服务、配置、程序、证书同步任务及管理命令。

- Caddyfile 与脚本生成内容完全一致时，停用本部署网站并删除该配置。
- Caddyfile 被修改过时，保留 Caddy 服务、配置和网页目录，提示人工检查指向已卸载后端的残留反代规则。
- 保留 Caddy 系统包、Caddy 证书存储、APT 依赖、服务账户、额外用户文件和全部备份，不执行 `apt autoremove`。
- 旧 v5.1 遗留的 `cert/server.crt`、`cert/server.key` 也不会直接删除。备份及遗留文件可能含私钥，请自行保管和清理。
- 只卸载能通过 v5.2 状态文件识别的部署；未知配置或尚未迁移的 v5.1 不会直接删除。
- 卸载失败时恢复卸载前的文件与服务状态。

## 运维命令

| 任务 | 命令 |
| --- | --- |
| 显示节点分享链接 | `sudo sb-v52 links` |
| 健康检查 | `sudo sb-v52 health` |
| 手动同步证书 | `sudo sb-v52 sync-cert` |
| 旧命令兼容入口 | `sudo sb-sync-cert` |
| 明确指定核心版本进行升级 | `sudo sb-v52 upgrade --version 1.14.3` |
| 恢复指定备份 | `sudo sb-v52 rollback --backup /var/backups/sb-v52/实际备份目录` |
| 查看近期日志 | `sudo journalctl -u sing-box -u caddy -u sb-v52-cert-sync.service -n 80` |
| 查看定时任务 | `systemctl list-timers sb-v52-cert-sync.timer` |

`--version` 仅接受稳定 `1.14.x`。非默认版本必须在官方 Release 资产中提供有效 SHA256 digest，否则拒绝安装。跨版本升级需重新审核配置，不自动执行。

证书每 30 分钟检查一次，内容变化时才重启 Sing-Box，重启可能中断现有连接。`health` 会报告 HY2 证书无效或剩余有效期不足 7 天的情况；它不主动发送告警，也不自动执行软件升级。

## 文件、备份与恢复

| 内容 | 路径 |
| --- | --- |
| Sing-Box 配置 | `/etc/sing-box/config.json` |
| 管理状态及凭证 | `/etc/sing-box/state-v52.json` |
| 节点分享链接 | `/etc/sing-box/node_info.txt` |
| Caddy 配置 | `/etc/caddy/Caddyfile` |
| 本部署网页 | `/var/www/sb-v52/` |
| 部署备份 | `/var/backups/sb-v52/` |

节点链接、管理状态和备份含敏感凭证，切勿上传到公开仓库。备份不会自动清理；请自行维护磁盘空间。手工修改配置后，升级和卸载的所有权检查可能拒绝操作，需人工核对。

卸载后管理命令已经删除，需要使用下载的安装脚本恢复：

```bash
sudo bash install.sh rollback --backup /var/backups/sb-v52/实际备份目录
```

恢复旧 v5.1 备份也会恢复其旧配置、服务权限等行为，不能视为仍具有 v5.2 的全部加固措施。

## 验证与限制

已完成 Bash 语法检查、内嵌 Python 编译检查，并使用真实 Sing-Box `1.14.3` 检查八种协议开关组合。十三项功能测试覆盖凭证迁移、输入检查、错误下载哈希拒绝、备份恢复、证书同步/升级失败回滚、卸载保护和卸载失败回滚。Caddy `2.11.7` 已通过包含 H2/gRPC 的配置检查；Worker 路由、方法限制与上游错误处理已通过模拟测试。

**尚未完成四个目标系统的实际 VPS 安装测试，也未完成代理端到端连接测试。** 当前验证环境禁止创建 Sing-Box 运行需要的 netlink socket。安装后的 `health` 检查仅覆盖本机服务、配置、进程监听、HTTPS 和证书；请使用客户端分别测试实际启用的协议。

## 仓库与 Worker 部署

仓库地址：<https://github.com/goodpcb/sci>。`install.sh` 与 `uninstall.sh` 必须放在 `main` 分支根目录。

现有 Worker 仍可使用。仓库中的 [worker.js](worker.js) 是可选的改进版，保留 `/`、`/uninstall`、`/un` 路由，并增加错误路径 404、方法限制和上游异常处理。

推送、Worker 配置、下载检查和恢复说明见 [DEPLOY_GUIDE.md](DEPLOY_GUIDE.md)。
