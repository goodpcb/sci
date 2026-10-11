#!/usr/bin/env bash
# ==============================================================================
# Sing-Box + Caddy 一键彻底卸载与清理脚本
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${YELLOW}警告: 此操作将彻底停止并删除 Sing-Box、Caddy、配置及伪装网页！${PLAIN}"
read -rp "确认彻底卸载吗？(y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "已取消卸载。"
    exit 0
fi

echo -e "${GREEN}[1/5] 停止系统守护服务...${PLAIN}"
systemctl stop sing-box 2>/dev/null || true
systemctl disable sing-box 2>/dev/null || true
systemctl stop caddy 2>/dev/null || true
systemctl disable caddy 2>/dev/null || true

echo -e "${GREEN}[2/5] 移除 Sing-Box 核心文件与配置...${PLAIN}"
rm -f /usr/local/bin/sing-box
rm -f /etc/systemd/system/sing-box.service
rm -rf /etc/sing-box

echo -e "${GREEN}[3/5] 卸载 Caddy 软件包与配置...${PLAIN}"
apt-get purge -y caddy 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
rm -rf /etc/caddy
rm -rf /var/lib/caddy
rm -f /etc/apt/sources.list.d/caddy-stable.list
rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg

echo -e "${GREEN}[4/5] 清理伪装网页与临时文件...${PLAIN}"
rm -rf /var/www/html

echo -e "${GREEN}[5/5] 重新加载 systemd 进程...${PLAIN}"
systemctl daemon-reload

echo -e "${GREEN}卸载与清理完成！VPS 已恢复初始状态。${PLAIN}"
