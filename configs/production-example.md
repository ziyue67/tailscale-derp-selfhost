# 生产环境配置存档

实际部署记录，供日后参考。

## 服务器信息

| 项目 | 值 |
|---|---|
| 公网 IP | `106.55.105.93` |
| 内网 IP | `10.1.6.207/16` |
| 网关 | `10.1.1.1` |
| 虚拟化 | kvm（全虚拟化） |
| 系统 | Debian 13 (trixie) |
| 内核 | 6.12.94+deb13-cloud-amd64 |
| 配置 | 1 核 / 2G 内存 / 10G 磁盘 |
| 机房 | 腾讯云（国内，免备案 NAT） |
| Docker | 29.7.2 |

## 端口映射（NAT）

服务器在内网，需通过控制台做端口映射：

| 外网端口 | 内网端口 | 协议 | 用途 |
|---|---|---|---|
| `21986` | `22` | TCP | SSH |
| `33232` | `12345` | TCP | **DERP 中继** |
| `63941` | `3478` | TCP+UDP | **STUN 打洞** |

## derper 配置

```bash
# systemd 服务
/etc/systemd/system/derper.service

ExecStart=/opt/derper-official -a :12345 -http-port -1 -stun-port 3478 \
  -hostname 106.55.105.93 -certmode manual -certdir /etc/derp-ip \
  -verify-clients=false
```

**二进制**：官方编译版 `/opt/derper-official`（25MB，来自 `go install tailscale.com/cmd/derper@v1.102.4`）

## 证书

```
Subject: CN=106.55.105.93
SAN: IP:106.55.105.93, IP:10.1.6.207, DNS:derp.yourdomain.com
有效期: 2026-10-01 ~ 2036-09-28 (10年)
路径: /etc/derp-ip/106.55.105.93.{crt,key}
```

生成命令：

```bash
openssl req -x509 -newkey rsa:2048 \
  -keyout 106.55.105.93.key -out 106.55.105.93.crt \
  -days 3650 -nodes -subj "/CN=106.55.105.93" \
  -addext "subjectAltName=IP:106.55.105.93,IP:10.1.6.207,DNS:derp.yourdomain.com"
```

## Tailscale ACL 配置

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
						"HostName": "106.55.105.93",
						"IPv4": "106.55.105.93",
						"DERPPort": 33232,
						"STUNPort": 63941,
						"CertName": "sha256-raw:6d67f5be1b6b667acc457ad2de379ce0f5eb04b7333affa3648138223aaaf126"
					}
				]
			}
		}
	}
}
```

## 验证结果

```
$ tailscale debug derp 900
{
 "Info": [
  "Region 900 == \"tx-cn\"",
  "Successfully established a DERP connection with node \"106.55.105.93\"",
  "Node \"106.55.105.93\" returned IPv4 STUN response: 10.1.6.254:49605"
 ],
 "Warnings": null,
 "Errors": [
  "Error connecting ... over IPv6: dial tcp6: ... no suitable address found"
 ]
}
```

```
$ tailscale netcheck
	* Nearest DERP: TX-CN
	* DERP latency:
		- tx-cn: 73.9ms  (TX-CN)      ← 自建，最快
		- sin:   83.7ms  (Singapore)
		- hkg:   83.8ms  (Hong Kong)
		- tok:  128.8ms  (Tokyo)
```

| 指标 | 结果 |
|---|---|
| DERP 连接 | ✅ 成功 |
| STUN 响应 | ✅ 正常 |
| 成为最近节点 | ✅ 是 |
| 延迟 | ✅ 73.9ms |
| 进程内存 | 18 MB |

## Docker 配置

```json
// /etc/docker/daemon.json
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://dockerpull.org"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

## 失败方案记录（避免重复踩坑）

### 方案 1：第三方镜像 `guyuan404643/tailscale-ipderp`

**问题**：
1. 内置证书 `CN=derp.yourdomain.com`，用 IP 访问时 TLS 握手失败（`cert mismatch with hostname`）
2. STUN 完全不工作（本机 `127.0.0.1:3478` 测试都超时）

**结论**：不推荐。改用官方编译的 derper。

### 方案 2：香港 NAT 机 `43.128.21.208`

**问题**：
1. 256M 内存，SSH 会话频繁断开
2. LXC 容器，Docker 完全不可用（`unshare: operation not permitted`）
3. STUN 无法工作

**结论**：LXC + 小内存不适合。

### 关键教训

1. **证书 hostname 必须与实际访问方式一致** —— 这是最容易踩的坑，会导致 TLS 和 STUN 一起失效
2. **STUN 和 TLS 共用监听进程** —— 证书错了两个都挂
3. **Docker 映射 UDP 不如 host 网络可靠** —— 优先用 `--network host`
4. **LXC 容器直接放弃 Docker** —— DERP 用二进制就行
5. **小内存机器不要本地编译 Go** —— 交叉编译后传输
