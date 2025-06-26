#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

#######################################
# 一键安装 Sing-box & 管理脚本 sb   #
#######################################

# —— 1. sudo 检查 —— 
if [[ $EUID -ne 0 ]]; then
  echo "请使用 sudo 或 root 运行本脚本！"
  exit 1
fi

# —— 2. 错误或中断时回滚旧配置 —— 
trap 'echo "✖️ 发生错误，回滚配置"; [[ -f /etc/sing-box/config.json.bak ]] && mv /etc/sing-box/config.json.bak /etc/sing-box/config.json; exit 1' ERR SIGINT

# —— 3. 安装依赖 & EPEL/Firewalld —— 
install_deps(){
  . /etc/os-release
  if [[ "$ID" =~ ^(centos|rhel)$ ]]; then
    yum install -y epel-release
    yum install -y curl wget openssl jq uuid-runtime qrencode coreutils iptables firewalld logrotate
    systemctl enable --now firewalld
  else
    apt update -y
    apt install -y curl wget openssl jq uuid-runtime qrencode coreutils iptables ufw logrotate
    ufw allow ssh
  fi
}
install_deps

# —— 4. 生成密钥 & UUID —— 
echo "🔑 生成 UUID 与 Reality 密钥对..."
UUID0=$(uuidgen)
KEYS=$(sing-box generate reality-keypair --json)
PRIVATE_KEY=$(jq -r .private_key <<<"$KEYS")
PUBLIC_KEY=$(jq -r .public_key  <<<"$KEYS")
SID0=$(head -c4 /dev/urandom | xxd -p)

# —— 5. 初始化数组 & 备份旧配置 —— 
PROTOS=(vless)
UUIDs=("$UUID0")
PORTs=(443)
SIDs=("$SID0")
TAGS=("sky-vless-0")
DOMAIN=""
SNI=""

mkdir -p /etc/sing-box /var/log/sing-box /usr/local/lib/singbox-extensions
[[ -f /etc/sing-box/config.json ]] && cp /etc/sing-box/config.json /etc/sing-box/config.json.bak

# —— 6. 写配置函数 (jq) & 写入独立脚本供 sb 调用 —— 
cat > /etc/sing-box/write_config.sh <<'WC'
#!/usr/bin/env bash
set -Eeuo pipefail

# 取环境变量
LOG_LEVEL=${LOG_LEVEL:-info}
DOMAIN=${DOMAIN:-}
SNI=${SNI:-}
PRIVATE_KEY=${PRIVATE_KEY}
PROTOS=(${PROTOS[@]})
UUIDs=(${UUIDs[@]})
PORTs=(${PORTs[@]})
SIDs=(${SIDs[@]})
TAGS=(${TAGS[@]})

# 构造 inbounds
inbounds=$(jq -n '[]')
for i in "${!UUIDs[@]}"; do
  proto="${PROTOS[i]}"
  tag="${TAGS[i]}"
  port="${PORTs[i]}"
  uuid="${UUIDs[i]}"
  sid="${SIDs[i]}"
  handshake=$( [[ -n "$SNI" ]] && jq -n --arg s "$SNI" '{server:$s,server_port:443}' || echo null )
  entry=$(jq -n \
    --arg tag "$tag" \
    --arg type "$proto" \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg sid "$sid" \
    --arg pk "$PRIVATE_KEY" \
    --argjson hs "$handshake" \
    --arg sni "$SNI" \
    '{
      tag:$tag,type:$type,listen:"0.0.0.0",listen_port:$port,
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
  inbounds=$(jq --argjson x "$entry" '. + [$x]' <<<"$inbounds")
done

# 输出 final config
jq -n \
  --arg logf "/var/log/sing-box/sing-box.log" \
  --arg level "$LOG_LEVEL" \
  --argjson ib "$inbounds" \
  '{
    log:{level:$level,output:"file",log_file:$logf},
    dns:{servers:["8.8.8.8","1.1.1.1"],disable_udp:false},
    inbounds:$ib,
    outbounds:[{type:"direct"}]
  }' > /etc/sing-box/config.json
