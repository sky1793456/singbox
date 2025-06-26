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
    DEBIAN_FRONTEND=noninteractive apt install -y curl wget openssl jq uuid-runtime qrencode coreutils iptables ufw logrotate
    ufw allow ssh
  fi
}
install_deps

# 4. 安装 sing-box & 生成 Reality 密钥和 UUID
echo "🔑 安装 sing-box，生成 UUID 和 Reality 密钥..."
bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"
KEYS=$(sing-box generate reality-keypair --json)
UUID0=$(uuidgen)
PRIVATE_KEY=$(jq -r .private_key <<<"$KEYS")
PUBLIC_KEY=$(jq -r .public_key  <<<"$KEYS")
SID0=$(head -c4 /dev/urandom | xxd -p)

# 5. 初始化节点设置和目录备份
PROTOS=(vless)
UUIDS=("$UUID0")
PORTS=(443)
SIDS=("$SID0")
TAGS=("sky-vless-0")
DOMAIN=""
SNI=""

mkdir -p /etc/sing-box /var/log/sing-box /usr/local/lib/singbox-extensions
[[ -f /etc/sing-box/config.json ]] && cp /etc/sing-box/config.json /etc/sing-box/config.json.bak

# 6. 写配置脚本
cat > /etc/sing-box/write_config.sh <<'WC'
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
  handshake=$( [[ -n "$SNI" ]] && jq -n --arg s "$SNI" '{server:$s,server_port:443}' || echo null )
  entry=$(jq -n \
    --arg tag "${TAGS[i]}" \
    --arg type "${PROTOS[i]}" \
    --argjson port "${PORTS[i]}" \
    --arg uuid "${UUIDS[i]}" \
    --arg sid "${SIDS[i]}" \
    --arg pk "$PRIVATE_KEY" \
    --argjson hs "$handshake" \
    --arg sni "$SNI" \
    '{
      tag:$tag, type:$type, listen:"0.0.0.0", listen_port:$port,
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
  inb=$(jq --argjson x "$entry" '. + [$x]' <<<"$inb")
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

# 7. 应用配置并启动 sing-box
export LOG_LEVEL DOMAIN SNI PRIVATE_KEY PROTOS UUIDS PORTS SIDS TAGS
bash /etc/sing-box/write_config.sh
systemctl enable --now sing-box

# 8. 日志轮转设置
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

# 9. 生成订阅和二维码
SUBS=()
for i in "${!UUIDS[@]}"; do
  url="vless://${UUIDS[i]}@${DOMAIN:-127.0.0.1}:${PORTS[i]}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SIDS[i]}"
  SUBS+=("$url")
done
qrencode -o /root/vless_reality.png "${SUBS[0]}"
echo "✅ 安装完成，二维码保存在 /root/vless_reality.png"

# 10. 生成 sb 管理脚本
cat > /usr/local/bin/sb <<'SB'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  cat <<HELP
sb 管理脚本
使用方法：sb subcommand [args]
subcommand:
  node [list|add|rename]   节点管理
  domain [set|delete]      域名管理
  port [set|open]          端口管理
  log [view|delete|level]  日志管理
  bbr [install|status|uninstall]  BBR 管理
  update [script|singbox|verify] 更新与验证
  status                   查看服务状态
  qr                       渲染二维码
  sub                      打印订阅链接
  uninstall                卸载清理
HELP
  exit 0
fi

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

node(){
  case "$2" in
    list)
      for i in "${!UUIDS[@]}"; do echo "[$i] ${TAGS[i]} ${PROTOS[i]} port=${PORTS[i]}"; done ;;
    add)
      echo "选择协议:1)VLESS 2)Trojan 3)VMess 4)Shadowsocks"
      read -rp "> " c
      case $c in
        2) proto=trojan ;;
        3) proto=vmess ;;
        4) proto=shadowsocks ;;
        *) proto=vless ;;
      esac
      read -rp "端口: " np
      NU=$(uuidgen); NS=$(head -c4 /dev/urandom | xxd -p)
      PROTOS+=(\$proto); UUIDS+=(\$NU); PORTS+=(\$np); SIDS+=(\$NS); TAGS+=(sky-\$proto-\$NS)
      write_config && systemctl restart sing-box
      echo "✅ 添加节点 \$proto" ;;
    rename)
      read -rp "编号: " idx; read -rp "新标签: " nn
      TAGS[\$idx]=\$nn; write_config && systemctl restart sing-box
      echo "✅ 重命名完成" ;;
    *)
      echo "用法: sb node [list|add|rename]" ;;
  esac
}

domain(){
  case "$2" in
    set)
      read -rp "新域名: " d; DOMAIN=\$d; SNI=\$d
      write_config && systemctl restart sing-box
      echo "✅ 域名设置为 \$DOMAIN" ;;
    delete)
      read -rp "确认删除域名？(Y/n) " yn
      [[ \$yn =~ ^[Yy] ]] && DOMAIN=""; SNI=""; write_config && systemctl restart sing-box
      echo "✅ 域名已删除" ;;
    *)
      echo "用法: sb domain [set|delete]" ;;
  esac
}

