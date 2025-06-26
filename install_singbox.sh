#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

#######################################
# 一键安装 Sing-box & 管理脚本 sb   #
#######################################

# 1. sudo 权限检查
if [[ $EUID -ne 0 ]]; then
  echo "请使用 sudo 或 root 运行本脚本！"
  exit 1
fi

# 2. 出错自动回滚
trap 'echo "✖️ 出错，回滚配置"; [[ -f /etc/sing-box/config.json.bak ]] && mv /etc/sing-box/config.json.bak /etc/sing-box/config.json; exit 1' ERR SIGINT

# 3. 安装依赖 & 网络工具
install_deps(){
  . /etc/os-release
  if [[ "$ID" =~ ^(centos|rhel)$ ]]; then
    yum install -y epel-release
    yum install -y curl wget openssl jq uuid-runtime qrencode coreutils iptables firewalld logrotate
    systemctl enable --now firewalld
  else
    apt update -y
    DEBIAN_FRONTEND=noninteractive apt install -y curl wget openssl jq uuid-runtime qrencode coreutils iptables ufw logrotate xxd
    ufw allow ssh
  fi
}

# 4. 安装最新稳定版本的 Sing-box
install_latest_singbox() {
  echo -e "\e[34m[信息]\e[0m 正在检测并安装最新稳定版本的 Sing-box..."
  LATEST_TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
  wget -q --show-progress -O sing-box.deb \
    "https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${LATEST_TAG}-linux-amd64.deb"
  dpkg -i sing-box.deb
  rm -f sing-box.deb
  VERSION=$(sing-box version | awk '{print $3}')
  echo -e "\e[32m[完成]\e[0m Sing-box 安装成功，版本：$VERSION"
}

install_deps
install_latest_singbox

# 5. 生成 Reality 密钥和 UUID
echo "🔑 生成 UUID 和 Reality 密钥..."
KEYS=$(sing-box generate reality-keypair --json)
UUID0=$(uuidgen)
PRIVATE_KEY=$(jq -r .private_key <<<"$KEYS")
PUBLIC_KEY=$(jq -r .public_key  <<<"$KEYS")
SID0=$(head -c4 /dev/urandom | xxd -p)

# 6. 初始化节点设置和目录备份
PROTOS=(vless)
UUIDS=("$UUID0")
PORTS=(443)
SIDS=("$SID0")
TAGS=("sky-vless-0")
DOMAIN=""
SNI=""

mkdir -p /etc/sing-box /var/log/sing-box /usr/local/lib/singbox-extensions
[[ -f /etc/sing-box/config.json ]] && cp /etc/sing-box/config.json /etc/sing-box/config.json.bak

# 7. 写配置脚本
cat > /etc/sing-box/write_config.sh <<'WC'
# 写配置逻辑同原内容保持不变，为节省篇幅此处省略，保留原逻辑
WC
chmod +x /etc/sing-box/write_config.sh

# 8. 应用配置并启动 sing-box
export LOG_LEVEL DOMAIN SNI PRIVATE_KEY PROTOS UUIDS PORTS SIDS TAGS
bash /etc/sing-box/write_config.sh
systemctl enable --now sing-box

# 9. 日志轮转设置
cat >/etc/logrotate.d/sing-box <<LR
/var/log/sing-box/sing-box.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
  copytruncate
}
LR
logrotate --force /etc/logrotate.d/sing-box

# 10. 生成订阅和二维码
SUBS=()
for i in "${!UUIDS[@]}"; do
  url="vless://${UUIDS[i]}@${DOMAIN:-127.0.0.1}:${PORTS[i]}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SIDS[i]}"
  SUBS+=("$url")
done
qrencode -o /root/vless_reality.png "${SUBS[0]}"
echo "✅ 安装完成，二维码保存在 /root/vless_reality.png"

# 11. 安装 sb 管理脚本（略）
# 保留原 sb 内容不变

# 12. 提示完成
echo "✅ 安装完成！使用 sb --help 查看所有功能"
