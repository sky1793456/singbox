#!/bin/bash
# 修复版：一键部署 VLESS + Reality，并创建 sb 菜单管理命令

set -e

CONFIG_DIR="/etc/sing-box"
QR_PATH="$CONFIG_DIR/qrcode/vless_reality.png"
URL_PATH="$CONFIG_DIR/qrcode/vless_reality.txt"
LOG_PATH="$CONFIG_DIR/log/access.log"

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 运行本脚本！" && exit 1

echo "[*] 安装依赖..."
apt update -y
apt install -y curl wget jq qrencode uuid-runtime iptables

echo "[*] 下载最新 Sing-box..."
ARCH=$(uname -m)
[[ $ARCH == "x86_64" ]] && ARCH="amd64"
[[ $ARCH == "aarch64" ]] && ARCH="arm64"
VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
URL="https://github.com/SagerNet/sing-box/releases/download/${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz"
mkdir -p /tmp/singbox && cd /tmp/singbox
curl -LO "$URL" && tar -xzf sing-box-*.tar.gz
install -m 755 sing-box*/sing-box /usr/local/bin/sing-box

echo "[*] 创建配置..."
mkdir -p $CONFIG_DIR/{log,qrcode}
UUID=$(uuidgen)
KEYS=$(sing-box generate reality-key)
PRIVATE_KEY=$(echo "$KEYS" | grep PrivateKey | cut -d ' ' -f2)
PUBLIC_KEY=$(echo "$KEYS" | grep PublicKey | cut -d ' ' -f2)
SHORT_ID=$(head /dev/urandom | tr -dc a-f0-9 | head -c 8)
SNI="www.bing.com"
DOMAIN=$(curl -s ipv4.ip.sb)
TAG="skydoing-vless-reality"

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
    { "type": "direct" },
    { "type": "block", "tag": "block" }
  ]
}
EOF

echo "[*] 创建 systemd 服务..."
cat > /etc/systemd/system/sing-box.service <<EOF
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

echo "[*] 生成链接与二维码..."
VLESS_URL="vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${SNI}#${TAG}"
echo "$VLESS_URL" > "$URL_PATH"
qrencode -o "$QR_PATH" "$VLESS_URL"

echo "[*] 安装菜单命令：sb"
cat > /usr/bin/sb << 'EOF'
#!/bin/bash
CONFIG_DIR="/etc/sing-box"
QR_PATH="$CONFIG_DIR/qrcode/vless_reality.png"
URL_PATH="$CONFIG_DIR/qrcode/vless_reality.txt"
LOG_PATH="$CONFIG_DIR/log/access.log"

show_qr_terminal() {
  if [[ -f "$URL_PATH" ]]; then
    echo -e "\n二维码如下（请扫码）：\n"
    cat "$URL_PATH" | qrencode -t ansiutf8
  else
    echo "未生成二维码，请先部署节点。"
  fi
}

view_link() {
  [[ -f "$URL_PATH" ]] && cat "$URL_PATH" || echo "未找到链接。"
}

view_log() {
  [[ -f "$LOG_PATH" ]] && tail -n 50 "$LOG_PATH" || echo "暂无日志。"
}

restart_singbox() {
  systemctl restart sing-box && echo "Sing-box 已重启"
}

status_singbox() {
  systemctl status sing-box
}

open_firewall_port() {
  PORT=$(jq -r '.inbounds[0].port' "$CONFIG_DIR/config.json" 2>/dev/null)
  [[ -z "$PORT" ]] && echo "无法读取端口。" && return
  echo "[*] 当前监听端口：$PORT"
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  ip6tables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  echo "✅ 端口 $PORT 已放行"
}

while true; do
  clear
  echo "======= Sing-box 管理菜单（sb）======="
  echo "1. 查看节点链接"
  echo "2. 显示二维码（终端扫码）"
  echo "3. 查看最近日志"
  echo "4. 重启 Sing-box"
  echo "5. 查看服务状态"
  echo "6. 自动放行端口"
  echo "7. 退出"
  echo
  read -rp "请输入选项 [1-7]: " opt
  case $opt in
    1) view_link ;;
    2) show_qr_terminal ;;
    3) view_log ;;
    4) restart_singbox ;;
    5) status_singbox ;;
    6) open_firewall_port ;;
    7) echo "再见！" && exit 0 ;;
    *) echo "无效选项。" && sleep 1 ;;
  esac
  echo -e "\n按任意键继续..."
  read -n 1
done
EOF

chmod +x /usr/bin/sb

echo
echo "✅ 安装完成！你现在可以运行命令：sb"
echo "📌 节点链接如下："
cat "$URL_PATH"
