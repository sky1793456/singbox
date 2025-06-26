#!/usr/bin/env bash
#==================================================
#  Sing-box + VLESS + REALITY 一键安装与管理脚本
#  节点命名：sky+协议名+域名
#  功能：
#    - 安装或升级到最新稳定版 sing-box（官方 GitHub Releases）
#    - 自动生成 UUID, Reality 密钥对, short ID
#    - 自动生成完整 config.json
#    - 创建 systemd 服务
#    - 安装依赖 jq, qrencode 并实现 sb 管理命令：
#        sb info   -> 查看节点 URL
#        sb qr     -> 生成并显示节点二维码
#        sb update -> 拉取并重跑最新脚本
#==================================================

set -euo pipefail

#-------------------------
# 默认配置，可被 -d/-p 覆盖
#-------------------------
NODE_PROTOCOL="VLESS-REALITY"
DOMAIN="your.domain.com"
PORT=443
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
# 更新脚本地址，请确保此 URL 永远指向最新脚本
SCRIPT_URL="https://raw.githubusercontent.com/sky1793456/singbox/main/install_singbox.sh"

usage(){
  cat <<EOF
用法：$(basename "$0") [-d domain] [-p port]

  -d 域名或 IP（默认：$DOMAIN）
  -p 监听端口   （默认：$PORT）
EOF
  exit 1
}

#-------------------------
# 解析参数
#-------------------------
while getopts "d:p:h" opt; do
  case "$opt" in
    d) DOMAIN="$OPTARG" ;; 
    p) PORT="$OPTARG" ;; 
    *) usage ;; 
  esac
done

#-------------------------
# 随机标识函数
#-------------------------
gen_uuid(){ command -v uuidgen &>/dev/null && uuidgen || head /dev/urandom | tr -dc 'a-f0-9' | head -c8; }

#-------------------------
# 安装或更新 sing-box
#-------------------------
install_singbox(){
  echo "==> 检测并安装最新稳定版 sing-box（官方仓库）..."
  # 获取最新的 Linux AMD64 tar.gz 下载链接
  LATEST_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep 'browser_download_url.*linux.*amd64\.tar\.gz' \
    | cut -d '"' -f4)
  echo "--> 下载: $LATEST_URL"
  TMPDIR=$(mktemp -d)
  curl -sL "$LATEST_URL" -o "$TMPDIR/sing-box.tar.gz"
  tar -C "$TMPDIR" -xzf "$TMPDIR/sing-box.tar.gz"
  if ls "$TMPDIR"/*/sing-box &>/dev/null; then
    mv "$TMPDIR"/*/sing-box /usr/local/bin/sing-box
  else
    mv "$TMPDIR"/sing-box /usr/local/bin/sing-box
  fi
  chmod +x /usr/local/bin/sing-box
  rm -rf "$TMPDIR"
  echo "--> sing-box 已安装: $(/usr/local/bin/sing-box version)"
}

#-------------------------
# 环境准备
#-------------------------
echo "==> 安装系统依赖：curl, jq, qrencode ..."
apt-get update
apt-get install -y curl jq qrencode

install_singbox

#-------------------------
# 生成 UUID 与 Reality 密钥对
#-------------------------
UUID=$(gen_uuid)
echo "==> 生成 Reality 密钥对（官方命令）..."
PAIR_OUTPUT=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$PAIR_OUTPUT" | awk '/PrivateKey/{print \$2}')
PUBLIC_KEY=$(echo "$PAIR_OUTPUT" | awk '/PublicKey/{print \$2}')
# 生成 short_id（6位十六进制）
SHORT_ID=$(sing-box generate rand 6 --hex)

#-------------------------
# 生成配置文件
#-------------------------
echo "==> 写入配置文件: $CONFIG_FILE"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "vless",
    "tag": "$NODE_PROTOCOL",
    "listen": "0.0.0.0",
    "listen_port": $PORT,
    "sniff": true,
    "decryption": "none",
    "clients": [{
      "uuid": "$UUID",
      "flow": "xtls-rprx-vision",
      "reality": {
        "handshake": "x25519",
        "private_key": "$PRIVATE_KEY",
        "public_key": "$PUBLIC_KEY",
        "short_id": "$SHORT_ID",
        "max_time": 86400
      }
    }]
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

#-------------------------
# 创建 systemd 服务
#-------------------------
echo "==> 创建 systemd 服务: $SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box --now

#-------------------------
# 安装 sb 管理命令
#-------------------------
echo "==> 安装 sb 命令到 /usr/local/bin/sb"
cat > /usr/local/bin/sb <<EOF
#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="$CONFIG_FILE"

case "\${1:-}" in
  info)
    UUID=$(jq -r '.inbounds[0].clients[0].uuid' \$CONFIG_FILE)
    PUBK=$(jq -r '.inbounds[0].clients[0].reality.public_key' \$CONFIG_FILE)
    SID=$(jq -r '.inbounds[0].clients[0].reality.short_id' \$CONFIG_FILE)
    echo "vless://\${UUID}@\${DOMAIN}:\${PORT}?encryption=none&security=reality&pbk=\${PUBK}&sid=\${SID}&flow=xtls-rprx-vision#sky-\${NODE_PROTOCOL,,}-\${DOMAIN}"
    ;;
  qr)
    sb info | awk '/vless:/{print \$1}' | qrencode -t ANSIUTF8
    ;;
  update)
    bash <(curl -sL "$SCRIPT_URL")
    ;;
  *)
    echo "用法: sb {info|qr|update}"
    exit 1;;
esac
EOF

chmod +x /usr/local/bin/sb
echo "==> 完成！使用 'sb info' 查看链接，'sb qr' 生成二维码，'sb update' 更新脚本与程序。"
