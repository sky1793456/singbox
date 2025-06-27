#!/bin/bash
# Sing-box VLESS+Reality 一键部署 —— 深度修复版

set -euo pipefail
trap 'echo "❌ 脚本执行失败，最后一条命令：$BASH_COMMAND"; exit 1' ERR

# 1. 获取系统ID，兼容大小写及部分老系统
OS_ID=$(awk -F= '/^ID=/{print tolower($2)}' /etc/os-release | tr -d '"')
if [[ -z "$OS_ID" ]]; then
  echo "❌ 无法识别系统类型 /etc/os-release 中缺少 ID" >&2
  exit 1
fi

echo "[*] 检测到系统：$OS_ID"

# 2. 确保命令存在，带重试防锁死
ensure_cmd() {
  local cmd=$1 pkg=$2
  if ! command -v "$cmd" &>/dev/null; then
    echo "[*] 未检测到 $cmd，尝试安装 $pkg…"
    local retry=3
    while ((retry > 0)); do
      case "$OS_ID" in
        ubuntu|debian)
          apt-get update -y && apt-get install -y "$pkg" && break
          ;;
        centos|rhel|almalinux|rocky)
          if command -v dnf &>/dev/null; then
            dnf install -y "$pkg" && break
          else
            yum install -y "$pkg" && break
          fi
          ;;
        *)
          echo "❌ 不支持的系统，请手动安装 $pkg" >&2
          exit 1
          ;;
      esac
      echo "安装失败，等待5秒后重试…"
      sleep 5
      ((retry--))
    done
    if ((retry == 0)); then
      echo "❌ 安装 $pkg 多次失败，请手动检查" >&2
      exit 1
    fi
  fi
}

ensure_cmd curl curl
ensure_cmd wget wget
ensure_cmd jq jq
ensure_cmd qrencode qrencode
ensure_cmd uuidgen uuid-runtime  # uuidgen 有时在 uuid-runtime 包里

# 3. 额外依赖安装，带锁文件等待检测
install_deps() {
  echo "[*] 安装系统依赖…"
  local deps="jq qrencode uuid-runtime xz-utils iptables xxd"
  case "$OS_ID" in
    ubuntu|debian)
      # 等待apt释放锁
      while fuser /var/lib/dpkg/lock >/dev/null 2>&1 ; do
        echo "等待 apt 锁释放..."
        sleep 3
      done
      apt-get update -y && apt-get upgrade -y
      apt-get install -y $deps
      ;;
    centos|rhel|almalinux|rocky)
      if command -v dnf &>/dev/null; then
        dnf update -y
        dnf install -y jq qrencode libuuid iptables-services xz xxd
      else
        yum update -y
        yum install -y jq qrencode libuuid iptables-services xz xxd
      fi
      ;;
    *)
      echo "❌ 不支持的系统类型" >&2
      exit 1
      ;;
  esac
}
install_deps

# 4. 下载 Sing-box 最新版本
echo "[*] 获取 Sing-box 最新版本下载链接…"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "❌ 不支持的 CPU 架构：$ARCH" >&2; exit 1 ;;
esac

# 使用 curl 带重试，避免 Github API 频率限制
RETRIES=3
while ((RETRIES > 0)); do
  RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest) && break
  echo "请求 Github API 失败，等待 5 秒后重试..."
  sleep 5
  ((RETRIES--))
done
if [[ -z "$RELEASE_JSON" ]]; then
  echo "❌ 无法获取 Github 最新发布信息" >&2
  exit 1
fi

VER=$(echo "$RELEASE_JSON" | jq -r .tag_name)
DOWNLOAD_URL=$(echo "$RELEASE_JSON" | jq -r --arg arch "$ARCH" '.assets[] | select(.name | test("linux.*" + $arch + "\\.(tar\\.gz|tar\\.xz)$")) | .browser_download_url' | head -n1)

if [[ -z "$DOWNLOAD_URL" ]]; then
  echo "❌ 未找到对应架构 $ARCH 的下载包" >&2
  exit 1
fi

echo "    → 版本: $VER"
echo "    → 链接: $DOWNLOAD_URL"

TMPDIR=$(mktemp -d)
cd "$TMPDIR"

curl -fsSL --retry 3 --retry-delay 5 -o sing-box.tar "$DOWNLOAD_URL"

# 5. 解压包，并确认 sing-box 二进制路径
if [[ "$DOWNLOAD_URL" == *.tar.gz ]]; then
  tar -xzf sing-box.tar
elif [[ "$DOWNLOAD_URL" == *.tar.xz ]]; then
  tar -xJf sing-box.tar
else
  echo "❌ 不支持的压缩格式" >&2
  exit 1
fi

