# 09. GCP 侧网络架构与 IAP TCP Forwarding 加固评估

**状态**：结论明确，附现状 vs 加固架构对比矩阵与 gcloud 迁移命令指南

---

## 1. 现状与安全隐患诊断

### 1.1 现状配置
- **GCP VM**：`usa-hub-1` 分配了公网 IPv4 (`<HUB_IP>`)。
- **防火墙规则**：
  - `allow-vless-reality`：允许 `0.0.0.0/0` 访问 TCP 443。
  - **默认 SSH 22 端口对 `0.0.0.0/0` 完全开放**。
- **隐患分析**：
  1. SSH 22 端口对全网开放，暴露在全网全天候黑客 SSH 爆破与 0-day 扫描之下。
  2. 运维依赖公网 SSH，若客户端 IP 变动容易引发访问控制混乱。

---

## 2. 加固方案对比：现状 vs IAP TCP Forwarding + 移除公网 22

Google Cloud **IAP (Identity-Aware Proxy) TCP Forwarding** 允许用户在不为 VM 分配公网 22 端口的前提下，由 Google 统一身份认证与 IAM 鉴权，建立加密 SSH 隧道连接 VM。

### 2.1 对比矩阵

| 评估维度 | 现状 (公网 443 业务 + 22 SSH) | 加固方案 A：IAP 仅收紧 SSH 22 (推荐) | 加固方案 B：完全无公网 IP (仅内网 VM) |
|---|---|---|---|
| **代理业务 (Reality 443)** | 公网 443 正常对外服务 | 公网 443 正常对外服务 | 🔴 **代理无法接收老挝 5G 客户端流量** |
| **管理面 SSH (22 端口)** | 暴露给全网 (`0.0.0.0/0`) | **完全关闭公网 22，仅允许 IAP IP 段 (`35.235.240.0/20`)** | 完全通过 IAP 连接 |
| **攻击面** | 易被全网爆破 SSH | **管理面完全隐身**，零 SSH 爆破风险 | 极小 |
| **可用性 / 运维成本** | 依靠 SSH Key | **更方便**：无需管理密钥/无需记动态 IP，`gcloud compute ssh` 自动建立 IAP 隧道 | 运维便利性相同 |
| **GCP 成本** | 公网 IP $0.005/小时 (约 $3.6/月) | 公网 IP $0.005/小时 (不变) | 省去外部 IP 费用 ($3.6/月) |

**结论**：**方案 A 是当前最优加固路径**。代理业务必须保留公网 IPv4 443 端口接入流量；而管理面 SSH 22 端口必须完全收窄给 IAP 网段！

---

## 3. 落地加固指南 (gcloud CLI 命令)

执行体在本地执行以下命令，即可完成 Hub 节点管理面的“零漏洞暴露”加固：

### 步骤 1：创建限制仅允许 IAP 源网段的 SSH 防火墙规则
```bash
# 35.235.240.0/20 是 Google IAP 专用源 IP 网段
gcloud compute firewall-rules create allow-ssh-ingress-from-iap \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --target-tags=wireguard-hub
```

### 步骤 2：删除默认的全网 0.0.0.0/0 允许 SSH 规则
```bash
gcloud compute firewall-rules delete default-allow-ssh --quiet
```

### 步骤 3：配置 IAM 授权 (授予操作员 IAP 隧道权限)
```bash
gcloud projects add-iam-policy-binding <GCP_PROJECT_ID> \
    --member="user:takeshi@utopiaaihub.com" \
    --role="roles/iap.tunnelResourceAccessor"
```

### 步骤 4：通过 IAP 建立 SSH 连接验证
加固完成后，不再使用常规 SSH 命令，而是统一使用 `gcloud` 拉起 IAP 隧道连接：
```bash
# 连接 usa-hub-1 管理终端
gcloud compute ssh usa-hub-1 --tunnel-through-iap --zone=us-west1-a
```

---

## 4. 收益评估

1. **管理面攻击面缩减 100%**：公网扫描器扫描 22 端口将直接超时丢包，彻底避免 SSH 暴力破解。
2. **审计与权限收窄**：所有运维 SSH 登录受 Google 账号 2FA/IAM 条件严格约束与 Cloud Logging 审计。
