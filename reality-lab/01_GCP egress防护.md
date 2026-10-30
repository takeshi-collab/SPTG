# 01. GCP Egress 出口流量防护方案与落地说明

**状态**：结论明确，配套脚本与 systemd 单元已落地 (`reality-lab/scripts/`)
**相关文件**：
- [egress-guard.sh](scripts/egress-guard.sh) (流量监控与熔断主脚本)
- [egress-guard.service](scripts/egress-guard.service) (Systemd 服务单元)
- [egress-guard.timer](scripts/egress-guard.timer) (定时触发器，每 15 分钟执行)

---

## 1. 现状与风险诊断

### 1.1 现状分析
- **GCP Hub 节点**：`usa-hub-1` 位于 `us-west1-a`，运行 sing-box VLESS-Reality (TCP 443)。
- **流量计费风险**：GCP Compute Engine 出口流量（Egress to Internet）按量收费（公网出站约 $0.12/GB，视区域而定）。若 Hub 节点被外部扫频、被滥用代理，或遭遇死循环流量（如与 SOCKS5 出口环路），可能导致产生意外高额账单。
- **缺失防护**：现状未配置 GCP 预算熔断，也未在 VM 本地设置流量监控硬顶。

### 1.2 防护目标
1. **本地硬熔断**：在 Hub 节点实现月度流量硬顶（默认 180 GB/月，可调），超限自动停止 `sing-box` 服务并利用 `iptables` 封禁 443 端口。
2. **云端预算告警**：结合 GCP Cloud Billing Budget，设置 $10 / $20 / $30 阶梯邮件与 Pub/Sub 告警。
3. **零额外成本**：不引入付费云监控中间件，仅依靠 Linux Kernel `/sys/class/net` 统计与本地轻量级 systemd timer。

---

## 2. 方案对比：云端 Budget 告警 vs 本地硬熔断

| 维度 | GCP Cloud Billing Budget | 本地 `egress-guard` 熔断脚本 (推荐) |
|---|---|---|
| **生效延迟** | 延迟较大（账单数据同步通常需 6~24 小时） | **秒级/分钟级**（最长 15 分钟轮询一次） |
| **动作能力** | 默认仅发邮件告警；需配置 Cloud Functions 才可关机 | **直接停止 proxy 服务 / 封禁端口 / 停止 VM** |
| **部署成本** | 需 GCP 账单管理员 (Billing Admin) 权限 | **仅需 VM 内 root 权限**，落地极其简单 |
| **推荐策略** | 作为二级兜底（防止其他 GCP 资源烧钱） | **作为一级核心防护（秒级切断 Hub 代理流量）** |

---

## 3. 落地实施指南

### 3.1 本地 `egress-guard` 部署 steps

所有文件均已放置于本仓库 `reality-lab/scripts/` 中。执行体（Claude Code / 本地运维）只需在 Hub VM (`usa-hub-1`) 上执行以下命令：

```bash
# 1. 复制脚本与 systemd 单元文件
sudo cp reality-lab/scripts/egress-guard.sh /usr/local/bin/egress-guard.sh
sudo chmod +x /usr/local/bin/egress-guard.sh

sudo cp reality-lab/scripts/egress-guard.service /etc/systemd/system/
sudo cp reality-lab/scripts/egress-guard.timer /etc/systemd/system/

# 2. 重载 systemd 并启用定时器
sudo systemctl daemon-reload
sudo systemctl enable --now egress-guard.timer

# 3. 手动触发一次测试
sudo systemctl start egress-guard.service
sudo journalctl -u egress-guard.service -n 20 --no-pager
```

### 3.2 环境变量自定义配置
在 `/etc/systemd/system/egress-guard.service` 中可通过 Environment 修改参数：
- `MONTHLY_LIMIT_GB=180`：设置月度阈值 (GB)。
- `EGRESS_IFACE=eth0`：网卡名称（脚本会自动检测 `eth0` 或 `ens4`）。

### 3.3 查看运行日志与状态
```bash
# 查看持久化状态文件
cat /var/lib/egress-guard/state.json

# 查看防护日志
cat /var/log/egress-guard.log
```

---

## 4. 辅助防护：GCP 预算告警设置 (gcloud CLI)

为了防止 VM 之外的 GCP 资源产生账单，推荐在本地执行体运行 `gcloud` 命令行创建项目级预算告警：

```bash
# 1. 获取 Billing Account ID
BILLING_ACCT=$(gcloud beta billing accounts list --format="value(name)" | head -n 1)

# 2. 创建 $20 月度预算告警 (50%, 80%, 100% 邮件通知)
gcloud billing budgets create \
    --billing-account="${BILLING_ACCT}" \
    --display-name="Reality-Hub-Egress-Budget" \
    --budget-amount=20USD \
    --threshold-rules=percent=0.5 \
    --threshold-rules=percent=0.8 \
    --threshold-rules=percent=1.0 \
    --all-updates-rule-pubsub-topic=""
```

---

## 5. 验证方法与恢复步骤

### 5.1 验证熔断逻辑 (模拟超限)
可在测试环境中修改 `/var/lib/egress-guard/state.json` 中的 `accumulated_bytes` 为超过阈值的值，然后运行：
```bash
sudo /usr/local/bin/egress-guard.sh
```
**预期结果**：
1. 日志显示 `CRITICAL: Monthly egress quota exceeded`。
2. `systemctl status sing-box` 显示已停止 (`inactive`)。
3. `iptables -L INPUT -n -v` 中出现 `DROP tcp dpt:443` 规则。

### 5.2 误触发或下月自动恢复
- **每月 1 号**：脚本检测到新月份 (`YYYY-MM`)，会自动清空已用流量计数，解除 `iptables` 封禁，并自动重启 `sing-box` 服务。
- **手动解封/充值后恢复**：
  ```bash
  # 清理封禁规则并重启服务
  sudo iptables -D INPUT -p tcp --dport 443 -j DROP 2>/dev/null || true
  sudo systemctl start sing-box
  # 修改/重置状态文件中的 is_blocked 为 "false"
  sudo sed -i 's/"is_blocked": "true"/"is_blocked": "false"/' /var/lib/egress-guard/state.json
  ```
