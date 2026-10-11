# Sing-Box (>=1.14) + Caddy 安全加固版多协议全套套件

现代化、高度自动化的 Linux VPS 代理环境一键部署工具。基于 **Sing-Box 官方最新版 (>=1.14)** 与 **Caddy v2**，集成了主流抗封锁协议，并完成了深度安全加固。

本项目已接入 **Cloudflare Workers** 极简域名加速分发（`sci.zdxq.xyz`），在全新 VPS 上可直接通过超短命令实现一键安装与卸载。

---

## 🌟 核心特性与安全加固

- **四合一全协议矩阵**：
  - **VLESS-Reality**：借用大厂境外正规网站证书与 SNI 伪装，`xtls-rprx-vision` 流控，免自备有效证书，日常主力低延迟推荐。
  - **Hysteria 2 (Hy2)**：极速 QUIC/UDP 自研拥塞控制算法，恶劣网络与晚高峰抗丢包优选。
  - **VLESS-H2**：由 Caddy 承载自动签发有效 HTTPS 证书并回源反代，伪装度极高。
  - **VLESS-gRPC**：高并发低资源消耗，通过 Caddy 统一分流。
- **深度安全与凭证隔离**：
  - **UUID 完全隔离**：H2、gRPC 与 Reality 分别使用完全独立生成的 UUID，杜绝单点泄漏风险。
  - **Hy2 正规证书挂载**：自动挂载 Caddy 申请的正规 Let's Encrypt / ZeroSSL 证书，拒绝高风险的 `insecure=1`，杜绝中间人攻击（MITM）。
  - **内核级加速**：脚本自动配置并开启 Linux 原生 **BBR 拥塞控制算法** 与 **FQ 队列调度**。
  - **企业级静态伪装站**：80/443 端口自动部署专业云服务落地页，无对应协议头直接访问回源网站。

---

## 📋 协议与端口规划

| 协议 | 监听端口 | 传输层 / 流控 | 适用场景与安全定位 |
| :--- | :--- | :--- | :--- |
| **VLESS-Reality** | `8443` (TCP) | TCP (`xtls-rprx-vision`) | **主力首选**：借用大厂证书，免自备域名证书，抗主动探测极强 |
| **Hysteria 2** | `8444` (UDP) | QUIC (UDP) | **网络加速**：抗弱网恶劣丢包，挂载正规 SSL 证书安全通信 |
| **VLESS-H2** | `443` (TCP) | HTTP/2 (TLS) | **双保险伪装**：Caddy 自动申请合法证书反代，企业站路径分流 |
| **VLESS-gRPC** | `443` (TCP) | gRPC (TLS) | **低延迟并发**：Caddy 反代分流，与 H2 共享 443 端口 |

---

## 🚀 极简一行命令安装与管理 (推荐)

在全新的 VPS 终端中，切换至 `root` 权限后直接运行：

### 1. 一键全自动安装
```bash
bash <(curl -fsSL https://sci.zdxq.xyz)
```

### 2. 一键彻底清理卸载
```bash
bash <(curl -fsSL https://sci.zdxq.xyz/un)
```
*(或 `bash <(curl -fsSL https://sci.zdxq.xyz/uninstall)`)*

---

## 💻 传统安装部署方式（从源码/脚本运行）

```bash
# 赋予脚本执行权限
chmod +x install.sh uninstall.sh

# 运行安装部署
sudo ./install.sh

# 卸载清理
sudo ./uninstall.sh
```

---

## ⚠️ 准备工作与防火墙配置

1. **操作系统**：推荐 Debian 11/12 或 Ubuntu 20.04/22.04/24.04。
2. **域名解析**：在 Cloudflare 添加一条 A 记录指向 VPS 公网 IP（**请勿开启橙色云朵 CDN**，使用仅 DNS 解析模式）。
3. **防火墙/安全组端口开放**：
   - `TCP 80` & `TCP 443`（Caddy 自动证书申请与 HTTPS 伪装）
   - `TCP 8443`（Reality 直连，如自定义请放行对应端口）
   - `UDP 8444`（Hysteria 2，**务必放行 UDP**）

---

## 📖 常用运维与调试命令

| 任务 | 命令 |
| :--- | :--- |
| **查看节点链接与连接凭据** | `cat /etc/sing-box/node_info.txt` |
| **查看 Sing-Box 实时运行日志** | `journalctl -u sing-box -f` |
| **查看 Caddy 状态与证书申请日志** | `systemctl status caddy` 或 `journalctl -u caddy -f` |
| **重启 Sing-Box 服务** | `systemctl restart sing-box` |
| **重启 Caddy 服务** | `systemctl restart caddy` |
| **编辑 Sing-Box 主配置文件** | `nano /etc/sing-box/config.json` |
| **编辑 Caddy 配置文件** | `nano /etc/caddy/Caddyfile` |

---

## 📱 推荐客户端

* **Windows**：[v2rayN](https://github.com/2dust/v2rayN)、[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)、[Sing-box 原生客户端](https://github.com/SagerNet/sing-box/releases)
* **Android**：[NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid)、[Sing-box](https://github.com/SagerNet/sing-box/releases)
* **macOS**：[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)、[Sing-box](https://github.com/SagerNet/sing-box/releases)
* **iOS**：Shadowrocket、Loon、Stash、Sing-box

---

## ⚠️ 免责声明

本项目仅供网络技术研究与学术测试使用。请遵循当地法律法规合理使用云服务器资源。