BIN_SUBDIR=$(find . -maxdepth 1 -type d -name "sing-box*" | head -n1)
if [[ -z "$BIN_SUBDIR" ]]; then
  echo "❌ 解压后未找到 sing-box 目录" >&2
  exit 1
fi

install -m 755 "$BIN_SUBDIR/sing-box" /usr/local/bin/sing-box

cd / && rm -rf "$TMPDIR"

if ! command -v sing-box &>/dev/null; then
  echo "❌ sing-box 安装失败" >&2
  exit 1
fi

# 6. 生成密钥对
CONFIG_DIR="/etc/sing-box"
KEY_FILE="$CONFIG_DIR/keys.txt"

mkdir -p "$CONFIG_DIR"

echo "[*] 生成 Reality 密钥对..."
if ! sing-box generate reality-key > "$KEY_FILE" 2>&1; then
  echo "❌ 生成 Reality 密钥对失败" >&2
  cat "$KEY_FILE"
  exit 1
fi

PRIVATE_KEY=$(awk -F':' '/PrivateKey/ {gsub(/ /,"",$2); print $2}' "$KEY_FILE")
PUBLIC_KEY=$(awk -F':' '/PublicKey/  {gsub(/ /,"",$2); print $2}' "$KEY_FILE")
SHORT_ID=$(awk -F':' '/ShortID|ShortId|Short_Id/ {gsub(/ /,"",$2); print $2}' "$KEY_FILE")

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || -z "$SHORT_ID" ]]; then
  echo "❌ 提取密钥失败，请检查 $KEY_FILE"
  exit 1
fi

echo "[*] 密钥提取成功"

# 7. 生成 UUID
UUID=$(uuidgen)

# 8. 写入 config.json，目录与日志路径
QR_DIR="$CONFIG_DIR/qrcode"
LOG_DIR="$CONFIG_DIR/log"
CONFIG_JSON="$CONFIG_DIR/config.json"
LOG_PATH="$LOG_DIR/access.log"

mkdir -p "$QR_DIR" "$LOG_DIR"

cat > "$CONFIG_JSON" <<EOF
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
            "server": "www.bing.com",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
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

# 9. 校验 config.json 语法
if ! jq empty "$CONFIG_JSON"; then
  echo "❌ config.json 格式错误" >&2
  exit 1
fi

# 10. 写 systemd service 文件
SERVICE_FILE="/etc/systemd/system/sing-box.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_JSON
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

# 11. 获取 VPS IP，支持重试
IP_RETRY=3
DOMAIN=""
while ((IP_RETRY > 0)); do
  DOMAIN=$(curl -fsSL https://api.ipify.org) && break
  echo "获取公网 IP 失败，等待5秒重试..."
  sleep 5
  ((IP_RETRY--))
done

if [[ -z "$DOMAIN" ]]; then
  echo "❌ 获取公网 IP 失败，请手动输入节点域名或 IP"
  read -rp "请输入节点 IP 或域名: " DOMAIN
fi

VLESS_URL="vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=www.bing.com#skydoing-vless-reality"

URL_PATH="$QR_DIR/vless_reality.txt"
QR_PATH="$QR_DIR/vless_reality.png"
echo "$VLESS_URL" > "$URL_PATH"
qrencode -o "$QR_PATH" "$VLESS_URL"

# 12. 安装 sb 管理脚本，增加部分健壮性检测
cat > /usr/bin/sb <<'EOF'
#!/bin/bash
set -euo pipefail

CONFIG="/etc/sing-box/config.json"
URL="/etc/sing-box/qrcode/vless_reality.txt"
KEYS="/etc/sing-box/keys.txt"
UNIT="sing-box"

check_dependencies() {
  for cmd in jq awk cat systemctl iptables qrencode; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "❌ 缺少依赖命令：$cmd"
      exit 1
    fi
  done
}

show_info() {
  check_dependencies
  echo "UUID:      $(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG)"
  echo "Port:      $(jq -r '.inbounds[0].port' $CONFIG)"
  echo "ShortID:   $(jq -r '.inbounds[0].stream.reality.short_id[0]' $CONFIG)"
  echo "PublicKey: $(awk -F':' '/PublicKey/ {gsub(/ /,"",$2); print $2}' $KEYS)"
  echo "SNI:       www.bing.com"
  echo "Link:      $(cat $URL)"
}

show_link() { cat $URL; }
show_qr() { cat $URL | qrencode -t ansiutf8; }
show_log() { journalctl -u $UNIT -n50 --no-pager; }
restart() { systemctl restart $UNIT && echo "已重启服务"; }
status() { systemctl status $UNIT --no-pager; }
open_port() {
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

echo -e "\n✅ 安装完成！"
echo "运行 → sb 进入管理菜单"
echo "节点链接：$VLESS_URL"
echo "二维码路径：$QR_PATH"
