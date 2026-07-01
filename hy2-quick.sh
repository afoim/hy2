#!/bin/bash
set -euo pipefail

# ============================================================
#  Hysteria2 一键部署脚本
#  适用: Ubuntu / Debian · arm64 / amd64
#  优化: 高延迟/高丢包国际链路 (BBR + 巨帧 QUIC 窗口)
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }

# ---------- root check ----------
[[ $EUID -ne 0 ]] && err "请以 root 身份运行此脚本"

# ---------- 架构检测 ----------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  GOARCH="amd64" ;;
  aarch64|arm64) GOARCH="arm64" ;;
  *) err "不支持的架构: $ARCH (仅支持 amd64 / arm64)" ;;
esac
ok "架构: $ARCH"

# ---------- OS 检测 ----------
. /etc/os-release 2>/dev/null || err "无法检测 OS"
case "$ID" in
  ubuntu|debian) ok "OS: $PRETTY_NAME" ;;
  *) warn "未验证的 OS: $ID (预期 Ubuntu/Debian，继续尝试...)";;
esac

# ---------- 配置参数 ----------
SHOW_CONFIG_ONLY="${SHOW_CONFIG_ONLY:-no}"

# 端口
HY2_PORT="${HY2_PORT:-$((RANDOM % 10000 + 20000))}"

# 密码
HY2_PASSWORD="${HY2_PASSWORD:-$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32)}"

# 带宽 (服务端上下行限制, 格式: "100 mbps" / "1 gbps")
HY2_UP="${HY2_UP:-1 gbps}"
HY2_DOWN="${HY2_DOWN:-1 gbps}"

# 伪装站点
HY2_MASQUERADE="${HY2_MASQUERADE:-https://dash.cloudflare.com}"

# SNI (伪装域名)
HY2_SNI="${HY2_SNI:-bing.com}"

# 是否忽略客户端带宽报告 (true = 服务端全力推, false = 客户端反馈更精准)
HY2_IGNORE_CLIENT_BW="${HY2_IGNORE_CLIENT_BW:-false}"

# ---------- 打印配置 ----------
print_config() {
  local pass64
  pass64=$(echo -n "$HY2_PASSWORD" | base64 -w0 2>/dev/null || echo -n "$HY2_PASSWORD")
  local hy2_link="hysteria2://${HY2_PASSWORD}@${PUBLIC_IP}:${HY2_PORT}/?sni=${HY2_SNI}&insecure=1#HY2-${PUBLIC_IP}"

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Hysteria2 部署完成！${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  服务器地址:  ${CYAN}${PUBLIC_IP}${NC}"
  echo -e "  端口:        ${CYAN}${HY2_PORT}${NC}"
  echo -e "  密码:        ${CYAN}${HY2_PASSWORD}${NC}"
  echo -e "  SNI:         ${CYAN}${HY2_SNI}${NC}"
  echo -e "  架构:        ${CYAN}${ARCH}${NC}"
  echo -e "  带宽上下行:  ${CYAN}${HY2_UP} / ${HY2_DOWN}${NC}"
  echo ""
  echo -e "  ${YELLOW}v2rayN / Nekoray 一键导入:${NC}"
  echo -e "  ${GREEN}${hy2_link}${NC}"
  echo ""
  echo -e "  ${YELLOW}服务管理:${NC}"
  echo -e "  systemctl status hysteria-server"
  echo -e "  systemctl restart hysteria-server"
  echo -e "  journalctl -u hysteria-server -n 50 -f"
  echo ""
  echo -e "  ${YELLOW}iperf3 测速 (客户端):${NC}"
  echo -e "  iperf3 -c ${PUBLIC_IP} -t 10 -P 4 -R"
  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════${NC}"
}

# ---------- 前置工具 ----------
install_deps() {
  info "安装依赖..."
  apt-get update -qq
  apt-get install -y -qq curl wget openssl coreutils uuid-runtime 2>&1 | tail -1
  ok "依赖已安装"
}

# ---------- 系统优化 ----------
sysctl_optimize() {
  info "应用系统网络优化..."

  cat >> /etc/sysctl.conf <<'SYSCTL'

# Hysteria2 优化 - 高延迟/高丢包链路
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.core.netdev_max_backlog = 5000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_forward = 1
SYSCTL

  sysctl -p 2>&1 | tail -1 || true

  # 启用 BBR 模块
  modprobe tcp_bbr 2>/dev/null || true
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true

  ok "系统网络优化已应用"
}

# ---------- RPS 多核中断分担 ----------
setup_rps() {
  local iface
  iface=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

  local queues
  queues=$(ls -d /sys/class/net/"$iface"/queues/rx-* 2>/dev/null | wc -l)
  if [[ "$queues" -gt 0 ]]; then
    # 获取在线 CPU 数，构建 RPS CPU mask
    local cpus
    cpus=$(nproc)
    local mask=0
    for ((i=0; i<cpus && i<8; i++)); do
      mask=$((mask | (1 << i)))
    done
    local hex_mask
    hex_mask=$(printf '%x' "$mask")

    for q in /sys/class/net/"$iface"/queues/rx-*; do
      echo "$hex_mask" > "$q"/rps_cpus 2>/dev/null || true
    done
    ok "RPS 已启用 (CPU mask: 0x${hex_mask})"
  fi

  # 创建持久化服务
  cat > /etc/systemd/system/rps.service <<RPS
[Unit]
Description=Enable RPS for $iface
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=bash -c 'for q in /sys/class/net/$iface/queues/rx-*; do echo $hex_mask > "'\$q'/rps_cpus" 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
RPS
  systemctl enable rps.service 2>&1 | tail -1 || true
}

# ---------- 安装 Hysteria2 ----------
install_hysteria() {
  local version
  version=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep tag_name | cut -d'"' -f4)
  [[ -z "$version" ]] && version="v2.9.3"

  local filename="hysteria-linux-${GOARCH}"
  local url="https://github.com/apernet/hysteria/releases/download/${version}/${filename}"

  info "下载 Hysteria2 ${version} (${GOARCH})..."
  curl -sL -o /usr/local/bin/hysteria "$url" || {
    # 备用下载源
    url="https://github.com/apernet/hysteria/releases/download/v2.9.3/hysteria-linux-${GOARCH}"
    curl -sL -o /usr/local/bin/hysteria "$url"
  }
  chmod +x /usr/local/bin/hysteria
  ok "Hysteria2 ${version} 已安装: $(/usr/local/bin/hysteria version 2>&1 | head -1)"
}

