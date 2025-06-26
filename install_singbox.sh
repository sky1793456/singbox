#!/usr/bin/env bash
set -Eeuo pipefail

#===========================
# 1. 检查 Root 权限
#===========================
if [[ $EUID -ne 0 ]]; then
  echo "\e[31m[错误]\e[0m 请使用 sudo 或 root 权限运行此脚本。"
  exit 1
fi

#===========================
# 2. 检查系统并更新依赖
#===========================
echo "\e[34m[信息]\e[0m 正在检测并更新系统..."
. /etc/os-release
if [[ "$ID" =~ ^(debian|ubuntu)$ ]]; then
  apt update -y && apt upgrade -y
  apt install -y curl wget jq qrencode uuid-runtime openssl ca-certificates xxd lsb-release gnupg
elif [[ "$ID" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
  yum install -y epel-release
  yum install -y curl wget jq qrencode uuid openssl lsof xxd redhat-lsb-core
else
  echo "\e[31m[错误]\e[0m 不支持的操作系统：$ID"
  exit 1
fi

#===========================
# 3. 安装官方最新 Sing-box
#===========================
echo "\e[34m[信息]\e[0m 正在安装 Sing-box..."
INSTALL_SCRIPT_URL="https://sing-box.app/deb-install.sh"
if curl -fsSL "$INSTALL_SCRIPT_URL" | bash; then
  echo "\e[32m[完成]\e[0m Sing-box 安装成功"
else
  echo "\e[31m[错误]\e[0m Sing-box 安装失败，退出。"
  exit 1
fi

#===========================
# 4. 生成 Reality Key & UUID
#===========================
KEYS=$(sing-box generate reality-keypair --json)
UUID=$(uuidgen)
PRIVATE_KEY=$(jq -r .private_key <<< "$KEYS")
PUBLIC_KEY=$(jq -r .public_key <<< "$KEYS")
SHORT_ID=$(head -c 4 /dev/urandom | xxd -p)

#===========================
# 5. 生成默认 config.json
#===========================
mkdir -p /etc/sing-box /var/log/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",
    "output": "file",
    "log_file": "/var/log/sing-box/sing-box.log"
  },
  "dns": {
    "servers": ["8.8.8.8", "1.1.1.1"]
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": 443,
      "tag": "vless-reality",
      "sniff": {"enabled": false},
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
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
    {"type": "direct"}
  ]
}
EOF

#===========================
# 6. 启动服务并设置开机自启
#===========================
systemctl enable sing-box --now

#===========================
# 7. 打印连接信息
#===========================
SUB_URL="vless://$UUID@your-domain.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.bing.com&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID"
echo "\n\e[32m[成功]\e[0m 节点信息如下："
echo "--------------------------------------"
echo "UUID:        $UUID"
echo "Public Key:  $PUBLIC_KEY"
echo "Short ID:    $SHORT_ID"
echo "订阅地址:    $SUB_URL"
echo "二维码路径:  /root/vless.png"
echo "--------------------------------------"
qrencode -o /root/vless.png "$SUB_URL"

#===========================
# 8. 安装完成提示
#===========================
echo -e "\n✅ \e[1;32mSing-box 安装与配置完成\e[0m，输入 \e[33msing-box run\e[0m 可手动运行调试。"
