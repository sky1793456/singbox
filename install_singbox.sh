#!/bin/bash
set -e

# —— 环境与依赖安装 —— 
echo "🛠 检测系统与安装依赖..."
. /etc/os-release
PM=apt
[[ "$ID" =~ ^(centos|rhel)$ ]] && PM=yum
$PM update -y
$PM install -y curl wget openssl uuid-runtime qrencode coreutils iptables

# —— 安装 sing-box 并生成 Reality 密钥对 —— 
echo "🚀 安装 sing-box..."
bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"
KEYS=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $3}')

# —— 初始化多节点数组 —— 
UUID0=$(uuidgen); PORT0=443; SID0=$(head -c4 /dev/urandom|xxd -p)
UUIDs=("$UUID0"); PORTs=("$PORT0"); SIDs=("$SID0"); TAGS=("node0")
DOMAIN=""; SNI=""

mkdir -p /etc/sing-box /var/log/sing-box

# —— 写入配置函数 —— 
write_config(){
  cat > /etc/sing-box/config.json <<EOF
{
  "log": {"level":"info","output":"file","log_file":"/var/log/sing-box/sing-box.log"},
  "dns": {"servers":["8.8.8.8","1.1.1.1"],"disable_udp":false},
  "inbounds": [
EOF
  for i in "${!UUIDs[@]}"; do
    cat >> /etc/sing-box/config.json <<EOF
    {
      "tag":"${TAGS[i]}",
      "type":"vless",
      "listen":"::",
      "listen_port":${PORTs[i]},
      "users":[{"uuid":"${UUIDs[i]}","flow":"xtls-rprx-vision"}],
      "tls":{
        "enabled":true,
        "reality":{
          "enabled":true,
          "handshake":{"server":"$SNI","server_port":443},
          "private_key":"$PRIVATE_KEY",
          "short_id":["${SIDs[i]}"]
        },
        "server_name":"$SNI"
      }
    }$( [ $i -lt $((${#UUIDs[@]}-1)) ] && echo "," )
EOF
  done
  cat >> /etc/sing-box/config.json <<EOF
  ],
  "outbounds":[{"type":"direct"}]
}
EOF
}

# —— 初次写配置 & 启动服务 —— 
write_config
systemctl enable --now sing-box

# —— 生成订阅链接 & 二维码 —— 
QRURL0="vless://${UUID0}@${DOMAIN}:${PORT0}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID0}"
QRURLS=("$QRURL0")
qrencode -o /root/vless_reality.png "$QRURL0"

# —— 生成 sb 管理脚本 —— 
cat > /usr/local/bin/sb <<'EOF'
#!/bin/bash
set -e

# —— 注入变量 —— 
UUIDs=(__UUIDS__)
PORTs=(__PORTs__)
SIDs=(__SIDs__)
TAGS=(__TAGS__)
DOMAIN="__DOMAIN__"
SNI="__SNI__"
PUBLIC_KEY="__PUBLIC_KEY__"
QRURLS=(__QRURLS__)

# —— 写配置函数 —— 
write_config(){
  cat > /etc/sing-box/config.json <<EOC
{
  "log": {"level":"info","output":"file","log_file":"/var/log/sing-box/sing-box.log"},
  "dns": {"servers":["8.8.8.8","1.1.1.1"],"disable_udp":false},
  "inbounds": [
EOC
  for i in "${!UUIDs[@]}"; do
    cat >> /etc/sing-box/config.json <<EOC
    {
      "tag":"${TAGS[i]}",
      "type":"vless",
      "listen":"::",
      "listen_port":${PORTs[i]},
      "users":[{"uuid":"${UUIDs[i]}","flow":"xtls-rprx-vision"}],
      "tls":{
        "enabled":true,
        "reality":{
          "enabled":true,
          "handshake":{"server":"$SNI","server_port":443},
          "private_key":"$PRIVATE_KEY",
          "short_id":["${SIDs[i]}"]
        },
        "server_name":"$SNI"
      }
    }$( [ $i -lt $((${#UUIDs[@]}-1)) ] && echo "," )
EOC
  done
  cat >> /etc/sing-box/config.json <<EOC
  ],
  "outbounds":[{"type":"direct"}]
}
EOC
}

show_info(){
  clear
  echo "📋 节点信息："
  for i in "${!UUIDs[@]}"; do
    echo " [$i] Tag=${TAGS[i]} UUID=${UUIDs[i]} 端口=${PORTs[i]} SID=${SIDs[i]}"
  done
  echo
  echo "域名: $DOMAIN"
  echo "SNI: $SNI"
  echo "订阅链接："
  printf "%s\n" "${QRURLS[@]}"
  echo
  systemctl status sing-box | grep -E "Active|Loaded"
  echo
  echo "日志：/var/log/sing-box/sing-box.log"
  echo "二维码：/root/vless_reality.png"
}

show_qr(){
  for u in "${QRURLS[@]}"; do qrencode -t ANSIUTF8 "$u"; done
}

gen_sub(){
  echo "📡 订阅链接："
  printf "%s\n" "${QRURLS[@]}"
}

update_sb(){
  echo "🔄 更新 sing-box…"
  bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"
  echo "✅ 更新完成"
}

update_script(){
  echo "🔄 更新管理脚本…"
  curl -Ls https://raw.githubusercontent.com/sky1793456/singbox/main/install_singbox.sh >/usr/local/bin/sb && chmod +x /usr/local/bin/sb
  echo "✅ 脚本已更新"
}

verify_sources(){
  echo "🔍 验证组件来源："
  if command -v sing-box &>/dev/null; then
    path=$(which sing-box)
    echo -n "sing-box: $path → "
    strings "$path" | grep -q "Sing-Box" && echo "官方" || echo "未知"
  else
    echo "sing-box 未安装"
  fi
  if command -v qrencode &>/dev/null; then
    echo "qrencode: 系统仓库"
  else
    echo "qrencode: 未安装"
  fi
}

load_extensions(){
  echo "🔌 加载扩展模块…"
  # for f in /usr/local/lib/singbox-extensions/*.sh; do [ -r "$f" ] && source "$f"; done
  echo "✅ 扩展加载完成"
}

change_domain(){
  read -p "请输入新域名: " nd
  DOMAIN="$nd"; SNI="$nd"
  write_config; systemctl restart sing-box
  echo "✅ 域名更新为 $DOMAIN"
}

delete_domain(){
  read -p "确定删除域名？(Y/n) " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    DOMAIN=""; SNI=""
    write_config; systemctl restart sing-box
    echo "✅ 域名已删除"
  fi
}

add_config(){
  echo "请选择协议:"; select p in VLESS Trojan VMess Shadowsocks Cancel; do
    [[ "$p" == Cancel ]] && return
    NU=$(uuidgen); NS=$(head -c4 /dev/urandom|xxd -p)
    read -p "新端口: " np
    UUIDs+=("$NU"); PORTs+=("$np"); SIDs+=("$NS"); TAGS+=("$p-$NS")
    url="vless://${NU}@${DOMAIN}:${np}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${NS}"
    QRURLS+=("$url")
    write_config; systemctl restart sing-box
    echo "✅ 添加节点 $p, tag=${TAGS[-1]}"
    break
  done
}

change_port(){
  show_info
  read -p "选择节点编号: " idx
  read -p "新端口: " np
  if ss -tunlp | grep -q ":$np"; then echo "❌ 端口已占用"; return; fi
  PORTs[$idx]=$np
  write_config; systemctl restart sing-box
  echo "✅ 节点 $idx 端口改为 $np"
}

rename_node(){
  show_info
  read -p "选择节点编号: " idx
  read -p "新标签: " nn
  TAGS[$idx]=$nn
  write_config; systemctl restart sing-box
  echo "✅ 节点 $idx 标签改为 $nn"
}

open_ports(){
  echo "放行 80,443 及节点端口…"
  ports=(80 443 "${PORTs[@]}")
  iptables -I INPUT -p tcp -m multiport --dports $(IFS=,;echo "${ports[*]}") -j ACCEPT
  iptables-save
  echo "✅ 已放行"
}

# —— 自动模式 —— 
if [[ "$1" == "auto" ]]; then
  show_info
  show_qr
  gen_sub
  exit 0
fi

# —— 交互菜单 —— 
while true; do
  clear
  cat <<MENU
===== Sing-box 管理菜单 =====
1) 查看节点信息
2) 生成二维码
3) 更新 sing-box
4) 更新管理脚本
5) 验证安装来源
6) 加载扩展模块
7) 域名管理
8) 添加节点配置
9) 更改端口
10) 修改节点名称
11) 放行防火墙端口
12) 生成订阅链接
0) 退出
MENU
  read -p "请选择 [0-12]: " o
  case $o in
    1) show_info;;
    2) show_qr;;
    3) update_sb;;
    4) update_script;;
    5) verify_sources;;
    6) load_extensions;;
    7)
      echo " a) 更改域名"
      echo " b) 删除域名"
      read -p "请选择 [a/b]: " c
      [[ $c == a ]] && change_domain || delete_domain
      ;;
    8) add_config;;
    9) change_port;;
    10) rename_node;;
    11) open_ports;;
    12) gen_sub;;
    0) exit 0;;
    *) echo "❌ 无效选项";;
  esac
  read -p "按回车返回菜单..."
done
EOF

# —— 注入真实变量 —— 
sed -i \
  -e "s|__UUIDS__|${UUIDs[@]}|" \
  -e "s|__PORTs__|${PORTs[@]}|" \
  -e "s|__SIDs__|${SIDs[@]}|" \
  -e "s|__TAGS__|${TAGS[@]}|" \
  -e "s|__DOMAIN__|${DOMAIN}|" \
  -e "s|__SNI__|${SNI}|" \
  -e "s|__PUBLIC_KEY__|${PUBLIC_KEY}|" \
  -e "s|__QRURLS__|${QRURLS[@]}|" \
  /usr/local/bin/sb

chmod +x /usr/local/bin/sb

# —— 安装完成后自动进入 —— 
echo "✅ 安装完成，正在进入自动模式：显示节点信息、二维码和订阅链接…"
exec sb auto