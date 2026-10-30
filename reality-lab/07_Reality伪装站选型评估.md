# 07. VLESS-Reality 伪装站选型评估与 SNI 策略

**状态**：结论明确，附候选域名评估矩阵与维持/替换建议

---

## 1. Reality 伪装站选型原则

VLESS-Reality 协议通过借用真实大型网站的 TLS 证书与 ClientHello/ServerHello 握手特征，实现消除代理特征与抵御 GFW 主动探测 (Active Probing)。选型必须严格符合以下四条原则：

1. **必须支持 TLS 1.3 与 HTTP/2 或 HTTP/3**。
2. **目标服务器 IP 必须位于海外 (最好与 Hub 节点同属美国/同区域 CDN)**。
3. **目标网站必须具有极高 SNI 信誉，流量体量极大**，在大流量背景中不易被阻断。
4. **证书链必须合法且有效期长**，且**不能启用 HSTS 强制跳转或 SNI 与 IP 不匹配的严格校验**。

---

## 2. 现状与候选域名对比评估

### 2.1 当前现状：`www.snapchat.com`
- **证书状态**：实测为 Snap Inc. 真实证书，2027-04-11 到期。
- **协议支持**：TLS 1.3 / HTTP2，CDNetworks / Cloudflare CDN 节点。
- **评价**：信誉良好，北美大流量社交流量，被墙风险极低。

### 2.2 热门候选域名对比矩阵

| 候选 SNI 域名 | 证书提供商/CDN | TLS 1.3 / H2 支持 | 节点地理位置 | 风险/隐患 | 综合推荐度 |
|---|---|---|---|---|---|
| **`www.snapchat.com`** (现状) | DigiCert / Cloudflare | 🟢 支持 | 北美 / 全球 CDN | 零已知风险 | 🟢 **维持现状 (最优)** |
| **`apple.com` / `gateway.icloud.com`** | Apple Inc. / Akamai | 🟢 支持 | 全球 Akamai Edge | Akamai 某些边缘节点对非 Apple SNI 会主动断开 TCP 连接 | 🟡 备选 |
| **`dl.google.com` / `www.microsoft.com`** | Google / Microsoft | 🟢 支持 | GCP / Azure | 某些地区 ISP 对 Google SNI 有 SNI RST 干扰 | 🟡 备选 |
| **`www.amazon.com`** | Amazon CloudFront | 🟢 支持 | AWS CloudFront | CloudFront 节点对 ClientHello SNI 校验极严，可能返回 403 | 🔴 不推荐 |
| **国内常见小网站 / 个人博客** | Let's Encrypt | 🟡 参差不齐 | 单节点 | 站点随时可能关站/过期，主动探测极易露馅 | 🔴 **禁忌** |

---

## 3. 评估结论与建议

### 结论：
1. **建议维持 `www.snapchat.com` 现行配置**。实证证书有效期至 2027 年，流量信誉极高，无替换必要。
2. **备用 SNI 列表**（若 `www.snapchat.com` 未来遭 ISP 干扰）：
   - `gateway.icloud.com`
   - `swdist.apple.com`
   - `itunes.apple.com`

### 配置注意事项：
- 确保 sing-box 服务端与客户端配置中的 `dest` 端口匹配：`www.snapchat.com:443`。
- 客户端配置中的 `server_name` 必须与 `dest` 保持一致，`short_id` 需定期轮换。
