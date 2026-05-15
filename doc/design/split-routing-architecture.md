# 分流架构重构 — 设计定稿（Rule + Mode + per-User + 双轨 DNS）

> **状态**：**已与用户达成共识，待 doge.10/11 完成后启动实施**。本文是 doge.12+ 的核心架构蓝图，固化了 2026-05-15 经过完整 Q1~Q19 决议轮 + sniffing-based routing + 双轨 DNS 双重核心变更后的最终方案。
>
> **目标版本区间**：doge.12 ~ doge.13（具体切片实施时细化）。doge.10 完成"砍协议"清理代码基（[protocol-roadmap.md §2](protocol-roadmap.md)），doge.11 完成 G1/G6/R1 硬编码出土（详见 [protocol-roadmap.md §7](protocol-roadmap.md)），二者为本设计扫清前置障碍。
>
> **核心设计**：把当前 fancyss 的"GFW/CHN/HOM/GAM/全局" 5 个硬编码模式 + "半成品 xray 分流" + 散落 16 处的硬编码强制直连/代理，统一重构为 **Clash/Mihomo 风格**的三层模型 + 路由层迁移到 **xray sniffing**（不再依赖 ipset 域名匹配）：
>
> - **Rule**（规则）= 一组域名 + IP/CIDR，可有 auto-update URL
> - **Mode**（模式）= (Rule → Action) 有序序列 + 全局修饰符 + 兜底动作 + **DNS 模式**
> - **User**（用户）= 每个 LAN 设备 1:1 分配一个 Mode
> - **DNS**：双轨并行——**分流 DNS**（chinadns 智能分流）与 **全局 DNS**（单一海外 upstream）按 Mode 选择
>
> 关联文档：
> - [protocol-roadmap.md](protocol-roadmap.md) — §5 自定义分流的总体战略位置
> - [chain-proxy-implementation.md](../implementation/chain-proxy-implementation.md) — 链式代理实现，本设计的 Action「代理（链式 Y→Z）」直接基于其 `dialerProxy` 注入机制
> - [failover-combo-implementation.md](../implementation/failover-combo-implementation.md) — 现有故障转移；按 Q8 决议（注释保留）与本架构**解耦**，不在 doge.12 主线
> - [CLAUDE.md](../../CLAUDE.md) — 硬规则 #1（dbus 前缀）/ #9（select 不静默清空）/ #10（运行状态 dbus 不新鲜）/ #11（chinadns tag 优先级——**本架构使其不再适用**，详见 §6.5）

---

## 1. 状态 + 关联文档

见上方引言。本文档**只写架构、不写实现细节**。具体实现策略落地时另写 `doc/implementation/split-routing-implementation.md`。

**第一稿对照说明**：2026-05-15 落盘的第一稿基于"chinadns-ng 打 tag → ipset → iptables match-set"架构，存在两个根本性缺陷：
1. 受 CLAUDE.md 硬规则 #11 约束，跨列表域名（如 microsoft.com 同时在 chnlist 和某 group）路由不可控
2. DNS 解析无法 per-Mode 区分（DNS 查询不带源 user 标识），导致"国内/国外站点真不同"场景无解（如 microsoft.com 国内返回中文站、国外返回英文站，全局代理 Mode 用户无法拿到英文站）

本稿通过**变更 1：xray sniffing-based routing** 消除缺陷 1，**变更 2：双轨 DNS** 消除缺陷 2。

---

## 2. 核心模型

### 2.1 三层数据结构总览

```
┌──────────────────────────────────────────────────────────────┐
│  Rule                                                        │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ id            : 数字（自增，1~99 预留内置预设）         │ │
│  │ name          : 用户可见名（"大陆白名单_常用"）         │ │
│  │ builtin       : 0/1（内置预设，不可删但可改内容）       │ │
│  │ source_url    : auto-update URL（空=手编规则）          │ │
│  │ update_hours  : 自动更新间隔小时（0=禁用）              │ │
│  │ last_update   : Unix ts（最近一次成功更新）             │ │
│  │ entries_path  : 文件路径（运行时合一存储域名+IP混排）   │ │
│  │ stat_domains  : 域名条数（缓存，UI 显示用）             │ │
│  │ stat_ips      : IP/CIDR 条数（缓存）                    │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
                            ▲
                            │ 引用（删除保护）
                            │
┌───────────────────────────┴──────────────────────────────────┐
│  Mode                                                        │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ id              : 数字（自增，1~99 预留内置预设）       │ │
│  │ name            : 用户可见名（"全局代理"/"大陆白名单"）  │ │
│  │ builtin         : 0/1（内置预设，不可删整条）           │ │
│  │ udp_proxy       : 0/1（启用 UDP 代理；Mode 级—Q18）     │ │
│  │ block_quic      : 0/1（屏蔽 QUIC；Mode 级—Q19）         │ │
│  │ apply_blackwhite: 0/1（受全局黑白名单文本框影响）       │ │
│  │ dns_mode        : "split" | "global"（DNS 轨道—新）     │ │
│  │ rules[]         : [{rule_id, action}]                   │ │
│  │ default_action  : 兜底动作字符串（不可为 reject）       │ │
│  └─────────────────────────────────────────────────────────┘ │
│   action ∈ {direct, reject, proxy_node:X, proxy_chain:Y:X}   │
└──────────────────────────────────────────────────────────────┘
                            ▲
                            │ 引用（删除保护）
                            │
┌───────────────────────────┴──────────────────────────────────┐
│  User                                                        │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ acl_node    : 数字（沿用现有 acl 行 ID）                │ │
│  │ ip / mac    : LAN 设备标识（沿用 acl 主键）             │ │
│  │ name        : 别名                                       │ │
│  │ mode_id     : 数字（Mode.id；0 = 不通过代理）—Q12 1:1   │ │
│  │ port_set    : 端口集（沿用 acl_port，与 Mode 解耦）     │ │
│  └─────────────────────────────────────────────────────────┘ │
│   "默认用户" = 未在表中列出的设备 → ss_split_default_mode_id │
└──────────────────────────────────────────────────────────────┘
```

### 2.2 关键约束（Q9-Q12 决议）

- **预设不可删**（Q9/Q10）：`builtin=1` 的 Rule 和 Mode 由 install.sh 写入，UI 上"删除整条"按钮置灰。但**预设 Mode 的 `rules[]` 顺序/增删 rule 用户可改**；**预设 Rule 关掉 auto-update 后用户可手编内容**。
- **删除保护**：Rule 被任一 Mode 引用时不可删；Mode 被任一 User 引用（或为默认 Mode）时不可删。UI 删除按钮置灰，hover tooltip 显示"被 Mode X / User Y 引用"。
- **默认 Mode 必须真实**（Q11）：`ss_split_default_mode_id` 必须指向真实存在的 Mode.id，**不允许指向 0（不通过代理）**。"全局直连"语义没有安全意义，强制要求至少有一个 Mode 兜底。
- **1:1 用户→Mode**（Q12）：一个 acl 行映射一个 mode_id；按端口区分多 Mode 的需求一期不支持，端口集仍由 acl_port 独立控制。
- **数据安全底线**：内置「全局代理」+「大陆白名单」两个 Mode 永远不可删——它们是 doge.11→doge.12 升级的迁移目标。

### 2.3 文件存储路径

- 规则文件：`/koolshare/ss/rules_user/rule_<id>.txt`（用户/预设统一目录，按 id 命名）
- Rule 备份（Q13）：`/koolshare/ss/rules_user/rule_<id>.txt.bak`（远程 update 前**保留 1 版**，拉到坏内容能回滚）
- 自动更新调度表：`/koolshare/ss/rules_user/update_schedule.txt`（cron 内部读，格式见 §10.2）
- 内置预设规则"出厂"副本：`/koolshare/ss/rules_ng/builtin/rule_<id>.txt`（install.sh 拷到 rules_user/）
- xray 配置：复用现有 `/koolshare/ss/xray.json`（生成器替换为新逻辑）

---

## 3. dbus key 设计

