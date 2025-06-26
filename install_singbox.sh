#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# --- 检查 root 权限 ---
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行脚本！"
  exit 1
fi

# --- 出错回滚配置 ---
trap 'echo "❗ 出错，回滚配置"; [[ -f /etc/sing-box/config.json.bak ]] && mv /etc/sing-box/config.json.bak /etc/sing-box/config.json; exit 1' ERR SIGINT

# --- 安装依赖 ---
install_deps(){
  . /etc/os-release
  if [[ "$ID" =~ ^(centos|rhel)$ ]]; then
    yum install -y epel-release
    yum install -y curl wget openssl jq uuid-runtime qrencode coreutils iptables firewalld logrotate
    systemctl enable --now firewalld
  else
    apt update -y
    DEBIAN_FRONTEND=noninteractive apt install -y curl wget openssl jq uuid-runtime qrencode coreutils iptables ufw logrotate
    ufw allow ssh
  fi
}
install_deps

# --- 版本比较函数 ---
vercmp() {
  printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1
}

# --- 检查并升级 sing-box ---
NEED_VER="1.13.0"
if command -v sing-box &>/dev/null; then
  OLD_VER=$(sing-box version | awk '{print $NF}')
else
  OLD_VER="0.0.0"
fi

if [[ "$(vercmp "$OLD_VER" "$NEED_VER")" == "$OLD_VER" ]]; then
  echo "⬆️ 当前版本 $OLD_VER 小于 $NEED_VER，升级 sing-box..."
  bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"
fi

NEW_VER=$(sing-box version | awk '{print $NF}')
echo "✅ sing-box 版本: $NEW_VER"

# --- 生成 Reality 密钥 ---
if sing-box generate reality-keypair --json &>/dev/null; then
  KEYS=$(sing-box generate reality-keypair --json)
  PRIVATE_KEY=$(jq -r .private_key <<< "$KEYS")
  PUBLIC_KEY=$(jq -r .public_key <<< "$KEYS")
else
  KEYS=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(awk '/PrivateKey/ {print $2}' <<< "$KEYS")
  PUBLIC_KEY=$(awk '/PublicKey/ {print $2}' <<< "$KEYS")
fi

echo "🔑 Reality 私钥: $PRIVATE_KEY"
echo "🔑 Reality 公钥: $PUBLIC_KEY"

# --- 生成 UUID 和 short ID ---
UUID0=$(uuidgen)
SID0=$(head -c4 /dev/urandom | xxd -p)

echo "🎲 UUID: $UUID0"
echo "🆔 Short ID: $SID0"

# --- 初始化参数 ---
PROTOS=(vless)
UUIDS=("$UUID0")
PORTS=(443)
SIDS=("$SID0")
TAGS=("sky-vless-0")
DOMAIN=""
SNI=""

# --- 目录准备 ---
mkdir -p /etc/sing-box /var/log/sing-box /usr/local/lib/singbox-extensions
[[ -f /etc/sing-box/config.json ]] && cp /etc/sing-box/config.json /etc/sing-box/config.json.bak

# --- 写配置脚本 ---
cat > /etc/sing-box/write_config.sh << 'WC'
#!/usr/bin/env bash
set -Eeuo pipefail

LOG_LEVEL=${LOG_LEVEL:-info}
DOMAIN=${DOMAIN:-}
SNI=${SNI:-}
PRIVATE_KEY=${PRIVATE_KEY}

PROTOS=(${PROTOS[@]})
UUIDS=(${UUIDS[@]})
PORTS=(${PORTS[@]})
SIDS=(${SIDS[@]})
TAGS=(${TAGS[@]})

inb=$(jq -n '[]')
for i in "${!UUIDS[@]}"; do
  if [[ -n "$SNI" ]]; then
    hs=$(jq -n --arg s "$SNI" '{server:$s,server_port:443}')
  else
    hs=null
  fi
  entry=$(jq -n \
    --arg tag "${TAGS[i]}" \
    --arg type "${PROTOS[i]}" \
    --argjson port "${PORTS[i]}" \
    --arg uuid "${UUIDS[i]}" \
    --arg sid "${SIDS[i]}" \
    --arg pk "$PRIVATE_KEY" \
    --argjson hs "$hs" \
    --arg sni "$SNI" \
    '{tag:$tag,type:$type,listen:"0.0.0.0",listen_port:$port,sniff:{enabled:false},users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,reality:{enabled:true,handshake:$hs,private_key:$pk,short_id:[$sid]},server_name:$sni}}')
  inb=$(jq --argjson x "$entry" '. + [$x]' <<< "$inb")
done

jq -n \
  --arg logf "/var/log/sing-box/sing-box.log" \
  --arg lvl "$LOG_LEVEL" \
  --argjson inb "$inb" \
  '{log:{level:$lvl,output:"file",log_file:$logf},dns:{servers:["8.8.8.8","1.1.1.1"],disable_udp:false},inbounds:$inb,outbounds:[{type:"direct"}]}' > /etc/sing-box/config.json
WC

chmod +x /etc/sing-box/write_config.sh

# --- 导出环境变量，生成配置并启动 ---
export LOG_LEVEL="info"
export DOMAIN
export SNI
export PRIVATE_KEY
export PROTOS
export UUIDS
export PORTS
export SIDS
export TAGS

bash /etc/sing-box/write_config.sh
systemctl enable --now sing-box

# --- 日志轮转 ---
cat > /etc/logrotate.d/sing-box << 'LR'
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

# --- 生成订阅 & 二维码 ---
SUBS=()
for i in "${!UUIDS[@]}"; do
  SUBS+=("vless://${UUIDS[i]}@${DOMAIN:-127.0.0.1}:${PORTS[i]}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SIDS[i]}")
done
qrencode -o /root/vless_reality.png "${SUBS[0]}"

# --- 生成 sb 管理脚本 ---
cat > /usr/local/bin/sb <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

# 导入环境（已写入）
export LOG_LEVEL="info"
export DOMAIN="${DOMAIN}"
export SNI="${SNI}"
export PRIVATE_KEY="${PRIVATE_KEY}"

PROTOS=(${PROTOS[@]})
UUIDS=(${UUIDS[@]})
PORTS=(${PORTS[@]})
SIDS=(${SIDS[@]})
TAGS=(${TAGS[@]})
PUBLIC_KEY="${PUBLIC_KEY}"
SUBS=(${SUBS[@]})

# 写配置并重启服务
source /etc/sing-box/write_config.sh

# 子命令函数
node(){ echo "功能开发中..." >&2; }
domain(){ echo "功能开发中..." >&2; }
port(){ echo "功能开发中..." >&2; }
log(){ echo "功能开发中..." >&2; }
bbr(){ echo "功能开发中..." >&2; }
update(){ echo "功能开发中..." >&2; }
status(){ systemctl status sing-box; }
qr(){ for u in "${SUBS[@]}"; do qrencode -t ANSIUTF8 "$u"; done; }
sub(){ printf "%s\n" "${SUBS[@]}"; }
uninstall(){ echo "功能开发中..." >&2; }

# 加载扩展脚本
for ext in /usr/local/lib/singbox-extensions/*.sh; do
  [[ -r $ext ]] && source "$ext"
done

case "${1:-}" in
  node|domain|port|log|bbr|update|status|qr|sub|uninstall) "$@" ;;
  *) sb --help ;;
esac
EOF

chmod +x /usr/local/bin/sb

echo "✅ 安装和配置完成！请运行 sb 查看功能。"
