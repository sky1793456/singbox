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

echo "📦 使用包管理器: $PM"

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
echo "📦 安装 sing-box ..."
bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"

# 生成 Reality 公钥
PUBLIC_KEY=$(sing-box generate reality-keypair | grep Public | awk '{print $2}')

SHORT_ID=$(head -c 4 /dev/urandom | xxd -p)
DOMAIN="sky-lever-1793456.xyz"
SNI="www.bing.com"
PORT=443

mkdir -p /etc/sing-box

# ========= 更新配置文件 =========
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",  # 日志级别：debug, info, warn, error
    "output": "file",  # 控制台输出（console） 或 文件输出（file）
    "log_file": "/var/log/sing-box/sing-box.log"  # 日志文件路径
  },
  "dns": {
    "servers": [
      "8.8.8.8",  # Google DNS
      "1.1.1.1"   # Cloudflare DNS
    ],
    "disable_udp": false  # 是否禁用 DNS over UDP
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",  # 或者 "0.0.0.0"
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

# 启动 sing-box
echo "🔁 启动 sing-box ..."
systemctl enable sing-box
systemctl restart sing-box

VLESS_URL="vless://$UUID@$DOMAIN:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID#skydoing-VLESS-REALITY-$DOMAIN"

# ========= 创建 sb 管理命令 =========
cat > /usr/local/bin/sb <<EOF
#!/bin/bash

UUID="$UUID"
DOMAIN="$DOMAIN"
SNI="$SNI"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
PORT=$PORT
VLESS_URL="$VLESS_URL"

bold_green="\\e[1;32m"
bold_cyan="\\e[1;36m"
bold_yellow="\\e[1;33m"
bold_red="\\e[1;31m"
reset="\\e[0m"

function show_main() {
  clear
  echo -e "\${bold_cyan}========== Sing-box 节点信息 ==========\${reset}"
  echo -e "\${bold_yellow}UUID：\${reset} \$UUID"
  echo -e "\${bold_yellow}域名：\${reset} \$DOMAIN"
  echo -e "\${bold_yellow}PublicKey：\${reset} \$PUBLIC_KEY"
  echo -e "\${bold_yellow}ShortID：\${reset} \$SHORT_ID"
  echo -e "\${bold_yellow}SNI：\${reset} \$SNI"
  echo -e "\${bold_yellow}端口：\${reset} \$PORT"
  echo -e "\\n\${bold_green}VLESS 链接：\${reset}"
  echo "\$VLESS_URL"
  echo -e "\\n\${bold_cyan}服务状态：\${reset}"
  systemctl status sing-box | grep -E "Active|Loaded"
  echo -e "\\n二维码文件路径：/root/vless_reality.png"
}

function show_qr() {
  if command -v qrencode >/dev/null; then
    qrencode -t ANSIUTF8 "\$VLESS_URL"
  else
    echo -e "\${bold_red}未安装 qrencode${reset}"
  fi
}

function update_singbox() {
  echo -e "${bold_cyan}正在更新 sing-box ...${reset}"
  bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"
  echo -e "${bold_green}更新完成！${reset}"
}

function show_menu() {
  clear
  echo -e "\${bold_cyan}========== Sing-box 菜单 ==========\${reset}"
  echo "1) 查看节点信息"
  echo "2) 生成二维码"
  echo "3) 更新 Sing-box"
  echo "4) 退出"
  echo -n "请输入选项 [1-4]: "
  read option
  case "\$option" in
    1) show_main ;;
    2) show_qr ;;
    3) update_singbox ;;
    4) exit 0 ;;
    *) echo "无效的选项，请选择 [1-4]" ; show_menu ;;
  esac
}

show_menu
EOF

chmod +x /usr/local/bin/sb

# ========= 完成提示 =========

echo ""
echo "✅ 安装完成！你可以使用以下命令："
echo "👉  sb        # 进入菜单"
echo ""
