#!/bin/bash
set -e

# —— 环境与依赖 —— 
echo "🛠 检测系统与安装依赖..."
. /etc/os-release
PM=apt; [[ "$ID" =~ ^(centos|rhel)$ ]] && PM=yum
$PM update -y
$PM install -y curl wget openssl uuid-runtime qrencode coreutils iptables

# —— 初始化 & 安装 sing-box —— 
UUID=$(uuidgen)
PORT=443
bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"
KEYS=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/ {print $3}')
SHORT_ID=$(head -c4 /dev/urandom|xxd -p)

mkdir -p /etc/sing-box /var/log/sing-box

# —— 全局数组，存储多节点信息 —— 
UUIDs=("$UUID")
PORTs=("$PORT")
SIDs=("$SHORT_ID")
TAGS=("node0")
# 域名/SNI 初始留空，后续在菜单中添加
DOMAIN=""
SNI=""

# —— 写入配置 —— 
write_config(){
  cat > /etc/sing-box/config.json <<EOF
{
  "log": {"level":"info","output":"file","log_file":"/var/log/sing-box/sing-box.log"},
  "dns":{"servers":["8.8.8.8","1.1.1.1"],"disable_udp":false},
  "inbounds":[
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
          "handshake":${DOMAIN:+{"server":"$SNI","server_port":443}},
          "private_key":"$PRIVATE_KEY",
          "short_id":["${SIDs[i]}"]
        },
        "server_name":"${SNI}"
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

# —— 第一次写配置 & 启动 —— 
write_config
systemctl enable --now sing-box

# —— 生成二维码文件 —— 
for u in "${UUIDs[@]}"; do
  url="vless://${u}@${DOMAIN}:${PORTs[0]}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SIDs[0]}"
  QRURLS+=("$url")
done
qrencode -o /root/vless_reality.png "${QRURLS[0]}"

# —— 创建管理脚本 sb —— 
cat > /usr/local/bin/sb <<'EOF'
#!/bin/bash
set -e

# 从安装时注入
UUIDs=(__UUIDS__)
PORTs=(__PORTs__)
SIDs=(__SIDs__)
TAGS=(__TAGS__)
DOMAIN="__DOMAIN__"
SNI="__SNI__"
QRURLS=(__QRURLS__)
PUBLIC_KEY="__PUBLIC_KEY__"

# 重写配置函数
write_config(){
  cat > /etc/sing-box/config.json <<EOC
{
  "log": {"level":"info","output":"file","log_file":"/var/log/sing-box/sing-box.log"},
  "dns":{"servers":["8.8.8.8","1.1.1.1"],"disable_udp":false},
  "inbounds":[
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
          $( [ -n "$DOMAIN" ] && echo "\"handshake\":{\"server\":\"$SNI\",\"server_port\":443\"," )
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
    echo " [$i] ${TAGS[i]} UUID:${UUIDs[i]} 端口:${PORTs[i]} SID:${SIDs[i]}"
  done
  echo "域名: $DOMAIN  SNI: $SNI"
  echo "订阅链接："; printf "%s\n" "${QRURLS[@]}"
  echo; systemctl status sing-box|grep Active
  echo "日志：/var/log/sing-box/sing-box.log"
  echo "二维码：/root/vless_reality.png"
}

show_qr(){
  for u in "${QRURLS[@]}"; do qrencode -t ANSIUTF8 "$u"; done
}

update_sb(){
  echo "🔄 更新 sing-box…"
  bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)"
  echo "✅ 更新完成"
}

change_domain(){
  read -p "新域名: " nd
  DOMAIN="$nd"; SNI="$nd"
  write_config; systemctl restart sing-box
  echo "✅ 域名更新为 $DOMAIN"
}

delete_domain(){
  read -p "确定删除域名？(Y/n) " c
  [[ $c =~ ^[Yy]$ ]] && DOMAIN="" && SNI="" && write_config && systemctl restart sing-box && echo "✅ 域名已删除"
}

add_config(){
  echo "选择协议:"; select p in VLESS Trojan VMess Shadowsocks Cancel; do
    [ "$p" = Cancel ] && return
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
  if ss -tunlp|grep -q ":$np"; then echo "❌ 端口 $np 占用"; return; fi
  PORTs[$idx]=$np
  write_config; systemctl restart sing-box
  echo "✅ 节点 $idx 端口改为 $np"
}

rename_node(){
  show_info
  read -p "选择节点编号: " idx
  read -p "新标签: " nn
  TAGS[$idx]="$nn"
  write_config; systemctl restart sing-box
  echo "✅ 节点 $idx 新标签: $nn"
}

open_ports(){
  echo "放行 80,443 和节点端口…"
  ports=(80 443 "${PORTs[@]}")
  iptables -I INPUT -p tcp -m multiport --dports $(IFS=,;echo "${ports[*]}") -j ACCEPT
  iptables-save
  echo "✅ 已放行"
}

gen_sub(){
  echo "📡 订阅链接："; printf "%s\n" "${QRURLS[@]}"
  echo "(复制到手机 App 订阅)"
}

while true; do
  clear
  cat <<EOM
===== Sing-box 管理菜单 =====
1) 查看节点信息
2) 生成二维码
3) 更新 Sing-box
4) 域名管理
5) 添加节点配置
6) 更改端口
7) 修改节点名称
8) 放行防火墙端口
9) 生成订阅链接
0) 退出
EOM
  read -p "选择 [0-9]: " o
  case $o in
    1) show_info;;
    2) show_qr;;
    3) update_sb;;
    4) 
      echo " a) 更改域名"
      echo " b) 删除域名"
      read -p "选择 [a/b]: " c
      [[ $c == a ]] && change_domain
      [[ $c == b ]] && delete_domain
      ;;
    5) add_config;;
    6) change_port;;
    7) rename_node;;
    8) open_ports;;
    9) gen_sub;;
    0) exit 0;;
    *) echo "❌ 无效选项";;
  esac
  read -p "回车返回菜单..."
done
EOF

# —— 注入实际变量 —— 
sed -i -e "s|__UUIDS__|${UUIDs[@]}|g" \
       -e "s|__PORTs__|${PORTs[@]}|g" \
       -e "s|__SIDs__|${SIDs[@]}|g" \
       -e "s|__TAGS__|${TAGS[@]}|g" \
       -e "s|__DOMAIN__|$DOMAIN|g" \
       -e "s|__SNI__|$SNI|g" \
       -e "s|__QRURLS__|${QRURLS[@]}|g" \
       -e "s|__PUBLIC_KEY__|$PUBLIC_KEY|g" \
       /usr/local/bin/sb

chmod +x /usr/local/bin/sb

echo ""
echo "✅ 安装完成！运行 'sb' 进入管理菜单。"
