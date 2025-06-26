#!/bin/bash
# 一键安装 sing-box 并配置 VLESS + REALITY
# 节点名: skydoing-VLESS-REALITY

set -Eeuo pipefail
shopt -s inherit_errexit

UUID=$(uuidgen)
SNI="www.bing.com"
PORT=443
SID=$(head -c4 /dev/urandom | xxd -p)
DOMAIN="127.0.0.1"

# 安装 sing-box
bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"

# 生成 Reality 密钥（兼容新版）
if sing-box generate reality-keypair --json &>/dev/null; then
  KEYS=$(sing-box generate reality-keypair --json)
  PRIVATE_KEY=$(jq -r .private_key <<< "$KEYS")
  PUBLIC_KEY=$(jq -r .public_key <<< "$KEYS")
else
  KEYS=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(echo "$KEYS" | awk '/PrivateKey/ {print $2}')
  PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey/ {print $2}')
fi

# 写入配置文件
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",
    "output": "console"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SID"]
        },
        "server_name": "$SNI"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

# 启动 sing-box
systemctl enable --now sing-box

# 安装 qrencode（用于生成二维码）
apt update && apt install -y qrencode

# 生成 VLESS Reality URL
VLESS_URL="vless://$UUID@$DOMAIN:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SID#skydoing-VLESS-REALITY-$DOMAIN"

echo "\n✅ VLESS Reality URL:"
echo "$VLESS_URL"

# 生成二维码
qrencode -o /root/vless_reality.png "$VLESS_URL"
echo "✅ 二维码已保存为 /root/vless_reality.png"

# 定义 sb 管理命令
cat > /usr/local/bin/sb <<EOL
#!/bin/bash
clear
echo -e "\n==== Sing-box 节点信息 ===="
echo "$VLESS_URL"
echo -e "\n二维码图片: /root/vless_reality.png"
echo -e "\n配置文件: /etc/sing-box/config.json"
echo -e "\n服务状态:"
systemctl status sing-box | grep -E "Active|Loaded"
echo -e "\nSing-box 版本:"
sing-box version
EOL

chmod +x /usr/local/bin/sb

echo -e "\n✅ 安装完成！运行 sb 查看节点信息和二维码。"
