#!/bin/bash
# 修复版：一键部署 VLESS + Reality，并创建 sb 管理菜单
# 使用官方稳定版本 sing-box

set -e

CONFIG_DIR="/etc/sing-box"
QR_PATH="$CONFIG_DIR/qrcode/vless_reality.png"
URL_PATH="$CONFIG_DIR/qrcode/vless_reality.txt"
LOG_PATH="$CONFIG_DIR/log/access.log"

# 确保以 root 运行
if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行本脚本！"
  exit 1
fi

echo "[*] 安装依赖..."
apt update -y
apt install -y curl wget jq qrencode uuid-runtime iptables

echo "[*] 获取最新 Sing-box 版本..."
ARCH=$(uname -m)
[[ $ARCH == "x86_64" ]] && ARCH="amd64"
[[ $ARCH == "aarch64" ]] && ARCH="arm64"
VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)

# 下载 URL（使用带 v 前缀的完整版本号）
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz"
echo "[*] 下载：$DOWNLOAD_URL"
mkdir -p /tmp/singbox && cd /tmp/singbox
curl -fsSL -O "$DOWNLOAD_URL"
tar -xzf sing-box-*.tar.gz
install -m 755 sing-box*/sing-box /usr/local/bin/sing-box

echo "[*] 构建配置..."
mkdir -p $CONFIG_DIR/{log,qrcode}
UUID=$(uuidgen)
KEYS=$(sing-box generate reality-key)
PRIVATE_KEY=$(echo "$KEYS" | awk '/PrivateKey/ {print $2}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey/ {print $2}')
SHORT_ID=$(head /dev/urandom | tr -dc a-f0-9 | head -c 8)
SNI="www.bing.com"
DOMAIN=$(curl -s ipv4.ip.sb)
TAG="skydoing-vless-reality"

cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {"level":"info","output":"$LOG_PATH"},
  "inbounds":[
    {
      "type":"vless",
      "listen":"0.0.0.0",
      "port":443,
      "tag":"vless-in",
      "settings":{
        "clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],
        "decryption":"none"
      },
      "stream":{
        "network":"tcp",
        "security":"reality",
        "reality":{
          "enabled":true,
          "handshake":{"server":"$SNI","server_port":443},
          "private_key":"$PRIVATE_KEY",
          "short_id":["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds":[{"type":"direct"},{"type":"block","tag":"block"}]
}
EOF

echo "[*] 设置 systemd 服务..."
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

echo "[*] 生成节点链接与二维码..."
VLESS_URL="vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${SNI}#${TAG}"
echo "$VLESS_URL" > "$URL_PATH"
qrencode -o "$QR_PATH" "$VLESS_URL"

echo "[*] 安装 sb 管理脚本..."
cat > /usr/bin/sb << 'SCRIPT'
#!/bin/bash
CONFIG_DIR="/etc/sing-box"
URL_PATH="$CONFIG_DIR/qrcode/vless_reality.txt"
LOG_PATH="$CONFIG_DIR/log/access.log"

view_link(){ [[ -f "$URL_PATH" ]] && cat "$URL_PATH" || echo "链接不存在"; }

show_qr(){
  [[ -f "$URL_PATH" ]] && cat "$URL_PATH" | qrencode -t ansiutf8 || echo "二维码未生成"
}

view_log(){
  [[ -f "$LOG_PATH" ]] && tail -n 50 "$LOG_PATH" || echo "暂无日志"
}

restart_singbox(){
  systemctl restart sing-box && echo "已重启 sing-box"
}

status_singbox(){
  systemctl status sing-box
}

open_port(){
  PORT=$(jq -r '.inbounds[0].port' "/etc/sing-box/config.json")
  [[ -z "$PORT" ]] && { echo "读取端口失败"; return; }
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
    7) exit ;;
    *) echo "无效";;
  esac
  read -n1 -p "按任意键继续…"
done
SCRIPT

chmod +x /usr/bin/sb

echo
echo "✅ 安装完成！执行 sb 启动管理菜单。"
echo "节点链接："
cat "$URL_PATH"