# ---------- 自签名 TLS 证书 ----------
setup_tls() {
  mkdir -p /etc/ssl/private

  if [[ ! -f /etc/ssl/private/${HY2_SNI}.crt ]]; then
    info "生成自签名 TLS 证书 (CN=${HY2_SNI})..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -days 36500 -keyout /etc/ssl/private/${HY2_SNI}.key \
      -out /etc/ssl/private/${HY2_SNI}.crt \
      -subj "/CN=${HY2_SNI}" -addext "subjectAltName=DNS:${HY2_SNI}" 2>/dev/null
    ok "自签名证书已生成: CN=${HY2_SNI}"
  else
    ok "证书已存在: /etc/ssl/private/${HY2_SNI}.crt"
  fi
}

# ---------- 配置文件 ----------
setup_config() {
  mkdir -p /etc/hysteria

  cat > /etc/hysteria/config.yaml <<CONF
listen: :${HY2_PORT}

tls:
  cert: /etc/ssl/private/${HY2_SNI}.crt
  key: /etc/ssl/private/${HY2_SNI}.key

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${HY2_MASQUERADE}
    rewriteHost: true

ignoreClientBandwidth: ${HY2_IGNORE_CLIENT_BW}

bandwidth:
  up: ${HY2_UP}
  down: ${HY2_DOWN}

quic:
  initStreamReceiveWindow: 67108864
  maxStreamReceiveWindow: 134217728
  initConnReceiveWindow: 134217728
  maxConnReceiveWindow: 268435456
  maxIdleTimeout: 60s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: true
  maxIncomingStreams: 2048

tcpForwarding: true
CONF

  ok "配置文件已生成: /etc/hysteria/config.yaml"
}

# ---------- Systemd 服务 ----------
setup_service() {
  local user="hysteria"
  id -u "$user" &>/dev/null || useradd -r -s /sbin/nologin "$user"

  cat > /etc/systemd/system/hysteria-server.service <<'SERVICE'
[Unit]
Description=Hysteria2 Server Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
User=hysteria
Group=hysteria
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
LimitNOFILE=1048576
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable hysteria-server 2>&1 | tail -1
  systemctl restart hysteria-server
  sleep 2

  if systemctl is-active hysteria-server &>/dev/null; then
    ok "Hysteria2 服务运行中"
  else
    warn "服务启动失败，检查日志: journalctl -u hysteria-server -n 20"
    systemctl status hysteria-server --no-pager 2>&1 | tail -5
    exit 1
  fi
}

# ---------- 防火墙 ----------
setup_firewall() {
  local port="${HY2_PORT}"

  if command -v ufw &>/dev/null; then
    ufw allow "${port}/udp" comment 'hysteria2' 2>/dev/null || true
    ufw --force enable 2>/dev/null || true
    ok "UFW 已放行 UDP/${port}"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/udp" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    ok "firewalld 已放行 UDP/${port}"
  else
    # iptables 兜底
    iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
      iptables -A INPUT -p udp --dport "$port" -j ACCEPT
    ok "iptables 已放行 UDP/${port} (需持久化)"
  fi
}

# ---------- 获取公网 IP ----------
get_public_ip() {
  PUBLIC_IP=""
  local providers=(
    "https://api.ipify.org"
    "https://ifconfig.me"
    "https://icanhazip.com"
  )
  for p in "${providers[@]}"; do
    PUBLIC_IP=$(curl -s --max-time 5 "$p" 2>/dev/null)
    [[ -n "$PUBLIC_IP" ]] && break
  done
  [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(ip -4 route get 8.8.8.8 | awk '{print $7; exit}')
  [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="<检测失败，请手动填写>"
  ok "公网 IP: ${PUBLIC_IP}"
}

# ============================================================
#  主流程
# ============================================================
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Hysteria2 一键部署脚本${NC}"
echo -e "${CYAN}  架构: ${ARCH} | OS: ${PRETTY_NAME:-unknown}${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

install_deps
sysctl_optimize
get_public_ip
install_hysteria
setup_tls
setup_config
setup_rps
setup_service
setup_firewall
print_config

# 留存安装信息
cat > /etc/hysteria/install.log <<LOG
HY2_PORT=${HY2_PORT}
HY2_PASSWORD=${HY2_PASSWORD}
HY2_SNI=${HY2_SNI}
PUBLIC_IP=${PUBLIC_IP}
INSTALL_DATE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
ARCH=${ARCH}
LOG
