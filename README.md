# Sing-Box (>=1.14) + Caddy 安全加固版多协议全套组件

针对审查环境优化的 Linux VPS 代理自动部署套件。基于 **Sing-Box 官方最新版 (>=1.14)** 与 **Caddy v2**，集成了当今最主流的抗封锁协议，并完成了深度安全加固。

---

## 🛡️ 核心安全性升级

1. **凭证彻底隔离**：
   - `VLESS-H2`、`VLESS-gRPC`、`VLESS-Reality` 全部采用**独立随机生成的 UUID**，杜绝单节点凭据泄漏导致的全盘暴露。
2. **Hysteria 2 正规证书挂载**：
   - 自动联动 Caddy 申请的 Let's Encrypt / ZeroSSL 正规证书，不再需要开启高风险的 `insecure=1` 跳过校验，杜绝中间人攻击（MITM）。
3. **内核级网络加速**：
   - 脚本自动配置开启 Linux 内核 **BBR 拥塞控制算法** 与 **FQ 队列调度**。
4. **多层伪装体系**：
   - **443 端口**：部署静态企业级 Web 站点，主域名正常对外展示。
   - **Reality 端口**：借用大型正规境外网站证书，避免主动探测暴露。

---

## 📋 协议与端口规划

| 协议 | 端口 | 传输层 | 安全特性 / 推荐定位 |
| :--- | :--- | :--- | :--- |
| **VLESS-Reality** | `8443` (TCP) | TCP (Vision) | **日常主力推荐**：真实海外网站 SNI 借用，抗主动探测最强 |
| **Hysteria 2** | `8444` (UDP) | QUIC (UDP) | **恶劣网络优选**：自研拥塞控制，抗弱网丢包，正规证书保护 |
| **VLESS-H2** | `443` (TCP) | HTTP/2 (TLS) | **高隐蔽双保险**：Caddy 正规证书反代，路径分流伪装 |
| **VLESS-gRPC** | `443` (TCP) | gRPC (TLS) | **高并发低损耗**：Caddy 反代分流，与 H2 并存 |

---

## 🚀 快速安装部署

### 前提条件
1. 系统：Debian 11/12 或 Ubuntu 20.04/22.04/24.04。
2. 域名：已将 A 记录解析到当前 VPS 公网 IP（Cloudflare 关闭小云朵，仅 DNS 解析）。
3. 防火墙放行：
   - `TCP 80` & `TCP 443` (Caddy Web 伪装与证书申请)
   - `TCP 8443` (Reality 直连)
   - `UDP 8444` (Hysteria 2，**务必放行 UDP**)

### 本地直接运行
```bash
chmod +x install.sh uninstall.sh
sudo ./install.sh
```

### GitHub 托管远程一行安装
将代码推送到你的 GitHub 仓库（设为 Public）后：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/<你的仓库名>/main/install.sh)
```

---

## 🛠️ 常用运维指令

```bash
# 查看所有节点链接与详细凭据
cat /etc/sing-box/node_info.txt

# 查看 Sing-Box 实时运行日志
journalctl -u sing-box -f

# 服务重启 / 状态
systemctl restart sing-box
systemctl restart caddy
systemctl status sing-box
```

---

## 🗑️ 彻底卸载

运行专用的清理脚本，可完整清除 Sing-Box 核心、Caddy 软件包、所有证书与静态网页：
```bash
sudo ./uninstall.sh
```