严格遵守 [CLAUDE.md 硬规则 #1](../../CLAUDE.md)：前端要读的用 `ss_*` 前缀，纯后端用 `fss_*`。

### 3.1 Rule 相关（前端可读）

| Key | 类型 | 说明 |
|---|---|---|
| `ss_split_rule_count` | int | Rule 总数 |
| `ss_split_rule_<i>_id` | int | 该行的 Rule.id（与 i 解耦，删除时不重排 id） |
| `ss_split_rule_<i>_name` | string | 显示名 |
| `ss_split_rule_<i>_builtin` | "0"/"1" | 是否内置预设 |
| `ss_split_rule_<i>_source_url` | string | auto-update URL（空=手编） |
| `ss_split_rule_<i>_update_hours` | int | 自动更新间隔（0=禁用） |
| `ss_split_rule_<i>_last_update` | int | Unix ts（成功） |
| `ss_split_rule_<i>_stat_domains` | int | 域名条数缓存 |
| `ss_split_rule_<i>_stat_ips` | int | IP/CIDR 条数缓存 |

> 注：`entries_path` 不进 dbus（路径可由 id 推出 `/koolshare/ss/rules_user/rule_<id>.txt`）。

### 3.2 Mode 相关（前端可读）

| Key | 类型 | 说明 |
|---|---|---|
| `ss_split_mode_count` | int | Mode 总数 |
| `ss_split_mode_<m>_id` | int | Mode.id |
| `ss_split_mode_<m>_name` | string | 显示名 |
| `ss_split_mode_<m>_builtin` | "0"/"1" | 是否内置 |
| `ss_split_mode_<m>_udp_proxy` | "0"/"1" | 启用 UDP 代理（Mode 级） |
| `ss_split_mode_<m>_block_quic` | "0"/"1" | 屏蔽 QUIC（Mode 级） |
| `ss_split_mode_<m>_apply_blackwhite` | "0"/"1" | 受黑白名单影响 |
| `ss_split_mode_<m>_dns_mode` | "split"/"global" | DNS 模式（新，split→分流 chinadns:65353，global→全局 chinadns:65354；详见 §6.2） |
| `ss_split_mode_<m>_default_action` | string | 兜底动作（编码见 §3.4；**不可为 reject**） |
| `ss_split_mode_<m>_rule_count` | int | rules[] 长度 |
| `ss_split_mode_<m>_rule_<r>_rid` | int | 引用的 Rule.id |
| `ss_split_mode_<m>_rule_<r>_action` | string | 该规则的动作（编码见 §3.4） |

### 3.3 User 相关

复用现有 acl 字段，追加分配映射 + 默认 Mode：

| Key | 类型 | 说明 |
|---|---|---|
| `ss_split_default_mode_id` | int | 默认 Mode.id（替代旧的 `ss_basic_mode`；**必须非 0**） |
| `ss_acl_split_mode_<acl_node>` | int | 该 acl 行设备分配的 Mode.id（0=不通过代理） |

> 旧的 `ss_basic_mode` 和 `ss_acl_mode_<i>` 由 [install.sh::migrate_split_routing_v1](../../fancyss/install.sh) 一次性迁移（详见 §14）；迁完保留旧 key 一个版本以便回滚（doge.13 起删除）。

### 3.4 Action 编码格式（Q1 决议：单字符串）

为减少 dbus key 数量，action + params 编进**单个字符串**，`:` 分隔：

| 动作 | 编码 |
|---|---|
| 直连 | `direct` |
| 屏蔽 | `reject` |
| 代理（节点 X） | `proxy_node:<node_id>` |
| 代理（链式 Y→Z） | `proxy_chain:<front_id>:<landing_id>` |

例：`ss_split_mode_2_default_action = "proxy_chain:5:3"` 表示模式 2 兜底=「前置=节点 5、落地=节点 3」。

节点 id 当前是 fancyss 自增整数无 `:` 分隔符，编码无歧义。**未来若节点 id 体系改造（如改为 hash/uuid），需重新审视编码方案**。

**未来扩展**：当前 `proxy_chain:Y:X` 已是 3 段，进一步复杂动作（如负载均衡 `proxy_loadbalance:[a,b,c]`）建议改用 `proxy_<verb>:<json_b64>` 形式预留。

### 3.5 后端专用（`fss_*` 前缀）

| Key | 类型 | 说明 |
|---|---|---|
| `fss_split_migrated_v1` | "0"/"1" | install.sh 迁移幂等标志 |
| `fss_split_outbound_dedup_cache` | string | xray.json 生成器去重缓存（可选） |
| `fss_split_rules_update_lock` | "0"/"1" | cron 互斥锁，防并发更新（被 §10.2 cron 流程使用） |
| `fss_split_rules_update_log` | string | 最近一次 cron 执行摘要（UI 可显示） |

**运行状态 dbus key（`ss_split_*` 前缀，前端要读 → 受 [CLAUDE.md 硬规则 #1](../../CLAUDE.md) 约束）**：

| Key | 类型 | 写者 | 读者 | 说明 |
|---|---|---|---|---|
| `ss_split_active_mode_count` | int | 后端 restart 时写 | 前端运行状态页 | 当前活跃 Mode 数 |
| `ss_split_xray_outbound_count` | int | 后端 restart 时写 | 前端 | xray 实际生成的 outbound 数（去重后） |
| `ss_split_last_restart_ts` | int | 后端 restart 完成时写 | 前端 | 最近 xray 重启时间戳 |
| `ss_split_dns_split_status` | string | 后端 cron 检测 | 前端 | "ok"/"down"，分流 DNS 实例状态 |
| `ss_split_dns_global_status` | string | 后端 cron 检测 | 前端 | "ok"/"down"，全局 DNS 实例状态 |

> 上述 5 个运行状态键由后端实时写、前端要显示，按 [CLAUDE.md 硬规则 #10](../../CLAUDE.md) 必须配合轮询机制（详见 §8.4 `refresh_split_status_only()`）才能保证 UI 显示新鲜值。

### 3.6 备份/恢复白名单

参考 [failover-combo-implementation.md §3.3](../implementation/failover-combo-implementation.md) 的 fss_failover_* 后端键处理方式（[ss_node_common.sh:2535/2553/4089](../../fancyss/scripts/ss_node_common.sh)），对 fss_split_* 后端键追加 `dbus list fss_split_` 行；ss_split_* 前缀键已被默认 `dbus list ss` 覆盖无需额外处理。规则文件（`rules_user/*.txt`）也加入备份范围（与 dbus 数据分开打 tar）。

### 3.7 导入/导出 Mode（Q14 决议）

**doge.12 即提供**"导入/导出 Mode" (JSON) 功能。导出时**Mode + 其引用的所有 Rule 整包导出**（含规则文件内容内联），导入时如目标系统已有同名 Rule 弹冲突解决对话框（覆盖/重命名/跳过）。

JSON schema 示例：
```json
{
  "schema": "fancyss-doge-mode-export-v1",
  "exported_at": "2026-05-15T10:00:00Z",
  "mode": { "id": 5, "name": "办公专用", "builtin": 0, "rules": [...], ... },
  "rules": [
    {
      "id": 101,
      "name": "公司内网",
      "builtin": 0,
      "entries": "intranet.corp\n...",
      "source_url": "..." // 可选，由导出对话框 checkbox 控制
    },
    ...
  ]
}
```

---

## 4. xray.json 生成策略

### 4.1 总体流程

```
┌─────────────┐  ┌──────────────┐  ┌──────────────────┐
│ Mode 列表   │  │ User 分配    │  │ Rule 文件加载    │
└──────┬──────┘  └──────┬───────┘  └────────┬─────────┘
       │                │                   │
       v                v                   v
┌──────────────────────────────────────────────────────┐
│  扫描 Active Modes (= 被任一 User 引用的 Mode)       │
│  + Default Mode 永远 active                          │
└──────────────────────────────┬───────────────────────┘
                               │
       ┌───────────────────────┼─────────────────────────┐
       v                       v                         v
┌──────────────┐    ┌────────────────────┐     ┌──────────────────┐
│ Outbounds 去 │    │ Inbounds 生成      │     │ Routing 生成     │
│ 重（按 tag） │    │ (per active Mode,  │     │ (含 inboundTag + │
│              │    │  含 sniffing)      │     │  sniffed domain) │
└──────┬───────┘    └─────────┬──────────┘     └─────────┬────────┘
       │                      │                          │
       └──────────────────────┴──────────────────────────┘
                              │
                              v
                      ┌───────────────┐
                      │ xray.json     │
                      └───────┬───────┘
                              │
                              v
                ┌─────────────────────────────┐
                │ fss_chain_apply 注入        │
                │ dialerProxy（已存在逻辑）   │
                └─────────────────────────────┘
```

### 4.2 Sniffing 配置（**架构核心变更 1**）

每个 inbound 启用 sniffing：

```json
{
  "tag": "mode_2",
  "port": 13334,
  "protocol": "dokodemo-door",
  "settings": { "network": "tcp,udp", "followRedirect": true },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "metadataOnly": false,
    "routeOnly": true
  },
  "streamSettings": { "sockopt": { "tproxy": "tproxy" } }
}
```

**关键点**：
- `destOverride: ["http","tls","quic"]` — 嗅探 HTTP Host 头、TLS SNI、QUIC SNI
- `routeOnly: true` — 嗅探结果**只用于 routing 匹配**，实际拨号仍用原 IP（避免破坏 SNI/Host）
- xray 看到真实域名后按 Mode rules 匹配 → 路由到对应 outbound
- IP CIDR 类 Rule 仍用 routing 的 `ip:` matcher（嗅探不到域名时回退到目的 IP 匹配）

**xray sniffing 性能开销**：参考 v2ray-core 社区数据估算 +5% CPU（fancyss 当前未启用 sniffing，PoC 验证留 doge.12 实施期）。家用场景可忽略。

### 4.3 Outbound 去重算法（**核心性能保障**）

**问题**：50 条规则全用同一节点，naive 实现会生成 50 个相同 outbound，xray 启动时间和内存炸。

**算法**：

```
outbound_set = {}    # key: action_tuple, value: tag_name
for mode in active_modes:
    for rule in mode.rules + [mode.default_action]:
        key = canonical(rule.action)
        if key not in outbound_set:
            tag = generate_unique_tag(key)
            outbound_set[key] = tag
            emit_outbound(key, tag)

def canonical(action_str):
    parts = action_str.split(":")
    if parts[0] == "direct":      return ("direct",)
    if parts[0] == "reject":      return ("reject",)
    if parts[0] == "proxy_node":  return ("node",  parts[1])
    if parts[0] == "proxy_chain": return ("chain", parts[1], parts[2])
```

**约束兑现**：50 条规则 × 同 1 节点 = **1 个 outbound**，不是 50 个。

> 软上界 25 / 硬上界 50 详见 §11。注：xray 本身可支持 100+ outbound，30~50 是 RT-AX86U 上 xray restart 时长超过 5s 的拐点（用户开始可感知）。

### 4.4 Routing 规则排列顺序（最高优先级在前）

xray routing 是**短路匹配**——第一条命中就走。生成器按以下严格顺序铺，**每个 active mode 一组**（用 `inboundTag` 区分）：

```
For each active mode m:
  inbound_tag = "mode_<m>"

  # 1. RFC1918 / loopback 等机制必需直连（R1，参见 audit findings）
  emit_routing(inboundTag=[m], ip=["geoip:private", "127.0.0.0/8", ...],
               outboundTag="direct")

  # 1.5 IP 兜底匹配（大陆白名单 Mode 特有）：
  #     sniff 拿不到 SNI 时（如 ECH/QUIC 加密 SNI），按 geoip:cn + Mode 内
  #     chnlist 关联 Rule 的 IP 部分匹配 → freedom outbound 直连
  if m has chnlist_rule with direct action:
    emit_routing(inboundTag=[m], ip=["geoip:cn", chnlist_rule.ip_list],
                 outboundTag="direct")

  # 2. (可选) 全局黑白名单 — 仅当 mode.apply_blackwhite=1 时
  #    沿用 ss_wan_white_domain / ss_wan_black_domain 文本框数据
  if m.apply_blackwhite:
    # 2a. 白名单 → direct
    emit_routing(inboundTag=[m], domain=white_domains, ip=white_ips,
                 outboundTag="direct")
    # 2b. 黑名单 → 该 Mode 的 default_action（Q2 决议）
    emit_routing(inboundTag=[m], domain=black_domains, ip=black_ips,
                 outboundTag=tag_of(m.default_action))
    # Q2 警告：前端编辑黑名单时，若 m.default_action="direct"，
    #         弹黄字"该模式下黑名单不生效（默认动作=直连）"

  # 3. 用户在该 Mode 中显式排序的规则
  for rule in m.rules:
    emit_routing(inboundTag=[m],
                 domain=load_domains(rule.rule_id),
                 ip=load_ips(rule.rule_id),
                 outboundTag=tag_of(rule.action))

  # 4. 兜底动作
  emit_routing(inboundTag=[m], outboundTag=tag_of(m.default_action))
```

### 4.5 InboundTag 与 User mapping

每个 active Mode → 一个 TPROXY inbound（端口分配见 §5.1）→ 该 inbound 的 routing 规则都带 `inboundTag: ["mode_<m>"]`。

iptables 把不同 user 流量按 MAC/IP 区分，TPROXY 到对应 inbound 端口。**xray 只看 inboundTag 不需要看源 IP**——把 user→mode 的映射完全推到 iptables 层。

### 4.6 reject outbound

xray 的 `blackhole` outbound 实现 reject。一个全局 `out_reject` tag 即可。DNS 层面 reject 由"全局 DNS 兜底"或 chinadns reject group 实现（视 Mode dns_mode 而定，见 §6）。

---

## 5. iptables / ipset 装配策略（**极简化**）

### 5.1 per-Mode TPROXY 端口分配

- 现有架构：1 个固定端口（`xray_redir_port` 默认 3333），所有用户共享
- 新架构：N 个端口，N = active mode 数。从 `xray_redir_port_base` 起递增（13333、13334、13335...）

```
# iptables 框架（PREROUTING 按 user 的 MAC/IP 区分，TPROXY 到对应端口）
for acl in users:
    mode_port = port_of(acl.mode_id)
    iptables -t mangle -A SHADOWSOCKS_USER \
             -m mac --mac-source $acl.mac \
             -j TPROXY --tproxy-mark <mark> --on-port $mode_port
    # 未列出设备走 ss_split_default_mode_id 对应端口
```

### 5.2 TCP/UDP 路径（Q3 决议：不切全 TPROXY）

**保持现状混搭**：TCP 走 nat REDIRECT，UDP 走 mangle TPROXY。理由：
- 现行 [`load_tproxy()`](../../fancyss/ss/ssconfig.sh) 已经在 hnd_v7/hnd_v8/qca/mtk 全平台验证 xt_TPROXY 模块可用
- 但 TCP REDIRECT 路径在某些平台更稳定（与现有 NAT 规则更兼容）
- 切全 TPROXY 收益小风险大，**doge.12 不做**

per-Mode 端口分配同时适用于 nat REDIRECT 链（TCP）和 mangle TPROXY 链（UDP）。

### 5.3 ipset 在新架构中的角色（**大幅瘦身**）

**旧架构**：ipset (`white_list`/`black_list`/`chnroute`/`chnlist`/`gfwlist`/`router`/`ignlist` 等) 由 iptables `-m set --match-set X dst -j RETURN/REDIRECT` 直接决定路由。

**新架构**：iptables 只负责"用户 → Mode 端口"分流，**不再**做"域名/IP → 走代理/直连"匹配——这部分完全交给 xray sniffing + routing。所以：

**删除的 ipset**：
- `chnlist` / `chnroute` — 国内 IP/域名走直连改由 xray routing 的 `geoip:cn` 和 chnlist Rule 完成
- `gfwlist` — 同理由 Rule 完成
- `black_list` / `white_list` — 由 §4.4 的 routing 规则 2a/2b 完成
- `router` — Mode 数据可替代（详见 §5.4 机内流量）
- `ignlist` 大部分内容 — 移到 xray routing 的 R1 直连段

**保留的 ipset**：
- `ignlist_minimal` —— **仅保留**绝对必要的 RFC1918 + 链路本地 + 多播段（精简版 R1），用于 iptables PREROUTING 提前 RETURN（保险机制，xray 万一挂了也不致内网流量打到代理）
- IP CIDR 类 Rule 数据 **不进 ipset**，直接写入 xray routing 的 `ip:` 字段（domain matcher 也是同理）

### 5.4 机内流量（Q4 决议）

**机内流量复用 Rule 数据**，**不进 Mode 系统**。现有 SHADOWSOCKS_EXT 链保留作为独立路径，但其"应代理域名表"的数据源切换为读取**某指定内置 Rule 的内容**（例如内置 Rule `id=10` "机内流量代理列表"），而非现在的硬编码 + `ss_wan_black_domain` 文本框。

**好处**：用户在 Rule 管理页编辑该 Rule 即同时影响机内流量行为，概念统一。
**约束**：机内流量永远用"默认 Mode 的兜底节点"作为代理出口（不能 per-Mode，因为路由器自己没有 user 概念）。

### 5.5 chinadns-ng 与 ipset 解耦

当前 chinadns-ng 把解析结果按 tag 写进对应 ipset（chnlist tag → chnroute ipset 等）。新架构 iptables 不再用这些 ipset 决策，所以 chinadns-ng 的 `add_tagchn_ip` / `add_taggfw_ip` 等"写入 ipset"指令**全部移除**——chinadns-ng 只负责返回 DNS 答案给客户端，不再喂 ipset。

---

## 6. DNS 层设计（**架构核心变更 2：双轨 DNS**）

> **架构强制前提**：`ss_basic_dns_serverx=1`（chinadns-ng 直接占 53，dnsmasq 不参与 DNS forward 链）。dnsmasq DHCP / hosts / LAN hostname 解析等附加功能照常工作，只是 DNS forward 关掉。[install.sh::migrate_split_routing_v1](../../fancyss/install.sh) 强制设置该值；前端 DNS 设定页对此切换为只读 + 锁定，hover 说明"分流架构必需"。

### 6.1 双轨设计动机

**第一稿的 P1 设计缺陷**：聚合所有 Mode 的"应直连域名"到 chinadns 走国内 DNS，"应代理域名"走可信 DNS。在**"国内/国外站点真不同"**场景失效：

> 例：`microsoft.com` 国内 DNS 返回中文站 IP（msn.cn 系），国外 DNS 返回英文站 IP。用户在"全局代理"Mode 想拿英文站，但被 P1 聚合塞了国内 DNS → 解析到中文站 IP → 即使代理出口，看到的仍是中文站。

**根因**：单一 chinadns 实例无法表达"某 user 想要国外 DNS 视图"。

### 6.2 双轨方案（F1 解法 A：chinadns-ng × 2 + dnsmasq 让 53）

**关键现实**：fancyss 默认环境下 dnsmasq 占着 53；只有 `ss_basic_dns_serverx=1` 时 chinadns-ng 才直接接管 53。本架构强制要求该值=1（见上方"架构强制前提"）。

**第一稿曾考虑过的 D 方案（xray 内置 DNS 模块）已废弃**：xray internal DNS 缺 chinadns 那套 chnlist/gfwlist tag 分流能力，硬补会重复造轮子。

部署**两个**chinadns-ng 实例 + dnsmasq 让出 53：

```
┌─────────────────────────────────────────────────────────────────┐
│  分流 DNS 实例  chinadns-ng @ 127.0.0.1:65353                   │
│  ───────────────────────────────────────────                    │
│  • 国内 DNS upstream（用户在"DNS 设置→分流 DNS"页配）           │
│  • 国外 DNS upstream（同上，DoH/DoT 通过代理走）                │
│  • chnlist tag → 国内组                                          │
│  • gfwlist tag → 国外组                                          │
│  • reject group（聚合所有 split-mode 的 reject 域名）           │
│  • 本地域名（*.lan / *.local / <asusrouter>）→ 127.0.0.1:dnsmasq_lan_port │
│  服务对象：所有 dns_mode="split" 的 Mode                        │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  全局 DNS 实例  chinadns-ng @ 127.0.0.1:65354                   │
│  ───────────────────────────────────────────                    │
│  • 单一海外 upstream（默认 1.1.1.1 over DoH，通过代理走）       │
│  • 所有查询经代理走，不做 tag 分流                              │
│  • 不挂 chnlist/gfwlist（让所有域名都走单一 upstream）          │
│  • 本地域名（*.lan / *.local）→ 127.0.0.1:dnsmasq_lan_port      │
│  服务对象：所有 dns_mode="global" 的 Mode                       │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  dnsmasq（被 chinadns 当作 LAN 域名权威服务器使用）             │
│  ───────────────────────────────────────────                    │
│  • listen 在 127.0.0.1:<dnsmasq_lan_port>（非 53，让位给 chinadns）│
│  • 仍处理 DHCP-lease 反向解析、<hostname>.lan、<asusrouter>.local │
│  • chinadns 两个实例都把"本地域名"分支指过来                    │
└─────────────────────────────────────────────────────────────────┘
```

**ASUS LAN 内域名解析**：dnsmasq 仍作为 LAN 域名权威服务器（listen 在另一端口，例如 65355），chinadns-ng 配置加一条 group 把 `*.lan` / `*.local` / `<asusrouter>` 等本地域名定向到 `127.0.0.1:dnsmasq_lan_port`。这样 LAN 内 hostname 解析仍工作。

### 6.3 DNS 流程图

```
LAN 设备 ──UDP/53──┐
                   │
       iptables PREROUTING DNAT (per acl.mode_id)
                   │
       ┌───────────┴────────────┐
       │                        │
       ▼ Mode.dns_mode=split    ▼ Mode.dns_mode=global
  127.0.0.1:65353          127.0.0.1:65354
  (chinadns 分流)          (chinadns 全局)
       │                        │
   ┌───┴───┐               走代理 outbound
   │       │                    │
chn组   gfw组                海外 DNS
直 upstream  代理 upstream
   │       │                    │
   └───┬───┴────────────────────┘
       ▼
   DNS 响应回到 LAN 设备
```

**iptables 实现**（Y4 决议 (iii)：**br0 per-user，其他 VLAN 锁默认 Mode**）：

**SHADOWSOCKS_DNS_0（主网 br0）**——per-MAC DNAT + fallback 到默认 Mode 的 DNS 端口：

```
# Step 1: per-MAC DNAT（只在 br0 上）
for acl in users_on_br0:
    dns_port = (65353 if mode_of(acl).dns_mode=="split" else 65354)
    iptables -t nat -A SHADOWSOCKS_DNS_0 \
             -i br0 -p udp --dport 53 -m mac --mac-source $acl.mac \
             -j DNAT --to-destination 127.0.0.1:$dns_port
    iptables -t nat -A SHADOWSOCKS_DNS_0 \
             -i br0 -p tcp --dport 53 -m mac --mac-source $acl.mac \
             -j DNAT --to-destination 127.0.0.1:$dns_port

# Step 2: br0 fallback（未列出设备走默认 Mode）
default_dns_port = (65353 if default_mode.dns_mode=="split" else 65354)
iptables -t nat -A SHADOWSOCKS_DNS_0 -i br0 -p udp --dport 53 \
         -j DNAT --to-destination 127.0.0.1:$default_dns_port
iptables -t nat -A SHADOWSOCKS_DNS_0 -i br0 -p tcp --dport 53 \
         -j DNAT --to-destination 127.0.0.1:$default_dns_port
```

**SHADOWSOCKS_DNS_${VLAN}（br1/br2/... 访客网络）**——**只有 fallback 一条规则**，全部到默认 Mode 的 DNS 端口（不做 per-user）：

```
for vlan_if in br1, br2, ...:  # 访客网络 / IoT 网络等
    iptables -t nat -A SHADOWSOCKS_DNS_${vlan_if} -i ${vlan_if} -p udp --dport 53 \
             -j DNAT --to-destination 127.0.0.1:$default_dns_port
    iptables -t nat -A SHADOWSOCKS_DNS_${vlan_if} -i ${vlan_if} -p tcp --dport 53 \
             -j DNAT --to-destination 127.0.0.1:$default_dns_port
```

**ACL 表 UI 影响**：访问控制 UI 只展示 br0 上的设备（其他 VLAN 不可分配 per-user Mode）。doge.13+ 如有需求再加"访客网络自定义默认 Mode 下拉"作为附加功能（不破坏 (iii) 基础结构）。

### 6.4 P1（直连优先）的退化语义

第一稿的 P1 直连优先在新架构里**退化为"分流模式 Mode 之间的冲突解决器"**：

- 仅适用于所有 `dns_mode=split` 的 Mode 共享同一份 chinadns-ng 配置时
- 当 Mode A 把 X.com 标 direct、Mode B 把 X.com 标 proxy_node，DNS 层无法区分 user，故所有 dns_mode=split 用户拿到同一份 DNS 视图
- **共享视图按"国内 DNS 优先"原则**（如果 X.com 在任一 Mode 标为 direct，则走 chn 组国内 DNS）
- `dns_mode=global` 的 Mode **不参与 P1 聚合**——它走全局 DNS 实例，与分流 DNS 完全隔离

### 6.5 硬规则 #11 在新架构下的处境（**重要说明**）

[CLAUDE.md 硬规则 #11](../../CLAUDE.md) 说："chinadns-ng tag 优先级是 `chnlist > gfwlist > 各 group`，凡同时在 chnlist/gfwlist 的域名永远拿不到 group white 的待遇"。

**新架构下的影响一分为二**：

(a) **对最终路由结果不再产生不可控影响**——路由决策迁到 xray sniffing 层。即使 X.com 被 chnlist tag 抢走、解析成国内 IP，xray 仍能从 sniffing 拿到真实域名 X.com，按用户配置的 Rule 路由。

(b) **chinadns-ng 实例内部行为仍受 #11 约束**——chnlist > gfwlist > group 的 tag 优先级在 DNS 解析阶段仍存在。**关键推论**：`reject` 动作必须在 xray routing 层做（generate `blackhole` outbound），不能在 chinadns 内通过 reject group 做——否则会被 chnlist/gfwlist tag 抢走，reject 静默失效。本架构 §4.6 已规定 reject 走 xray blackhole outbound，与该约束自洽。

**结论**：**在 doge.12 实施完成且 install.sh 走过 migrate_split_routing_v1 之后**，新架构代码不再受 #11 约束。doge.12 之前（包括 doge.11 期间）以及任何向 ipset 模型的回退路径上，#11 仍然适用——向 white_list/black_list/router 等 ipset 添加域名前必须双查 chnlist/gfwlist。

### 6.6 旧 chinadns 配置生成代码改造

[ssconfig.sh:2097-2734 start_chinadns_ng()](../../fancyss/ss/ssconfig.sh#L2097) 整段 chinadns-ng 配置生成函数拆为两个：

```
generate_chinadns_split_conf()   → 生成分流 DNS 实例配置（端口 65353）
generate_chinadns_global_conf()  → 生成全局 DNS 实例配置（端口 65354）
```

**保留**：用户在"DNS 设置"页配的国内/国外 upstream
**删除**：`add_tagchn_ip` / `add_taggfw_ip` / `add_tagignore_ip` 等"写入 ipset"指令
**新增**：reject group 动态收集（扫所有 dns_mode=split 的 Mode 的 reject rule，去重后写入分流实例）

**性能**：第二个 chinadns-ng 实例额外内存 ≈ **+30~50MB**（实测待 PoC 验证；chinadns-ng 用 malloc 构 trie，不 mmap，两实例各自加载一份 chnlist+gfwlist）。**hnd_v7 平台（512MB RAM）建议慎用 `dns_mode=global`**，或考虑只在分流实例上加载 chnlist。

---

## 7. 数据迁移（doge.11 → doge.12）

> 详细伪代码见 §14 老用户升级路径。本节只列概要。

迁移触发：install.sh 末尾调用 `migrate_split_routing_v1`，幂等标志 `fss_split_migrated_v1`。

**核心映射**：

| 旧设置 | 新设置 |
|---|---|
| `ss_basic_mode=5`（全局） | `ss_split_default_mode_id` → 内置「全局代理」Mode（dns_mode=global） |
| `ss_basic_mode ∈ {0,1,2,3,6}` | `ss_split_default_mode_id` → 内置「大陆白名单」Mode（dns_mode=split） |
| `ss_basic_mode=7`（xray 半成品分流） | 同上归到大陆白名单；**xray 分流模式相关 dbus key 物理移除** |
| `ss_acl_mode_<i>` | `ss_acl_split_mode_<acl_node>`（同上规则映射） |
| `ssconf_basic_node` + `ssconf_basic_node_front` | 灌入两个内置 Mode 的 default_action |
| `ss_wan_white_domain` / `ss_wan_black_domain` | 保留原数据，两个内置 Mode 默认 `apply_blackwhite=1` |
| 旧 chinadns 配置 | 数据保留，生成器全换为双轨生成 |
| `failover-combo-*` 数据 | 保留但 UI 隐藏（Q8） |

---

## 8. UI 设计

四个独立 ASP 页面（或同一页面的 tab）：模式管理、规则管理、DNS 设置（双轨）、运行状态。

**通用 select 控件约束**：本章所有引用 mode/rule 的 `<select>` 控件遵循 [CLAUDE.md 硬规则 #9](../../CLAUDE.md)——`refresh_options` 时若 dbus 值在选项列表中找不到，必须插入 `data-stale="1"` 占位 option 保留 ID，并在 `save()` 时检测到 stale 跳过 dbus 覆盖；不允许静默 `val('')` 丢数据。

### 8.1 模式管理页

```
┌──────────────────────────────────────────────────────────────────────────┐
│  模式管理                                       [+ 新建模式] [导入Mode]   │
├──────────────────────────────────────────────────────────────────────────┤
│  模式名        │规则状态     │UDP│QUIC│DNS模式│ 状态    │ 操作            │
├────────────────┼─────────────┼───┼────┼───────┼─────────┼─────────────────┤
│全局代理[内置]  │0+兜底       │✓  │    │全局   │ 默认    │ [编辑][导出]    │
│大陆白名单[内置]│7+兜底       │✓  │    │分流   │ 3 用户  │ [编辑][导出]    │
│办公专用        │5+兜底       │   │ ✓  │分流   │ 1 用户  │ [编辑][删][导出]│
└──────────────────────────────────────────────────────────────────────────┘

┌─────────── 编辑模式：办公专用 ────────────────────────────────────────────┐
│  模式名: [办公专用_______________]                                       │
│                                                                          │
│  全局修饰符:                                                             │
│    [ ] 启用 UDP 代理                                                     │
│    [✓] 屏蔽 QUIC 流量                                                    │
│    [✓] 受全局黑白名单影响（白名单文本框 + 黑名单文本框）                  │
│                                                                          │
│  DNS 模式:                                                               │
│    (●) 分流模式 — 国内域名走国内 DNS，国外走代理 DNS                     │
│    ( ) 全局模式 — 所有域名走单一海外 DNS（代理出口）                     │
│                                                                          │
│  规则列表 (按顺序匹配，匹配命中即走对应动作):                            │
│  ┌──┬─────────────────────┬───────────────────────────┬──┬──┬───┐       │
│  │序│ 规则名              │ 动作                      │↑ │↓ │ × │       │
│  ├──┼─────────────────────┼───────────────────────────┼──┼──┼───┤       │
│  │ 1│ 中国公共 DNS        │ [直连           ▾]        │  │↓ │ × │       │
│  │ 2│ 广告/统计屏蔽       │ [屏蔽           ▾]        │↑ │↓ │ × │       │
│  │ 3│ Telegram 加速       │ [代理: 节点A    ▾]        │↑ │↓ │ × │       │
│  │ 4│ 公司内网            │ [直连           ▾]        │↑ │↓ │ × │       │
│  │ 5│ GFW列表_常用        │ [代理链: B→A    ▾]        │↑ │  │ × │       │
│  └──┴─────────────────────┴───────────────────────────┴──┴──┴───┘       │
│                                                          [+ 添加规则]    │
│                                                                          │
│  兜底流量 (前面所有规则未命中时):                                        │
│    动作: [代理链: B→A         ▾]  ← 注：兜底不可为「屏蔽」               │
│                                                                          │
│                                          [保存模式 (将重启代理)]         │
└──────────────────────────────────────────────────────────────────────────┘

┌─── 新建模式弹窗 ───────────────────────────────────────────┐
│  模式名: [_______________]                                  │
│  复制模板: [空白模式 ▾] (空白/全局代理/大陆白名单)          │
│  [ ] 启用 UDP 代理   [ ] 屏蔽 QUIC 流量                     │
│  DNS 模式: (●) 分流  ( ) 全局     ← 默认分流                │
│                                            [取消] [创建]    │
└─────────────────────────────────────────────────────────────┘
```

**交互要点**：
- 编辑模式中所有改动**只写 dbus 不重启**（用 `dummy_script.sh` 路由，参见 [failover-combo-implementation.md §5.2](../implementation/failover-combo-implementation.md)）
- **只有点"保存模式"才触发** `ssconfig.sh restart`
- 黑名单编辑时若 `default_action="direct"`，弹**黄字警告**（Q2）："该模式默认动作为直连，黑名单将不生效"
- 兜底动作下拉**不显示"屏蔽"**（前端硬编码过滤）
- 删除按钮：被引用时置灰，hover tooltip 显示"被 N 个用户使用"
- 拖动重排（jQuery UI sortable）+ ↑↓ 按钮双备份
- [导入Mode]/[导出] 走 §3.7 的 JSON 格式（Q14）
- 批量导出当前无入口，未来按需再加（doge.13+）

### 8.2 规则管理页

```
┌────────────────────────────────────────────────────────────────────────┐
│  规则管理                                                 [+ 新建规则] │
├────────────────────────────────────────────────────────────────────────┤
│  规则名                  │ 内容统计          │ 自动更新 │ 操作         │
├──────────────────────────┼───────────────────┼──────────┼──────────────┤
│  大陆白名单_常用 [内置]  │ 14k 域名 + 10k IP │ 每 24h   │ [编辑]       │
│  GFW列表_常用    [内置]  │ 7k 域名           │ 每 24h   │ [编辑]       │
│  中国公共DNS     [内置]  │ 10 IP             │ 禁用     │ [编辑]       │
│  广告/统计屏蔽   [内置]  │ 12k 域名          │ 每 24h   │ [编辑]       │
│  公司内网        [手编]  │ 12 域名 + 3 CIDR  │ 禁用     │ [编辑] [×]   │
└────────────────────────────────────────────────────────────────────────┘

┌─── 编辑规则：大陆白名单_常用 (内置, auto-update 启用) ─────────────┐
│  规则名:   [大陆白名单_常用_______]   [内置规则，名称只读]         │
│  自动更新: ( ) 禁用  (●) 启用                                      │
│  更新间隔: [24 小时   ▾]  (1 / 6 / 12 / 24 / 72 / 168 小时)        │
│  来源 URL:                                                         │
│   [https://raw.githubusercontent.com/folderdoge/fancyss_doge/3.0/  │
│    rules_ng/builtin/chnlist_v1.txt_____________________________]   │
│  最近更新: 2026-05-14 03:21:08  (内容: 14k 域名 + 10k IP)          │
│  上次备份: rule_3.txt.bak (2026-05-13 03:20)                       │
│                                                                    │
│                       [立即更新] [回滚到 .bak] [取消] [保存规则]   │
└────────────────────────────────────────────────────────────────────┘
```

**交互要点**：
- 自动更新"启用 vs 禁用"单选切换。切到禁用时显示编辑域名/IP 文本框（Q10：内置 Rule 关掉 auto-update 后允许手编）
- 切到启用时，原手编内容保留作为初始内容，但 UI 隐藏编辑入口（要改先关 auto-update）
- 内置规则的"规则名"只读，但 auto-update URL 和间隔可改（用户可指向自己的镜像）
- [立即更新] 按钮：调用 `fss_rules_update.sh --rule-id <id>` 立即拉一次
- [回滚到 .bak] 按钮：用 `.bak` 覆盖 .txt，更新 last_update 时间（Q13）
- 内置 Rule 的 source_url 走 fork 自己（Q16）：`https://raw.githubusercontent.com/folderdoge/fancyss_doge/3.0/rules_ng/...`

### 8.3 DNS 设置页（双轨）

```
┌──────────────────────────────────────────────────────────────────────────┐
│  DNS 设置                                                                │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ─── 分流 DNS（服务 dns_mode=split 的 Mode）─────────────────────────────│
│                                                                          │
│  国内 DNS upstream:                                                      │
│   1. [udp://223.5.5.5________________]  [✓ 启用]                         │
│   2. [udp://119.29.29.29_____________]  [  禁用]                         │
│   3. [______________________________]                                    │
│                                                                          │
│  国外 DNS upstream (通过代理走):                                         │
│   1. [tls://8.8.8.8__________________]  [✓ 启用]                         │
│   2. [doh://1.1.1.1/dns-query________]  [✓ 启用]                         │
│                                                                          │
│  ─── 全局 DNS（服务 dns_mode=global 的 Mode）────────────────────────────│
│                                                                          │
│  海外 upstream (单一，通过代理走):                                       │
│   [doh://1.1.1.1/dns-query___________]                                   │
│                                                                          │
│                                                       [保存 DNS 设置]    │
└──────────────────────────────────────────────────────────────────────────┘
```

**说明**：原"DNS 设置"区块的所有现有字段（国内/国外 upstream、DoT/DoH 开关）平移到"分流 DNS"区块，向后兼容。"全局 DNS"是新增区块。

### 8.4 运行状态页（原"账号设置"改名）

```
┌──────────────────────────────────────────────────────────────────────────┐
│  运行状态                                                                │
├──────────────────────────────────────────────────────────────────────────┤
│  插件状态: 运行中  |  当前默认模式: 大陆白名单(分流DNS)                  │
│  规则更新: 12h 前 ✓   |  active Mode 数: 3                               │
│  链式代理状态: 启用  |  路径: 节点B → 节点A → 目标                       │
├──────────────────────────────────────────────────────────────────────────┤
│  快速节点设置 (仅当默认模式为内置「全局代理」或「大陆白名单」时可用):    │
│                                                                          │
│   落地节点: [节点 A ▾]    前置节点: [无 ▾]                              │
│                                                       [应用快速节点]     │
│                                                                          │
│   说明: 此处一键覆盖默认模式的"兜底动作"，无需进入模式管理页。           │
│                                                                          │
├──────────────────────────────────────────────────────────────────────────┤
│  默认规则 (未在下方列出的设备走默认模式):                                │
│   默认模式: [大陆白名单                  ▾]                              │
│             (UDP/QUIC/DNS 模式由所选 Mode 决定—只读显示在 Mode 编辑页)   │
├──────────────────────────────────────────────────────────────────────────┤
│  访问控制 (per-User 模式分配):                          [+ 添加]         │
│                                                                          │
│  客户端     │主机别名│ 代理模式      │UDP*│QUIC*│DNS*│ 代理端口  │操作  │
│  ───────────┼────────┼───────────────┼────┼─────┼────┼───────────┼──────│
│  AA:BB:..   │手机    │[大陆白名单 ▾] │✓继 │    │分流│ all       │ [×] │
│  CC:DD:..   │PS5     │[办公专用   ▾] │    │ ✓继 │分流│ all       │ [×] │
│  192.168.50 │电视    │[不通过代理 ▾] │    │     │    │ all       │ [×] │
│                                                                          │
│  * UDP/QUIC/DNS 列只读显示「继承自所选 Mode」(Q18/Q19)                   │
└──────────────────────────────────────────────────────────────────────────┘
```

**交互要点**：
- "快速节点设置"区块只在默认模式 ∈ {内置「全局代理」, 内置「大陆白名单」} 时显示。其他自定义模式时区块隐藏并提示"自定义模式请到 模式管理 页编辑兜底动作"。
- "应用快速节点" = 把选定的节点写入默认模式的 `default_action` + `ssconfig.sh restart`
- ACL 表的 UDP/QUIC 列改为**只读显示**"继承自 Mode：✓UDP / ✗QUIC"（Q18+Q19）
- 模式管理 / 规则管理 / DNS 设置 / 运行状态 4 个入口加到左侧 nav。"账号设置"改名为"运行状态"（保留原 ASP 文件名 `Module_shadowsocks.asp` 以免破坏链接）

**运行状态轮询机制**（兑现 [CLAUDE.md 硬规则 #10](../../CLAUDE.md)）：

运行状态页顶栏显示的"插件状态 / 当前默认模式 / 规则更新时间 / active Mode 数 / 链式代理路径 / DNS 实例状态"等字段，源于 §3.5 列出的 5 个 `ss_split_*` 运行状态键 + 已有的 `ss_chain_status` / `ss_chain_path`。这些键由后端 `ssconfig.sh restart` 或 cron 实时写入，前端 `db_ss` 是页面打开时的一次性快照，必须配合轮询才能保证显示新鲜值。

参考 [chain-proxy-implementation.md](../implementation/chain-proxy-implementation.md) 已实现的 `refresh_chain_status_only()` + `start_chain_status_polling()` 模板，新增：

```js
// 每 15s 拉一次 5 个 split 运行状态键 + 重渲染状态行（轻量，只查这几个 key）
function refresh_split_status_only(cb) {
    $.post("/_api/ss", { keys: [
        "ss_split_active_mode_count",
        "ss_split_xray_outbound_count",
        "ss_split_last_restart_ts",
        "ss_split_dns_split_status",
        "ss_split_dns_global_status"
    ] }, function(resp) {
        // merge into db_ss, re-render 顶栏
        render_split_status();
        if (cb) cb();
    }, "json");
}

function start_split_status_polling() {
    if (window._splitStatusPollTimer) return;  // 幂等
    window._splitStatusPollTimer = setInterval(refresh_split_status_only, 15000);
}
```

`start_split_status_polling()` 在 `refresh_options()` 末尾调用一次。

---

## 9. 规则文件格式

### 9.1 规范（Q6 决议：只 suffix + exact）

```
# fancyss-rule v1
# updated: 2026-05-15T10:00:00Z
# name: 大陆白名单_常用
# 注释行以 # 开头，被解析器忽略

example.com           # 默认 suffix match (覆盖 sub.example.com 等)
+exact.example.com    # +前缀 = 精确匹配 (不覆盖子域名)
1.2.3.0/24            # 自动识别为 IPv4 CIDR
2001:db8::/32         # 自动识别为 IPv6 CIDR
1.1.1.1               # 自动识别为单 IPv4 (→ /32)
2001:db8::1           # 自动识别为单 IPv6 (→ /128)
```

**域名 vs IP 合一存储**：一个文件混排，后端加载时自动拆为两套 matcher。用户/远程源不需要维护两个文件。

**不支持** keyword（子串匹配）和正则（Q6 决议）。理由：
- keyword 性能差（每条要扫整个域名字符串）
- 正则用户容易写错（一个错误正则可能命中所有域名导致路由错乱）
- 实际场景 suffix + exact 覆盖 99%

### 9.2 解析伪代码

```python
def parse_rule_file(path):
    domains_suffix, domains_exact, ips_v4, ips_v6 = [], [], [], []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"): continue
        if "#" in line: line = line.split("#", 1)[0].strip()
        if not line: continue
        if "/" in line and is_valid_cidr(line):
            (ips_v6 if ":" in line else ips_v4).append(line)
        elif is_valid_ip(line):
            (ips_v6 if ":" in line else ips_v4).append(line + ("/128" if ":" in line else "/32"))
        elif line.startswith("+"):
            domains_exact.append(line[1:])
        else:
            domains_suffix.append(line)
    return { "domain_suffix": domains_suffix, "domain_exact": domains_exact,
             "ip_v4": ips_v4, "ip_v6": ips_v6 }
```

### 9.3 与 xray routing 的对接

xray routing 的 `domain` 字段语法：`domain:` 前缀 = suffix、`full:` 前缀 = exact、`regexp:` 前缀 = 正则。**生成器必须永远显式加前缀**，不依赖 xray 默认行为（xray 默认纯字符串是 substring keyword match，与 fancyss 用户预期的 suffix 不一致）。生成器转换：

```json
{
  "type": "field",
  "inboundTag": ["mode_2"],
  "domain": ["domain:example.com", "full:exact.example.com"],
  "ip": ["1.2.3.0/24", "2001:db8::/32"],
  "outboundTag": "out_node_5"
}
```

---

## 10. 自动更新 cron 设计

### 10.1 总体策略（Q7 决议：30 分钟硬编码）

**统一一个 cron** `/koolshare/scripts/fss_rules_update.sh`，每 30 分钟醒一次，内部维护调度表逐条检查"哪条 rule 该更新"。**不**为每条 rule 加单独 cron entry。

### 10.2 调度表

文件 `/koolshare/ss/rules_user/update_schedule.txt`，格式（一行一 rule）：

```
<rule_id>\t<update_hours>\t<source_url>\t<last_update_unix_ts>
```

每次 cron 醒来（互斥锁 / 状态键定义见 [§3.5 后端专用 dbus key](#35-后端专用fss_-前缀)）：
1. 上锁 `dbus set fss_split_rules_update_lock=1`
2. 读 dbus，扫所有 `ss_split_rule_<i>_*` 重新生成 `update_schedule.txt`（dbus 是真理之源）
3. 遍历每行：if `now - last_update >= update_hours * 3600`：
   - **备份现文件**（Q13）：`cp rule_<id>.txt rule_<id>.txt.bak`
   - `curl --connect-timeout 30 --max-time 300 -fsSL <url> -o /tmp/rule_<id>.tmp`
   - 校验：行数 ≤ 100 万、文件大小 ≤ 50MB、UTF-8 合法
   - 通过校验 → `mv /tmp/rule_<id>.tmp /koolshare/ss/rules_user/rule_<id>.txt`
   - 重算 `stat_domains` / `stat_ips` 写回 dbus
   - 更新 `ss_split_rule_<i>_last_update`
4. 解锁 `dbus set fss_split_rules_update_lock=0`
5. 写摘要到 `fss_split_rules_update_log`
6. 若有任意 rule 实际更新成功 → 触发 `ssconfig.sh restart`。**Batching 优化**：cron 醒来时收集本轮**所有**成功更新的 rule，统一在最后一次性触发 restart（不是每条 rule 更新立即 restart），避免一天内多次重启。未来 doge.13+ 可考虑接入 xray Reload API 做 hot reload

### 10.3 cron 注册

install.sh 加 `cru a fancyss_rules_update "*/30 * * * * /koolshare/scripts/fss_rules_update.sh"`，uninstall.sh `cru d fancyss_rules_update`。

### 10.4 边角情况

- **网络不可用**：单条 rule 拉失败不影响其他，本轮跳过，下轮再试。**不**当轮重试
- **磁盘满**：写 `/tmp/rule_<id>.tmp` 失败时不动现文件，LOG warning
- **URL 改了**：dbus 改 URL 后下轮 cron 自动用新 URL
- **回滚**：UI [回滚到 .bak] 按钮 = `cp rule_<id>.txt.bak rule_<id>.txt` + 重算 stat + 触发 restart
- **用户 force 立即更新**：UI 按钮调用 `fss_rules_update.sh --rule-id <id>`，与 cron 复用同一锁

---

## 11. 性能约束 + 实测上界

**RT-AX86U / hnd_v8 平台上界**（**软上界 = 估算，硬上界 = 实测 / 待 PoC**）：

| 指标 | 软上界（估算） | 硬上界（实测/待 PoC） | 后果 |
|---|---|---|---|
| 同时 active 独立 outbound 对 | ≤ 25 | 50 | xray 实际可支持 100+ outbound，30~50 是 RT-AX86U 上 xray restart 时长超过 5s 的拐点 |
| 总规则数（域名+IP 跨所有 rule 求和） | ≤ 50 万 | 100 万 | 超过 100 万 xray 内存 > 200MB |
| 总 inbound 数（= active mode 数） | ≤ 15 | 30 | 端口分配 + iptables 规则膨胀风险 |
| User（acl 行）数量 | ≤ 50 | 100 | iptables 规则爆 |
| xray sniffing 额外 CPU | 参考社区数据 +5% | 待 PoC | 家用场景可忽略；fancyss 当前未启用，PoC 留 doge.12 实施期 |
| 第二个 chinadns 实例额外内存 | +30~50MB | 待 PoC | chinadns-ng 用 malloc 构 trie，不 mmap，两实例各自加载 chnlist+gfwlist |

**xray 重启时长**：
- 50 outbound + 30 万规则：约 2~3 秒
- 30 outbound + 50 万规则：约 4~5 秒（**用户可感知**）

**判据使用**：UI 在 Mode/Rule 数量逼近软上界时显示黄色警告，逼近硬上界时拒绝新增并提示"超过设备性能容量"。

**设计前提兑现**：所有中间编辑只改 dbus 不重启，只有"保存模式" / "应用快速节点" / cron 实际拉到新规则时才触发重启——把每天的重启次数控制在个位数。

---

## 12. 多用户冲突场景验证

**场景**：用户 A 配 = 大陆白名单 Mode，用户 B 配 = 全局代理 + bilibili.com 直连 Mode。两人同时访问 baidu.com（B 没配 baidu 规则）。

```
        用户A (大陆白名单, dns_mode=split)         用户B (全局代理+bilibili直连, dns_mode=global)
            │                                          │
   ┌────────┴─────────┐                       ┌────────┴──────────┐
   │ DNS: baidu.com   │                       │ DNS: baidu.com    │
   │ → 分流DNS:65353  │                       │ → 全局DNS:65354   │
   │ chnlist 命中     │                       │ 单一海外 upstream │
   │ → 国内 DNS       │                       │ → 海外 IP (可能慢)│
   │ → baidu 国内 IP  │                       │                   │
   └────────┬─────────┘                       └────────┬──────────┘
            │                                          │
   ┌────────▼─────────┐                       ┌────────▼──────────┐
   │ 路由: mode_2     │                       │ 路由: mode_3      │
   │ 大陆白名单 Rule  │                       │ 无 baidu 显式规则 │
   │ 命中 → direct    │                       │ → 兜底 proxy_node │
   │ ✅ 直连国内 IP   │                       │ ⚠️ 代理出口 → IP  │
   │                  │                       │ (符合B"全局代理"  │
   │                  │                       │  自身配置)        │
   └──────────────────┘                       └───────────────────┘
```

**结论**：**无冲突**，A、B 各得其所。
- A 走分流 DNS 拿国内 IP + 直连，最快路径
- B 走全局 DNS 拿海外 IP + 代理出口，慢但符合 B 的"全局代理"语义（B 自愿承担）

**边角冲突**（用户反 chnlist 把 baidu 强制代理）：
- A 配在自己的 Mode 里把 baidu 改成 proxy_node → A 自己看到代理出口结果（符合 A 显式配置）
- DNS 层 A 仍走分流 → 国内 IP（即 A 拿到国内 IP 但流量走代理出口）
- 这不是 bug，是用户显式选择的结果

**写入文档作为"已验证场景"**。

---

## 13. 未决问题汇总

**Q1~Q19 全部决议完成**（见引言"所有已答的 Q"清单）。实施阶段可能新增的边角 case 仅以下几条，记为"实施时再决"：

| # | 实施期边角 case | 说明 |
|---|---|---|
| E1 | **xray sniffing 失败回退策略** | 部分加密流量（如 ECH 启用的 TLS）sniffing 拿不到 SNI，此时只能走 IP 匹配 + 兜底动作。生成器不需处理，xray 自身行为已合理。**已通过 §4.4 R1.5 解决，无遗留问题** |
| E2 | **iptables PREROUTING 顺序敏感性** | DNAT（DNS 重定向）和 TPROXY（流量分流）的链顺序需确保 DNS 先匹配。`SHADOWSOCKS_DNS` 应早于 `SHADOWSOCKS_USER` |
| E3 | **acl 表批量切 Mode** | 用户批量编辑 acl 行 mode_id 时只改 dbus 不立即生效，需要"应用"按钮显式触发 restart（避免每改一行重启一次） |
| E4 | **Mode 改名时引用一致性** | Mode 改名只改 `ss_split_mode_<m>_name`，不影响其他 dbus key（mode_id 是 stable 主键）。已设计稳妥，无遗留 |
| E5 | **导出 Mode 的 source_url 是否携带** | Q14 决议导出 Mode + 其引用的 Rule 整包。Rule 的 source_url 是否随包导出？§3.7 JSON schema 已加 source_url 可选字段，由导出对话框 checkbox"包含 Rule 来源 URL"控制；**实施期决定是否在 UI 加 checkbox** |

**Q1~Q19 不再列入待确认**——已固化为定稿决议。

---

## 14. 老用户升级路径

doge.11 → doge.12 升级时，[install.sh](../../fancyss/install.sh) 调用 `migrate_split_routing_v1` 一次性迁移。**幂等标志**：`fss_split_migrated_v1`（一次性，永不清）。

> **hnd_v7 平台（512MB RAM）升级时风险**：本节 Step 7.5 必须先于 Step 8 执行，否则 chnlist + chnroute（合计 80MB+ 内存峰值）+ 新架构启动可能触发 OOM watchdog 重启路由器。Step 7.5 显式 destroy 旧 ipset 是 hnd_v7 升级路径的必要步骤，hnd_v8 / qca / mtk 不强制但建议保留以收一致性。

### 14.1 完整迁移伪代码

```sh
migrate_split_routing_v1() {
    [ "$(dbus get fss_split_migrated_v1)" = "1" ] && return

    echo_date "🔄 开始迁移到分流架构 v1..."

    # ---------- Step 1: 写入内置预设 Rule (1~99 预留) ----------
    # 由 install.sh 从 /koolshare/ss/rules_ng/builtin/ 拷贝到 rules_user/
    # dbus 写入对应的 ss_split_rule_<i>_* 元数据
    for preset in chnlist_v1 gfwlist_v1 china_public_dns telegram_cidrs adblock office_intranet; do
        write_builtin_rule "$preset"  # 内部封装：cp 文件 + dbus set
    done

    # ---------- Step 1.5: 现节点（front + landing）→ Mode 兜底动作 ----------
    # 读取现节点设置，准备 Mode 兜底动作字符串供 Step 2 灌入
    local cur_node=$(dbus get ssconf_basic_node)
    local cur_front=$(dbus get ssconf_basic_node_front)
    local cur_udp=$(dbus get ss_basic_udp_relay)  # 0/1
    if [ -n "$cur_front" ]; then
        local cur_action="proxy_chain:${cur_front}:${cur_node}"
    else
        local cur_action="proxy_node:${cur_node}"
    fi

    # ---------- Step 2: 写入内置预设 Mode（含 Step 1.5 构造的兜底动作） ----------
    # 预设 Mode 1 = 全局代理（dns_mode=global）
    write_mode 1 "全局代理" builtin=1 \
               apply_blackwhite=1 \
               udp_proxy="$cur_udp" \
               block_quic=0 \
               dns_mode="global" \
               rules=[] \
               default_action="$cur_action"

    # 预设 Mode 2 = 大陆白名单（dns_mode=split）
    write_mode 2 "大陆白名单" builtin=1 \
               apply_blackwhite=1 \
               udp_proxy="$cur_udp" \
               block_quic=0 \
               dns_mode="split" \
               rules=[
                   (rule_id_of("china_public_dns"), "direct"),
                   (rule_id_of("adblock"),         "reject"),
                   (rule_id_of("telegram_cidrs"),  "$cur_action"),
                   (rule_id_of("gfwlist_v1"),      "$cur_action"),
                   (rule_id_of("chnlist_v1"),      "direct"),
               ] \
               default_action="$cur_action"

    # ---------- Step 3: 迁移当前 ss_basic_mode ----------
    local old_mode=$(dbus get ss_basic_mode)
    case "$old_mode" in
        5)  dbus set ss_split_default_mode_id="1" ;;  # 全局 → 全局代理
        *)  dbus set ss_split_default_mode_id="2" ;;  # 其他全部 → 大陆白名单
            # 0/1/2/3/6=GFW/CHN/HOM/GAM/回国 + 7=xray分流半成品 全归大陆白名单
    esac

    # ---------- Step 4: 迁移 acl 行 ----------
    for acl_row in $(iter_acl_rows); do
        local old_acl_mode=$(dbus get ss_acl_mode_${acl_row})
        case "$old_acl_mode" in
            0)  dbus set ss_acl_split_mode_${acl_row}="0" ;;  # 不通过代理
            5)  dbus set ss_acl_split_mode_${acl_row}="1" ;;  # 全局代理
            *)  dbus set ss_acl_split_mode_${acl_row}="2" ;;  # 大陆白名单
        esac
    done

    # ---------- Step 5: 黑白名单文本框保留 ----------
    # ss_wan_white_domain / ss_wan_black_domain 不动
    # 两个预设 Mode 默认 apply_blackwhite=1 自动让它们生效

    # ---------- Step 6: xray 半成品分流物理移除 ----------
    # 删除 ss_node_shunt_* 等遗留 key
    # （参见本文档 §7 数据迁移 / protocol-roadmap.md §8.1 里程碑表
    #  "xray 半成品分流 物理移除"，doge.12 里程碑）
    for k in $(dbus list ss_node_shunt_); do
        dbus remove "$k"
    done

    # ---------- Step 7: failover-combo 数据保留 + UI 隐藏 ----------
    # ss_failover_combo_* 数据不动（Q8 决议 - 注释保留方案）
    # asp 文件中故障转移 UI 块加 display:none + 注释保留
    # helper 代码（ss_node_common.sh 末尾段）注释保留
    # 新架构不为 failover 设计共存钩子，未来重新设计"节点组+组级故障转移"

    # ---------- Step 7.5: 显式销毁旧架构 ipset ----------
    # 防止 hnd_v7 (512MB RAM) 升级时 OOM
    # 必须在 Step 8（首次 ssconfig.sh restart 按新逻辑重建）之前执行
    for old_set in chnlist chnroute gfwlist white_list black_list router ignlist \
                   chnlist6 chnroute6 gfwlist6 white_list6 black_list6 router6 ignlist6; do
        ipset destroy "${old_set}" 2>/dev/null || true
    done

    # ---------- Step 8: ipset 清理 ----------
    # 经 Step 7.5 销毁后，由首次 ssconfig.sh restart 时按新逻辑重建
    # 新逻辑只创建 ignlist_minimal / ignlist_minimal6 两套（详见 §5.3）

    # ---------- Step 8.5: 改写 flush_ipset() 枚举白名单 ----------
    # ssconfig.sh:5240 的 flush_ipset() 硬编码 ipset 名单
    # 从  chnlist|chnroute|gfwlist|white_list|black_list|router|ignlist|chnlist6|... （14 项）
    # 缩到 ignlist_minimal|ignlist_minimal6                                            （2 项）
    # doge.12 新架构只保留 RFC1918 等极简集合作为 ipset，其他全迁到 xray routing
    # 这一步是源码修改（doge.12 发布版本自带），不是运行时操作；列入迁移步骤是为了
    # 提醒"升级前提"——install.sh 跑此函数时 ssconfig.sh 必须已经是 doge.12 版本

    # ---------- Step 9: 落幂等标志 ----------
    dbus set fss_split_migrated_v1="1"
    echo_date "✅ 分流架构迁移完成"
}
```

### 14.2 旧 key 处理

| 旧 key | 处置 |
|---|---|
| `ss_basic_mode` | doge.12 期间保留（生成器优先读新 key，缺失时回退）；doge.13 起 `dbus remove` |
| `ss_acl_mode_<i>` | 同上 |
| `ssconf_basic_node` / `ssconf_basic_node_front` | 保留——它们是"当前生效节点"的概念，新架构下作为"快速节点设置"的兜底（§8.4） |
| `ss_node_shunt_*` | doge.12 物理移除（xray 半成品分流彻底切除） |
| `ss_failover_combo_*` / `fss_failover_*` | 保留（Q8 决议；含 `fss_failover_internal_restart` / `fss_failover_last_switch_ts` / `fss_failover_cool_down_sec` / `fss_failover_migrated_v1` + `ss_failover_combo_migrated_v2` + `ss_failover_main_combo_seeded`） |

### 14.3 升级验收清单

- [ ] 升级后 `dbus get ss_split_default_mode_id` 返回非空且非 0
- [ ] 升级后 `dbus list ss_split_mode_` 至少有 2 个 Mode（id=1 和 id=2）
- [ ] 升级后 `dbus list ss_split_rule_` 至少有内置预设 Rule（chnlist_v1 / gfwlist_v1 等）
- [ ] 升级后路由器实际行为与升级前一致（用户感受不到行为变化）
- [ ] 升级后 `dbus get fss_split_migrated_v1` = "1"
- [ ] 二次跑 install.sh 不重复迁移（幂等）
- [ ] 老 GLO 模式用户升级后 default_mode 是"全局代理"且 dns_mode=global
- [ ] 老 GFW/CHN/HOM/GAM 模式用户升级后 default_mode 是"大陆白名单"且 dns_mode=split

---

## 修订记录

- **2026-05-15 重写**：基于 Q1-Q19 全部决议 + sniffing-based routing + 双轨 DNS 双重核心变更。第一稿（基于 ipset 架构）被本稿完全取代。新增 §6.5 解释硬规则 #11 为何不适用、§12 多用户冲突场景验证、§14 老用户升级路径。Q1~Q19 从"待用户确认"全部转为已固化决议。
- 2026-05-15 初稿：基于"Rule + Mode + per-User"架构共识（已被本稿取代）。
