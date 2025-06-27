#!/bin/bash
# 完整修正版：一键部署 Sing-box VLESS+Reality，并创建 sb 管理菜单

set -euo pipefail

# ----------------- 配置常量 -----------------
CONFIG_DIR="/etc/sing-box"
QR_DIR="$CONFIG_DIR/qrcode"
LOG_DIR="$CONFIG_DIR/log"
QR_PATH="$QR_DIR/vless_reality.png"
URL_PATH="$QR_DIR/vless_reality.txt"
LOG_PATH="$LOG_DIR/access.log"
BIN_PATH="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
TAG="skydoing-vless-reality"
# --------------------------------------------

# 1. 检查 root
if [[ $EUID -ne 0 ]]; then
  echo "请以 root 身份运行此脚本" >&2
  exit 1
fi

# 2. 检测系统发行版
echo "[*] 检测系统类型..."
. /etc/os-release
OS_ID=$ID
echo "    → $NAME ($OS_ID) $VERSION_ID"

# 3. 安装依赖
install_deps_debian() {
  apt update -y && apt upgrade -y
  apt install -y curl wget jq qrencode uuid-runtime xz-utils iptables xxd
}
install_deps_rhel() {
  if command -v dnf &>/dev/null; then
    dnf update -y
    dnf install -y curl wget jq qrencode libuuid iptables-services xz xxd
  else
    yum update -y
    yum install -y curl wget jq qrencode libuuid iptables-services xz xxd
  fi
}
case "$OS_ID" in
  ubuntu|debian) install_deps_debian ;;
  almalinux|rocky|centos|rhel) install_deps_rhel ;;
  *)
    echo "不支持的系统：$OS_ID" >&2
    exit 1
    ;;
esac

# 4. 获取最新 Sing-box 版本与下载链接
echo "[*] 获取最新 Sing-box 版本和下载链接..."
ARCH=$(uname -m)
[[ $ARCH == "x86_64" ]] && ARCH="amd64"
[[ $ARCH =~ ^(aarch64|arm64)$ ]] && ARCH="arm64"

read -r VER DOWNLOAD_URL <<EOF
$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
  | jq -r --arg arch "$ARCH" '
     .tag_name as $v
     | .assets[]
     | select(.name | test("linux.*" + $arch + "\\.(tar\\.gz|tar\\.xz)$"))
     | "\($v) " + .browser_download_url
  ')
EOF

if [[ -z "$DOWNLOAD_URL" ]]; then
  echo "❌ 未找到适合架构 $ARCH 的下载链接" >&2
  exit 1
fi
echo "    → 版本: $VER"
echo "    → 下载链接: $DOWNLOAD_URL"

# 5. 下载并安装 Sing-box
echo "[*] 下载并安装 Sing-box..."
TMP=$(mktemp -d)
cd "$TMP"
curl -fsSL -o package "$DOWNLOAD_URL"
if [[ "$DOWNLOAD_URL" == *.tar.gz ]]; then
  tar -xzf package
elif [[ "$DOWNLOAD_URL" == *.tar.xz ]]; then
  tar -xJf package
else
  echo "❌ 无法识别压缩格式" >&2
  exit 1
fi
install -m 755 sing-box*/sing-box "$BIN_PATH"

# 6. 生成配置
echo "[*] 生成 VLESS+Reality 配置..."
mkdir -p "$CONFIG_DIR" "$QR_DIR" "$LOG_DIR"

UUID=$(uuidgen)
KEYS=$("$BIN_PATH" generate reality-key)
PRIVATE_KEY=$(echo "$KEYS" | awk '/PrivateKey/ {print $2}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey/ {print $2}')
SHORT_ID=$(head -c16 /dev/urandom | tr -dc 'a-f0-9' | head -c16)
SNI="www.bing.com"
DOMAIN=$(curl -fsSL https://api.ipify.org)

# 校验密钥
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  echo "❌ Reality 密钥生成失败" >&2
  exit 1
fi

CONFIG_JSON="$CONFIG_DIR/config.json"
cat >"$CONFIG_JSON" <<EOF
{
  "log": {"level":"info","output":"$LOG_PATH"},
  "inbounds": [
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

# 验证 JSON 语法
if ! jq . "$CONFIG_JSON" &>/dev/null; then
  echo "❌ 配置文件 JSON 语法错误" >&2
  jq . "$CONFIG_JSON" || true
  exit 1
fi

# 7. 配置 systemd 服务
echo "[*] 设置 systemd 单元..."
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=$BIN_PATH run -c $CONFIG_JSON
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

# 8. 生成节点链接及二维码
echo "[*] 生成节点链接与二维码..."
VLESS_URL="vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${SNI}#${TAG}"
echo "$VLESS_URL" >"$URL_PATH"
qrencode -o "$QR_PATH" "$VLESS_URL"

echo "[*] 清理临时目录"
rm -rf "$TMP"

# 9. 安装 sb 管理脚本
echo "[*] 安装 sb 管理菜单..."
cat >/usr/bin/sb <<'MENU'
#!/bin/bash
set -euo pipefail

CONFIG_DIR="/etc/sing-box"
URL_PATH="$CONFIG_DIR/qrcode/vless_reality.txt"
LOG_PATH="$CONFIG_DIR/log/access.log"
BIN="/usr/local/bin/sing-box"

view_info(){
  echo "UUID:    $(jq -r '.inbounds[0].settings.clients[0].id' /etc/sing-box/config.json)"
  echo "Port:    $(jq -r '.inbounds[0].port' /etc/sing-box/config.json)"
  echo "ShortID: $(jq -r '.inbounds[0].stream.reality.short_id[0]' /etc/sing-box/config.json)"
  echo "PublicKey: $(jq -r '.inbounds[0].stream.reality.private_key' /etc/sing-box/config.json)"
  echo "SNI:	    www.bing.com"
  echo "Link:    $(cat \"$URL_PATH\")"
}

view_link(){ cat "$URL_PATH"; }
show_qr(){ cat "$URL_PATH" | qrencode -t ansiutf8; }
view_log(){ journalctl -u sing-box -n50 --no-pager; }
restart(){ systemctl restart sing-box && echo "服务已重启"; }
status(){ systemctl status sing-box --no-pager; }
open_port(){
  P=$(jq -r '.inbounds[0].port' /etc/sing-box/config.json)
  iptables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$P" -j ACCEPT
  ip6tables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$P" -j ACCEPT
  echo "已放行端口 $P"
}

while true; do
  clear
  cat <<EOF
=== sing-box 管理菜单 ===
0) 查看节点详细信息
1) 查看节点链接
2) 终端扫码
3) 查看最近日志
4) 重启服务
5) 服务状态
6) 放行端口
7) 退出
EOF
  read -rp "选项 [0-7]: " opt
  case $opt in
    0) view_info ;;
    1) view_link ;;
    2) show_qr ;;
    3) view_log ;;
    4) restart ;;
    5) status ;;
    6) open_port ;;
    7) exit 0 ;;
    *) echo "无效选项"; sleep 1 ;;
  esac
done
MENU

chmod +x /usr/bin/sb

# 最终输出
echo -e "\n✅ 安装完成！"
echo "运行 → sb 进入管理菜单"
echo "节点链接：$VLESS_URL"
echo "二维码文件：$QR_PATH"