WC
chmod +x /etc/sing-box/write_config.sh

# —— 7. 写入配置 & 启动服务 —— 
export LOG_LEVEL DOMAIN SNI PRIVATE_KEY PROTOS UUIDs PORTs SIDs TAGS
bash /etc/sing-box/write_config.sh
systemctl enable --now sing-box

# —— 8. 日志轮转 —— 
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

# —— 9. 生成订阅 & 二维码 —— 
SUBS=()
for i in "${!UUIDs[@]}"; do
  url="vless://${UUIDs[i]}@${DOMAIN:-127.0.0.1}:${PORTs[i]}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SIDs[i]}"
  SUBS+=("$url")
done
qrencode -o /root/vless_reality.png "${SUBS[0]}"
echo "✅ 安装完成！二维码保存在 /root/vless_reality.png"

# —— 10. 生成 sb 管理脚本 —— 
cat > /usr/local/bin/sb <<'SB'
#!/usr/bin/env bash
set -Eeuo pipefail

# —— 帮助信息 —— 
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  cat <<H
sb 管理脚本 - 子命令说明
1) node    节点管理
2) domain  域名管理
3) port    端口管理
4) log     日志管理
5) update  更新与验证
6) status  服务状态
7) qr      渲染二维码
8) sub     打印订阅链接
9) uninstall  卸载清理
H
  exit 0
fi

# —— 变量注入 —— 
declare -a PROTOS=(__PROTOS__)
declare -a UUIDs=(__UUIDs__)
declare -a PORTs=(__PORTs__)
declare -a SIDs=(__SIDs__)
declare -a TAGS=(__TAGS__)
DOMAIN="__DOMAIN__"
SNI="__SNI__"
PUBLIC_KEY="__PUBLIC_KEY__"
declare -a SUBS=(__SUBS__)
LOG_LEVEL="info"

# —— 写配置函数 —— 
write_config(){
  source /etc/sing-box/write_config.sh
}

# —— 子命令：node —— 
node(){
  case "$2" in
    list)
      for i in "${!UUIDs[@]}"; do
        echo "[$i] \${TAGS[i]} \${PROTOS[i]} port=\${PORTs[i]}"
      done;;
    add)
      echo "选择协议: 1)VLESS 2)Trojan 3)VMess 4)Shadowsocks"
      read -rp "> " c
      proto=vless
      [[ $c == 2 ]] && proto=trojan
      [[ $c == 3 ]] && proto=vmess
      [[ $c == 4 ]] && proto=shadowsocks
      read -rp "新端口: " np
      NU=\$(uuidgen); NS=\$(head -c4 /dev/urandom|xxd -p)
      PROTOS+=("\$proto"); UUIDs+=("\$NU"); PORTs+=("\$np"); SIDs+=("\$NS"); TAGS+=("sky-\$proto-\$NS")
      write_config; systemctl restart sing-box
      echo "✅ 添加节点 \$proto"
      ;;
    rename)
      read -rp "编号: " idx; read -rp "新标签: " nn
      TAGS[\$idx]=\$nn; write_config; systemctl restart sing-box
      echo "✅ 重命名完成"
      ;;
    *) echo "用法: sb node [list|add|rename]";;
  esac
}

# —— 子命令：domain —— 
domain(){
  case "$2" in
    set)
      read -rp "新域名: " d; DOMAIN=\$d; SNI=\$d; write_config; systemctl restart sing-box
      echo "✅ 域名设置为 \$DOMAIN";;
    delete)
      read -rp "确认删除? (Y/n) " c
      [[ \$c =~ ^[Yy] ]] && DOMAIN=""; SNI=""; write_config; systemctl restart sing-box
      echo "✅ 域名已删除";;
    *) echo "用法: sb domain [set|delete]";;
  esac
}

