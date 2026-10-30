# 02. LAN PC IPv6 不通诊断、TUN 补丁与架构对比

**状态**：结论明确，附客户端配置补丁与三方案对比
**状态标记**：待验证（修复配置需本地路由器应用后实测）

---

## 1. 现象与根因诊断

### 1.1 现状与问题描述
- **路由器本机**：v4 经过出口 A，v6 经过出口 B (SOCKS5 v6)，`curl -6 https://ipv6.google.com` 正常获取 `2a10:6d41:...`。
- **LAN 下属 PC**：IPv4 透明代理正常；**IPv6 完全不可达**。

### 1.2 根因定位
1. **老挝 5G CPE 无原生 IPv6**：CPE 无法从运营商 WAN 口获得 IPv6 Prefix（无 DHCPv6 / PD / RA）。
2. **sing-box TUN 路由抓取范围缺失**：路由器的 `sing-box` TUN 接口仅配置了 `inet4_address` / `inet4_route` (或 `route_address` 只有 IPv4 `172.19.0.1/30` / `0.0.0.0/0`)，**缺少 IPv6 ULA 地址与 `::/0` 默认路由**。
3. **PC 流量 bypass 隧道**：LAN 侧 PC 尝试发起 IPv6 连接时，因 PC 没有有效 Global/ULA IPv6 地址，或者 OpenWrt 内核没有把 IPv6 流量路由进 TUN 网卡，导致 IPv6 包在路由器 LAN 口直接丢弃或被 ICMP Unreachable 拒答。

---

## 2. 解决方案一：sing-box TUN 接管 `::/0` 完整补丁 (推荐)

### 2.1 核心思路
给 OpenWrt 客户端的 sing-box TUN 接口分配一个 IPv6 ULA 本地单播地址（如 `fdfe:dcba:9876::1/126`），并将 `route_address` / `route_exclude_address` 增加 `::/0`，强制将全屋 LAN 侧的 IPv6 请求通过 TUN 虚拟网卡捕获，再由 sing-box 的路由规则转发至出口 B (SOCKS5 IPv6)。

### 2.2 路由器 `/etc/sb-reality/config.json` 修改补丁

```json
<<<<<<< SEARCH
    "inbounds": [
      {
        "type": "tun",
        "tag": "tun-in",
        "interface_name": "tun0",
        "inet4_address": "172.19.0.1/30",
        "auto_route": true,
        "strict_route": true,
        "stack": "system",
        "sniff": true
      }
    ],
=======
    "inbounds": [
      {
        "type": "tun",
        "tag": "tun-in",
        "interface_name": "tun0",
        "inet4_address": "172.19.0.1/30",
        "inet6_address": "fdfe:dcba:9876::1/126",
        "auto_route": true,
        "strict_route": true,
        "stack": "mix",
        "sniff": true,
        "sniff_override_destination": true
      }
    ],
>>>>>>> REPLACE
```

### 2.3 OpenWrt LAN 侧 IPv6 告示 (RA) 配置 (可选，使 PC 获取 ULA v6 地址)

在 OpenWrt `/etc/config/dhcp` 中开启 LAN 口的 ULA 前缀与 Router Advertisement (RA)：

```ini
config dhcp 'lan'
	option interface 'lan'
	option start '100'
	option limit '150'
	option leasetime '12h'
	option ra 'server'
	option dhcpv6 'server'
	option ra_management '1'

# 确保 /etc/config/network 中定义了 ULA 前缀
config globals 'globals'
	option ula_prefix 'fdfe:dcba:9876::/48'
```

---

## 3. 三种架构方案对比分析

| 对比维度 | 方案 A：TUN 增加 ULA + `::/0` 接管 (推荐) | 方案 B：PC 客户端直接绑定出口 B (SOCKS5) | 方案 C：OpenWrt 6to4 / NPTv6 隧道 |
|---|---|---|---|
| **改动位置** |仅 OpenWrt 路由器 sing-box 配置 | 局域网各 PC 独立配置 (系统/浏览器代理) | OpenWrt 网络层重构 (6in4 / WireGuard) |
| **设备覆盖** | **整屋透明无感** (PC/手机/智能家居) | 仅支持设置 SOCKS5 代理的软件 (应用级) | 整屋 IPv6 直连 (需外部 IP 配合) |
| **透明度** | 高 (零配置，PC 无感知) | 低 (每台设备/应用需手动配 SOCKS5) | 中 |
| **DNS 隐患** | **已解决** (sing-box FakeIP/Remote DNS 接管) | 易发生 DNS 泄漏与 AAAA 拒答 | 依赖上游 ISP |
| **复杂度** | 非常低 (只需加 2 行配置) | 繁琐 (终端分散) | 高 (需公网 6in4 隧道或复杂 NAT66) |

---

## 4. 本地验证步骤 (验证方法)

在本地执行体于 OpenWrt 应用补丁并重启 `sb-reality` 服务后，在 LAN PC 上运行以下操作进行核验：

1. **测试 IPv6 路由连通性**：
   ```cmd
   # Windows Command Prompt / PowerShell
   ping -6 ipv6.google.com
   tracert -6 ipv6.google.com
   ```
2. **测试 IPv6 出口 IP 是否匹配出口 B**：
   ```bash
   # Linux / macOS / PowerShell
   curl -6 https://api64.ipify.org
   # 或
   curl -6 https://ipv6.icanhazip.com
   ```
   **预期结果**：返回出口 B 的 IPv6 地址 (`<PROXY_B_IP>` 绑定的 v6 地址 / `2a10:6d41:...`)。

3. **测试 DNS 真实解析**：
   ```cmd
   nslookup -type=aaaa google.com
   ```
   **预期结果**：正常获得 AAAA 记录，且不再出现 `Query refused` 拒答错误。
