#!/bin/bash

set -e

# ========= 环境检查与依赖安装 =========

echo "✅ 正在检测系统依赖..."

# 检测操作系统类型
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  echo "❌ 无法识别系统类型"
  exit 1
fi

# 设置包管理器
if [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
  PM="apt"
elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
  PM="yum"
else
  echo "❌ 不支持的系统: $OS"
  exit 1
fi

# 检查是否安装 curl 或 wget
if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
  echo "❌ curl 和 wget 都未安装，开始安装..."
  $PM install -y curl wget
else
  echo "✅ 找到 curl 或 wget 工具，继续执行"
fi

# 安装其他必要依赖
echo "📥 安装依赖: openssl, uuidgen, qrencode"
$PM update -y
$PM install -y openssl uuid-runtime qrencode coreutils wget

# ========= 开始部署 =========

echo "🚀 开始安装 Sing-box VLESS + Reality"

UUID=$(uuidgen)
PRIVATE_KEY=$(openssl rand -base64 32)

# 安装 sing-box
bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"

# 生成 Reality 公钥
KEY_OUTPUT=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep Private | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep Public | awk '{print $3}')

SHORT_ID=$(head -c 4 /dev/urandom | xxd -p)
DOMAIN="sky-lever-1793456.xyz"
SNI="www.bing.com"
PORT=443

mkdir -p /etc/sing-box
mkdir -p /var/log/sing-box

# ========= 配置文件 =========
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",
    "output": "file",
    "log_file": "/var/log/sing-box/sing-box.log"
  },
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1"
    ],
    "disable_udp": false
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

# 启动服务
systemctl enable sing-box
systemctl restart sing-box

VLESS_URL="vless://$UUID@$DOMAIN:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID#skydoing-VLESS-REALITY-$DOMAIN"

# 生成二维码
qrencode -o /root/vless_reality.png "$VLESS_URL"

# ========= 创建 sb 菜单工具 =========
cat > /usr/local/bin/sb <<EOF
#!/bin/bash

UUID="$UUID"
DOMAIN="$DOMAIN"
SNI="$SNI"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
PORT=$PORT
VLESS_URL="$VLESS_URL"

function show_main() {
  clear
  echo "========== 节点信息 =========="
  echo "UUID: \$UUID"
  echo "域名: \$DOMAIN"
  echo "PublicKey: \$PUBLIC_KEY"
  echo "ShortID: \$SHORT_ID"
  echo "SNI: \$SNI"
  echo "端口: \$PORT"
  echo ""
  echo "VLESS 链接："
  echo "\$VLESS_URL"
  echo ""
  echo "二维码图片：/root/vless_reality.png"
  echo ""
  echo "服务状态："
  systemctl status sing-box | grep -E "Active|Loaded"
  echo ""
  echo "日志路径：/var/log/sing-box/sing-box.log"
}

function show_qr() {
  if command -v qrencode >/dev/null; then
    qrencode -t ANSIUTF8 "\$VLESS_URL"
  else
    echo "未安装 qrencode"
  fi
}

function update_singbox() {
  echo "🔄 正在更新 sing-box..."
  bash -c "\$(curl -Ls https://sing-box.app/deb-install.sh)"
  echo "✅ 更新完成"
}

function show_menu() {
  while true; do
    echo ""
    echo "========= Sing-box 菜单 ========="
    echo "1) 查看节点信息"
    echo "2) 生成二维码"
    echo "3) 更新 Sing-box"
    echo "4) 退出"
    echo -n "请选择操作 [1-4]: "
    read option
    case "\$option" in
      1) show_main ;;
      2) show_qr ;;
      3) update_singbox ;;
      4) exit 0 ;;
      *) echo "❌ 无效选择，请输入 1-4。" ;;
    esac
  done
}

show_menu
EOF

chmod +x /usr/local/bin/sb

echo ""
echo "✅ 安装完成！现在你可以运行命令："
echo "👉  sb        # 进入菜单"
echo "👉  sb qr     # 生成终端二维码"
echo "👉  tail -f /var/log/sing-box/sing-box.log  # 查看运行日志"
echo ""