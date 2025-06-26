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
  # 返回两个版本号中较小的那个
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

# --- 生成 Reality 密钥（兼容新版和旧版） ---
if sing-box generate reality-keypair --json &>/dev/null; then
  KEYS=$(sing-box generate reality-keypair --json)
  PRIVATE_KEY=$(jq -r .private_key <<< "$KEYS")
  PUBLIC_KEY=$(jq -r .public_key <<< "$KEYS")
else
  KEYS=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(awk '/PrivateKey/ {print $2}' <<< "$KEYS")
  PUBLIC_KEY=$(awk '/PublicKey/ {print $2}' <<< "$KEYS")
fi

# --- 生成 UUID 和 short ID ---
UUID0=$(uuidgen)
SID0=$(head -c4 /dev/urandom | xxd -p)

# --- 初始化配置参数 ---
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
  # 生成 reality handshake 配置
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
    '{
      tag:$tag,
      type:$type,
      listen:"0.0.0.0",
      listen_port:$port,
      sniff:{enabled:false},
      users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],
      tls:{
        enabled:true,
        reality:{
          enabled:true,
          handshake:$hs,
          private_key:$pk,
          short_id:[$sid]
        },
        server_name:$sni
      }
    }')

  inb=$(jq --argjson x "$entry" '. + [$x]' <<< "$inb")
done

jq -n \
  --arg logf "/var/log/sing-box/sing-box.log" \
  --arg lvl "$LOG_LEVEL" \
  --argjson inb "$inb" \
  '{
    log:{level:$lvl,output:"file",log_file:$logf},
    dns:{servers:["8.8.8.8","1.1.1.1"],disable_udp:false},
    inbounds:$inb,
    outbounds:[{type:"direct"}]
  }' > /etc/sing-box/config.json
WC

chmod +x /etc/sing-box/write_config.sh

# --- 导出环境变量供配置脚本使用 ---
export LOG_LEVEL DOMAIN SNI PRIVATE_KEY PROTOS UUIDS PORTS SIDS TAGS

# --- 生成配置文件 ---
bash /etc/sing-box/write_config.sh

# --- 启用并启动 sing-box ---
systemctl enable --now sing-box

# --- 设置日志轮转 ---
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

# --- 生成订阅链接和二维码 ---
SUBS=()
for i in "${!UUIDS[@]}"; do
  SUBS+=("vless://${UUIDS[i]}@${DOMAIN:-127.0.0.1}:${PORTS[i]}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SIDS[i]}")
done

qrencode -o /root/vless_reality.png "${SUBS[0]}"

echo "✅ 安装完成！二维码保存在 /root/vless_reality.png"

# --- 生成管理脚本 sb ---
cat > /usr/local/bin/sb << SB
#!/usr/bin/env bash
set -Eeuo pipefail

# sb 管理脚本帮助信息
if [[ "\${1:-}" =~ ^(-h|--help|help)\$ ]]; then
  cat << HELP
sb 管理脚本
sb node [list|add|rename]       节点操作
sb domain [set|delete]          设置/清除域名
sb port [set|open]              修改/放行端口
sb log [view|delete|level]      日志查看/管理
sb bbr [install|status|uninstall] BBR 管理
sb update [script|singbox|verify] 更新与验证
sb status                       sing-box 服务状态
sb qr                           渲染二维码
sb sub                          显示订阅链接
sb uninstall                    卸载全部内容
HELP
  exit 0
fi

# 配置参数 (请确保更新此处为实际值)
declare -a PROTOS=(__PROTOS__)
declare -a UUIDS=(__UUIDS__)
declare -a PORTS=(__PORTS__)
declare -a SIDS=(__SIDS__)
declare -a TAGS=(__TAGS__)
DOMAIN="__DOMAIN__"
SNI="__SNI__"
PUBLIC_KEY="__PUBLIC_KEY__"
declare -a SUBS=(__SUBS__)
LOG_LEVEL="info"

source /etc/sing-box/write_config.sh

# 以下函数需根据具体需求实现
node(){ echo "功能开发中..." >&2; }
domain(){ echo "功能开发中..." >&2; }
port(){ echo "功能开发中..." >&2; }
log(){ echo "功能开发中..." >&2; }
bbr(){ echo "功能开发中..." >&2; }
update(){ echo "功能开发中..." >&2; }
status(){ systemctl status sing-box; }
qr(){ for u in "\${SUBS[@]}"; do qrencode -t ANSIUTF8 "\$u"; done; }
sub(){ printf "%s\n" "\${SUBS[@]}"; }
uninstall(){ echo "功能开发中..." >&2; }

# 加载扩展脚本
for ext in /usr/local/lib/singbox-extensions/*.sh; do
  [[ -r \$ext ]] && source "\$ext"
done

case "\${1:-}" in
  node|domain|port|log|bbr|update|status|qr|sub|uninstall) "\$@" ;;
  *) sb --help ;;
esac
SB

chmod +x /usr/local/bin/sb

echo "✅ 完整安装和配置已完成！请运行 sb 查看功能."