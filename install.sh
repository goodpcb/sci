#!/usr/bin/env bash
# ==============================================================================
# Sing-Box (>=1.14) + Caddy + VLESS (H2/gRPC/Reality) + Hysteria 2 全自动加固部署脚本
# 系统支持: Debian 11+/12+ 或 Ubuntu 20.04+/22.04+/24.04+
# 安全加固版:
#  1. 凭据隔离: H2, gRPC, Reality 分别使用完全独立独立的 UUID
#  2. 证书联动: Hy2 自动挂载 Caddy 申请的正规 Let's Encrypt / ZeroSSL 证书 (拒绝 insecure=1)
#  3. 内核优化: 自动开启 TCP BBR 与 fq 拥塞控制
#  4. 证书健康巡检: 包含证书就绪轮询机制与自动兜底
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

function info() { echo -e "${GREEN}[INFO] $1${PLAIN}"; }
function warn() { echo -e "${YELLOW}[WARN] $1${PLAIN}"; }
function err() { echo -e "${RED}[ERROR] $1${PLAIN}"; exit 1; }

[[ $EUID -ne 0 ]] && err "请使用 root 权限运行此脚本！"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) SB_ARCH="amd64" ;;
    aarch64) SB_ARCH="arm64" ;;
    armv7l) SB_ARCH="armv7" ;;
    *) err "不支持的系统架构: $ARCH" ;;
esac

clear
echo "=================================================================="
echo " Sing-Box (1.14+) + Caddy 安全加固版全功能自动部署脚本            "
echo "=================================================================="
echo ""

# 域名与基础配置
read -rp "1. 请输入解析到本 VPS 的域名 (例如: node.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && err "域名不能为空！"

