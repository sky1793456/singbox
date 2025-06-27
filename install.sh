#!/bin/bash
# Sing-box VLESS+Reality 一键部署脚本（官方稳定版 v1.11.14）
# 自动安装依赖，下载 sing-box，生成配置，启动服务，创建管理菜单 sb

set -e

CONFIG_DIR="/etc/sing-box"
QR_PATH="$CONFIG_DIR/qrcode/vless_reality.png"
URL_PATH="$CONFIG_DIR/qrcode/vless_reality.txt"
LOG_PATH="$CONFIG_DIR/log/access.log"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
VERSION="v1.11.14"

# 运行检查 root 权限
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 用户运行本脚本！"
  exit 1
fi

# 检测系统包管理器
if command -v apt &>/dev/null; then
  PKG_INSTALL="apt install -y"
  PKG_UPDATE="apt update -y"
elif command -v yum &>/dev/null; then
  PKG_INSTALL="yum install -y"
  PKG_UPDATE="yum makecache"
else
  echo "暂不支持当前操作系统，请手动安装依赖"
  exit 1
fi

echo "[*] 更新系统包索引..."
$PKG_UPDATE

echo "[*] 安装依赖..."
$PKG_INSTALL curl wget jq qrencode uuid-runtime iptables iptables-services

# 判断架构
ARCH=$(uname -m)
case $ARCH in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

echo "[*] 下载 sing-box ${VERSION}，架构: $ARCH"
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"

mkdir -p /tmp/singbox
cd /tmp/singbox
curl -fsSL -O "$DOWNLOAD_URL"

tar -xzf sing-box-*.tar.gz
install -m 755 sing-box*/sing-box /usr/local/bin/sing-box

echo "[*] 清理临时文件..."
cd ~
rm -rf /tmp/singbox

echo "[*] 创建配置目录..."
mkdir -p "$CONFIG_DIR"/{log,qrcode}

UUID=$(uuidgen)
KEYS=$(sing-box generate reality-key)
PRIVATE_KEY=$(echo "$KEYS" | awk '/PrivateKey/ {print $2}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey/ {print $2}')
SHORT_ID=$(head -c 16 /dev/urandom | xxd -p)
SNI="www.bing.com"
DOMAIN=$(curl -s ipv4.ip.sb)
TAG="skydoing-vless-reality"

echo "[*] 生成 sing-box 配置文件..."
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "level": "info",
    "output": "$LOG_PATH"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "port": 443,
      "tag": "vless-in",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "stream": {
        "network": "tcp",
        "security": "reality",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF

echo "[*] 创建 systemd 服务..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_DIR/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

echo "[*] 生成节点链接和二维码..."
VLESS_URL="vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${SNI}#${TAG}"
echo "$VLESS_URL" > "$URL_PATH"
qrencode -o "$QR_PATH" "$VLESS_URL"

echo "[*] 安装 sb 管理菜单脚本..."
cat > /usr/bin/sb << 'EOF'
#!/bin/bash
CONFIG_DIR="/etc/sing-box"
URL_PATH="$CONFIG_DIR/qrcode/vless_reality.txt"
LOG_PATH="$CONFIG_DIR/log/access.log"

view_link(){
  if [[ -f "$URL_PATH" ]]; then
    cat "$URL_PATH"
  else
    echo "链接不存在"
  fi
}

show_qr(){
  if [[ -f "$URL_PATH" ]]; then
    cat "$URL_PATH" | qrencode -t ansiutf8
  else
    echo "二维码未生成"
  fi
}

view_log(){
  if [[ -f "$LOG_PATH" ]]; then
    tail -n 50 "$LOG_PATH"
  else
    echo "暂无日志"
  fi
}

restart_singbox(){
  systemctl restart sing-box && echo "已重启 sing-box"
}

status_singbox(){
  systemctl status sing-box --no-pager
}

open_port(){
  PORT=$(jq -r '.inbounds[0].port' "/etc/sing-box/config.json")
  if [[ -z "$PORT" ]]; then
    echo "读取端口失败"
    return
  fi
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  ip6tables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  echo "已放行端口 $PORT"
}

while true; do
  clear
  cat <<EOM
====== sing-box 管理菜单 ======
1. 查看节点链接
2. 显示二维码（终端扫码）
3. 查看最近日志
4. 重启 sing-box
5. 查看服务状态
6. 自动放行端口
7. 退出
EOM
  read -rp "选择 [1-7]: " opt
  case $opt in
    1) view_link ;;
    2) show_qr ;;
    3) view_log ;;
    4) restart_singbox ;;
    5) status_singbox ;;
    6) open_port ;;
    7) exit 0 ;;
    *) echo "无效选项" ;;
  esac
  read -n1 -rsp $'按任意键继续...\n'
done
EOF

chmod +x /usr/bin/sb

echo -e "\n✅ 安装完成！运行 sb 命令启动管理菜单。"
echo "节点链接："
cat "$URL_PATH"
