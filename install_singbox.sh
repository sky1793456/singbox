#!/usr/bin/env bash
#==================================================
#  Sing-box + VLESS + REALITY 一键安装与管理脚本
#  节点命名：sky+协议名+域名
#  功能：
#    - 安装或升级到最新稳定版 sing-box
#    - 自动生成 UUID, Reality 密钥对, short ID
#    - 自动生成完整 config.json
#    - 创建 systemd 服务
#    - 安装依赖 jq, qrencode 并实现 sb 管理命令：
#        sb info   -> 查看节点 URL
#        sb qr     -> 生成并显示节点二维码
#        sb update -> 更新并重跑安装脚本
#==================================================

set -euo pipefail

#-------------------------
# 配置变量（请根据实际修改）
#-------------------------
NODE_PROTOCOL="VLESS-REALITY"
DOMAIN="your.domain.com"       # 替换成你的域名或 IP
PORT=443
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
# 原始脚本下载地址（用于 sb update）
SCRIPT_URL="https://raw.githubusercontent.com/sky1793456/singbox/main/install_singbox.sh"

#-------------------------
# 生成随机标识函数
#-------------------------
gen_uuid(){ command -v uuidgen >/dev/null 2>&1 && uuidgen || head /dev/urandom | tr -dc 'a-f0-9' | head -c8; }
gen_shortid(){ head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c6; }

#-------------------------
# 安装或更新 sing-box
#-------------------------
install_singbox(){
  echo "==> 检测并安装最新稳定版 sing-box ..."
  LATEST_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep 'browser_download_url.*linux.*amd64\.tar\.gz' | cut -d '"' -f4)
  TMPDIR=$(mktemp -d)
  curl -sL "$LATEST_URL" -o "$TMPDIR/sing-box.tar.gz"
  tar -C "$TMPDIR" -xzf "$TMPDIR/sing-box.tar.gz"
  # 尝试移动二进制: 支持多层目录
  if ls "$TMPDIR"/*/sing-box >/dev/null 2>&1; then
    mv "$TMPDIR"/*/sing-box /usr/local/bin/sing-box
  else
    mv "$TMPDIR"/sing-box /usr/local/bin/sing-box
  fi
  chmod +x /usr/local/bin/sing-box
  rm -rf "$TMPDIR"
  echo "--> sing-box 安装完成: $(sing-box version)"
}

#-------------------------
# 环境准备
#-------------------------
echo "==> 安装系统依赖: curl, jq, qrencode ..."
apt-get update
apt-get install -y curl jq qrencode

install_singbox

#-------------------------
# 生成标识与 Reality 密钥对
#-------------------------
UUID=$(gen_uuid)
SHORT_ID=$(gen_shortid)
echo "==> 生成 Reality 密钥对..."
KEY_JSON=$(sing-box reality generate-key)
PRIVATE_KEY=$(echo "$KEY_JSON" | jq -r '.private_key')
PUBLIC_KEY=$(echo "$KEY_JSON" | jq -r '.public_key')

#-------------------------
# 生成配置文件
#-------------------------
echo "==> 生成配置文件: $CONFIG_FILE"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" << EOF
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
cat > "$SERVICE_FILE" << EOF
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
echo "==> 执行：systemctl enable sing-box && systemctl restart sing-box"
systemctl enable sing-box && systemctl restart sing-box

echo "==> sing-box 已启动并开机自启"

#-------------------------
# 安装 sb 管理命令
#-------------------------
echo "==> 安装 sb 管理脚本到 /usr/local/bin/sb"
cat > /usr/local/bin/sb << EOF
#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="$CONFIG_FILE"

case "\${1:-}" in
  info)
    UUID=\$(jq -r '.inbounds[0].clients[0].uuid' \$CONFIG_FILE)
    PUBK=\$(jq -r '.inbounds[0].clients[0].reality.public_key' \$CONFIG_FILE)
    SID=\$(jq -r '.inbounds[0].clients[0].reality.short_id' \$CONFIG_FILE)
    URL="vless://\${UUID}@\${DOMAIN}:\${PORT}?encryption=none&security=reality&pbk=\${PUBK}&sid=\${SID}&flow=xtls-rprx-vision#sky-\${NODE_PROTOCOL,,}-\${DOMAIN}"
    echo "节点 URL: \$URL"
    ;;
  qr)
    sb info | awk -F": " '{print \$2}' | qrencode -t ANSIUTF8
    ;;
  update)
    bash <(curl -sL "$SCRIPT_URL")
    ;;
  *)
    echo "用法: sb {info|qr|update}"
    exit 1
    ;;
esac
EOF

chmod +x /usr/local/bin/sb
echo "==> 安装完成！使用 'sb info' 查看节点信息，'sb qr' 显示二维码，'sb update' 更新程序。"
