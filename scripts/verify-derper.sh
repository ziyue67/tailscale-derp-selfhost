#!/bin/bash
# DERP 部署验证脚本
# 用法: ./verify-derper.sh <服务器IP> [DERP端口] [STUN端口] [RegionID]
IP="${1:?用法: $0 <IP> [DERP端口] [STUN端口] [RegionID]}"
DERP_PORT="${2:-12345}"
STUN_PORT="${3:-3478}"
REGION="${4:-900}"

echo "=== DERP 服务验证: $IP ==="
echo

echo "--- 1. DERP 端点 (HTTP) ---"
curl -sSk -o /dev/null -w "  /derp/latency-check -> HTTP %{http_code}\n" \
  "https://$IP:$DERP_PORT/derp/latency-check" 2>&1

echo
echo "--- 2. DERP 协议升级 (Tailscale 客户端实际动作) ---"
curl -sSk -o /dev/null -w "  Upgrade: derp -> HTTP %{http_code}\n" --http1.1 \
  -H "Connection: Upgrade" -H "Upgrade: derp" "https://$IP:$DERP_PORT/derp" 2>&1
echo "  (101 = 成功, 其他 = 失败)"

echo
echo "--- 3. 证书指纹 ---"
echo | openssl s_client -connect "$IP:$DERP_PORT" -servername "$IP" 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^/  /'

echo
echo "--- 4. 证书有效期 ---"
echo | openssl s_client -connect "$IP:$DERP_PORT" -servername "$IP" 2>/dev/null \
  | openssl x509 -noout -subject -dates 2>/dev/null | sed 's/^/  /'

echo
echo "--- 5. STUN 测试 (UDP) ---"
python3 - "$IP" "$STUN_PORT" <<'PY'
import socket, struct, os, sys
ip, port = sys.argv[1], int(sys.argv[2])
pkt = struct.pack('>HHI12s', 1, 0, 0x2112A442, os.urandom(12))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
try:
    s.sendto(pkt, (ip, port))
    d, _ = s.recvfrom(1024)
    print(f"  ✅ STUN 响应 {len(d)} 字节")
except Exception as e:
    print(f"  ❌ {type(e).__name__} (UDP 未映射或 STUN 未工作)")
PY

echo
echo "--- 6. Tailscale 客户端验证 ---"
if command -v tailscale >/dev/null; then
    echo "  DERP map 中的区域 $REGION:"
    tailscale debug derp-map 2>/dev/null | grep -A8 "\"$REGION\"" | head -10 | sed 's/^/    /'
    echo
    echo "  连接测试:"
    tailscale debug derp "$REGION" 2>&1 | head -8 | sed 's/^/    /'
else
    echo "  未安装 tailscale，跳过"
fi
