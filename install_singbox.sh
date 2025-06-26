#!/bin/bash
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

CONFIG_FILE="/etc/sing-box/config.json"
QR_CODE_FILE="/root/vless_reality.png"
LOG_FILE="/var/log/sing-box.log"

function show_qr() {
  if [[ ! -f "$QR_CODE_FILE" ]]; then
    echo "二维码文件不存在: $QR_CODE_FILE"
    return
  fi
  if command -v qrencode &>/dev/null; then
    echo -e "${GREEN}终端显示二维码:${RESET}"
    qrencode -t ansiutf8 < "$QR_CODE_FILE"
  else
    echo -e "${YELLOW}终端不支持二维码显示，二维码保存在：${QR_CODE_FILE}${RESET}"
  fi
  read -rp "按回车返回菜单..."
}

function view_config() {
  clear
  echo -e "${GREEN}==== 节点信息 ====${RESET}"
  # 这里尝试简单从配置里grep链接，实际可按需改进
  grep -oP 'vless://[^ ]+' <<< "$(cat $CONFIG_FILE)" || echo "无法直接提取节点链接"
  echo -e "\n二维码图片路径：$QR_CODE_FILE"
  echo -e "\n配置文件路径：$CONFIG_FILE"
  echo -e "\n服务状态："
  systemctl status sing-box | grep -E "Active|Loaded"
  echo -e "\nSing-box 版本："
  sing-box version
  echo
  read -rp "按回车返回菜单..."
}

function update_singbox() {
  clear
  echo -e "${GREEN}==== 更新 sing-box ====${RESET}"
  local_version=$(sing-box version | head -n1 | awk '{print $2}')
  latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

  echo "本地版本: $local_version"
  echo "最新版本: $latest_version"

  if [[ "$local_version" == "$latest_version" ]]; then
    echo -e "${GREEN}已是最新版本，无需更新。${RESET}"
  else
    read -rp "检测到新版本，是否更新？(y/n): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      echo "开始更新 sing-box..."
      bash -c "$(curl -Ls https://sing-box.app/deb-install.sh)" || { echo "更新失败"; return; }
      echo -e "${GREEN}更新完成，当前版本：$(sing-box version)${RESET}"
    else
      echo "取消更新。"
    fi
  fi
  read -rp "按回车返回菜单..."
}

function service_status() {
  systemctl status sing-box | grep -E "Active|Loaded"
  echo
  read -rp "按回车返回菜单..."
}

function restart_service() {
  echo "重启 sing-box 服务..."
  systemctl restart sing-box && echo -e "${GREEN}服务已重启${RESET}" || echo -e "${YELLOW}重启失败，请检查日志${RESET}"
  read -rp "按回车返回菜单..."
}

function view_logs() {
  echo -e "${GREEN}显示 sing-box 日志，按 Ctrl+C 退出查看${RESET}"
  # 先判断日志文件是否存在
  if [[ -f "$LOG_FILE" ]]; then
    tail -n 100 -f "$LOG_FILE"
  else
    echo "日志文件不存在：$LOG_FILE"
  fi
  echo
  read -rp "按回车返回菜单..."
}

function main_menu() {
  while true; do
    clear
    echo -e "${GREEN}== Sing-box 管理菜单 ====${RESET}"
    echo "1) 查看配置（节点信息）"
    echo "2) 更新 sing-box"
    echo "3) 显示二维码"
    echo "4) 查看服务状态"
    echo "5) 重启 sing-box 服务"
    echo "6) 查看 sing-box 日志"
    echo "0) 退出"
    read -rp "请选择操作数字: " choice

    case $choice in
      1) view_config ;;
      2) update_singbox ;;
      3) show_qr ;;
      4) service_status ;;
      5) restart_service ;;
      6) view_logs ;;
      0) echo "退出脚本"; exit 0 ;;
      *) echo "无效输入，请重新选择"; sleep 1 ;;
    esac
  done
}

# 参数支持
if [[ $# -eq 0 ]]; then
  main_menu
else
  case $1 in
    qr) show_qr ;;
    status) service_status ;;
    restart) restart_service ;;
    logs) view_logs ;;
    *) echo "未知命令参数: $1" ;;
  esac
fi
