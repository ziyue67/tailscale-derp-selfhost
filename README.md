# Tailscale 自建 DERP 中继（国内免备案）

一套经过实测验证的 Tailscale DERP 自建方案。**解决国内访问 Tailscale 官方 DERP 延迟高、丢包严重的问题。**

实测效果（从华东电信网络）：

| DERP 节点 | 延迟 |
|---|---|
| **自建 TX-CN** | **73.9ms** ✅ |
| 官方 Singapore | 83.7ms |
| 官方 Hong Kong | 83.8ms |
| 官方 Tokyo | 128.8ms |

自建节点比所有官方节点都快，且**中继 + STUN 打洞双双可用**。

---

## 一、核心原理

Tailscale 节点之间默认尝试 P2P 直连，失败时才走 DERP 中继。官方 DERP 全在海外，国内用户：

- **中继延迟高**（100-300ms）
- **丢包严重**（晚高峰更差）
- **STUN 打洞经常失败**，被迫走中继

自建国内/香港 DERP 后：

1. **中继变快** —— 流量走你自己的服务器
2. **打洞成功率提升** —— STUN 由你自己提供，不受跨洋链路影响
3. **不消耗官方配额** —— 完全自主

---

## 二、服务器要求

| 项目 | 最低 | 推荐 |
|---|---|---|
| CPU | 1 核 | 1 核 |
| 内存 | 512M | 1G |
| 磁盘 | 5G | 10G |
| 带宽 | 10M | 100M |
| 系统 | Debian 12/13 | Debian 13 |

**DERP 本身极省资源**，实测运行内存仅 **16-18MB**。

**关键：必须是 KVM 全虚拟化，不能是 LXC 容器。**

LXC 容器会缺少 `CAP_SYS_ADMIN`，导致：
- Docker 无法解压镜像层（`unshare: operation not permitted`）
- 无 `/dev/net/tun` 设备

检测方法：

```bash
systemd-detect-virt          # 输出 kvm 则 OK
[ -e /dev/net/tun ] && echo OK
```

**带宽说明**：DERP 只负责中继和协助打洞，**打通后流量直连**，所以带宽要求不高。真正吃带宽的是中继场景。

---

## 三、部署步骤

### 3.1 安装 Docker（可选）

如果使用官方二进制方式，可以跳过这步。

```bash
curl -fsSL https://get.docker.com | sh
```

国内加速：

```bash
# 阿里云镜像源安装
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
```

配置镜像加速 + 日志上限：

```bash
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://dockerpull.org"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl restart docker
```

**日志上限必须配** —— 容器日志无限制会吃满磁盘。

### 3.2 获取 derper 二进制

有两种方式，**推荐官方编译版**（见下方"踩坑记录"）。

**方式 A：用第三方镜像（有已知问题）**

```bash
docker run -d --name tailscale-derp \
  --network host \
  -e DERP_ADDR=:12345 \
  -e DERP_STUN_PORT=3478 \
  -e DERP_CERTDIR=/ssl \
  -e DERP_CERTMODE=manual \
  -e DERP_VERIFY_CLIENTS=false \
  --restart=always \
  guyuan404643/tailscale-ipderp:latest
```

**方式 B：官方 derper 二进制（推荐）**

```bash
# 本地有 Go 环境时编译
go install tailscale.com/cmd/derper@v1.102.4
# 产物在 ~/go/bin/derper，约 25MB
scp ~/go/bin/derper root@服务器:/opt/derper-official
chmod +x /opt/derper-official
```

**Go 下载加速**（`go.dev` 国内经常连不上，用这个）：

```bash
curl -o go.tgz https://golang.google.cn/dl/go1.24.4.linux-amd64.tar.gz
tar xzf go.tgz -C /opt
export PATH=$PATH:/opt/go/bin
export GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy,direct
```

**内存不足时交叉编译**：小内存机器（<1G）编译大项目会被 OOM kill。解决办法是在**本地或大内存机器**编译好，再 scp 传过去。

### 3.3 生成证书（关键步骤）

**必须用访问时使用的 hostname 签证书，否则 TLS 握手会失败。**

```bash
mkdir -p /etc/derp-ip && cd /etc/derp-ip

# 用 IP 访问时（推荐，免域名）
openssl req -x509 -newkey rsa:2048 \
  -keyout 你的IP.key -out 你的IP.crt \
  -days 3650 -nodes -subj "/CN=你的IP" \
  -addext "subjectAltName=IP:你的公网IP,IP:你的内网IP,DNS:你的域名"
```

或用域名（需要域名解析到服务器）：

```bash
# 用 derper 自动申请 Let's Encrypt
-certmode letsencrypt -hostname derp.你的域名.com
```

### 3.4 配置 systemd 服务

```bash
cat > /etc/systemd/system/derper.service <<'EOF'
[Unit]
Description=DERP Server (official derper)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/derper-official \
  -a :12345 \
  -http-port -1 \
  -stun-port 3478 \
  -hostname 你的公网IP \
  -certmode manual \
  -certdir /etc/derp-ip \
  -verify-clients=false
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:/var/log/derper.log
StandardError=append:/var/log/derper.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now derper
```