# —— 子命令：port —— 
port(){
  case "$2" in
    set)
      read -rp "编号: " idx; read -rp "新端口: " np
      [[ \$np =~ ^[0-9]{1,5}$ ]] || { echo "端口格式错误"; exit 1; }
      if ss -tunlp|grep -q ":\$np"; then echo "端口占用"; exit 1; fi
      PORTs[\$idx]=\$np; write_config; systemctl restart sing-box
      echo "✅ 端口更新完成";;
    open)
      ports=(80 443 "\${PORTs[@]}")
      iptables -I INPUT -p tcp -m multiport --dports \$(IFS=,;echo "\${ports[*]}") -j ACCEPT
      iptables-save; echo "✅ 放行完成";;
    *) echo "用法: sb port [set|open]";;
  esac
}

# —— 子命令：log —— 
log(){
  case "$2" in
    view) less /var/log/sing-box/sing-box.log;;
    clear)
      read -rp "确认清空? (Y/n) " c
      [[ \$c =~ ^[Yy] ]] && > /var/log/sing-box/sing-box.log && echo "✅ 已清空";;
    level)
      echo "1) debug 2) info 3) warn 4) error"
      read -rp "> " l
      case \$l in 1) LOG_LEVEL=debug;;2) LOG_LEVEL=info;;3) LOG_LEVEL=warn;;4) LOG_LEVEL=error;;esac
      write_config; systemctl restart sing-box
      echo "✅ 日志等级: \$LOG_LEVEL";;
    *) echo "用法: sb log [view|clear|level]";;
  esac
}

# —— 子命令：update —— 
update(){
  case "$2" in
    script)
      cp /usr/local/bin/sb /usr/local/bin/sb.bak
      curl -Ls https://raw.githubusercontent.com/sky1793456/singbox/main/install_singbox.sh -o /usr/local/bin/sb
      chmod +x /usr/local/bin/sb
      echo "✅ 管理脚本已更新";;
    singbox)
      bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"
      echo "✅ sing-box 已更新";;
    verify)
      echo "sing-box: $(which sing-box)"
      echo "qrencode: $(which qrencode)";;
    *) echo "用法: sb update [script|singbox|verify]";;
  esac
}

# —— 子命令：status, qr, sub, uninstall —— 
status(){ systemctl status sing-box; }
qr(){ for u in "\${SUBS[@]}"; do qrencode -t ANSIUTF8 "\$u"; done; }
sub(){ printf "%s\n" "\${SUBS[@]}"; }
uninstall(){
  read -rp "确认卸载所有并清理? (Y/n) " c
  [[ \$c =~ ^[Yy] ]] || exit
  systemctl disable --now sing-box
  rm -rf /etc/sing-box /var/log/sing-box /usr/local/lib/singbox-extensions
  iptables -D INPUT -p tcp -m multiport --dports 80,443,\${PORTs[*]} -j ACCEPT || :
  rm -f /usr/local/bin/sb
  echo "✅ 卸载完成"
}

# —— 框架扩展口 —— 
for ext in /usr/local/lib/singbox-extensions/*.sh; do
  [[ -r \$ext ]] && source "\$ext"
done

# —— 主命令分发 —— 
case "${1:-}" in
  node)    node "\$@";;
  domain)  domain "\$@";;
  port)    port "\$@";;
  log)     log "\$@";;
  update)  update "\$@";;
  status)  status;;
  qr)      qr;;
  sub)     sub;;
  uninstall) uninstall;;
  *) echo "用法: sb <node|domain|port|log|update|status|qr|sub|uninstall>";;
esac
SB
chmod +x /usr/local/bin/sb

# —— 11. 扩展 logrotate 生效 —— 
logrotate --force /etc/logrotate.d/sing-box

# —— 12. 自动进入 sb 帮助 —— 
echo "✅ 安装完成！使用 'sb --help' 查看子命令。"
sb --help