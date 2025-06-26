#!/bin/bash
set -e

green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

green "[1/9] 安装依赖..."
apt update && apt install -y curl qrencode wget

green "[2/9] 安装 sing-box..."
bash -c "$(curl -fsSL https://sing-box.app/install.sh)"

green "[3/9] 生成 UUID 和 Reality 密钥..."
UUID=$(sing-box generate uuid)
KEYS=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYS" | grep 'PrivateKey' | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYS" | grep 'PublicKey' | awk '{print $2}')
SHORT_ID=$(head -c 8 /dev/urandom | xxd -p)

green "[4/9] 获取 VPS IP 作为节点地址..."
IP=$(curl -s ipv4.ip.sb || curl -s ipinfo.io/ip)
green "检测到IP: $IP"

CONFIG_DIR="/usr/local/etc/sing-box"
mkdir -p "$CONFIG_DIR"

green "[5/9] 写入配置文件..."
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "level": "info",
    "output": "sing-box.log"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
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
            "server": "www.bing.com",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

green "[6/9] 创建 systemd 服务并启动..."
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_DIR/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable sing-box
systemctl restart sing-box

green "[7/9] 构造 VLESS Reality 链接及生成二维码..."
VLESS_URL="vless://${UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.bing.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#sky-vless"

echo "$VLESS_URL" > /root/vless-url.txt
qrencode -o /root/vless-qr.png "$VLESS_URL"

green "[8/9] 创建 sb 命令，快速查看节点信息和服务状态..."
cat > /usr/bin/sb <<EOF
#!/bin/bash
case \$1 in
  qr)
    echo -e "\\033[36m========= sky-vless 节点二维码 =========\\033[0m"
    if [ -f /root/vless-qr.png ]; then
      if command -v display &>/dev/null; then
        display /root/vless-qr.png
      else
        echo "请安装 ImageMagick (sudo apt install imagemagick) 以查看二维码图片"
        echo "二维码文件路径：/root/vless-qr.png"
      fi
    else
      echo "二维码文件不存在：/root/vless-qr.png"
    fi
    ;;
  *)
    echo -e "\\033[36m========= sky-vless 节点信息 =========\\033[0m"
    echo "UUID: $UUID"
    echo "IP: $IP"
    echo "PublicKey: $PUBLIC_KEY"
    echo "ShortID: $SHORT_ID"
    echo
    echo "VLESS 链接："
    echo "$VLESS_URL"
    echo
    echo "二维码路径：/root/vless-qr.png"
    echo
    systemctl status sing-box --no-pager
    ;;
esac
EOF

chmod +x /usr/bin/sb

green "[9/9] 安装完成！"
green "使用命令 sb 查看节点信息"
green "使用命令 sb qr 查看二维码（需要 ImageMagick 支持）"
