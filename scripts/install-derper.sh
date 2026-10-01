#!/bin/bash
# Tailscale DERP 一键部署脚本
# 用法: ./install-derper.sh <公网IP> [DERP端口] [STUN端口]
set -e

PUBLIC_IP="${1:?用法: $0 <公网IP> [DERP端口] [STUN端口]}"
DERP_PORT="${2:-12345}"
STUN_PORT="${3:-3478}"
CERT_DIR="/etc/derp-ip"
BIN="/opt/derper-official"

echo "=== Tailscale DERP 部署 ==="
echo "  公网IP:   $PUBLIC_IP"
echo "  DERP端口: $DERP_PORT"
echo "  STUN端口: $STUN_PORT"
echo

# 检查环境
if ! [ -e /dev/net/tun ]; then
    echo "⚠️  /dev/net/tun 不存在（LXC 容器会缺少）"
fi
VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
echo "  虚拟化: $VIRT"
if [ "$VIRT" = "lxc" ]; then
    echo "❌ LXC 容器无法运行 Docker，请直接使用二进制方式"
fi

# 检查二进制
if [ ! -f "$BIN" ]; then
    echo "❌ 未找到 $BIN"
    echo "   请先编译/传输 derper 二进制："
    echo "   go install tailscale.com/cmd/derper@v1.102.4"
    echo "   scp ~/go/bin/derper root@$PUBLIC_IP:$BIN"
    exit 1
fi
chmod +x "$BIN"

# 生成证书（CN + SAN 都包含 IP，避免 TLS hostname 不匹配）
echo "=== 生成自签证书 ==="
mkdir -p "$CERT_DIR"
INNER_IP=$(ip -4 addr show $(ip route show default | awk '{print $5}' | head -1) 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
openssl req -x509 -newkey rsa:2048 \
    -keyout "$CERT_DIR/$PUBLIC_IP.key" \
    -out "$CERT_DIR/$PUBLIC_IP.crt" \
    -days 3650 -nodes \
    -subj "/CN=$PUBLIC_IP" \
    -addext "subjectAltName=IP:$PUBLIC_IP,IP:${INNER_IP:-$PUBLIC_IP}" 2>/dev/null
echo "  ✅ 证书已生成（SAN: $PUBLIC_IP, ${INNER_IP:-无内网IP}）"

# 写 systemd 服务
echo "=== 配置 systemd 服务 ==="
cat > /etc/systemd/system/derper.service <<EOF
[Unit]
Description=DERP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -a :$DERP_PORT -http-port -1 -stun-port $STUN_PORT \
  -hostname $PUBLIC_IP -certmode manual -certdir $CERT_DIR -verify-clients=false
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:/var/log/derper.log
StandardError=append:/var/log/derper.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable derper 2>/dev/null
systemctl restart derper
sleep 5

if systemctl is-active --quiet derper; then
    echo "  ✅ 服务已启动"
else
    echo "  ❌ 服务启动失败"
    journalctl -u derper --no-pager -n 20
    exit 1
fi

# 日志轮转
mkdir -p /etc/logrotate.d
cat > /etc/logrotate.d/derper <<'EOF'
/var/log/derper.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    copytruncate
}
EOF

# 提取 CertName
echo
echo "=== 部署完成 ==="
sleep 3
CERTNAME=$(grep -oP 'sha256-raw:[a-f0-9]+' /var/log/derper.log | tail -1)
if [ -n "$CERTNAME" ]; then
    echo "CertName: $CERTNAME"
    echo
    echo "=== 复制下面这段到 Tailscale ACL (https://login.tailscale.com/admin/acls/file) ==="
    cat <<ACLEOF
"derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
        "900": {
            "RegionID": 900,
            "RegionCode": "self",
            "RegionName": "Self-Hosted",
            "Nodes": [{
                "Name": "900a",
                "RegionID": 900,
                "HostName": "$PUBLIC_IP",
                "IPv4": "$PUBLIC_IP",
                "DERPPort": $DERP_PORT,
                "STUNPort": $STUN_PORT,
                "CertName": "$CERTNAME"
            }]
        }
    }
}
ACLEOF
else
    echo "⚠️  未提取到 CertName，请手动查看："
    echo "   grep CertName /var/log/derper.log"
fi
echo
echo "=== 端口放行 / NAT 映射 ==="
echo "  TCP $DERP_PORT   (DERP 中继)"
echo "  UDP $STUN_PORT   (STUN 打洞)"
echo
echo "=== 验证命令 ==="
echo "  tailscale debug force-netmap-update"
echo "  tailscale debug derp 900"
echo "  tailscale netcheck"