**参数说明**：

| 参数 | 作用 | 注意 |
|---|---|---|
| `-a :12345` | DERP 监听端口（TLS） | 防火墙/映射要放行 |
| `-http-port -1` | 禁用明文 HTTP | 避免额外暴露端口 |
| `-stun-port 3478` | STUN 端口（UDP） | 打洞必需 |
| `-hostname` | 证书 hostname | **必须与实际访问方式一致** |
| `-certmode manual` | 使用手动证书 | 配合 `-certdir` |
| `-verify-clients=false` | 不校验客户端 | 自建场景必须关 |

### 3.5 获取 CertName

derper 启动时会打印 CertName，**必须记录**：

```bash
journalctl -u derper --no-pager | grep CertName
# 或
grep CertName /var/log/derper.log
```

输出示例：

```
Using self-signed certificate for IP address "1.2.3.4".
Configure it in DERPMap using:
{"Name":"custom","RegionID":900,"HostName":"1.2.3.4",
 "CertName":"sha256-raw:6d67f5be1b6b667acc457ad2de379ce0f5eb04b7333affa3648138223aaaf126"}
```

**自己核对指纹**（确保一致）：

```bash
echo | openssl s_client -connect 你的IP:12345 -servername 你的IP 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
```

### 3.6 配置 Tailscale ACL

打开 https://login.tailscale.com/admin/acls/file

**先备份原有配置！** 然后加入 `derpMap`：

```json
{
	"acls": [
		{ "action": "accept", "src": ["*"], "dst": ["*:*"] }
	],
	"ssh": [
		{
			"action": "check",
			"src": ["autogroup:member"],
			"dst": ["autogroup:self"],
			"users": ["autogroup:nonroot", "root"]
		}
	],
	"derpMap": {
		"OmitDefaultRegions": false,
		"Regions": {
			"900": {
				"RegionID": 900,
				"RegionCode": "tx-cn",
				"RegionName": "TX-CN",
				"Nodes": [
					{
						"Name": "900a",
						"RegionID": 900,
						"HostName": "你的公网IP",
						"IPv4": "你的公网IP",
						"DERPPort": 12345,
						"STUNPort": 3478,
						"CertName": "sha256-raw:你的证书指纹"
					}
				]
			}
		}
	}
}
```

**字段说明**：

| 字段 | 值 | 说明 |
|---|---|---|
| `RegionID` | 900-999 | **自定义值，不要用 1-29**（官方占用了） |
| `OmitDefaultRegions` | `false` | `true` = 只用自建 DERP（跨网会失败，不建议） |
| `DERPPort` | 映射后的**外网**端口 | 有 NAT 时填外网端口 |
| `STUNPort` | 映射后的**外网**端口 | UDP |
| `CertName` | `sha256-raw:<指纹>` | 自签证书必须填 |

### 3.7 验证

```bash
# 1. 强制刷新 netmap
tailscale debug force-netmap-update

# 2. 检查 DERP map 是否包含你的区域
tailscale debug derp-map | grep -A5 "900"

# 3. 官方工具测试连接（最权威）
tailscale debug derp 900
```

**成功的输出**：

```
{
 "Info": [
  "Region 900 == \"tx-cn\"",
  "Successfully established a DERP connection with node \"1.2.3.4\"",
  "Node \"1.2.3.4\" returned IPv4 STUN response: 10.1.6.254:49605"
 ],
 "Errors": [
  "Error connecting ... over IPv6: dial tcp6: ... no suitable address found"
 ]
}
```

- ✅ `Successfully established` = DERP 中继可用
- ✅ `returned IPv4 STUN response` = STUN 打洞可用
- ⚠️ IPv6 报错可忽略（服务器无 IPv6 时正常）

```bash
# 4. 查看延迟排名
tailscale netcheck | head -10
```

期望看到你的节点成为 `Nearest DERP`。

---

## 四、端口与防火墙

需要放行（或 NAT 映射）**两个端口**：

| 协议 | 端口 | 用途 | 必需 |
|---|---|---|---|
| **TCP** | 12345（或自定义） | DERP 中继 | ✅ 必需 |
| **UDP** | 3478 | STUN 打洞 | ✅ 必需 |

**NAT 机器注意**：
- 映射时 `外网端口` 和 `内网端口` 要对应正确
- DERP 和 STUN 是**两个不同的映射**
- 云厂商安全组也要放行

---

## 五、踩坑记录

以下是实际部署中踩过的坑，**每一条都真实遇到过**。

### 5.1 证书 hostname 不匹配（最容易踩）

**现象**：

```bash
curl https://1.2.3.4:12345/derp/latency-check
# error:0A000438:SSL routines::tlsv1 alert internal error
```

**服务端日志**：

```
http: TLS handshake error from x.x.x.x: cert mismatch with hostname: ""
```

**原因**：证书是 `CN=derp.yourdomain.com`，但客户端用 IP 访问，SNI 对不上，derper 拒绝握手。

**后果**：**TLS 和 STUN 会一起失效**（因为共用一个监听进程），表现为"节点在 DERP map 里但探测不出延迟"。

