#!/bin/bash
set -e

echo "==== Sing-box VLESS+REALITY 一键安装脚本 ===="

SNI="www.bing.com"
PORT=443

# 1. 自动生成 UUID
if command -v uuidgen &> /dev/null; then
  UUID=$(uuidgen)
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
fi
echo "生成 UUID: $UUID"

# 2. 获取 VPS 公网 IP
echo "获取 VPS 公网 IP..."
DOMAIN=$(curl -s https://ip.sb)
if [[ -z "$DOMAIN" ]]; then
  echo "❌ 获取公网 IP 失败，请检查网络"
  exit 1
fi
echo "检测到公网 IP: $DOMAIN"

# 3. 检查并安装 sing-box
if ! command -v sing-box &> /dev/null; then
  echo "sing-box 未安装，开始安装..."
  bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)" || { echo "sing-box 安装失败"; exit 1; }
fi
echo "sing-box 已安装，版本：$(sing-box version)"

# 4. 生成 Reality 密钥对
echo "生成 Reality 密钥对..."
KEY_OUTPUT=$(sing-box generate key)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep 'private key' | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep 'public key' | awk '{print $3}')
SHORT_ID=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c8)

echo "private_key: $PRIVATE_KEY"
echo "public_key: $PUBLIC_KEY"
echo "short_id: $SHORT_ID"

# 5. 写入配置文件
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
            "server_port": $PORT
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
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

echo "配置文件已写入 /etc/sing-box/config.json"

# 6. 启动并设置开机自启
systemctl enable sing-box
systemctl restart sing-box

# 7. 安装二维码生成工具
apt update
apt install -y qrencode

# 8. 生成 VLESS Reality 链接
VLESS_URL="vless://$UUID@$DOMAIN:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID#skydoing-VLESS-REALITY-$DOMAIN"

echo -e "\n✅ VLESS Reality URL:\n$VLESS_URL"

# 9. 生成二维码图片
qrencode -o /root/vless_reality.png "$VLESS_URL"
echo "✅ 二维码已保存到 /root/vless_reality.png"

# 10. 创建 sb 管理命令
cat > /usr/local/bin/sb <<EOL
#!/bin/bash
clear
echo -e "\n==== Sing-box 节点信息 ===="
echo "$VLESS_URL"
echo -e "\n二维码图片路径：/root/vless_reality.png"
echo -e "\n配置文件路径：/etc/sing-box/config.json"
echo -e "\n服务状态："
systemctl status sing-box | grep -E "Active|Loaded"
echo -e "\nSing-box 版本："
sing-box version
EOL
chmod +x /usr/local/bin/sb

echo -e "\n✅ 安装完成！运行命令 'sb' 查看节点信息和二维码。"