port(){
  case "$2" in
    set)
      read -rp "编号: " idx; read -rp "新端口: " np
      [[ \$np =~ ^[0-9]{1,5}$ ]] || { echo "端口不合法"; exit 1; }
      ss -tunlp|grep -q ":$np" && { echo "端口 $np 被占用"; exit 1; }
      PORTS[\$idx]=\$np; write_config && systemctl restart sing-box
      echo "✅ 端口更新完成" ;;
    open)
      ports=(80 443 "\${PORTS[@]}")
      iptables -I INPUT -p tcp -m multiport --dports $(IFS=,;echo "\${ports[*]}") -j ACCEPT
      iptables-save && echo "✅ 放行完成" ;;
    *)
      echo "用法: sb port [set|open]" ;;
  esac
}

log(){
  case "$2" in
    view) less /var/log/sing-box/sing-box.log ;;
    delete)
      read -rp "确认删除日志？(Y/n) " yn
      [[ \$yn =~ ^[Yy] ]] && rm -f /var/log/sing-box/sing-box.log && echo "✅ 日志已删除" ;;
    level)
      echo "日志等级:1)off 2)error 3)warning 4)info 5)debug"
      read -rp "> " lvl
      case \$lvl in
        1) LOG_LEVEL=off ;;
        2) LOG_LEVEL=error ;;
        3) LOG_LEVEL=warning ;;
        4) LOG_LEVEL=info ;;
        5) LOG_LEVEL=debug ;;
        *) echo "无效选项"; exit 1 ;;
      esac
      write_config && systemctl restart sing-box
      echo "✅ 日志等级设置为 \$LOG_LEVEL" ;;
    *)
      echo "用法: sb log [view|delete|level]" ;;
  esac
}

bbr(){
  case "$2" in
    install)
      modprobe tcp_bbr
      echo "tcp_bbr" >>/etc/modules-load.d/modules.conf
      echo "net.core.default_qdisc=fq" >>/etc/sysctl.conf
      echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.conf
      sysctl -p && echo "✅ BBR 安装启用" ;;
    status)
      cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
      lsmod | grep -q bbr && echo "✔ BBR 已启用($cc)" || echo "✘ BBR 未启用" ;;
    uninstall)
      sed -i '/tcp_bbr/d;/default_qdisc/d;/congestion_control/d' /etc/sysctl.conf
      sed -i '/tcp_bbr/d' /etc/modules-load.d/modules.conf
      sysctl -p && echo "✅ BBR 已移除" ;;
    *)
      echo "用法: sb bbr [install|status|uninstall]" ;;
  esac
}

update(){
  case "$2" in
    script)
      cp /usr/local/bin/sb /usr/local/bin/sb.bak
      curl -Ls https://raw.githubusercontent.com/sky1793456/singbox/main/install_singbox.sh -o /usr/local/bin/sb
      chmod +x /usr/local/bin/sb
      echo "✅ 脚本已更新" ;;
    singbox)
      bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"
      echo "✅ sing-box 更新完成" ;;
    verify)
      echo "sing-box: $(which sing-box)"
      echo "qrencode: $(which qrencode)" ;;
    *)
      echo "用法: sb update [script|singbox|verify]" ;;
  esac
}

status(){ systemctl status sing-box; }
qr(){ for u in "${SUBS[@]}"; do qrencode -t ANSIUTF8 "$u"; done; }
sub(){ printf "%s\n" "${SUBS[@]}"; }

uninstall(){
  read -rp "确认卸载所有？(Y/n) " yn
  [[ $yn =~ ^[Yy] ]] || exit
  systemctl disable --now sing-box
  rm -rf /etc/sing-box /var/log/sing-box /usr/local/lib/singbox-extensions
  iptables -D INPUT -p tcp -m multiport --dports 80,443,"${PORTS[*]}" -j ACCEPT || :
  rm -f /usr/local/bin/sb
  echo "✅ 已卸载全部内容"
}

for ext in /usr/local/lib/singbox-extensions/*.sh; do
  [[ -r $ext ]] && source "$ext"
done

case "${1:-}" in
  node)     node "$@" ;;
  domain)   domain "$@" ;;
  port)     port "$@" ;;
  log)      log "$@" ;;
  bbr)      bbr "$@" ;;
  update)   update "$@" ;;
  status)   status ;;
  qr)       qr ;;
  sub)      sub ;;
  uninstall) uninstall ;;
  *) sb --help ;;
esac
SB
chmod +x /usr/local/bin/sb

# 11. 输出安装完成信息并引导
echo "✅ 安装完成！使用 sb --help 查看所有功能"