**解决**：证书的 CN / SAN 必须包含实际访问用的 hostname（IP 或域名）。

### 5.2 第三方镜像的 STUN 是坏的

`guyuan404643/tailscale-ipderp` 镜像内置的 STUN（`3478/udp`）即使在本机 `127.0.0.1` 测试也不响应。

**判断方法**：

```bash
# 在服务器本机测，排除网络因素
python3 -c "
import socket, struct, os
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
s.sendto(struct.pack('>HHI12s', 1, 0, 0x2112A442, os.urandom(12)), ('127.0.0.1', 3478))
try: print('OK', len(s.recvfrom(1024)[0]))
except Exception as e: print('FAIL', e)
"
```

本机都不响应 = 镜像本身的问题。**改用官方编译的 derper。**

### 5.3 Docker 绑定的 STUN 只监听 IPv6

用 `docker run -p 3478:3478/udp` 时，derper 在容器内可能只绑定 `[::]:3478`：

```
UNCONN  [::]:3478      ← 只有 IPv6
```

**解决**：用 `--network host` 让容器直接用宿主机网络栈：

```
UNCONN  *:3478         ← IPv4 + IPv6
```

### 5.4 LXC 容器跑不了 Docker

**现象**：

```
failed to register layer: unshare: operation not permitted
```

**原因**：LXC 容器缺少 `CAP_SYS_ADMIN` / `CAP_NET_ADMIN`，无法创建命名空间。

**排查**：

```bash
unshare --user --mount echo test    # Permission denied
mount -t tmpfs none /tmp/test       # permission denied
grep CapEff /proc/self/status
```

**结论**：遇到 LXC 就放弃 Docker，直接用二进制。DERP 不需要 Docker。

### 5.5 小内存机器编译 Go 项目被 OOM

256M 内存编译 derper 会被 kill：

```
runtime: .../compile: signal: killed
```

**解决**：在本地/大内存机器编译好，再 scp 传过去。

### 5.6 go.dev 国内下载不了

```bash
curl https://go.dev/dl/go1.24.4.linux-amd64.tar.gz   # TLS error
```

**解决**：用 `golang.google.cn`：

```bash
curl -o go.tgz https://golang.google.cn/dl/go1.24.4.linux-amd64.tar.gz
```

### 5.7 GitHub 下载慢

用加速代理：

```bash
https://gh-proxy.com/https://github.com/...
```

---

## 六、日常维护

### 检查服务

```bash
systemctl status derper
tail -20 /var/log/derper.log
```

### 日志轮转

derper 日志会持续增长，建议配置：

```bash
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
```

### 证书续期

自签证书默认 10 年有效（上面命令用 `-days 3650`）。到期前重新生成并**更新 ACL 里的 CertName**。

### 常用调试命令

```bash
tailscale debug derp-map            # 查看 DERP 地图
tailscale debug derp 900            # 测试指定区域
tailscale netcheck                  # 延迟排名
tailscale ping <设备>                # 查看是否走 DERP
tailscale debug force-netmap-update # 强制刷新
```

---

## 七、多区域部署

可以同时部署多个 DERP（比如国内 + 香港），Tailscale 会自动选最近的：

```json
"derpMap": {
	"OmitDefaultRegions": false,
	"Regions": {
		"900": {
			"RegionID": 900,
			"RegionCode": "tx-cn",
			"RegionName": "TX-CN",
			"Nodes": [{ "...": "国内节点" }]
		},
		"901": {
			"RegionID": 901,
			"RegionCode": "hk",
			"RegionName": "HK-Selfhosted",
			"Nodes": [{ "...": "香港节点" }]
		}
	}
}
```

**注意**：每个节点必须用**自己的证书**（不能复制别人的），否则 CertName 校验失败。

---

## 八、效果与限制

### 能解决的

- ✅ 国内中继延迟高
- ✅ P2P 打洞成功率低
- ✅ 晚高峰丢包
- ✅ 不依赖官方 DERP

### 不能解决的

- ❌ **DERP 中继带宽受限** —— 中继时流量走服务器，带宽决定速度
- ❌ **打洞失败仍需中继** —— 对称 NAT 下无法直连
- ❌ **手机流量场景** —— 移动网络打洞困难，基本都走中继

**性能提示**：如果经常走中继，建议选**三线 BGP** 或对应运营商优化线路的服务器。

---

## 九、资源占用实测

| 项目 | 占用 |
|---|---|
| derper 进程内存 | 16-18 MB |
| 磁盘（二进制 + 证书） | ~30 MB |
| CPU | 接近 0（空闲时） |
| 带宽 | 仅中继时消耗 |

**1 核 512M 的机器绰绰有余。**

---

## 十、快速命令速查

```bash
# 部署
scp derper root@server:/opt/derper-official
systemctl enable --now derper

# 查 CertName
grep CertName /var/log/derper.log

# 验证
tailscale debug derp 900

# 延迟
tailscale netcheck

# 日志
tail -f /var/log/derper.log
```

---

## 许可证

文档内容可自由使用。
