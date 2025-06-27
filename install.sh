#!/bin/bash
# 一键部署 Sing-box VLESS+Reality —— 支持 .tar.gz/.tar.xz 资产，跨 Debian/Ubuntu/Alma/Rocky

set -e

CONFIG_DIR="/etc/sing-box"
QR_PATH="$CONFIG_DIR/qrcode/vless_reality.png"
URL_PATH="$CONFIG_DIR/qrcode/vless_reality.txt"
LOG_PATH="$CONFIG_DIR/log/access.log"
BIN_PATH="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# 1. 检查 root
[[ $EUID -ne 0 ]] && { echo "请用 root 运行"; exit 1; }

# 2. 检测系统
echo "[*] 检测系统类型..."
. /etc/os-release
OS_ID=$ID
echo "    → $NAME ($OS_ID) $VERSION_ID"

install_deps_debian() {
  apt update -y && apt upgrade -y
  apt install -y curl wget jq qrencode uuid-runtime xz-utils iptables
}

install_deps_rhel() {
  if command -v dnf &>/dev/null; then
    dnf update -y
    dnf install -y curl wget jq qrencode uuid libuuid iptables-services xz
  else
    yum update -y
    yum install -y curl wget jq qrencode uuid libuuid iptables-services xz
  fi
}

case "$OS_ID" in
  ubuntu|debian) install_deps_debian ;;
  almalinux|rocky|centos|rhel) install_deps_rhel ;;
  *) echo "不支持的系统：$OS_ID" && exit 1 ;;
esac

# 3. 获取最新版本和对应资产下载链接
echo "[*] 获取最新 Sing-box 版本和下载链接..."
ARCH=$(uname -m)
[[ $ARCH == "x86_64" ]] && ARCH="amd64"
[[ $ARCH =~ ^(aarch64|arm64)$ ]] && ARCH="arm64"

read -r VER DOWNLOAD_URL <<EOF
$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
  | jq -r --arg arch "$ARCH" '.tag_name + " " +
      (.assets[] 
       | select(.name | test("linux.*" + $arch + "\\.(tar\\.gz|tar\\.xz)$")) 
       | .browser_download_url)
  ')
EOF

[[ -z "$DOWNLOAD_URL" ]] && { echo "❌ 未找到下载链接，请检查架构"; exit 1; }

echo "    → 版本: $VER"
echo "    → 链接: $DOWNLOAD_URL"

# 4. 下载并解压
echo "[*] 下载并安装 Sing-box..."
TMP="/tmp/singbox"
rm -rf "$TMP" && mkdir -p "$TMP" && cd "$TMP"
curl -fsSL -o package "$DOWNLOAD_URL"

# 根据后缀选择解压方式
if [[ "$DOWNLOAD_URL" == *.tar.gz ]]; then
  tar -xzf package
elif [[ "$DOWNLOAD_URL" == *.tar.xz ]]; then
  tar -xJf package
else
  echo "❌ 无法识别压缩格式" && exit 1
fi

install -m 755 sing-box*/sing-box "$BIN_PATH"

# 5. 生成配置
echo "[*] 生成 VLESS+Reality 配置..."
mkdir -p "$CONFIG_DIR"/{log,qrcode}
UUID=$(uuidgen)
KEYS=$("$BIN_PATH" generate reality-key)
PRIVATE_KEY=$(echo "$KEYS" | awk '/PrivateKey/ {print $2}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey/ {print $2}')
SHORT_ID=$(head -c16 /dev/urandom | xxd -p -c16)
SNI="www.bing.com"
DOMAIN=$(curl -s ipv4.ip.sb)
TAG="skydoing-vless-reality"

cat >"$CONFIG_DIR/config.json" <<EOF
{
  "log": {"level":"info","output":"$LOG_PATH"},
  "inbounds":[
    {
      "type":"vless","listen":"0.0.0.0","port":443,"tag":"vless-in",
      "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
      "stream":{"network":"tcp","security":"reality",
        "reality":{"enabled":true,"handshake":{"server":"$SNI","server_port":443},
                   "private_key":"$PRIVATE_KEY","short_id":["$SHORT_ID"]}}
    }
  ],
  "outbounds":[{"type":"direct"},{"type":"block","tag":"block"}]
}
EOF

# 6. 设置 systemd 服务
echo "[*] 设置并启动 systemd 服务..."
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=$BIN_PATH run -c $CONFIG_DIR/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

# 7. 生成链接和二维码
echo "[*] 生成节点链接和二维码..."
VLESS_URL="vless://$UUID@$DOMAIN:443?encryption=none&flow=xtls-rprx-vision&security=reality&pbk=$PUBLIC_KEY&sid=$SHORT_ID&sni=$SNI#$TAG"
echo "$VLESS_URL" >"$URL_PATH"
qrencode -o "$QR_PATH" "$VLESS_URL"

# 8. 安装管理脚本 sb
echo "[*] 安装 sb 管理菜单..."
cat >/usr/bin/sb <<'EOF'
#!/bin/bash
CONFIG_DIR="/etc/sing-box"
URL_PATH="$CONFIG_DIR/qrcode/vless_reality.txt"
LOG_PATH="$CONFIG_DIR/log/access.log"

view_link(){ [[ -f "$URL_PATH" ]] && cat "$URL_PATH" || echo "链接不存在"; }
show_qr(){ [[ -f "$URL_PATH" ]] && cat "$URL_PATH" | qrencode -t ansiutf8 || echo "未生成二维码"; }
view_log(){ [[ -f "$LOG_PATH" ]] && tail -n50 "$LOG_PATH" || echo "暂无日志"; }
restart(){ systemctl restart sing-box && echo "已重启"; }
status(){ systemctl status sing-box --no-pager; }
open_port(){
  P=$(jq -r '.inbounds[0].port' "/etc/sing-box/config.json")
  iptables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$P" -j ACCEPT
  ip6tables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$P" -j ACCEPT
  echo "放行端口 $P"
}
while true; do
  clear
  cat <<MENU
=== sing-box 菜单 ===
1) 查看链接
2) 终端扫码
3) 查看日志
4) 重启服务
5) 服务状态
6) 放行端口
7) 退出
MENU
  read -rp "选项 [1-7]: " i
  case $i in
    1) view_link ;;
    2) show_qr ;;
    3) view_log ;;
    4) restart ;;
    5) status ;;
    6) open_port ;;
    7) exit ;;
    *) echo "无效";;
  esac
  read -n1 -rsp $'回车继续...\n'
done
EOF
chmod +x /usr/bin/sb

# 9. 完成提示
echo
echo "✅ 完成！运行 【sb】 进入管理菜单"
echo "节点链接："
cat "$URL_PATH"
echo "二维码路径：$QR_PATH"