read -rp "2. 请输入 H2 反代伪装路径 (默认回车: /rayh2): " H2_PATH
H2_PATH=${H2_PATH:-"/rayh2"}
[[ "$H2_PATH" != /* ]] && H2_PATH="/$H2_PATH"

read -rp "3. 请输入 gRPC 服务名 (默认回车: vless-grpc): " GRPC_SERVICE
GRPC_SERVICE=${GRPC_SERVICE:-"vless-grpc"}

# Reality 配置
echo ""
echo "------------------- Reality 节点参数 -------------------"
read -rp "4. 请输入 Reality 监听端口 (默认回车: 8443): " REALITY_PORT
REALITY_PORT=${REALITY_PORT:-8443}

read -rp "5. 请输入 Reality 伪装域名/SNI (默认回车: addons.mozilla.org): " REALITY_DEST_DOMAIN
REALITY_DEST_DOMAIN=${REALITY_DEST_DOMAIN:-"addons.mozilla.org"}

# Hysteria 2 配置
echo ""
echo "------------------- Hysteria 2 节点参数 -------------------"
read -rp "6. 请输入 Hysteria 2 监听端口 (UDP, 默认回车: 8444): " HY2_PORT
HY2_PORT=${HY2_PORT:-8444}

# 获取 VPS 公网 IP
SERVER_IP=$(curl -s4m 8 ip.sb || curl -s4m 8 ifconfig.me || curl -s4m 8 api.ipify.org || echo "")
if [[ -z "$SERVER_IP" ]]; then
    read -rp "未能自动获取公网 IPv4，请输入本机外网 IP: " SERVER_IP
fi

# 1. 内核优化：开启 BBR
info "优化系统内核网络参数 (开启 BBR & FQ)..."
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1 || true

# 2. 安装基础依赖
info "更新源并安装依赖 (curl, jq, tar, openssl, socat)..."
apt-get update -y && apt-get install -y curl jq tar openssl socat debian-keyring debian-archive-keyring apt-transport-https

# 3. 安装 Caddy
info "安装官方最新 Caddy..."
curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y && apt-get install -y caddy

# 4. 下载安装 Sing-Box (>=1.14)
info "获取 Sing-Box 最新版本..."
LATEST_TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
[[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]] && LATEST_TAG="v1.14.0"

info "下载并安装 Sing-Box $LATEST_TAG ($SB_ARCH)..."
SB_VER=${LATEST_TAG#v}
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"

curl -Lo /tmp/sing-box.tar.gz "$DOWNLOAD_URL"
tar -xzf /tmp/sing-box.tar.gz -C /tmp
mv /tmp/sing-box-${SB_VER}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/sing-box*

# 5. 安全加固：凭据相互隔离
info "安全加固: 生成各协议完全隔离的凭证与密钥..."
UUID_H2=$(cat /proc/sys/kernel/random/uuid)
UUID_GRPC=$(cat /proc/sys/kernel/random/uuid)
UUID_REALITY=$(cat /proc/sys/kernel/random/uuid)
HY2_PASSWORD=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9')
H2_PORT=10001
GRPC_PORT=10002

KEY_PAIR=$(/usr/local/bin/sing-box generate reality-keypair)
REALITY_PRIVATE_KEY=$(echo "$KEY_PAIR" | grep -i "PrivateKey:" | awk '{print $2}')
REALITY_PUBLIC_KEY=$(echo "$KEY_PAIR" | grep -i "PublicKey:" | awk '{print $2}')
REALITY_SHORT_ID=$(openssl rand -hex 8)

# 6. 部署伪装网页
info "部署伪装静态网站..."
mkdir -p /var/www/html
cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Edge Acceleration & Cloud Services</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background-color: #f1f5f9; color: #334155; margin: 0; display: flex; justify-content: center; align-items: center; height: 100vh; }
        .card { background: #ffffff; padding: 2.5rem; border-radius: 12px; box-shadow: 0 10px 15px -3px rgba(0,0,0,0.1); max-width: 480px; width: 100%; text-align: center; }
        h1 { font-size: 1.4rem; color: #0f172a; margin-bottom: 0.5rem; }
        p { font-size: 0.95rem; color: #64748b; line-height: 1.6; }
        .status { display: inline-block; padding: 0.3rem 0.8rem; background-color: #ecfdf5; color: #059669; border-radius: 9999px; font-size: 0.8rem; font-weight: 600; margin-top: 1.2rem; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Cloud Delivery Gateway</h1>
        <p>This edge cluster provides global asset distribution, caching optimizations, and routing infrastructure.</p>
        <span class="status">● All Systems Operational</span>
    </div>
</body>
</html>
EOF

# 7. 配置 Caddyfile 并启动以申请正式 SSL 证书
info "配置 Caddy 并申请正式 HTTPS 证书..."
cat << EOF > /etc/caddy/Caddyfile
$DOMAIN {
    root * /var/www/html
    file_server

    @grpc {
        header Content-Type application/grpc*
        path /$GRPC_SERVICE/*
    }
    reverse_proxy @grpc 127.0.0.1:$GRPC_PORT {
        transport http {
            versions h2c 2
        }
    }

    @h2 {
        path $H2_PATH
    }
    reverse_proxy @h2 127.0.0.1:$H2_PORT {
        transport http {
            versions h2c 2
        }
    }
}
EOF

systemctl daemon-reload
systemctl enable --now caddy
systemctl restart caddy

CERT_DIR="/etc/sing-box/cert"
mkdir -p "$CERT_DIR"

info "正在验证 Caddy 证书申请状态..."
# 等待 Caddy 申请证书 (最多等待 25 秒)
CADDY_CERT_FOUND=false
for i in {1..25}; do
    CERT_FILE=$(find /var/lib/caddy/.local/share/caddy/certificates -type f -name "$DOMAIN.crt" 2>/dev/null | head -n 1)
    KEY_FILE=$(find /var/lib/caddy/.local/share/caddy/certificates -type f -name "$DOMAIN.key" 2>/dev/null | head -n 1)
    if [[ -n "$CERT_FILE" && -n "$KEY_FILE" && -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then
        CADDY_CERT_FOUND=true
        break
    fi
    sleep 1
done

if [[ "$CADDY_CERT_FOUND" == "true" ]]; then
    info "成功捕获 Caddy 正规正式 SSL 证书！同步至 Sing-Box..."
    cp -L "$CERT_FILE" "$CERT_DIR/server.crt"
    cp -L "$KEY_FILE" "$CERT_DIR/server.key"
    chmod 644 "$CERT_DIR/server.crt"
    chmod 600 "$CERT_DIR/server.key"
    HY2_INSECURE_PARAM=""
    HY2_INSECURE_NOTE="启用严格校验证书 (抗中间人攻击)"
else
    warn "未能在限定时间内直接获取 Caddy 签发证书 (可能 ACME 速率限制或 DNS 解析刚生效)。"
    info "临时启用高质量 ECC 自签名证书兜底，可在证书生效后随时执行同步..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout "$CERT_DIR/server.key" \
      -out "$CERT_DIR/server.crt" \
      -days 3650 \
      -subj "/CN=$DOMAIN" \
      -addext "subjectAltName=DNS:$DOMAIN" >/dev/null 2>&1
    chmod 644 "$CERT_DIR/server.crt"
    chmod 600 "$CERT_DIR/server.key"
    HY2_INSECURE_PARAM="&insecure=1"
    HY2_INSECURE_NOTE="当前使用备用证书 (insecure=1)"
fi

# 8. 生成 Sing-Box 配置文件 (隔离各用户凭据)
info "生成 Sing-Box 配置文件..."
mkdir -p /etc/sing-box
cat << EOF > /etc/sing-box/config.json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-h2-in",
      "listen": "127.0.0.1",
      "listen_port": $H2_PORT,
      "users": [
        {
          "uuid": "$UUID_H2",
          "flow": ""
        }
      ],
      "transport": {
        "type": "http",
        "host": [
          "$DOMAIN"
        ],
        "path": "$H2_PATH"
      }
    },
    {
      "type": "vless",
      "tag": "vless-grpc-in",
      "listen": "127.0.0.1",
      "listen_port": $GRPC_PORT,
      "users": [
        {
          "uuid": "$UUID_GRPC",
          "flow": ""
        }
      ],
      "transport": {
        "type": "grpc",
        "service_name": "$GRPC_SERVICE"
      }
    },
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "uuid": "$UUID_REALITY",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_DEST_DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_DEST_DOMAIN",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "password": "$HY2_PASSWORD"
        }
      ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# 9. 创建守护进程并启动
info "创建 systemd 服务守护..."
cat << EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box
systemctl restart sing-box

# 构建独立链接
LINK_HY2="hysteria2://${HY2_PASSWORD}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}${HY2_INSECURE_PARAM}#Hy2-${DOMAIN}"
LINK_REALITY="vless://${UUID_REALITY}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DEST_DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#Reality-${REALITY_DEST_DOMAIN}"
LINK_H2="vless://${UUID_H2}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=http&path=$(echo -n "$H2_PATH" | jq -sRr @uri)&host=${DOMAIN}#${DOMAIN}-H2"
LINK_GRPC="vless://${UUID_GRPC}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=grpc&serviceName=${GRPC_SERVICE}#${DOMAIN}-gRPC"

# 保存并输出配置信息
INFO_FILE="/etc/sing-box/node_info.txt"
cat << EOF > "$INFO_FILE"
==================================================================
              Sing-Box 节点配置与连接信息 (安全加固版)
==================================================================
主域名 (SNI):       $DOMAIN
VPS 公网 IP:        $SERVER_IP
H2 UUID (独立):     $UUID_H2
gRPC UUID (独立):   $UUID_GRPC
Reality UUID (独立):$UUID_REALITY
Hy2 强密码:         $HY2_PASSWORD
Hy2 证书状态:       $HY2_INSECURE_NOTE
Hy2 端口 (UDP):     $HY2_PORT
Reality 端口 (TCP): $REALITY_PORT
Reality 伪装 SNI:   $REALITY_DEST_DOMAIN
Reality 公钥:       $REALITY_PUBLIC_KEY
Reality Short ID:   $REALITY_SHORT_ID
------------------------------------------------------------------
[1] VLESS + Reality 节点 (主力推荐 / 直连低延迟):
$LINK_REALITY

[2] Hysteria 2 节点 (UDP加速 / 晚高峰与拥塞优选):
$LINK_HY2

[3] VLESS + H2 节点 (Caddy TLS 443 伪装反代):
$LINK_H2

[4] VLESS + gRPC 节点 (Caddy TLS 443 伪装反代):
$LINK_GRPC
==================================================================
EOF

clear
cat "$INFO_FILE"
echo ""
echo -e "${GREEN}配置已保存至文件: ${INFO_FILE}${PLAIN}"
echo "日常查看节点信息命令: cat ${INFO_FILE}"
