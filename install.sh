#!/bin/bash
# Sing-box VLESS+Reality 一键部署 —— 全自动密钥持久化 & 全部依赖检测

set -euo pipefail

# ---------- 常量区 ----------
CONFIG_DIR="/etc/sing-box"
QR_DIR="$CONFIG_DIR/qrcode"
LOG_DIR="$CONFIG_DIR/log"
KEY_FILE="$CONFIG_DIR/keys.txt"
CONFIG_JSON="$CONFIG_DIR/config.json"
QR_PATH="$QR_DIR/vless_reality.png"
URL_PATH="$QR_DIR/vless_reality.txt"
LOG_PATH="$LOG_DIR/access.log"
BIN_PATH="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
TAG="skydoing-vless-reality"
# -------------------------

# 1. 检查 root
if [[ $EUID -ne 0 ]]; then
  echo "请以 root 身份运行脚本" >&2
  exit 1
fi

# 2. 检测系统
. /etc/os-release
OS_ID=$ID
echo "[*] 检测到系统：$NAME ($OS_ID) $VERSION_ID"

# 3. 确保 curl/wget 存在
ensure_cmd() {
  local cmd=$1 pkg=$2
  if ! command -v "$cmd" &>/dev/null; then
    echo "[*] 安装缺失命令：$cmd"
    case "$OS_ID" in
      ubuntu|debian)
        apt-get update -y
        apt-get install -y "$pkg"
        ;;
      almalinux|rocky|centos|rhel)
        if command -v dnf &>/dev/null; then
          dnf install -y "$pkg"
        else
          yum install -y "$pkg"
        fi
        ;;
      *)
        echo "不支持的系统，请手动安装 $pkg" >&2
        exit 1
        ;;
    esac
  fi
}
ensure_cmd curl curl
ensure_cmd wget wget

# 4. 安装其他依赖
install_deps() {
  case "$OS_ID" in
    ubuntu|debian)
      apt-get update -y
      apt-get upgrade -y
      apt-get install -y jq qrencode uuid-runtime xz-utils iptables xxd
      ;;
    almalinux|rocky|centos|rhel)
      if command -v dnf &>/dev/null; then
        dnf update -y
        dnf install -y jq qrencode libuuid iptables-services xz xxd
      else
        yum update -y
        yum install -y jq qrencode libuuid iptables-services xz xxd
      fi
      ;;
    *)
      echo "不支持的系统：$OS_ID" >&2
      exit 1
      ;;
  esac
}
install_deps

# 5. 下载并安装 Sing-box
echo "[*] 下载并安装 Sing-box..."
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
  echo "❌ 未找到匹配架构 $ARCH 的下载链接" >&2
  exit 1
fi
echo "    → 版本: $VER"
echo "    → 链接: $DOWNLOAD_URL"

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
cd / && rm -rf "$TMP"

# 校验安装
if [[ ! -x "$BIN_PATH" ]]; then
  echo "❌ 未找到 sing-box 二进制：" $BIN_PATH >&2
  exit 1
fi

# 6. 生成 Reality 密钥对并持久化
echo "[*] 生成 Reality 密钥对，保存到 $KEY_FILE"
mkdir -p "$CONFIG_DIR"
"$BIN_PATH" generate reality-key > "$KEY_FILE" 2>&1

# 7. 提取 PrivateKey/PublicKey/ShortID
PRIVATE_KEY=$(grep -i 'PrivateKey' "$KEY_FILE" | cut -d':' -f2 | tr -d '[:space:]')
PUBLIC_KEY=$(grep -i 'PublicKey'  "$KEY_FILE" | cut -d':' -f2 | tr -d '[:space:]')
SHORT_ID=$(grep -i 'ShortID\|ShortId\|Short_Id' "$KEY_FILE" | cut -d':' -f2 | tr -d '[:space:]')

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || -z "$SHORT_ID" ]]; then
  echo "❌ 提取密钥失败，请检查 $KEY_FILE" >&2
  exit 1
fi

# 8. 生成 UUID
UUID=$(uuidgen)

# 9. 写入 config.json
mkdir -p "$QR_DIR" "$LOG_DIR"
cat > "$CONFIG_JSON" <<EOF
{
  "log":{"level":"info","output":"$LOG_PATH"},
  "inbounds":[
    {
      "type":"vless","listen":"0.0.0.0","port":443,"tag":"vless-in",
      "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
      "stream":{"network":"tcp","security":"reality",
        "reality":{"enabled":true,
          "handshake":{"server":"www.bing.com","server_port":443},
          "private_key":"$PRIVATE_KEY","short_id":["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds":[{"type":"direct"},{"type":"block","tag":"block"}]
}
EOF

# 验证 JSON
jq . "$CONFIG_JSON" &>/dev/null || { echo "❌ config.json 语法错误"; exit 1; }

# 10. 配置并启动 systemd 服务
cat > "$SERVICE_FILE" <<EOF
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

# 11. 生成节点链接与二维码
DOMAIN=$(curl -fsSL https://api.ipify.org)
VLESS_URL="vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=www.bing.com#${TAG}"
echo "$VLESS_URL" > "$URL_PATH"
qrencode -o "$QR_PATH" "$VLESS_URL"

# 12. 安装 sb 管理脚本
cat > /usr/bin/sb <<'EOF'
#!/bin/bash
set -euo pipefail
CONFIG="/etc/sing-box/config.json"
URL="/etc/sing-box/qrcode/vless_reality.txt"
LOG_UNIT="sing-box"

show_info(){
  echo "UUID:      $(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG)"
  echo "Port:      $(jq -r '.inbounds[0].port' $CONFIG)"
  echo "ShortID:   $(jq -r '.inbounds[0].stream.reality.short_id[0]' $CONFIG)"
  echo "PublicKey: $(grep -i PublicKey /etc/sing-box/keys.txt | cut -d: -f2-)"
  echo "SNI:       www.bing.com"
  echo "Link:      $(cat $URL)"
}

show_link(){ cat $URL; }
show_qr(){ cat $URL | qrencode -t ansiutf8; }
show_log(){ journalctl -u $LOG_UNIT -n50 --no-pager; }
restart(){ systemctl restart $LOG_UNIT && echo "已重启服务"; }
status(){ systemctl status $LOG_UNIT --no-pager; }
open_port(){
  P=$(jq -r '.inbounds[0].port' $CONFIG)
  iptables -C INPUT -p tcp --dport $P -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $P -j ACCEPT
  ip6tables -C INPUT -p tcp --dport $P -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport $P -j ACCEPT
  echo "已放行端口 $P"
}

while true; do
  clear
  cat <<MENU
=== sing-box 管理菜单 ===
0) 节点详细信息
1) 查看节点链接
2) 终端扫码
3) 查看日志
4) 重启服务
5) 服务状态
6) 放行端口
7) 退出
MENU
  read -rp "选项 [0-7]: " o
  case $o in
    0) show_info ;;
    1) show_link ;;
    2) show_qr ;;
    3) show_log ;;
    4) restart ;;
    5) status ;;
    6) open_port ;;
    7) exit 0 ;;
    *) echo "无效选项"; sleep 1 ;;
  esac
done
EOF
chmod +x /usr/bin/sb

# 13. 完成提示
echo -e "\n✅ 安装完成！\n运行 → sb 进入管理菜单\n节点链接：$VLESS_URL\n二维码：$QR_PATH"
