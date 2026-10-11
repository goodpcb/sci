#!/usr/bin/env bash
# ==============================================================================
# Sing-Box (>=1.14) + Caddy 生产加固版全自动部署脚本 (v5)
# 针对痛点强化:
#  1. GitHub API / Release 镜像 Fallback 下载机制
#  2. 核心配置文件与凭证严格设为 600/700 权限
#  3. systemd 启动前增加 sing-box check 预检防护
#  4. 内置 sb-sync-cert 证书热同步与一键状态切换命令
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
echo " Sing-Box (1.14+) + Caddy 生产加固版 (集成 Fallback & 权限加固)   "
echo "=================================================================="
echo ""

read -rp "1. 请输入解析到本 VPS 的域名 (例如: node.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && err "域名不能为空！"

read -rp "2. 请输入 H2 反代伪装路径 (默认回车: /rayh2): " H2_PATH
H2_PATH=${H2_PATH:-"/rayh2"}
[[ "$H2_PATH" != /* ]] && H2_PATH="/$H2_PATH"

read -rp "3. 请输入 gRPC 服务名 (默认回车: vless-grpc): " GRPC_SERVICE
GRPC_SERVICE=${GRPC_SERVICE:-"vless-grpc"}

read -rp "4. 请输入 Reality 监听端口 (默认回车: 8443): " REALITY_PORT
REALITY_PORT=${REALITY_PORT:-8443}

read -rp "5. 请输入 Reality 伪装域名/SNI (默认回车: addons.mozilla.org): " REALITY_DEST_DOMAIN
REALITY_DEST_DOMAIN=${REALITY_DEST_DOMAIN:-"addons.mozilla.org"}

read -rp "6. 请输入 Hysteria 2 监听端口 (UDP, 默认回车: 8444): " HY2_PORT
HY2_PORT=${HY2_PORT:-8444}

SERVER_IP=$(curl -s4m 8 ip.sb || curl -s4m 8 ifconfig.me || curl -s4m 8 api.ipify.org || echo "")
if [[ -z "$SERVER_IP" ]]; then
    read -rp "未能自动获取公网 IPv4，请输入本机外网 IP: " SERVER_IP
fi

# 1. 开启 BBR
info "配置系统内核参数 (BBR + FQ)..."
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1 || true

# 2. 基础软件依赖
info "更新软件源并安装基础工具..."
apt-get update -y && apt-get install -y curl jq tar openssl socat debian-keyring debian-archive-keyring apt-transport-https

# 3. 安装 Caddy
info "安装官方 Caddy..."
curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y && apt-get install -y caddy

# 4. 下载 Sing-Box (改进点 1: 带镜像 Fallback)
info "获取 Sing-Box 版本信息..."
LATEST_TAG=$(curl -s4m 8 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name 2>/dev/null || echo "")
if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
    warn "访问 GitHub API 失败或触发表率限制，启用固定默认版本 v1.14.0"
    LATEST_TAG="v1.14.0"
fi

SB_VER=${LATEST_TAG#v}
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"
MIRROR_URL="https://ghfast.top/${DOWNLOAD_URL}"

info "正在下载 Sing-Box $LATEST_TAG..."
if ! curl -Lo /tmp/sing-box.tar.gz --fail "$DOWNLOAD_URL"; then
    warn "官方 GitHub Releases 下载超时/失败，正在尝试通过镜像源加速下载..."
    curl -Lo /tmp/sing-box.tar.gz --fail "$MIRROR_URL" || err "Sing-box 核心下载失败，请检查网络！"
fi

tar -xzf /tmp/sing-box.tar.gz -C /tmp
mv /tmp/sing-box-${SB_VER}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/sing-box*

# 5. 生成凭证
info "生成各协议独立 UUID 及凭证..."
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

# 6. 伪装网页
mkdir -p /var/www/html
cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
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

# 7. 配置 Caddy
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

# 8. 轮询证书 (改进点 2: 严格 120 秒及全量 Fallback)
CERT_DIR="/etc/sing-box/cert"
mkdir -p "$CERT_DIR"

info "等待 Caddy 申请正式 SSL 证书 (最长 120 秒)..."
CADDY_CERT_FOUND=false
TIMEOUT=120
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    CERT_FILE=$(find /var/lib/caddy/.local/share/caddy/certificates -type f -name "$DOMAIN.crt" 2>/dev/null | head -n 1)
    KEY_FILE=$(find /var/lib/caddy/.local/share/caddy/certificates -type f -name "$DOMAIN.key" 2>/dev/null | head -n 1)
    if [[ -n "$CERT_FILE" && -n "$KEY_FILE" && -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then
        CADDY_CERT_FOUND=true
        break
    fi
    printf "\r[INFO] 正在申请/等待证书: 已耗时 %ds / %ds..." "$ELAPSED" "$TIMEOUT"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
echo ""

if [[ "$CADDY_CERT_FOUND" == "true" ]]; then
    info "成功获取 Caddy 正式证书，同步至 Sing-Box..."
    cp -L "$CERT_FILE" "$CERT_DIR/server.crt"
    cp -L "$KEY_FILE" "$CERT_DIR/server.key"
    H2_INSECURE_PARAM=""
    GRPC_INSECURE_PARAM=""
    HY2_INSECURE_PARAM=""
    CERT_STATUS_STR="已挂载正规正式证书 (严格校验抗 MITM)"
else
    warn "120 秒内未捕获到 Caddy 证书，启动自签名证书兜底！"
    warn "受影响节点链接将自动开启 allowInsecure 确保连通性。"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout "$CERT_DIR/server.key" \
      -out "$CERT_DIR/server.crt" \
      -days 3650 \
      -subj "/CN=$DOMAIN" \
      -addext "subjectAltName=DNS:$DOMAIN" >/dev/null 2>&1
    H2_INSECURE_PARAM="&allowInsecure=1"
    GRPC_INSECURE_PARAM="&allowInsecure=1"
    HY2_INSECURE_PARAM="&insecure=1"
    CERT_STATUS_STR="注意: 使用自签名证书兜底 (后续可通过 sb-sync-cert 升级为正式证书)"
fi

# 9. 生成配置文件
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

# 改进点 3: sing-box check 严格预检
info "正在执行 Sing-Box 配置语法严格预检..."
if ! /usr/local/bin/sing-box check -c /etc/sing-box/config.json; then
    err "Sing-Box 配置文件校验失败！已中断部署，请检查配置内容。"
fi
info "配置语法校验通过！"

# 10. 创建 systemd 服务
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

# 改进点 4: 注册 sb-sync-cert 证书热更新命令
cat << 'EOF' > /usr/local/bin/sb-sync-cert
#!/usr/bin/env bash
set -e
DOMAIN=$(grep -o '"server_name": *"[^"]*"' /etc/sing-box/config.json 2>/dev/null | head -n 1 | awk -F'"' '{print $4}')
[[ -z "$DOMAIN" ]] && { echo "[ERROR] 未能从 config.json 获取到域名配置！"; exit 1; }

echo "[INFO] 正在从 Caddy 存储目录检索 $DOMAIN 的正规证书..."
CERT_FILE=$(find /var/lib/caddy/.local/share/caddy/certificates -type f -name "$DOMAIN.crt" 2>/dev/null | head -n 1)
KEY_FILE=$(find /var/lib/caddy/.local/share/caddy/certificates -type f -name "$DOMAIN.key" 2>/dev/null | head -n 1)

if [[ -n "$CERT_FILE" && -n "$KEY_FILE" && -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then
    cp -L "$CERT_FILE" /etc/sing-box/cert/server.crt
    cp -L "$KEY_FILE" /etc/sing-box/cert/server.key
    chmod 644 /etc/sing-box/cert/server.crt
    chmod 600 /etc/sing-box/cert/server.key
    systemctl restart sing-box
    echo -e "\033[32m[SUCCESS] 正式证书已成功同步至 Sing-Box，服务已重启！客户端请关闭 allowInsecure/insecure 开关。\033[0m"
else
    echo -e "\033[31m[FAILED] Caddy 证书目录暂未发现已签发的正式证书，请检查 Caddy 运行状态或稍后再试。\033[0m"
fi
EOF
chmod +x /usr/local/bin/sb-sync-cert

# 改进点 2: 严格加固文件权限为 600 / 700
chmod 700 /etc/sing-box
chmod 700 /etc/sing-box/cert
chmod 600 /etc/sing-box/cert/server.key
chmod 644 /etc/sing-box/cert/server.crt
chmod 600 /etc/sing-box/config.json

# 拼接节点链接
LINK_HY2="hysteria2://${HY2_PASSWORD}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}${HY2_INSECURE_PARAM}#Hy2-${DOMAIN}"
LINK_REALITY="vless://${UUID_REALITY}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DEST_DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#Reality-${REALITY_DEST_DOMAIN}"
LINK_H2="vless://${UUID_H2}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=http&path=$(echo -n "$H2_PATH" | jq -sRr @uri)&host=${DOMAIN}${H2_INSECURE_PARAM}#${DOMAIN}-H2"
LINK_GRPC="vless://${UUID_GRPC}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=grpc&serviceName=${GRPC_SERVICE}${GRPC_INSECURE_PARAM}#${DOMAIN}-gRPC"

INFO_FILE="/etc/sing-box/node_info.txt"
cat << EOF > "$INFO_FILE"
==================================================================
              Sing-Box 节点配置与连接信息 (生产加固版)
==================================================================
主域名 (SNI):       $DOMAIN
VPS 公网 IP:        $SERVER_IP
H2 UUID (独立):     $UUID_H2
gRPC UUID (独立):   $UUID_GRPC
Reality UUID (独立):$UUID_REALITY
Hy2 强密码:         $HY2_PASSWORD
SSL 证书状态:       $CERT_STATUS_STR
Hy2 端口 (UDP):     $HY2_PORT
Reality 端口 (TCP): $REALITY_PORT
Reality 伪装 SNI:   $REALITY_DEST_DOMAIN
Reality 公钥:       $REALITY_PUBLIC_KEY
Reality Short ID:   $REALITY_SHORT_ID
------------------------------------------------------------------
[1] VLESS + Reality 节点 (主力首选 / 直连低延迟):
$LINK_REALITY

[2] Hysteria 2 节点 (UDP加速 / 晚高峰与拥塞优选):
$LINK_HY2

[3] VLESS + H2 节点 (Caddy TLS 443 伪装反代):
$LINK_H2

[4] VLESS + gRPC 节点 (Caddy TLS 443 伪装反代):
$LINK_GRPC
==================================================================
EOF
chmod 600 "$INFO_FILE"

clear
cat "$INFO_FILE"
echo ""
echo -e "${GREEN}配置已保存至文件: ${INFO_FILE} (权限已严格锁定为 600)${PLAIN}"
echo "若使用了自签证书兜底，待域名生效后随时运行 sb-sync-cert 即可升级正规证书！"