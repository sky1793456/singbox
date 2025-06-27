#!/bin/bash
# Sing-box VLESS+Reality 一键部署 —— 去除 xxd、完美跨系统支持

set -e

CONFIG_DIR="/etc/sing-box"
QR_DIR="$CONFIG_DIR/qrcode"
LOG_DIR="$CONFIG_DIR/log"
QR_PATH="$QR_DIR/vless_reality.png"
URL_PATH="$QR_DIR/vless_reality.txt"
LOG_PATH="$LOG_DIR/access.log"
BIN_PATH="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# 1. 检查 root
if [[ $EUID -ne 0 ]]; then
  echo "请以 root 身份运行脚本"
  exit 1
fi

# 2. 检测系统
echo "[*] 检测系统类型..."
. /etc/os-release
OS_ID=$ID
echo "    → $NAME ($OS_ID) $VERSION_ID"

# 3. 安装依赖
install_deps_debian() {
  echo "[*] 更新APT并安装依赖..."
  apt update -y && apt upgrade -y
  apt install -y curl wget jq qrencode uuid-runtime xz-utils iptables
}
install_deps_rhel() {
  echo "[*] 更新DNF/YUM并安装依赖..."
  if command -v dnf &>/dev/null; then
    dnf update -y
    dnf install -y curl wget jq qrencode libuuid iptables-services xz
  else
    yum update -y
    yum install -y curl wget jq qrencode libuuid iptables-services xz
  fi
}
case "$OS_ID" in
  ubuntu|debian) install_deps_debian ;;
  almalinux|rocky|centos|rhel) install_deps_rhel ;;
  *) echo "不支持的系统: $OS_ID" && exit 1 ;;
esac

# 4. 获取最新版本和下载链接
echo "[*] 获取最新 Sing-box 版本和下载链接..."
ARCH=$(uname -m)
[[ $ARCH == "x86_64" ]] && ARCH="amd64"
[[ $ARCH =~ ^(aarch64|arm64)$ ]] && ARCH="arm64"
read -r VER DOWNLOAD_URL <<EOF
$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
  | jq -r --arg arch "$ARCH" '.tag_name + " " +
      (.assets[] | select(.name | test("linux.*" + $arch + "\\.(tar\\.gz|tar\\.xz)$")) | .browser_download_url)')
EOF
[[ -z "$DOWNLOAD_URL" ]] && { echo "❌ 未找到下载链接" && exit 1; }
echo "    → 版本: $VER"
echo "    → 链接: $DOWNLOAD_URL"

# 5. 下载并解压
echo "[*] 下载并安装 Sing-box..."
TMP="/tmp/singbox"
rm -rf "$TMP" && mkdir -p "$TMP" && cd "$TMP"
curl -fsSL -o package "$DOWNLOAD_URL"
if [[ "$DOWNLOAD_URL" == *.tar.gz ]]; then
  tar -xzf package
elif [[ "$DOWNLOAD_URL" == *.tar.xz ]]; then
  tar -xJf package
else
  echo "❌ 无法识别压缩格式" && exit 1
fi
install -m 755 sing-box*/sing-box "$BIN_PATH"

# 6. 生成配置
echo "[*] 生成 VLESS+Reality 配置..."
mkdir -p "$CONFIG_DIR" "$QR_DIR" "$LOG_DIR"
UUID=$(uuidgen)
KEYS=$("$BIN_PATH" generate reality-key)
PRIVATE_KEY=$(echo "$KEYS" | awk '/PrivateKey/ {print $2}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey/ {print $2}')
# 取16位十六进制 ShortID，无需 xxd
SHORT_ID=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 16)
SNI="www.bing.com"
DOMAIN=$(curl -s ipv4.ip.sb)
TAG="skydoing-vless-reality"
cat >"$CONFIG_DIR/config.json" <<CFG
{
  "log":{"level":"info","output":"$LOG_PATH"},
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
CFG

# 7. 设置 systemd 服务
echo "[*] 配置 systemd 服务..."
cat >"$SERVICE_FILE" <<SVC
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=$BIN_PATH run -c $CONFIG_DIR/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable --now sing-box

# 8. 生成节点链接和二维码
echo "[*] 生成节点链接和二维码..."
VLESS_URL="vless://$UUID@$DOMAIN:443?encryption=none&flow=xtls-rprx-vision&security=reality&pbk=$PUBLIC_KEY&sid=$SHORT_ID&sni=$SNI#$TAG"
echo "$VLESS_URL" >"$URL_PATH"
qrencode -o "$QR_PATH" "$VLESS_URL"

# 9. 安装 sb 管理脚本
echo "[*] 安装 sb 管理脚本..."
cat >/usr/bin/sb <<'MENU'
#!/bin/bash
CONFIG_DIR="/etc/sing-box"
URL_PATH="$CONFIG_DIR/qrcode/vless_reality.txt"
LOG_PATH="$CONFIG_DIR/log/access.log"

view_link(){ [[ -f "$URL_PATH" ]] && cat "$URL_PATH" || echo "链接不存在"; }
show_qr(){ [[ -f "$URL_PATH" ]] && cat "$URL_PATH" | qrencode -t ansiutf8 || echo "二维码未生成"; }
view_log(){ [[ -f "$LOG_PATH" ]] && tail -n50 "$LOG_PATH" || echo "暂无日志"; }
restart(){ systemctl restart sing-box && echo "已重启服务"; }
status(){ systemctl status sing-box --no-pager; }
open_port(){
  P=$(jq -r '.inbounds[0].port' "/etc/sing-box/config.json")
  iptables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$P" -j ACCEPT
  ip6tables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$P" -j ACCEPT
  echo "已放行端口 $P"
}
while true; do
  clear
  cat <<EOF
=== sing-box 管理菜单 ===
1) 查看节点链接
2) 终端扫码
3) 查看日志
4) 重启服务
5) 服务状态
6) 放行端口
7) 退出
EOF
  read -rp "选项 [1-7]: " opt
  case $opt in
    1) view_link ;;
    2) show_qr ;;
    3) view_log ;;
    4) restart ;;
    5) status ;;
    6) open_port ;;
    7) exit ;;
    *) echo "无效选项";;
  esac
  read -n1 -rsp $'按任意键继续...\n'
done
MENU
chmod +x /usr/bin/sb

echo -e "\n✅ 安装完成！"
echo "运行 'sb' 进入管理菜单"
echo "节点链接：$(cat "$URL_PATH")"
echo "二维码路径：$QR_PATH"
