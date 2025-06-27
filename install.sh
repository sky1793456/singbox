#!/bin/bash

# sing-box 一键安装脚本（修改版）
# 修复 Reality 密钥生成问题，完善依赖安装和服务启动

set -e

BIN_PATH="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
KEY_FILE="$CONFIG_DIR/keys.txt"

# 检查并安装必备命令 curl wget
install_dep() {
  echo "[*] 检查依赖: curl wget"
  for cmd in curl wget; do
    if ! command -v $cmd >/dev/null 2>&1; then
      echo "[*] 检测到 $cmd 未安装，正在安装..."
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y $cmd
      elif command -v yum >/dev/null 2>&1; then
        yum install -y $cmd
      else
        echo "错误：无法自动安装 $cmd，请手动安装后重试。"
        exit 1
      fi
    else
      echo "[*] $cmd 已安装"
    fi
  done
}

install_dep

echo "[*] 创建配置目录 $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

# 获取 sing-box 最新版本和下载链接
echo "[*] 获取 Sing-box 最新版本下载链接…"
LATEST_JSON=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest)
VERSION=$(echo "$LATEST_JSON" | grep -Po '"tag_name": "\K.*?(?=")')
VERSION_NO_V=${VERSION#v}  # 去掉前缀 v

DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/$VERSION/sing-box-$VERSION_NO_V-linux-amd64.tar.gz"

echo "    → 版本: $VERSION"
echo "    → 链接: $DOWNLOAD_URL"

# 下载并安装 sing-box
echo "[*] 下载并安装 sing-box ..."
curl -L "$DOWNLOAD_URL" -o /tmp/sing-box.tar.gz
tar -zxf /tmp/sing-box.tar.gz -C /tmp
chmod +x /tmp/sing-box
mv /tmp/sing-box "$BIN_PATH"

# 生成 Reality 密钥对，直接解析命令输出
echo "[*] 生成 Reality 密钥对..."
KEY_OUTPUT=$("$BIN_PATH" generate reality-key)
if [[ $? -ne 0 || -z "$KEY_OUTPUT" ]]; then
  echo "❌ Reality 密钥对生成失败"
  exit 1
fi

PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep PrivateKey | awk '{print $2}' | tr -d '\r\n ')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep PublicKey | awk '{print $2}' | tr -d '\r\n ')
SHORT_ID=$(echo "$KEY_OUTPUT" | grep -i shortid | awk '{print $2}' | tr -d '\r\n ')

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || -z "$SHORT_ID" ]]; then
  echo "❌ 提取 Reality 密钥失败"
  echo "$KEY_OUTPUT"
  exit 1
fi

echo "$KEY_OUTPUT" > "$KEY_FILE"
echo "[*] Reality 密钥对已保存到 $KEY_FILE"

# 写入示例配置文件（请根据实际需求修改）
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "inbounds": [],
  "outbounds": [],
  "reality": {
    "private_key": "$PRIVATE_KEY",
    "public_key": "$PUBLIC_KEY",
    "short_id": "$SHORT_ID"
  }
}
EOF

echo "[*] 配置文件已写入 $CONFIG_DIR/config.json"

# systemd 服务配置并启动
if command -v systemctl >/dev/null 2>&1; then
  echo "[*] 设置 sing-box 服务开机启动"
  cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Service
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH run -c $CONFIG_DIR/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
  systemctl restart sing-box
else
  echo "警告：系统不支持 systemctl，无法设置服务开机自启"
fi

echo -e "\n安装完成，正在启动管理菜单...\n"
exec "$BIN_PATH" manage
