# Sing-Box (>=1.14) + Caddy 生产加固版全功能套件

基于 **Sing-Box 官方最新版 (>=1.14)** 与 **Caddy v2** 的现代化 VPS 代理自动部署环境。已彻底解决 ACME 证书等待超时、自签 Fallback 节点失效以及管道流式执行截断等生产痛点。

本项目通过 **Cloudflare Workers** 域名（`sci.zdxq.xyz`）完成极简安全分发。

---

## 🛡️ 核心修复与安全加固

1. **防截断安全执行**：
   - 官方推荐命令采用先完整落盘校验再执行的方式，彻底杜绝网络抖动导致管道执行半截脚本引发系统损坏。
2. **ACME 轮询与证书容灾**：
   - 证书申请轮询时间放宽至 **120 秒** 并配有动态耗时显示，大幅降低 ACME 误判率。
   - 若极端情况下触发自签兜底，**统一为 H2、gRPC 注入 `allowInsecure=1`，为 Hy2 注入 `insecure=1`**，确保全部节点绝对开箱可用。
3. **凭据全面隔离**：
   - `VLESS-H2`、`VLESS-gRPC`、`VLESS-Reality` 全部采用**独立随机生成的 UUID**，杜绝单点配置泄漏风险。
4. **内核自动优化**：
   - 自动开启 Linux 原生 **BBR 拥塞控制算法** 与 **FQ 调度队列**。

---

## 📋 协议与端口规划

| 协议 | 监听端口 | 传输层 / 流控 | 适用场景与安全定位 |
| :--- | :--- | :--- | :--- |
| **VLESS-Reality** | `8443` (TCP) | TCP (`xtls-rprx-vision`) | **主力首选**：借用大厂证书，免自备域名证书，抗主动探测极强 |
| **Hysteria 2** | `8444` (UDP) | QUIC (UDP) | **网络加速**：抗弱网恶劣丢包，挂载正规 SSL 证书安全通信 |
| **VLESS-H2** | `443` (TCP) | HTTP/2 (TLS) | **双保险伪装**：Caddy 自动申请合法证书反代，企业站路径分流 |
| **VLESS-gRPC** | `443` (TCP) | gRPC (TLS) | **低延迟并发**：Caddy 反代分流，与 H2 共享 443 端口 |

---

## 🚀 极简安全安装命令 (推荐)

采用**下载完整落盘 + 确认无误再执行**的两步式防截断调用：

### 1. 一键全自动安装
```bash
curl -fsSL https://sci.zdxq.xyz -o install.sh && bash install.sh
```

### 2. 一键彻底清理卸载
```bash
curl -fsSL https://sci.zdxq.xyz/un -o uninstall.sh && bash uninstall.sh
```

---

## ⚠️ 准备工作与防火墙配置

1. **操作系统**：推荐 Debian 11/12 或 Ubuntu 20.04/22.04/24.04。
2. **域名解析**：在 Cloudflare 添加一条 A 记录指向 VPS 公网 IP（**请勿开启橙色云朵 CDN**，使用仅 DNS 解析模式）。
3. **防火墙/安全组端口开放**：
   - `TCP 80` & `TCP 443`（Caddy 自动证书申请与 HTTPS 伪装）
   - `TCP 8443`（Reality 直连）
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
