# 分流架构实施说明 (doge.12 alpha → doge.13 stable → doge.14 唯一路径)

> **状态**：**doge.14 stable 已落地**——`ss_split_enabled` 总开关物理移除、`ss_node_shunt.sh` 整文件物理删除、`ss_basic_mode=7` 全部 case 物理清理、老 [DNS 设置] section 退役、`migrate_split_routing_v3` 完成 mode=7 → mode=2 + 老 `ss_basic_chng_*` 清理。**分流架构成为唯一路径**，无兼容旧路径回退。Phase 1+2+3 历史记录与 alpha/beta 演进保留在本文档（§6 / 修订记录）作为后人审计参考。
> 关联设计：[../design/split-routing-architecture.md](../design/split-routing-architecture.md)
> 关联路线图：[../design/protocol-roadmap.md §8](../design/protocol-roadmap.md)
> 关联 audit：[../design/doge14-deletion-scope-audit.md](../design/doge14-deletion-scope-audit.md)（archive 标记，doge.14 sprint 收尾）
>
> **冷开必读** —— 历史 alpha 修订与已知漂移在 §6.2（D1-D16）+ doge.14 物理删除收尾在 §6.3（D17+）：
> - D9 = alpha.13/.14 `ss_split_rule_to_json` ARG_MAX + awk O(n²) 双修
> - D10 = alpha.15 chinadns-ng DNS 层 reject 整套删除（伪语法）
> - D11 = alpha.16 Mode 级 `block_quic` / `udp_proxy` 接通 iptables 层
> - **D1 / D5 / D8 端口分配 gate / D12-D15** = doge.13 beta 兑现段（per-rule 独立 outbound 解 collapse + sentinel `proxy_main` + ASP preflight + 节点删除清理 + dnsmasq_lan 子实例 + DNS upstream migrate_v2）
> - **D16** = doge.13-beta.4 LAN DNS 在 mangle+nat PREROUTING 双跳被 xray FakeUDP 抢 65353
> - **D17+ doge.14 物理删除收尾** = `ss_split_enabled` 总开关 + `ss_node_shunt.sh` + `ss_basic_mode=7` 全部 case + 老 [DNS 设置] section + 老 chinadns 单实例 + 老 iptables 分支 + hint 220/221（详见 §6.3）
> 文末「修订记录」按时间倒序列出版本里程碑。

---

## 0. 范围与演进历程（doge.12 alpha → doge.13 stable → doge.14 唯一路径）

doge.12 是 1-2 周量级的架构跃迁，单次 release 全切风险极大。本节记录三阶段演进历程：

### 0.1 阶段时间线

| 阶段 | 时间 | 策略 | `ss_split_enabled` 含义 |
|---|---|---|---|
| **doge.12 alpha (alpha.1 → alpha.18)** | 2026-05-15 → 2026-05-22 | **新旧并存**，开关默认 `0` opt-in | `=1` 走新分流路径；`=0` 走老 `ss_basic_mode` GFW/CHN/全局/回国/xray分流 路径 |
| **doge.13 beta + stable** | 2026-05-22 → 2026-05-24 | **新装机默认 `1`**，老用户显式值保留不动 | 同上，但 install.sh 仅在 dbus 完全未设置时种 `1` |
| **doge.14 stable** (本阶段) | 2026-05-27 起 | **唯一路径**，`ss_split_enabled` 物理移除变常量 `1` 永远 | 不再有开关，路由层无 fork else 分支可回退 |

### 0.2 doge.14 物理删除收尾（**当前状态**）

- **总开关 `ss_split_enabled` 路由层 fork 入口 + dbus key 已物理移除** — `migrate_split_routing_v3` 一次性 `dbus remove ss_split_enabled`，ssconfig.sh 6 处 else 分支 + install.sh state read + ASP JS handler 整体删除。**ASP `<select id="ss_split_enabled">` UI 元素**仍保留在 [分流] 标签页（L18308），由 init JS `E('ss_split_enabled').disabled = true`（L6838）锁定为 disabled placeholder——doge.14.x UI 重设计阶段一并清。
- **`ss_node_shunt.sh` 整文件物理删除** — 2121 行整文件清空，3 处 source 调用点（`ss_base.sh:16-17` / `ss_node_postsave.sh:6` / `ss_shunt_hot_reload.sh:4`）同步删除。Phase 1+2 先 stub 化到 ≤50 行容错升级，Phase 3 stable 完全清。
- **`ss_basic_mode=7` 全套清理** — 14 处 case 分支删除 + `creat_shunt_json` 函数体改 no-op；`migrate_split_routing_v3` step 1 把存量 `ss_basic_mode=7` / `ss_acl_mode_<i>=7` 自动迁到 `2`（大陆白名单）。
- **老 [DNS 设置] section 退役** — ASP `Module_shadowsocks.asp` 老 section（18353-18428 ~95 行）+ JS handler 删除，40+ 个 `ss_basic_chng_china_dns_*` / `_trust_dns_*` / `_china_udp/tcp/dot_*` dbus key 由 `migrate_split_routing_v3` step 2 一次性清理。新 DNS upstream 由 `ss_split_dns_*` 系列管理（详见 §1.6.1）。
- **老 `start_chinadns_ng()` 单实例移除** — 整段函数及调用点全删（仅保留 `start_chinadns_ng_split` / `stop_chinadns_ng_split` 双实例 V2 路径）。
- **老 iptables / ipset 老分支移除** — `load_iptables()` 老分支 + `flush_ipset()` 老分支 + `apply_ss()` fork 入口删除（仅保留 `load_iptables_split` / `flush_ipset_split`）。
- **hint 220 / 221 退役** — `ss-menu.js` hint 220/221 定义 + ASP 4 处触发点删除（开关物理移除后触发条件不存在）。

### 0.3 历史路径不假装从未存在

本文档保留以下历史段落作为审计参考，不**删除**：
- §6.1 alpha 阶段简化清单 — 内含 D7/D8/D11/D12 alpha 阶段决策与 doge.13 beta 兑现路径，对理解当前代码形态仍有价值
- §6.2 D1-D16 已知集成漂移 — 历史发现 + 修订路径，下次出类似问题时可类比
- §14 老用户升级路径 — 跨版本升级（doge.11 → doge.12 alpha → doge.13 stable → doge.14）的迁移设计

> **新加 §6.3 "D17+ doge.14 物理删除收尾"** — 集中记录 doge.14 sprint Phase 1+2+3 物理删除的范围、决策、真机验证记录与 Reviewer 留 WARN 收尾。

> **设计文档 §7 "ss_node_shunt 物理移除" 的历史修订记录**：alpha/beta/stable 三阶段**不物理删除** `ss_node_shunt.sh`，保留旧路径作为回退兜底。**doge.14 起兑现物理删除**。

---

## 1. dbus key 完整契约（**所有 subagent 必须严格遵守**）

### 1.1 总开关 + 迁移标志

| Key | 类型 | 默认 | 说明 |
|---|---|---|---|
| ~~`ss_split_enabled`~~ | ~~"0"/"1"~~ | ~~"1"（doge.13 起）~~ | **doge.14 已物理移除**：`migrate_split_routing_v3` 一次性 `dbus remove`；路由层不再有 fork 入口。历史值（alpha/beta 期 opt-out 老用户的 `0`）一并清除 |
| `fss_split_migrated_v1` | "0"/"1" | "0" | install.sh::migrate_split_routing_v1 幂等标志（保留供 audit 用，doge.14 不再走 v1 主流路径） |
| `fss_split_migrated_v2` | "0"/"1" | "0" | install.sh::migrate_split_routing_v2 幂等标志（doge.13 新增；DNS upstream 老→新 key 一次性迁移） |
| `fss_doge14_migrated` | "0"/"1" | "0" | install.sh::migrate_split_routing_v3 幂等标志（**doge.14 新增**；mode=7 → 2 + ss_basic_chng_* 清理 + ss_split_enabled remove + ss_node_shunt_* 清理） |

### 1.2 Rule 数据

| Key | 类型 | 说明 |
|---|---|---|
| `ss_split_rule_count` | int | Rule 总数 |
| `ss_split_rule_<i>_id` | int | Rule.id（与 i 解耦，删除不重排） |
| `ss_split_rule_<i>_name` | string | 显示名 |
| `ss_split_rule_<i>_builtin` | "0"/"1" | 是否内置预设 |
| `ss_split_rule_<i>_source_url` | string | auto-update URL（空=手编） |
| `ss_split_rule_<i>_update_hours` | int | 自动更新间隔（0=禁用） |
| `ss_split_rule_<i>_last_update` | int | Unix ts |
| `ss_split_rule_<i>_stat_domains` | int | 域名条数缓存 |
| `ss_split_rule_<i>_stat_ips` | int | IP/CIDR 条数缓存 |

> 规则文件路径不进 dbus，按 id 推：`/koolshare/ss/rules_user/rule_<id>.txt`

### 1.3 Mode 数据

| Key | 类型 | 说明 |
|---|---|---|
| `ss_split_mode_count` | int | Mode 总数 |
| `ss_split_mode_<m>_id` | int | Mode.id |
| `ss_split_mode_<m>_name` | string | 显示名 |
| `ss_split_mode_<m>_builtin` | "0"/"1" | 是否内置 |
| `ss_split_mode_<m>_udp_proxy` | "0"/"1" | 启用 UDP 代理 |
| `ss_split_mode_<m>_block_quic` | "0"/"1" | 屏蔽 QUIC |
| `ss_split_mode_<m>_apply_blackwhite` | "0"/"1" | 受全局黑白名单影响 |
| `ss_split_mode_<m>_dns_mode` | "split"/"global" | DNS 模式 |
| `ss_split_mode_<m>_default_action` | string | 兜底动作（编码见 §1.5；**不可为 reject**） |
| `ss_split_mode_<m>_rule_count` | int | rules[] 长度 |
| `ss_split_mode_<m>_rule_<r>_rid` | int | 引用的 Rule.id |
| `ss_split_mode_<m>_rule_<r>_action` | string | 该规则的动作（编码见 §1.5） |

### 1.4 User 分配 + 默认

| Key | 类型 | 说明 |
|---|---|---|
| `ss_split_default_mode_id` | int | 默认 Mode.id（**必须非 0**） |
| `ss_acl_split_mode_<acl_node>` | int | 该 acl 行分配的 Mode.id（0=不通过代理） |

> **注**：ACL 默认行 `ss_acl_default_mode`（取值 `follow` / `0` / `1` / `2` / `3` / `5` / `7`）**不参与 split mode 翻译**——split V2 路径下表外设备走 `ss_split_default_mode_id` 兜底（[ssconfig.sh:7288](../../fancyss/ss/ssconfig.sh#L7288)），跟 ACL 默认行 UI 是两条独立逻辑。alpha.18 Q2 翻译 + install.sh::migrate_split_routing_v1 step 4 一致只处理数字下标行 `ss_acl_mode_<i>`。doge.13 ACL UI 改造时可顺便确认要不要把两套默认行 UI 合并/联动（独立 task）。

### 1.4.1 索引规范（**doge.13 beta — 方案 B 已升级**）

dbus key 中的 `<m>` (Mode 索引) / `<r>` (rule 序号) / `<i>` (Rule 索引) 的语义演进：

**alpha 阶段（doge.12.alpha-1 → alpha.18，已固化为历史）**：
- **从 1 开始连续**（与 `install.sh::migrate_split_routing_v1` 写入 `mid=1, mid=2 ...` 一致）
- **index == id** — alpha 阶段不区分（避免编辑弹窗未实现时的 gap 问题）
- **消费方用 `for X in $(seq 1 count); do` / `for (X=1; X<=n; X++)` 1-indexed 枚举**

**doge.13 beta 升级到方案 B（已落地）**：
- Mode CRUD helper `ss_split_mode_save.sh` 已实施（对标 `ss_split_rule_save.sh`），支持 Mode 编辑/删除/添加；index 与 id 正式解耦——删除中间 Mode 留 gap 不重排。
- 消费方改用 `dbus list ss_split_mode_ | awk -F_ '$4 ~ /^[0-9]+$/ {print $4}' | sort -nu` **动态枚举 actual slot**（详见 `__split_active_mode_indices` / `__split_active_rule_indices`）。
- `for $(seq 1 count)` 1-indexed 枚举在 doge.13 路由层逐步替换为动态枚举；旧 1-indexed 写法残留视为待清理 (legacy，**禁止新增**)。
- alpha 阶段的"index == id"假设**仍兼容**——新写入的 Mode/Rule 仍可以走 install.sh 风格的连续 1-indexed 写入，方案 B 只是允许 gap 出现而已。

### 1.5 Action 编码格式

单字符串、`:` 分隔：

| 动作 | 编码 |
|---|---|
| 直连 | `direct` |
| 屏蔽 | `reject` |
| 代理（跟随主节点） | `proxy_main`（**doge.13 beta 新增 sentinel**，xray 生成器实时查 `ssconf_basic_node` / `ssconf_basic_node_front` 转译） |
| 代理（节点 X） | `proxy_node:<node_id>` |
| 代理（链式 Y→Z） | `proxy_chain:<front_id>:<landing_id>` |

> **`proxy_main` sentinel（doge.13 beta 落地，详见 §6.2 D12 兑现段）**：解决 stale 节点 ID 问题。alpha 阶段 install.sh::migrate_split_routing_v1 把当前 `ssconf_basic_node` 烘焙成具体 ID 写入 Mode 2 rule_5/rule_6 action，主节点变更后 dbus 残留 stale。doge.13 改写为字面量 `proxy_main`，由 [ssconfig.sh::ss_split_action_to_tag](../../fancyss/ss/ssconfig.sh) 解析、xray 生成器查实时主节点构建 outbound。ASP action select 加 `proxy_main` option（默认值）。Mode helper (`ss_split_mode_save.sh`) 接受该字面量。**新代码写 action 字符串时优先用 `proxy_main`**，仅在用户显式指定异于主节点的代理时才写 `proxy_node:<id>`。

### 1.6 运行状态（后端写，前端读，**必须配合轮询**）

| Key | 类型 | 写者 | 说明 |
|---|---|---|---|
| `ss_split_active_mode_count` | int | restart 时 | 活跃 Mode 数 |
| `ss_split_xray_outbound_count` | int | restart 时 | xray 实际生成 outbound 数（去重后） |
| `ss_split_node_outbound_count` | int | restart 时 | xray 生成的独立节点 outbound 数（doge.13 解 collapse 后新增诊断 key；`proxy_node:` 引用) |
| `ss_split_chain_outbound_count` | int | restart 时 | xray 生成的独立链式 outbound 数（doge.13 解 collapse 后新增诊断 key；`proxy_chain:` 引用） |
| `ss_split_last_restart_ts` | int | restart 完成时 | 最近重启时间戳 |
| `ss_split_dns_split_status` | "ok"/"down" | cron 检测 | 分流 DNS 实例状态 |
| `ss_split_dns_global_status` | "ok"/"down" | cron 检测 | 全局 DNS 实例状态 |

### 1.6.1 分流 DNS upstream（doge.13 beta 新 key 主消费路径）

| Key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `ss_split_dns_china_upstream` | base64 string | 空（回退老 key） | 国内 DNS upstream 列表（每行一条，base64 编码 multi-line）。**新 key 优先消费**，回退老 `ss_basic_chng_china_dns_*` |
| `ss_split_dns_overseas_upstream` | base64 string | 空 | 国外 DNS upstream 列表，同上。回退老 `ss_basic_chng_trust_dns_*` |
| `ss_split_dns_global_upstream` | base64 string | 空 | 全局 Mode 专用 DNS upstream 列表，回退老 trust dns |

> **doge.13 beta 兑现路径**（详见 §6.2 D1 兑现段）：`install.sh::migrate_split_routing_v2` 把老 `ss_basic_chng_china_dns_*` / `ss_basic_chng_trust_dns_*` 一次性切到新 key（**不删老 key**，保留 fallback 兜底），落 `fss_split_migrated_v2=1` 守卫；`ssconfig.sh::generate_chinadns_split_conf` / `generate_chinadns_global_conf` 优先读新 key，新 key 为空时回退老路径。

#### 1.6.1.1 DNS upstream 输入 UI：协议下拉 + 地址框（doge.14-beta.3，2026-06-15）

DNS tab 的「国内 / 国外（可增删行）」+「全局（单行）」三处 upstream **输入控件**从纯文本框升级为 **`[协议▼] + [地址]`** 两段式（防止用户把协议前缀打错）。**纯前端表现层改动，后端 0 改动** —— 上面三个 `ss_split_dns_*` base64 key 的存储格式（每行一条 upstream 字符串）和 `save()` / `conf2obj()` 的 base64 通道一字未改。

- 隐藏的原 `<textarea>` / `<input>`（原 id）仍存「每行一条」真实 upstream 字符串，是真理之源；可见的协议下拉+地址框只是它的双向投影。
- 关键 JS（`Module_shadowsocks.asp`）：`DNS_PROTOS`（udp / tcp / tls / https 四选项）、`dns_split_proto(line)`（把 `tcp://1.2.3.4` / `tls://host@ip` / `https://host/path` 拆成 `{proto, addr}`；裸地址或未知协议 → `udp` + 原样保留）、`dns_join_proto(proto, addr)`（拼回，`udp` = 裸地址不加前缀）、`dns_make_proto_select()`、`add_dns_upstream_row` / `sync_dns_upstream_rows`（国内/国外多行）、`render_dns_global_upstream` / `sync_dns_global_upstream`（全局单行，原 input 改 `type=hidden` + `#grow_*` 容器）。
- 地址框 placeholder 随协议变（DoT = `域名@IP`、DoH = `域名/路径`）。CSS 加 `.dns-up-proto`（[fancyss/res/fancyss.css](../../fancyss/res/fancyss.css)）。
- **改这块前注意**：协议下拉只认 udp / tcp / tls / https 四种；遇到 dbus 里存的其它协议（如 h3）会 fallback 成 udp + 把整串当地址原样保留（不丢数据），下拉显示回落到 udp —— 符合 CLAUDE.md 硬规则 #9「找不到选项不要 `val("")`」的精神（这里是 fallback 保留而非清空）。

### 1.6.2 Mode CRUD helper 协议（`ss_split_mode_save.sh`，doge.13 beta 新增）

`ss_split_mode_save.sh` 是 Mode 编辑/添加/删除的后端 sanitize 入口（对标 `ss_split_rule_save.sh`，解决 §6.1 alpha "Mode name 后端 sanitize 缺口"）。前端通过 dummy_script.sh 把以下临时 key 写入 dbus 后调用 `ss_split_mode_save.sh`，helper 校验后落到正式 `ss_split_mode_<m>_*` key 并删除临时 key。

| 临时 Key | 类型 | 说明 |
|---|---|---|
| `ss_split_mode_save_action` | "add"/"update"/"delete" | CRUD 动作 |
| `ss_split_mode_save_id` | int | 目标 Mode.id（add 时 helper 自动分配，update/delete 时由前端指定） |
| `ss_split_mode_save_name` | string | Mode 名（add/update 用，case sanitize 防止注入） |
| `ss_split_mode_save_udp_proxy` | "0"/"1" | 同 §1.3 |
| `ss_split_mode_save_block_quic` | "0"/"1" | 同 §1.3 |
| `ss_split_mode_save_apply_blackwhite` | "0"/"1" | 同 §1.3 |
| `ss_split_mode_save_dns_mode` | "split"/"global" | 同 §1.3 |
| `ss_split_mode_save_default_action` | string | 同 §1.3 action 编码（§1.5） |
| `ss_split_mode_save_rule_count` | int | rules[] 长度 |
| `ss_split_mode_save_rule_<r>_rid` | int | 引用的 Rule.id |
| `ss_split_mode_save_rule_<r>_action` | string | 该规则的 action（§1.5） |
| `ss_split_mode_save_result` | "0"/"1" | helper 写出：操作成功(1)/失败(0) |
| `ss_split_mode_save_error` | string | helper 写出：失败时的错误码（`name_invalid` / `id_conflict` / `builtin_locked` 等） |

> **helper 行为**：校验 name 合法字符集（与 `ss_split_rule_save.sh` 同款 case sanitize）、阻止 builtin Mode 的危险操作（删除 / 改名 / 改 rule 顺序）、允许 builtin Mode 修改运行时字段（dns_mode / udp_proxy / block_quic / apply_blackwhite / default_action / rule action）。详见 [fancyss/scripts/ss_split_mode_save.sh](../../fancyss/scripts/ss_split_mode_save.sh)。

### 1.7 后端专用 (`fss_*` 前缀，不上前端)

| Key | 类型 | 说明 |
|---|---|---|
| `fss_split_rules_update_lock` | "0"/"1" | cron 互斥锁 |
| `fss_split_rules_update_log` | string | 最近一次 cron 摘要 |
| `fss_split_outbound_dedup_cache` | string | xray 生成器去重缓存（可选） |
| `fss_split_xray_warn` | string | xray 生成器失败码：`baseline_missing` / `jq_missing` / `jq_merge_failed` / `output_empty` / `xray_test_failed` / `no_active_mode` / "" (空=正常) |

### 1.8 旧 key 处置历史

#### 1.8.1 alpha 阶段（doge.12.alpha-1 → doge.13.1，已废弃）

| 旧 key | alpha/doge.13 处置 |
|---|---|
| `ss_basic_mode` / `ss_acl_mode_<i>` | **保留并继续生效**（`ss_split_enabled=0` 时是唯一路径） |
| `ss_basic_shunt_*`（ss_node_shunt 系列） | **保留**（mode=7 仍使用） |
| `ssconf_basic_node` / `ssconf_basic_node_front` | **保留**——doge.12 新架构作为"快速节点设置"的兜底 |
| `ss_basic_chng_china_dns_*` / `_trust_dns_*` / `_china_udp/tcp/dot_*` | **保留作 fallback**（migrate_v2 写新 key 后老 key 仍读得到） |

#### 1.8.2 doge.14 阶段（**唯一路径**，老 key 物理清理）

| 旧 key | doge.14 处置（`migrate_split_routing_v3`） |
|---|---|
| `ss_basic_mode=7` | **存量值自动迁到 `2`（大陆白名单）**，mode=7 case 物理删除；新装机默认值变 `2` |
| `ss_acl_mode_<i>=7` | 同上规则迁移（acl 行 mode=7 → mode=2） |
| `ss_basic_shunt_*`（ss_node_shunt 系列） | **物理 dbus remove 全清**；`ss_node_shunt.sh` 整文件物理删除 |
| `ssconf_basic_node` / `ssconf_basic_node_front` | **保留**——仍是"主节点"概念，新架构下走 `proxy_main` sentinel（详见 §1.5） |
| `ss_basic_chng_china_dns_*` / `_trust_dns_*` / `_china_udp/tcp/dot_*` | **物理 dbus remove 全清**（40+ 个 key），新 DNS upstream 由 `ss_split_dns_*` 统一管理（§1.6.1） |
| `ss_split_enabled` | **物理 dbus remove**，路由层无 fork 入口可回退 |

---

## 2. 内置 Rule 与 Mode 初始 layout

### 2.1 内置 Rule（id 1~99 预留）

| Rule.id | name | source（首次安装的内容来源） | source_url | update_hours |
|---|---|---|---|---|
| 1 | 大陆白名单_常用 | install 期 zcat 现有 `fancyss/ss/rules/chnlist.gz` + 加 `rules_ng2/ip/cn.txt` IP | 留空 alpha；doge.13 起指向 fork raw | 0（alpha 不自动更新） |
| 2 | GFW列表_常用 | install 期 zcat 现有 `fancyss/ss/rules/gfwlist.gz` | 同上 | 0 |
| 3 | 中国公共DNS | install 期写入硬编码 10 IP（沿用 [ssconfig.sh:3228 `ip_lan_chndns`](../../fancyss/ss/ssconfig.sh)） | 空（永禁用 auto-update） | 0 |
| 4 | 广告统计屏蔽 | install 期 zcat 现有 `fancyss/ss/rules/adslist.gz`（若存在；否则留空） | 同 Rule 1 | 0 |
| 5 | Telegram 加速 | install 期合并 `rules_ng2/site/telegram.txt` + `rules_ng2/ip/telegram.txt` | 同 Rule 1 | 0 |
| 6 | 在线状态检测站 | install 期硬编码 5 项（worldtimeapi + 4 个 IP 检测源，参见 [ssconfig.sh:264](../../fancyss/ss/ssconfig.sh)） | 空 | 0 |
| 7 | 查IP常用站 | install 期硬编码（沿用现有 `block_list` 文件 6 项 + rotlist 28 项中"查 IP"类） | 空 | 0 |
| 8 | Bing 加速 | install 期 1 行 `bing.com` | 空 | 0 |

> alpha 阶段 update_hours 全部=0（cron 不去更新内置 Rule）。doge.13 切到 fork raw URL 后再开启。
> Rule.id 1~99 预留给内置，用户自定义从 100 起。

### 2.2 内置 Mode（id 1~99 预留）

| Mode.id | name | dns_mode | apply_blackwhite | udp_proxy | block_quic | rules（按顺序） | default_action |
|---|---|---|---|---|---|---|---|
| 1 | 全局代理 | global | 1 | (沿用 `ss_basic_udp_relay`) | 0 | [] | 取自 `ssconf_basic_node` / `ssconf_basic_node_front` |
| 2 | 大陆白名单 | split | 1 | 同上 | 0 | (Rule 3 → direct, Rule 4 → reject, Rule 6 → direct, Rule 7 → direct, Rule 5 → 主节点动作, Rule 2 → 主节点动作, Rule 1 → direct) | 取自 `ssconf_basic_node` |

> 用户自定义 Mode 从 100 起。

---

## 3. 文件路径布局

```
fancyss/                                  # 仓库内
  ss/
    rules_ng2/                            # 现有上游资产（不动）
      site/*.txt                          # 沿用
      ip/*.txt                            # 沿用
      meta/*.json                         # 沿用
      dat/*.dat                           # 沿用
    rules/                                # 现有上游"运行时初始数据"目录（不动）
      chnlist.gz, gfwlist.gz, ...
  scripts/
    fss_rules_update.sh                   # 新增：cron 自动更新内置 Rule

/koolshare/ss/                            # 路由器运行时
  rules_user/                             # 新增：用户/内置 Rule 实际数据目录
    rule_<id>.txt                         # 规则文件（域名+IP 混排）
    rule_<id>.txt.bak                     # 远程更新前备份（保留 1 版）
    update_schedule.txt                   # cron 调度表
```

---

## 4. 关键约束（**所有 subagent 必读**）

### 4.1 CLAUDE.md 硬规则

- **#1**：前端要读的 dbus key 必须 `ss_*` 前缀（**包括 `ss_split_*`**）。后端专用用 `fss_*`。
- **#2**：`fancyss/webs/Module_shadowsocks.asp` 是 **UTF-8 with BOM, CRLF, tab 缩进**。改 asp 前先 `git diff -U0` 验证只有目标行变化。多行带前导 tab 的替换走 PowerShell 而非 Edit。
- **#3**：新加 hint id 选 200+。已用：0, 1, 11, 24, 27, 31, 32, 34, 29, 35-41, 44, 47-49, 54-56, 104-118, 133-156, 200-204（doge.9~11）, 210-218（doge.12 alpha）, 221（doge.13 beta D13 preflight，**doge.14 已退役** —— ss_split_enabled 总开关移除后 preflight 触发条件消失）。**doge.14+ 新 hint 从 222 开始**（220/221 物理删除）。
- **#9**：select 控件 `refresh_options` 时若 dbus 值找不到对应 option，**不能** `val('')`——必须插 `data-stale="1"` 占位 option，`save()` 检测到 stale 跳过 dbus 覆盖。
- **#10**：运行状态 dbus key 必须配合前端轮询（参考 `refresh_chain_status_only`），不能假设 `db_ss` 新鲜。
- **#11**：~~旧路径（`ss_split_enabled=0`）继续受 chinadns tag 优先级约束~~ **doge.14 已物理移除旧路径**——新装机和升级老用户全部走新分流路径，chinadns tag 约束在 split 路径下不影响最终路由结果（详见架构 §6.5）。#11 在 doge.14 起仅作"历史警示"保留（指导未来如果有人再次引入 ipset 决策时需注意）。

### 4.2 doge.14 唯一路径约束（**已物理移除旧路径回退**）

> **历史背景**：doge.12 alpha → doge.13 stable 阶段采用 "fork-not-replace" 策略（所有路由层函数加 `if ss_split_enabled=1; then ...新逻辑...; else ...旧逻辑...; fi`，旧逻辑 byte-for-byte 保留），用作回退兜底。**doge.14 sprint Phase 1+2+3 物理删除完成后**，旧路径已不存在。

doge.14 起的硬约束：

- **`ss_split_enabled` 总开关已物理移除** — 路由层无 else 分支可回退；新改路由层代码直接面向 split 路径（无需 fork 入口）。
- **`ss_node_shunt.sh` 整文件物理删除** — 不再有 mode=7 路径；任何 `source ss_node_shunt.sh` / `creat_shunt_json` 调用都是历史残留 dead code。
- **`ss_basic_mode=7` 已不可达** — `migrate_split_routing_v3` 把存量值迁到 `2`；ASP `<select>` 选项物理删除，新装机 default `2`。
- **老 [DNS 设置] section + 40+ ss_basic_chng_* dbus key 已退役** — 新 DNS upstream 由 `ss_split_dns_china_upstream` / `_overseas_upstream` / `_global_upstream` 统一管理（详见 §1.6.1）。
- **不修改 `rules_ng2/site/*.txt` `rules_ng2/ip/*.txt`** — 这些仍是上游资产，作为内置 Rule 内容源使用。如需 fork 改造本地源另开 sprint 讨论。

### 4.3 仓库文档/注释约束

- 源码注释、asp hint、doc/ 文档"详见"/"参考"**只能**指向：仓库内文件、公开 URL。**绝不引用** `~/.claude/projects/.../memory/*.md`。
- 战略/规划文档**不**写猜想性远期方向，只记录已确认事项。

### 4.4 不要做的事

- 不要 `git push`、`git tag`、`gh release create`
- 不要 bump 版本号（这一步留主代理收尾时统一做）
- 不要主动 `git commit --amend` / `git reset --hard`
- 不要重新引入广告位
- 不要把 update URL 指回 hq450
- 改了 asp 后**不要**自己跑 build_min.sh —— alpha 仅产源码

---

## 5. 实施清单（subagent 工作分配）

> 主代理统筹，subagent 并行落地各模块。每个 subagent 完成后回报：改动的文件清单 + 关键决策点 + 留给主代理验证的事项。

- **Subagent A**：[fancyss/install.sh](../../fancyss/install.sh) `migrate_split_routing_v1` 函数 + 内置 Rule 文件写入（zcat chnlist.gz/gfwlist.gz/adslist.gz、组装 cn IP 等）+ install_now() 中接 migrate 调用。
- **Subagent B**：[fancyss/ss/ssconfig.sh](../../fancyss/ss/ssconfig.sh) 路由层改造：
  - `generate_chinadns_split_conf` / `generate_chinadns_global_conf` 双轨生成（从 `start_chinadns_ng` @ 2116 拆出来）
  - `start_xray` 内 fork：`ss_split_enabled=1` 时调用新生成器（含 sniffing + outbound 去重 + per-Mode inbound）
  - `load_tproxy` / `load_nat` 内 fork：`ss_split_enabled=1` 时按 per-Mode 端口 + per-MAC DNAT 装配
  - `apply_ss` 内 fork
  - `flush_ipset` 改名单
- **Subagent C**：[fancyss/webs/Module_shadowsocks.asp](../../fancyss/webs/Module_shadowsocks.asp) 加 4 个新 tab/section（模式管理 / 规则管理 / DNS 设置（双轨）/ 实验性架构开关）+ ss-menu.js hint 210~ 新增。
- **Subagent D**：[fancyss/scripts/fss_rules_update.sh](../../fancyss/scripts/fss_rules_update.sh) 新文件 + install.sh `cru a fancyss_rules_update` 注册。

---

## 6. 实施期 TODO 与边角决策

### 6.1 已知 alpha 简化（**留 doge.12-stable / doge.13 解决**）

由 4 个 subagent 报告 + 主代理验证汇总。

**ssconfig.sh 路由层**（B）：
- ~~`proxy_node:X` 当 X 不是当前 `ssconf_basic_node` 时，xray 生成器折回 `out_main`（不构建独立 outbound）。理由：跨节点 outbound 构建要复用所有协议 creat_*_json，alpha 不做。~~ **✓ doge.13 beta 兑现** —— 新建 [fancyss/scripts/ss_split_node_outbound.sh](../../fancyss/scripts/ss_split_node_outbound.sh) 拆出 ss_chain_proxy.sh 节点 outbound 构建器，[ssconfig.sh::generate_xray_json_split](../../fancyss/ss/ssconfig.sh) 为每个被 split rule 引用的非主节点构建独立 outbound + jq merge 进基线，诊断 dbus `ss_split_node_outbound_count` 记数；helper 未部署时 graceful fallback 仍回退 `out_main` 并写 `fss_split_xray_warn=baseline_missing`。
- ~~`proxy_chain:Y:X` per-rule 链式~~ **✓ doge.13 beta 兑现**：per-rule chain landing outbound 通过 [`fss_split_build_node_outbound_json`](../../fancyss/scripts/ss_split_node_outbound.sh) 第 4 参 `dialer_tag` 注入 `streamSettings.sockopt.dialerProxy=chain_front_<Y>`；[ssconfig.sh::generate_xray_json_split](../../fancyss/ss/ssconfig.sh) L5598 chain build 循环按合同对齐 helper 签名，前置 `chain_front_<Y>` outbound + landing `out_chain_<Y>_<X>` outbound 双 jq merge 进基线；诊断 dbus key `ss_split_chain_outbound_count` 在 restart 时由 `generate_xray_json_split` 实际填值。helper 未部署时与 §6.1 节点 outbound 同走 graceful fallback。
- ~~`block_quic` Mode 级开关 alpha 在 iptables 层不实现（xray sniffing 已能识别 QUIC SNI 但无 DROP；doge.13 加 `iptables -A SHADOWSOCKS -p udp --dport 443 -j DROP`）。~~ **alpha.16 已兑现 → 详见 §6.2 D11**；`udp_proxy` Mode 级开关同时兑现。
- active Mode 判定粗放：alpha 把"内置 Mode + default Mode"都激活，不严格按 acl 引用过滤。**doge.13 beta** 引入 `__split_active_mode_indices` 动态枚举（dbus list 切片），与 D8 端口分配 gate 解除联动。
- 单条 dbus 调用 fork 多个 jq 子进程，50 mode × 10 rule 量级启动 ~3s。alpha 接受。
- **acl per-Mode 路由层（doge.13 beta 兑现，详见 §6.2 D8 兑现段）**：合同 §1.4 定义 `ss_acl_split_mode_<acl_node>` = 每个 acl 行分配的 Mode.id（0 = 不走代理）。**alpha.18 写者侧已 OK**（save() 翻译 + delTr 清零）；**doge.13 beta 读者侧端口分配 gate 解除**：`__split_mode_port_by_id` / `__split_mode_dns_port_by_id` 同步删除 `is_default || builtin` gate，按 `__split_active_mode_indices` 动态分配端口偏移，用户自定义 Mode 不再静默退化到默认端口。**仍待 doge.13 收尾真机三 MAC 验证 + ACL UI select 扩展支持自定义 Mode**。
- ~~**Mode name 后端 sanitize 缺口**~~ **✓ doge.13 beta 兑现**：新增 [fancyss/scripts/ss_split_mode_save.sh](../../fancyss/scripts/ss_split_mode_save.sh) 545 行 helper（对标 `ss_split_rule_save.sh`），Mode CRUD 改走专用 helper 加 case sanitize；dummy_script.sh 仅保留给"只改单个标量字段"的轻量场景。详见 §1.6.2 helper 协议。

**install.sh 迁移层**（A）：
- 旧 key 物理删除（设计 §14 Step 6 / Step 7.5）alpha 跳过，新旧并存。
- ipset 销毁 alpha 跳过（旧路径仍用）。
- helper `write_builtin_mode_meta` 硬编码 `apply_blackwhite=1`，doge.13 视需要扩展签名。

**UI 第一稿**（C）：
- ~~新建/编辑/删除 Mode/Rule 对话框用 `alert()` 占位文字。doge.13 做漂亮弹窗。~~ **✓ doge.13 beta 兑现**：Mode 走 `ss_split_mode_save.sh` helper + UI 弹窗（详见 §1.6.2）；Rule 沿用 alpha.10 的 `ss_split_rule_save.sh` 路径。
- 拖动重排未实现（依赖编辑弹窗）。
- 立即更新 / 回滚到 .bak 按钮无 UI 入口（脚本能力已就绪 by D，UI 后接）。
- **访问控制 UI 改造仍待**：alpha.18 写者侧 save() 翻译 + delTr 清零已就绪；doge.13 beta 端口分配 gate 已解除（读者侧自定义 Mode 独立端口）；但 ACL UI select 仍只有旧 6 个 option（0/1/2/3/5/7），**用户不能从 ACL 直接选自定义 Mode**。完整 ACL UI 改造留 doge.13 收尾。
- 导入/导出 Mode (JSON) 留 doge.13。
- Mode/Rule 子字段写入路径（如 `ss_split_mode_<m>_udp_proxy`）通过 helper 协议 §1.6.2 兑现。
- **内置 Mode 字段全锁** → **alpha.18 修正 / doge.13 沿用**：alpha.17 F-B-7 把内置 Mode 所有字段一律 disabled 设计过度。alpha.18 拆 `disName`（锁名字）+ `disRun=''`（运行时字段放开）：name + rule list 顺序仍锁（防止破坏 install.sh 种子标识），default_action / udp_proxy / block_quic / apply_blackwhite / dns_mode / rule action 全放开。详见 [Module_shadowsocks.asp:7318-7340](../../fancyss/webs/Module_shadowsocks.asp#L7318)。Mode helper 在 doge.13 同样落实 builtin_locked 错误码兜底。
- **「确定」按钮仅写 dbus 不重启代理** → **alpha.18 加「保存并立即生效」按钮 / doge.13 沿用**：Mode 弹窗 footer 三按钮（取消 / 保存 / 保存并立即生效）。`split_v2_persist(fields, cb, applyAfter)` 新增 applyAfter 参数，true 时 dbus 落盘后调 `push_data_ws('ss_config.sh', enabled?'start':'stop', {})` 复用主面板「保存&应用」路径。详见 [splitDlg.okApply](../../fancyss/webs/Module_shadowsocks.asp#L7025) / [split_v2_persist](../../fancyss/webs/Module_shadowsocks.asp#L7039)。
- **UI 方案 A（doge.13 beta 新增）**：ASP 标签 "分流V2 (实验)" → "分流"；ss_basic_mode select 中 mode 7 option 隐藏 + stale 占位（老用户保留旧值，不在 UI 主流入口暴露 xray 分流旧路径）。

**cron**（D）：
- `recount_stats` 用 grep 单行处理，10 万行规则路由器上估算 5-10s（alpha 阶段 update_hours=0 cron 不实际跑）。doge.13 改 awk 单遍。
- UTF-8 校验罕见环境下 isutf8/iconv 都不在则降级到行数/字节数兜底。
- busybox ash trap EXIT 在 SIGKILL 下不释放锁——下轮 cron 卡 30 分钟。doge.13 加 stale-lock 检测。

### 6.2 已知集成漂移（**需要主代理协调 / 由审查 subagent 复查**）

> **关于 dbus 工具语义（避免再踩 D6 那种坑）**：koolshare `dbus` 二进制的 `list` / `remove` 行为**不对称**——
> - `dbus list KEY` = **前缀匹配**（返回所有以 KEY 开头的 key）
> - `dbus remove KEY` = **精确匹配**（只删字面 KEY，不删 `KEY_<i>` 之类）
>
> 想批量删一组前缀 key 的正确写法是 `dbus list <prefix>_ | cut -d= -f1 | while read k; do dbus remove "$k"; done`（见 [install.sh:491-499](../../fancyss/install.sh#L491) 已有范例）。看到形如 `dbus remove ss_acl_mode` 这种"裸前缀单行调用"不要假设它能删一票子 key，那是上游 no-op 死代码。

#### D1: 分流 DNS upstream 读写两套 key（**✓ doge.13 beta 兑现 + doge.13 beta.3 修对称漏洞 + TAB 污染清理**）
- **alpha 历史**：C 的 UI textarea 写新 key `ss_split_dns_china_upstream` 等，但 B 的 chinadns conf 生成器仍读老 key。alpha 决议用 placeholder 方案避免分裂心智。
- **doge.13 beta 兑现**：
  - `install.sh::migrate_split_routing_v2` 把老 `ss_basic_chng_china_dns_*` / `ss_basic_chng_trust_dns_*` 一次性切到新 key（base64 multi-line 编码），落 `fss_split_migrated_v2=1` 守卫；**不删老 key**保留 fallback 兜底；
  - `ssconfig.sh::generate_chinadns_split_conf` / `generate_chinadns_global_conf` 优先读新 key，新 key 为空时回退老路径；
  - 新 key 契约入 §1.6.1。
- **doge.13 beta.3 修订（2026-05-23）**：beta.1 实施有两个 chained bug，用户报"chinadns 启动失败"+"每次登录弹 skipd 弹窗"。
  - **Bug A (chinadns 启动失败)**：[ASP save() params_base64](../../fancyss/webs/Module_shadowsocks.asp) **加了** 3 个 split DNS upstream key 走 `Base64.encode`，但 [conf2obj _base64](../../fancyss/webs/Module_shadowsocks.asp) **漏加** 对应 decode → textarea 填 RAW 1 层 base64 → 用户每点"保存&应用"(任意 tab) save() 重新 encode → +1 层 → 多次 save 后变 N 层 → chinadns-ng 收到 `VFdwS...` 当 IP → `[opt.zig:310] invalid ip` → 启动失败。**修法**：conf2obj `_base64` 数组加 3 个 key 对称，`refresh_split_v2_panel` 移除冗余 decode（避免双重 decode）。
  - **Bug B (skipd 弹窗)**：`/koolshare/bin/base64_encode` 二进制**输出末尾带 raw TAB**（U+0009）。`install.sh::migrate_split_routing_v2` 的 `enc_china="$(... | base64_encode 2>/dev/null)"` 写入 dbus 末尾含 TAB → httpdb 塞进 `/_api/ss` JSON string 不 escape control char → 浏览器 `JSON.parse` 拒收 → ajax error → 弹"skipd 数据读取错误"。**修法**：所有 `base64_encode` pipe 加 `| tr -d ' \t\r\n'`（参考 [ss_node_subscribe.sh:5724](../../fancyss/scripts/ss_node_subscribe.sh#L5724) 老代码已有的 strip 模式）。CLAUDE.md 硬规则 #18 新增固化这条。
  - **新加迁移函数** `install.sh::unwrap_split_dns_multilayer_b64`（幂等 `fss_split_dns_b64_unwrapped=1`）：清理老用户已被多层 base64 污染 + 末尾 TAB 的 dbus 值。逻辑：反复 decode 直到 decoded 含 `.` 或 `:`（IP/URL 必有）= plaintext → 停，避免 over-decode（DNS 上游字符集有限，可能多次 decode 都是合法 base64 字符集但产 garbage）；末尾 whitespace 也独立 strip。
  - **教训**：所有 asp 端 `params_base64` 数组的 key 都必须在 `conf2obj()` `_base64` 数组对称出现，否则就是 silent data corruption。审计任何新 asp base64 key 时双向 grep `params_base64\|_base64` 看对称。

#### D2: Mode index `m` 与 Mode.id 在 alpha 时等同（**✓ doge.13 beta 兑现，方案 B 升级**）
- **alpha 历史**：A 写入用 `mid=1, mid=2` 同时作为索引和 id；alpha 阶段无编辑弹窗，等同没问题。
- **doge.13 beta 兑现**：`ss_split_mode_save.sh` helper 实施 + `__split_active_mode_indices` 动态枚举（dbus list 切片），索引与 id 正式解耦——删除中间 Mode 留 gap 不重排，消费方 awk 动态拿 actual slot。详见 §1.4.1 索引规范方案 B。

#### D3: data-skip-save 通用机制 vs 设计文档的 data-stale
- **症状**：设计文档 §8 通用 select 约束讲 `data-stale="1"` 模式（save() 时跳过 dbus 覆盖）。C 实现的是更通用的 `data-skip-save="1"` 属性，save() 收集循环检测此属性跳过。
- **alpha 决议**：通用化是改进，**接受**。在本文档备注以便后续 ASP 改造遵循同一机制。

#### D4: ss_split_runtime_status / ss_split_enabled_state 是 C 内部状态
- **症状**：C asp 引入了 `ss_split_runtime_status` / `ss_split_enabled_state` 两个 key 不在合同 §1。
- **审查结论**（Reviewer 3）：纯 DOM `<span id=>`，仅 `.html()` 渲染，**未** `dbus set`。属命名巧合，无需进合同。

#### D5: dnsmasq 让位 65355 未接线（**✓ doge.13 beta 兑现，方案 C-2 而非 pc_insert**）
- **alpha 历史**：ssconfig.sh 定义 `SS_SPLIT_DNS_LAN_PORT="65355"`，chinadns conf 把 LAN 域名 group-upstream 指向 127.0.0.1#65355，但无代码让 dnsmasq 实际 listen 65355。alpha 降级 WARN。
- **doge.13 beta 兑现（方案 C-2：独立 dnsmasq_lan 子实例）**：**不动**主 dnsmasq（保留它在标准 53/UDP 服务路由器自身名解析与广播 LAN 客户端），新起一个独立 `dnsmasq_lan` 子实例占 127.0.0.1:65355，仅服务 chinadns 回查"LAN 域名"的 split path。
  - 实施位置：`ssconfig.sh::start_chinadns_ng_split`（启动子实例）/ `stop_chinadns_ng_split`（回收）；
  - **与原计划的差异**：原 doge.13 计划走 `postscripts/dnsmasq.postconf` 改主 dnsmasq listen 到 65355（"pc_insert port=65355"方案），但实施期评估发现改主实例 listen 会破坏路由器自身名解析、增加跟 asus 系统脚本耦合的风险；改走独立子实例方案，零侵入主 dnsmasq。
  - 旧方案描述（pc_insert port=65355）**已废弃**，本条记入修订记录。

#### D6: ACL 清空连带删 ss_acl_split_mode_* （~~审查发现 → alpha WARN~~ → **2026-05-18 实测为误报，无需修复**）
- ~~**症状**：现有 `ssconfig.sh::clean_acl()` 有 `dbus remove ss_acl_mode`（前缀匹配），新迁移的 `ss_acl_split_mode_<i>` 在用户点 ACL 清空按钮时会跟着被删。~~
- ~~**alpha 决议**：alpha 阶段 ss_split_enabled=0 默认关，影响有限。doge.13 默认开后，把 `clean_acl()` 改为显式 `dbus remove ss_acl_mode_` (加下划线)，避免前缀串到 `ss_acl_split_mode_*`。~~
- **2026-05-18 实测结论**：审查阶段拍脑袋假设错了 `dbus remove` 的语义。**`dbus remove KEY` 是精确匹配，不是前缀匹配**（只有 `dbus list KEY` 是前缀）。测试机对照实验：`dbus set ss_test_dbg_a=foo / ss_test_dbg_b=bar / ss_test_dbg_ab=baz`，`dbus remove ss_test_dbg_a` 只删 `_a`，`dbus remove ss_test_dbg`（无后缀）**什么都没删**。
- **附带发现**：[ssconfig.sh:6712-6718](../../fancyss/ss/ssconfig.sh#L6712) 那 7 行 `dbus remove ss_acl_ip` / `_mac` / `_name` / `_mode` / `_port` / `_udp` / `_quic` 是上游 fancyss 多年的**死代码 no-op**——试图删字面 key `ss_acl_ip` 等（不存在），真正的 `ss_acl_ip_<i>` 完全不受影响。无害但也无效。alpha 阶段不动它（不在本次工作范围）。
- **`ss_acl_split_mode_<i>` 双重安全**：(1) `dbus remove` 不是 prefix；(2) 就算它是 prefix，`ss_acl_split_mode_<i>` 也不以 `ss_acl_mode` 开头（中间 `_split` 隔开），不会被串到。

#### D7: fss_chain_apply 与 split 路径下 out_main tag 兼容性（**alpha.15 注释修正 + alpha.18 W6 dead branch 删除 + ✓ doge.13 beta per-rule chain dialerProxy 已收敛**）
- **alpha 历史**：B 的 `generate_xray_json_split` 把基线 outbounds[0].tag 改为 `out_main`，担心 fss_chain_apply 按 tag 匹配会断；alpha.15 注释修正（D10 顺手做的事）澄清"split 路径下 generate_xray_json_split 只动主 outbound tag + 追加 direct/reject，不注入链式；链式由 fss_chain_apply 唯一一次注入到 out_main"。
- **alpha.18 W6**：[L5504-5508 dead if/else 删除](../../fancyss/ss/ssconfig.sh#L5504)（split=0/1 两分支调用相同 fss_chain_apply）。
- **doge.13 beta 收敛**：主节点链式（fss_chain_apply 注入到 out_main）正常工作；**per-rule chain outbound dialerProxy 注入已闭环** —— `fss_split_build_node_outbound_json` 函数签名已由 3 参扩到 4 参（新增 `dialer_tag`），jq 注入 `streamSettings.sockopt.dialerProxy=chain_front_<Y>`，与 [ssconfig.sh::generate_xray_json_split L5598](../../fancyss/ss/ssconfig.sh#L5598) chain build 循环对齐。详见 §6.1 "ssconfig.sh 路由层" `proxy_chain:Y:X` 兑现段。

#### D8: ss_acl_split_mode_<i> per-MAC 路由层（**端口分配 gate doge.13 beta 兑现 + 真机三 MAC 验证仍待**）
- **症状**：合同 §1.4 定义 `ss_acl_split_mode_<acl_node>` = 该 acl 行分配的 Mode.id（0=不通过代理）。alpha.10 起 `load_iptables_split` 已加基础装配（per-MAC TPROXY + per-MAC DNS DNAT），alpha.18 ACL UI 写者侧也已兑现（save() 翻译 + delTr 清零）。
- **端口分配 gate（doge.13 beta 兑现）**：alpha 阶段 `__split_mode_port_by_id` / `__split_mode_dns_port_by_id` 循环 gate 是 `if (is_default || builtin)`，用户自定义 Mode 静默退化到默认端口。**doge.13 beta 删除 gate**：
  - 改为 `__split_active_mode_indices` 动态枚举所有写入 dbus 的 Mode slot（通过 `dbus list ss_split_mode_` awk 切片）；
  - 按 active_indices 顺序分配端口偏移，用户自定义 Mode 拿到独立端口（不再 collapse 到默认 Mode 端口）；
  - `load_iptables_split` per-MAC 段同步消费 active_indices，避免读到尚未装配的 Mode slot。
- **仍待 doge.13 收尾**：
  - **真机三 MAC 验证**：default + builtin + user-defined Mode 三条路径独立工作（alpha 阶段从未跑过 per-MAC 多分支真机）；
  - **ACL UI select 扩展**：alpha.18 写者侧用保守的翻译规则（0/5/* → 0/1/2），ACL UI 仍只有旧 6 个 option，用户不能从 ACL 直接选自定义 Mode；
  - **iptables 规则顺序 / fallback 链优先级**：真机暴露的细节 bug 一并修。
- 修复后同步删除本条 D8（端口分配 gate 解除部分已完成，剩余条目跟随 doge.13 真机验收）。

#### D9: `ss_split_rule_to_json` 必须文件中转，不能走 stdout / 变量（**alpha.13 + alpha.14 修订，已落地**）
- **症状（alpha.13 ARG_MAX）**：alpha.12 修好 hot reseed 后，Rule 1（大陆白名单_常用）文件首次出现真实内容（chnlist 11 万行）。`ss_split_rule_to_json` 把 ~1.6MB JSON 通过 `rdata=$(ss_split_rule_to_json ...)` 灌进 shell 变量，紧接着 [ssconfig.sh:5359-5361](../../fancyss/ss/ssconfig.sh#L5359) 三处消费（`[ -n "${rdata}" ]` / `[ "${rdata}" != "{}" ]` / `printf '%s' "${rdata}" | jq`）全部踩 busybox `[` 内置 ARG_MAX (~128KB) → restart 永久 hang。alpha.11 没爆是因为 Rule 1 文件丢失走 `{}` 短路；alpha.12 hot reseed 修文件 → 暴露这个 latent bug。
- **症状（alpha.14 性能）**：alpha.13 修好 ARG_MAX 后 awk 处理 chnlist 11 万行 + cn.txt 1 万 IP 单次 37.5s。根因：原 awk END 块用 `ip_buf = ip_buf "..."` 字符串累加，每 append 拷贝整段 buffer → O(n²) 复杂度。用户实测 50s "卡住"的根因。
- **修法（alpha.13）**：`ss_split_rule_to_json` 加 `outfile` 必传参数（无 stdout fallback），全程文件中转 + 上层用 `jq --slurpfile` 读文件流式输出 routing_rules_file；`ss_split_rule_to_json` 输出 `{}` 而非空时，jq 用 `if length>0 then ... else empty end` 防空 rule 文件 shadow 兜底（V1-reviewer 发现）。
- **修法（alpha.14）**：awk 内 ip 行 streaming 写到临时文件 `${outfile}.iptmp`，END 块 `close()` 后 `getline` 拼回主输出。Domain 路径无需改（本来就是 streaming printf 不累加）。实测 37.5s → 3.88s（9.7x 提升），用户实测 50s hang → 15s 启动完成。
- **附带事实（为什么不能 stdout fallback）**：hnd_v8 busybox 1.25 路由器 `/dev/stdout` 不存在（实测）—— 函数若默认 `outfile=/dev/stdout`，空 outfile 参数会被当物理文件路径写到 `/dev/` 下产生垃圾文件。alpha.13 dry-run 实测后写死 outfile 必传，无 fallback。
- **已落地版本**：alpha.13（文件中转 + jq empty 兜底）/ alpha.14（awk O(n²) → O(n) streaming）。详见 [ssconfig.sh:4960-5024](../../fancyss/ss/ssconfig.sh#L4960) 函数体注释。

#### D10: chinadns-ng `group-tag-noip` 是伪语法，DNS 层 reject 整套删除（**alpha.15 修订，已落地**）
- **症状**：doge.12 alpha 实施期"凭直觉"给 chinadns-ng 加 `group-tag-noip` 选项来实现 DNS 层 reject（让 reject 域名返回空 IP）。V1-reviewer 拿源码 `zfl9/chinadns-ng/src/opt.zig` 实证 grep 不到该选项 —— 完全是 doge.12 alpha 自己发明的伪语法。一旦用户在 Mode 配 action=reject rule → `reject_file` 非空 → chinadns-ng 启动时遇未知选项 exit(1) → DNS 实例全挂 → 整个分流 DNS 路径瘫痪。
- **为什么没炸**：默认两个内置 Mode 都没有 reject rule，`[ -s reject_file ]` 守卫短路。这是个潜伏地雷，等第一个 alpha 用户配 reject rule 就触发。
- **修法**：删 DNS 层 reject 整套（-75 行）：
  - `ss_split_collect_reject_domains` 函数整删
  - `generate_chinadns_split_conf` / `generate_chinadns_global_conf` 中 `group reject` 配置块整删
  - `stop_chinadns_ng_split` 中 `rm /tmp/fss_split_reject_dnl.txt` 整删
  - [ssconfig.sh:2151-2155](../../fancyss/ss/ssconfig.sh#L2151) / [ssconfig.sh:2256-2259](../../fancyss/ss/ssconfig.sh#L2256) 注释保留"为何删"的实证说明（grep zfl9/chinadns-ng 源码无该选项）
- **reject 语义改由 xray blackhole outbound 接管**：`generate_xray_json_split` 注册 `out_reject` outbound (blackhole) + routing.rules 中 action=reject → outboundTag=out_reject。该接管路径在 alpha.14 之前就已就位（[ssconfig.sh:5031](../../fancyss/ss/ssconfig.sh#L5031) / [ssconfig.sh:5163](../../fancyss/ss/ssconfig.sh#L5163) / [ssconfig.sh:5239](../../fancyss/ss/ssconfig.sh#L5239)），所以删除 DNS 层 reject **没有功能损失**，只是消除潜伏地雷。
- **顺手做的事**：[ss_proc_status.sh:264-326](../../fancyss/scripts/ss_proc_status.sh#L264) 加 3 个 helper（`GET_CHAIN_PROXY_STATUS` / `GET_SPLIT_V2_STATUS` / `GET_DIRECT_ASUSGO`）+ `check_status` 加 3 行 echo，方便用户在 Web UI 状态页一眼看到 split V2 是否启用 / 主节点链式状态 / 直连白名单状态。
- **修正注释**：[ssconfig.sh:5465](../../fancyss/ss/ssconfig.sh#L5465) 链式代理注释（V3-reviewer 发现"split × chain 关系"原描述误导，已改为"split 路径下 generate_xray_json_split 只动主 outbound tag + 追加 direct/reject，不注入链式；链式由 fss_chain_apply 唯一一次注入"）。
- **已落地版本**：alpha.15。注释保留在 ssconfig.sh 同位置防止后人重蹈覆辙。

#### D11: Mode 级 `block_quic` / `udp_proxy` 写者写满、读者 0 人（**alpha.16 修订，已落地**）
- **症状**：alpha 实施期 ASP UI 复选框 + dbus key（`ss_split_mode_<m>_block_quic` / `ss_split_mode_<m>_udp_proxy`） + `install.sh::write_builtin_mode_meta` 写入默认值，**全链路写者完整**；但 `ssconfig.sh::load_iptables_split` 装配 per-user TPROXY 时**完全不读这两个 key**。生成 xray inbound 时 [ssconfig.sh:5210](../../fancyss/ss/ssconfig.sh#L5210) 有一行 `local block_quic=$(dbus get ss_split_mode_${mi}_block_quic)` 但变量未使用（dead local），紧跟一行注释"block_quic 不在 inbound 控制；走 iptables 层屏蔽 udp/443" —— 实际从没写过 iptables 层 DROP。
- **后果**：用户在 Mode 编辑 UI 勾选"屏蔽 QUIC" / 取消"UDP 代理"完全 no-op。QUIC 流量绕过 SNI 嗅探直奔代理；UDP 强制走 TPROXY 无法关闭。
- **修法**：`load_iptables_split` 加 2 个 helper（[__split_mode_block_quic_by_id](../../fancyss/ss/ssconfig.sh#L7102) / [__split_mode_udp_proxy_by_id](../../fancyss/ss/ssconfig.sh#L7123)）按 mode_id 反查 dbus key。per-user TPROXY 循环之前按 Mode 决定：
  - `block_quic=1` → 加 `-p udp --dport 443 -m mac --mac-source <mac> -j DROP`（放在该 user 的 TPROXY 之前，iptables 顺序敏感）
  - `udp_proxy=0` → 跳过该 user 的 UDP TPROXY（UDP 落原生路由 = 直连）
  - default fallback 同样消费（对未在 acl 表中列出的设备生效）
- **未删的"占位注释"**：[ssconfig.sh:5210](../../fancyss/ss/ssconfig.sh#L5210) 那行 dead `local block_quic=$(...)` 和注释保留不动 —— 这是 xray inbound 层的"标记我们考虑过 QUIC 但 inbound 不是合适层"的痕迹，删除会丢失这条决策记录。真正的 block_quic 实现在 alpha.16 接到了 iptables 层 ([L7212-7218](../../fancyss/ss/ssconfig.sh#L7212) / [L7232-7237](../../fancyss/ss/ssconfig.sh#L7232))。
- **alpha 实施期反模式教训**：写者（UI + dbus + install 默认值）写满了，读者（路由层）是空的。alpha 实施期文档化"以后兑现"的占位注释（"走 iptables 层屏蔽" / §6.1 line 236 "doge.13 加 iptables -A SHADOWSOCKS -p udp --dport 443 -j DROP"）而非真正接通。**doge.12-stable 收尾前应该全仓库 grep 一次 `ss_split_mode_*_` / `ss_split_rule_*_` dbus key，检查每个 key 都有真实消费者** — 这次 alpha.16 是 manual 发现的，下次靠工具。
- **已落地版本**：alpha.16。

#### D12: Split Mode 2 rule actions 烘焙 stale 节点 ID（**✓ doge.13 beta 兑现，选方案 A sentinel**）
- **alpha 历史**：install.sh::migrate_split_routing_v1 把当前 `ssconf_basic_node` 编码成具体 `proxy_node:<N>` / `proxy_chain:<front>:<N>` 烘焙到 Mode 2 rule_5/rule_6 action，主节点变更后 dbus 残留 stale。
- **doge.13 beta 兑现（方案 A sentinel）**：
  - **install.sh 写入端**：迁移阶段写 `proxy_main` 字面量而非具体 node ID（覆盖 Mode 1/2 default_action + Mode 2 rule_5/rule_6 action 共 4 处）；
  - **ssconfig.sh::ss_split_action_to_tag 解析端**：xray 生成器遇 `proxy_main` 时实时查 dbus `ssconf_basic_node` / `ssconf_basic_node_front` 转译为 `out_main` tag；
  - **ASP action select**：新增 `proxy_main` option（默认值），UI 默认写入 `proxy_main` 而非具体节点；
  - **Mode helper (`ss_split_mode_save.sh`)**：接受 `proxy_main` 字面量 + 校验通过；
  - action 编码格式见 §1.5（已加 `proxy_main`）。
- 顺手合并 §6.2 D15（空 cur_node trailing colon），install.sh cur_action 改为单行 sentinel 后空节点场景自然解决。

#### D13: `fss_chain_apply` 在 `ss_basic_mode=7` 时静默 fallback（**✓ doge.13 beta 兑现，ASP preflight 已实施**）
- **alpha 历史**：ss_basic_mode=7 与 ss_split_enabled=1 混合状态下 fss_chain_apply 内部 return 0 + 设 ss_chain_status=fallback，链式静默失效，alpha 用户无 UI 提示。
- **doge.13 beta 兑现**：[Module_shadowsocks.asp `#ss_split_enabled change handler`](../../fancyss/webs/Module_shadowsocks.asp) 加 preflight：用户尝试启用 `ss_split_enabled=1` 时检查 `ss_basic_mode==="7"`，触发 **hint 221**（三按钮弹窗：取消 / 仅启用 split 保留 mode=7 / 同时切换 mode→0）。用户主动选择路径，无静默失效。
- doge.14 物理移除旧路径后本问题自然消失，hint 221 届时可下线。

#### D14: 订阅删除节点不清理 split rule action 引用（**✓ doge.13 beta 兑现**）
- **alpha 历史**：collect_node_reference_delete_impact 只扫 failover combos 和 mode=7 shunt，不扫 split rule action 里的节点引用，订阅刷新或手动删节点会留下 stale ID。
- **doge.13 beta 兑现**：
  - **ASP `collect_node_reference_delete_impact` 扩展**：加 `splitRules` 数组扫所有 `ss_split_mode_*_rule_*_action` 模式（含 default_action / rule action）；
  - **ASP `match_split_action_node(action, deletedId)` helper**：解析 action 字符串（区分 `proxy_node:<N>` / `proxy_chain:<Y>:<N>` / `proxy_chain:<N>:<Z>`），返回角色（landing / front / both）；
  - **`process_schema2_node_delete_queue` 合入**：landing 被删 → 该 rule action 改 `proxy_main`（与 D12 sentinel 方案统一）；front 被删 → `proxy_chain:Y:Z` 降级为 `proxy_node:Z`；front == landing → action 改 `proxy_main`。

#### D15: `cur_node` 空时 install 烘焙 `"proxy_node:"`（trailing colon）（**✓ doge.13 beta 兑现，与 D12 合并**）
- **alpha 历史**：install.sh::migrate_split_routing_v1 cur_action 构造无空节点防御，全新安装时写 `"proxy_node:"` 进 4 处 dbus key。
- **doge.13 beta 兑现**：与 D12 sentinel 方案统一——install.sh cur_action 改为单行 `cur_action="proxy_main"` 字面量，不再依据 `ssconf_basic_node` 内容判断；空 cur_node 场景自然不再产生 trailing colon。Mode 1/2 default_action / Mode 2 rule_5/rule_6 action 4 处全部写 `proxy_main`。

> **D12-D15 共性（doge.13 beta 全部兑现）**：四条 latent issue 都在 alpha 阶段被 generate_xray_json_split 的 `out_main` collapse 掩盖。doge.13 beta 解除 collapse（per-rule 独立 outbound 构建）的同时兑现 D12 sentinel + D13 ASP preflight + D14 节点删除清理 + D15 空节点 → proxy_main（与 D12 合并）；四条形成"一组完整修订包"。

#### D16: LAN DNS 在 mangle+nat PREROUTING 双跳被 xray FakeUDP 抢 65353（**✓ doge.13 beta.4 兑现**）
- **beta.3 用户报现象**：装包后 LAN 客户端 (Ubuntu 192.168.51.2) DNS 全 5s timeout / curl 任何网站 HTTP 000，但 SSH 到路由器本机用 dnsclient @127.0.0.1:65353 解析正常。
- **根因（实地 + xray-core upstream 实证）**：
  1. iptables `mangle PREROUTING` (NF_PRI=-150) 跑在 `nat PREROUTING` (-100) **之前**
  2. LAN UDP dport=53 进 mangle SHADOWSOCKS 时 dst 还是原 DNS server（`8.8.8.8:53` 等）
  3. mangle SHADOWSOCKS 命中 TPROXY rule → 重定向给 xray inbound mode_2 @ 13334
  4. **接着** nat PREROUTING SHADOWSOCKS_DNS_0 把 dst DNAT 成 `127.0.0.1:65353`
  5. xray 拿到 packet，看 `back addr` (transparent destination) = `127.0.0.1:65353`
  6. xray routing 命中 `127.0.0.0/8 → out_direct` → freedom UDP outbound
  7. xray freedom UDP 调 `FakeUDP()`（[xray-core/proxy/freedom/fakeudp_linux.go](https://github.com/XTLS/Xray-core)），用 IP_TRANSPARENT + bind 绑 `127.0.0.1:65353` 作为返回客户端的 source addr
  8. 跟 chinadns split listen socket 通过 SO_REUSEPORT 共享端口 → 内核 round-robin 部分 LAN DNS 包被 xray 截走但 xray 不读（recv-Q 持续涨）→ 客户端 timeout
- **实地证据**：beta.3 上 LAN 50 个 DNS query → xray 在 `127.0.0.1:65353` 累积 ~50 个 UDP socket，recv-Q 最大 72KB 排队
- **修法（[ssconfig.sh::load_iptables_split](../../fancyss/ss/ssconfig.sh) ~line 7494 之前）**：DNS 劫持开启时，dport 53 流量在 mangle SHADOWSOCKS 入口就 RETURN，不进 TPROXY；nat PREROUTING DNS 劫持 DNAT 再把它转给本机 chinadns 正常解析。
  ```sh
  if [ "${ss_basic_dns_hijack}" = "1" ]; then
      append_if_not_exists mangle -A SHADOWSOCKS -p udp --dport 53 -j RETURN
      append_if_not_exists mangle -A SHADOWSOCKS -p tcp --dport 53 -j RETURN
  fi
  ```
- **实地验证（修前 vs 修后）**：50 LAN DNS query → 修前 OK=0 BAD=50 / xray 占 65353 ~50 socket，修后 OK=50 BAD=0 / xray 占 65353 = 0 socket，curl 5 站全 200 OK。
- **修法同步到老路径**（[ssconfig.sh::_start_iptables](../../fancyss/ss/ssconfig.sh) `ensure_chain mangle SHADOWSOCKS` 之后）：老路径 `ss_split_enabled=0` 同样有 TPROXY UDP rule（SHADOWSOCKS_GFW/CHN 等 sub-chain 各 TPROXY 到 port 3333）+ nat DNS 劫持 DNAT 到 chinadns-ng 单实例，钩子顺序的 race 完全等价。补丁结构一致：
  ```sh
  if [ "${ss_basic_dns_hijack}" = "1" ]; then
      append_if_not_exists mangle -A SHADOWSOCKS -p udp --dport 53 -j RETURN
      append_if_not_exists mangle -A SHADOWSOCKS -p tcp --dport 53 -j RETURN
  fi
  ```
  这条修订意义重大：**老用户即使不切 V2 分流也会受益**（用户报告 daily router 跑 ss_split_enabled=0 + DNS hijack 时 PC 主网卡 DNS 经过该路由器解析也偶发卡死）。
- **未尽事项（doge.14 IPv6 build-out 注意）**：`SHADOWSOCKS6` chain 当前无 IPv6 split 路径，所以 D16 IPv6 mirror 暂不需要；未来给 split 加 IPv6 时必须同步加 ip6tables RETURN 规则。
- **教训写入 CLAUDE.md 硬规则 #19**：iptables hook priority 影响 mangle/nat 跑序：raw(-300) → conntrack(-200) → mangle(-150) → nat-dst(-100) → routing。**新增 DNS 劫持 DNAT 之类"改写 dst"的 nat 规则前，必须审计 mangle PREROUTING 是否会先看到原 dst 后做出错误判断**（TPROXY、ipset 命中等）。

### 6.3 D17+ doge.14 物理删除收尾（**已落地**）

doge.14 sprint Phase 1+2+3 共物理删除 ~3310 行，让分流架构成为唯一路径。本节按"删除项 → 关联 audit 段 → 真机验证 → 留 WARN"维度记录。详细 audit 在 [../design/doge14-deletion-scope-audit.md](../design/doge14-deletion-scope-audit.md)（archive 状态）。

#### D17: 总开关 `ss_split_enabled` 物理移除（audit §A）

- **删除范围**：
  - `migrate_split_routing_v3` step 4：`dbus remove ss_split_enabled`（清存量值）
  - ssconfig.sh 6 处 fork else 分支（L1653-1657 DNS 启动 / L5739-5748 xray json / L6366-6369 ipset 清空 / L7267-7270 iptables 加载 / L8699-8701 ipset 创建 / L9010-9015 chinadns 重启）
  - ssconfig.sh L8775-8788 诊断日志（绿色直接删）
  - install.sh L519 / L729-730 文档注释清理 + L2604 `dbus set ss_split_enabled="1"` 状态读取删除
  - ASP `Module_shadowsocks.asp` L6850-8601 范围内 5 个 JS handler（`ss_split_enabled` change + UI 同步）
- **新代码原则**：新加路由层代码直接面向 split 路径，无需 `if [ "${ss_split_enabled}" = "1" ]` fork 入口。

#### D18: `ss_basic_mode=7` xray 节点分流整套退役（audit §B + §C）

- **migrate_split_routing_v3 step 1**：存量 `ss_basic_mode=7` → `2`（大陆白名单），`ss_acl_mode_<i>=7` → `2`（一次性、幂等）。
- **ssconfig.sh 13 处 case 分支删除**：L245 / L1393 / L1988-91 / L2017 / L3631 / L3703-18 / L5753 / L5763-65 / L6543 / L6617 / L6647 / L8770 + **L8708-8731 `creat_shunt_json` 函数体改 no-op return 0**（dead code，标注 doge.15 物理删整函数）。
- **scripts/ 5 处环境检测清理**：`ss_base.sh:68/137/140/143`（mode=7 环境检测）+ `ss_chain_proxy.sh:212`（chain proxy fallback）+ `ss_node_shunt.sh:154`（自检）+ `ss_shunt_stats.sh:352`（自检）+ `ss_node_subscribe.sh:3627`（mode=7 订阅逻辑）。
- **ASP select 物理删除**：`<select id="ss_basic_mode">` 中 mode=7 option 物理 remove（含 stale 占位）；存量值已被 migrate_v3 迁出。
- **保留 stub 期 + 物理删的 2 阶段策略**：Phase 1+2 把 `ss_node_shunt.sh` 整文件 stub 化到 43 行（export func 全 return 0），等 1 周真机验证无任何用户卡老路径；Phase 3 / doge.14 stable 整文件物理删 + 3 个 sourcer 调用点删（`ss_base.sh:16-17` / `ss_node_postsave.sh:6` / `ss_shunt_hot_reload.sh:4`）。

#### D19: `ss_node_shunt.sh` 整文件物理删除（audit §C）

- **整文件大小**：2121 行（比早期 handoff 估算 600 偏高 3.5×）。
- **Phase 1+2 中间态**：stub 化到 43 行（保留文件名 + export func 改 `return 0`），避免 `source` 调用点立即报错。
- **Phase 3 终态**：整文件物理删除，3 个 source 调用点（`scripts/ss_base.sh:16-17` / `scripts/ss_node_postsave.sh:6` / `scripts/ss_shunt_hot_reload.sh:4`）同步删除。`ss_shunt_stats.sh` / `ss_shunt_hot_reload.sh` 整文件也物理删除（dead）。

#### D20: 老 `start_chinadns_ng()` 单实例 + 老 iptables 老分支移除（audit §D + §E）

- **`start_chinadns_ng()` 单实例**（L2517-2790 约 275 行）整段删除；调用方 ssconfig.sh L1656 / L2465 / L2473 / L9014 同步删（保留 `start_chinadns_ng_split` 和 `stop_chinadns_ng_split` V2 双实例路径）。
- **`load_iptables()` 老分支**（L7265-7293 约 35 行）+ **`flush_ipset()` 老分支**（L6370-6435 约 70 行）+ **`apply_ss()` fork 入口**（L8699-8701 约 3 行）整删；保留 `load_iptables_split` / `flush_ipset_split`。
- **D16 老路径残留 bug 一并消失**：beta.4 修的 LAN DNS hijack mangle PREROUTING RETURN 只覆盖了新路径；老路径同款 race 在 doge.14 物理删除时自然消失。

#### D21: 老 [DNS 设置] section + 40+ `ss_basic_chng_*` dbus key 退役（audit §F）

- **ASP `Module_shadowsocks.asp:18353-18428` 约 95 行老 DNS section 物理删除**（含 27 个 input + 6 个 select / checkbox + 8 个 IPv6 设置 + JS handler L10056-10084 + `params_input` 数组 L8494-8496 引用）。
- **`migrate_split_routing_v3` step 2**：`dbus remove` 40+ 个老 key（`ss_basic_chng_china_dns_1/2/3_*` / `_trust_dns_1/2/3_*` / `_china_udp/tcp/dot_*_opt/usr` / `_ipv6_drop_direc/proxy` 等）。
- **新 DNS upstream 由 §1.6.1 系列 key 唯一管理**：`ss_split_dns_china_upstream` / `_overseas_upstream` / `_global_upstream`。

#### D22: hint 220 / 221 退役（audit §G）

- `ss-menu.js` hint 220 定义 L1247-1257 + hint 221 定义 L1258-1271 物理删除（共 25 行）。
- ASP `openssHint(220)` 触发点 L7747 / L7758 / L7795-96 + `openssHint(221)` 触发点 L7771 物理删除。
- `ss_split_enabled` 总开关物理移除后所有触发条件不存在，hint 220/221 在 doge.14 起完全无可达路径。

#### D23: `migrate_split_routing_v3` 设计（实施合同 §1.1 `fss_doge14_migrated` 幂等标志）

```sh
migrate_split_routing_v3() {
    [ "$(dbus get fss_doge14_migrated)" = "1" ] && return

    # Step 1: mode=7 → mode=2 一次性迁移
    [ "$(dbus get ss_basic_mode)" = "7" ] && dbus set ss_basic_mode="2"
    for acl_row in $(iter_acl_rows); do
        [ "$(dbus get ss_acl_mode_${acl_row})" = "7" ] && dbus set ss_acl_mode_${acl_row}="2"
    done

    # Step 2: 老 ss_basic_chng_* dbus key 全清（40+ key）
    dbus list ss_basic_chng_ | cut -d= -f1 | while read k; do dbus remove "$k"; done

    # Step 3: ss_node_shunt_* dbus key 全清
    dbus list ss_node_shunt_ | cut -d= -f1 | while read k; do dbus remove "$k"; done

    # Step 4: ss_split_enabled 总开关物理移除
    dbus remove ss_split_enabled

    # Step 5: 落幂等标志
    dbus set fss_doge14_migrated="1"
}
```

#### D24: 真机验证 PASS 清单（详见 audit §M.4）

| 项 | 结果 |
|---|---|
| migrate_v3 mode 7→2 | ✅ 日志 `ss_basic_mode 7 → 2（节点分流已退役）` |
| ss_node_shunt_* 全清 | ✅ 2 个伪装 key 全 dbus remove |
| ss_basic_chng_* 全清 | ✅ 85 个真实 key 全 dbus remove |
| ss_split_enabled 清 | ✅ `dbus get ss_split_enabled` 返回空 |
| fss_doge14_migrated=1 | ✅ |
| rules_user 保护 fix 触发 | ✅ 用户自定义 Rule (rule_100+) 文件未丢 |
| xray pid 监听 4 端口 | ✅ 23456 + 13333 + 13334 + 13335 |
| chinadns 双轨 | ✅ split @65353 + global @65354 |
| split iptables 装配 | ✅ default_mode=100 default_port=13335 |
| 51.2 LAN curl 出口 | ✅ `3.9.92.164`（Mode #3 default_action 出口） |

#### D25: 真机暴露 + 修复的 2 个老 BUG（不属 doge.14 引入，doge.14 顺手修）

- **`install.sh:2348 rm -rf /koolshare/ss/*` 把 rules_user/ 清掉（doge.13 老 BUG）**：升级时所有用户自定义 Rule 文件（rule_100+.txt）会被 `rm -rf` 清光，自愈只重建内置 1~8。这不是 doge.14 引入，但 doge.14 后是唯一路径所以严重性放大。**修法**：rm 前 `cp -af rules_user/. /tmp/__fss_rules_user_backup_doge14/`，rm 后 restore。
- **`ss_split_rule_seed.sh` syntax error（base.sh alias 干扰）**：busybox sh + `alias echo_date='...'` + 后续 `echo_date(){...}` function 定义 = parse 时 alias 展开 → syntax error。**修法**：function 定义前 `unalias echo_date >/dev/null 2>&1`。CLAUDE.md 硬规则 #21 候选（未来共享 helper 文件 source 多上下文时必须先 unalias）。

#### D26: Reviewer 留 WARN（doge.14 stable 清完）

详见 audit §N.3。

- **W1**：install.sh:516-518 + 723-725 历史注释指向 migrate_v3 step 3
- **W3**：ASP 11 处 mode=7 真业务逻辑分支（audit §B 漏列，需扫一遍）—— L2021 / L2023 / L4158 / L4161 / L6563 / L6590 / L8242 / L8480 / L8502 / L8521 / L8905 / L12935 / L17185
- **W4**：ss_shunt_stats.sh:354+ 80 行 dead code（已在 D19 物理删时清理）
- **I5**：`params_input` 数组 L8303-8317 仍含 14 个 `ss_basic_chng_*` 字段引用（save() 写空 → install 又删，无害但 noisy）
- **L1605 / L2588**：ssconfig.sh 老 `chng_chk` → UDP relay 检测 dead path

#### D27: UDP/STUN 不走白名单直连 — domain+ip 合写一条 rule 的 AND 陷阱（doge.14-beta.5 修复）

2026-06-17 用户报 WebRTC 泄露检测里国内 STUN 也显示代理 IP。51.1 实证根因 + 修复：

- **根因**：`generate_xray_json_split`（ssconfig.sh）per-Rule emit 把每条 Rule 的 `domains` 与 `ips` 写进**同一条** xray routing rule（`{domain:[...],ip:[...],outboundTag}`）。xray 同一 rule 内多 matcher 是 **AND**：UDP（STUN/WebRTC 等）无可嗅探域名 → `domain` 条件恒 false → 整条 rule miss → 落兜底。「大陆白名单」= chnlist 域名 + cn.txt 中国 IP 合写一条 → 国内 STUN（stun.miwifi.com → 111.206.174.x，IP 在 cn.txt 的 `111.192.0.0/12` 内）UDP 走代理；国内网页 TCP 有嗅探域名能命中 domain 故正常，掩盖了 bug。
- **51.1 四象限实证**：修前 miwifi STUN reflexive = 代理 `86.53.160.85`；加 ip-only rule 后 = 真实 `123.158.55.243`（浙江联通）。修后国内 TCP/UDP 直连、海外 TCP/UDP 代理全部正确，无回归。
- **修复**：per-Rule emit 拆成两条独立 rule（domain-only + ip-only，同 outboundTag）。顺带修好「白名单只有 IP 无域名」条目（AND 下也曾失效）—— 对齐"白名单内 IP **或** 域名走直连"的预期。
- **实现踩坑**（armv7l busybox，大陆白名单 domain 11 万 / domain rule ~2MB 单行）：① `map(tojson)|join` → tojson 复制 2MB 串 OOM 被 Killed → emit 截断 → `jq_merge_failed` 回退基线；② `jq -c` 流式 + `while read` → busybox read 截断 2MB 单行变量 → 同样损坏；③ ✅ 两次独立 `jq -c '… else empty end'` + `cat`（cat 不受行长限制）。
- **影响面**：所有"域名+IP 混排"的 Rule（大陆白名单、Telegram 等）的无域名 UDP；全局黑白名单(`ss_wan_white_domain`)按设计仍 domain-only，不受影响；webtest 路由只用 inboundTag→outboundTag 无 domain/ip matcher，不受影响。

### 6.4 实施期约定的回溯修订

**alpha 阶段（doge.12.alpha-1 → alpha.18）**：
- 合同 §0 "alpha 不物理删除旧 key" — 由 A 完全遵守 ✓
- 合同 §4.1 "硬规则 #2 asp 编码" — 由 C 完全遵守 ✓（BOM+CRLF 字节级验证通过）
- 合同 §4.1 "硬规则 #3 hint id 200+" — C 使用 210-218 ✓
- 合同 §4.1 "硬规则 #9 select stale 占位" — C 用 data-skip-save 通用化实现 ✓
- 合同 §4.4 "不打包不发版" — 4 个 subagent 全部遵守 ✓
- 合同 §4.2 "不动 rules_ng2" — 全部遵守 ✓
- 合同 §4.2 "不删 ss_node_shunt.sh" — 全部遵守 ✓

**doge.13 beta 新增**：
- 合同 §4.2 "ssconfig.sh fork-not-replace" — doge.13 路由层改造仍遵守（generate_xray_json_split / __split_mode_port_by_id 等 split 路径函数独立，旧路径 byte-for-byte 保留） ✓
- 合同 §4.2 "不删现有 dbus key" — `migrate_split_routing_v2` 把老 DNS upstream 切到新 key 时**保留**老 key 作 fallback ✓
- 合同 §4.1 "硬规则 #3 hint id" — doge.13 beta 用 hint 221（D13 preflight），与 alpha 210-218 不冲突 ✓
- 合同 §4.1 "硬规则 #1 ss_* 前缀" — `ss_split_node_outbound_count` / `ss_split_chain_outbound_count` 等诊断 key 沿用 ss_ 前缀；`fss_split_xray_warn` / `fss_split_migrated_v2` 后端 hot 状态用 fss_ 前缀 ✓
- 合同 §4.2 "不动 ss_node_shunt.sh" — doge.13 beta 仍未动 ss_node_shunt.sh，留 doge.14 物理移除 ✓

**doge.14 stable（本阶段）**：
- 合同 §4.2 "doge.14 唯一路径" — Phase 1+2+3 全部兑现 ✓
- 合同 §4.1 "硬规则 #14 fork-not-replace 旧路径" — 由 D17 物理移除收尾，旧路径不再存在，规则在 doge.14 起作"历史"标记保留 ✓
- 合同 §4.1 "硬规则 #11 chinadns tag 优先级" — 旧路径物理移除后约束在 split 路径下不影响最终路由结果，规则在 doge.14 起作"历史警示"保留 ✓

---

## 7. doge.14 物理删除范围总结

> 本节是 §0.2 + §6.3 D17-D26 + audit §M/§N 的高层总结索引。详细 audit 在 [../design/doge14-deletion-scope-audit.md](../design/doge14-deletion-scope-audit.md)（archive 状态，doge.14 sprint 收尾归档）。

### 7.1 删除范围一览（按 audit 字母段对照）

| audit 段 | 删除项 | 净行数 | doge.14 状态 |
|---|---|---|---|
| §A | `ss_split_enabled` 总开关 11 处 fork 入口 | ~50 行 | ✅ Phase 1+2+3 兑现 |
| §B | `ss_basic_mode=7` 14 处 case 分支 + scripts/ 5 处环境检测 | ~80 行 | ✅ Phase 2 兑现，残留 11 处真业务逻辑分支留 W3 |
| §C | `ss_node_shunt.sh` 整文件 + 3 个 sourcer | -2129 行（2121→0） | ✅ Phase 1+2 stub 化 → Phase 3 物理删 |
| §D | 老 `start_chinadns_ng()` 单实例 + 4 处调用点 | -275 行 | ✅ Phase 1 兑现，B1 BLOCKER fallback 分支补 fix |
| §E | 老 `load_iptables()` + `flush_ipset()` + `apply_ss()` fork | -108 行 | ✅ Phase 1 兑现，D16 老路径残留 bug 一并消失 |
| §F | 老 [DNS 设置] section + 40+ `ss_basic_chng_*` dbus key | -95 行 ASP + 85 个 dbus key | ✅ Phase 1 兑现，I5 残留 14 个 params_input 引用待清 |
| §G | hint 220 / 221 退役 | -25 行（ss-menu.js）+ 4 处 ASP 触发点 | ✅ Phase 1 兑现 |
| §H | AnyTLS TODO | 无残留 | ✅ 已在 doge.13 beta D7 解决 |
| §M.3 | 真机暴露 2 fix（rules_user 保护 + alias unalias） | +51 行 install.sh / +unalias 命令 | ✅ Phase 2 兑现 |

### 7.2 删除总量

- **净 -3310 行**（vs 早期估计 -2300 / -2786 偏低 ~42%）
- 14 modified + 1 untracked（audit doc）
- ssconfig.sh -1059 行 / ss_node_shunt.sh -2129 行 / Module_shadowsocks.asp -257 行 / install.sh +51 -14
- 1 P0 BLOCKER 修（B1 = chng_* fallback 删除 + 未用 local 声明删除）+ 1 W2 顺手修（creat_shunt_json 函数体 no-op）+ 3 WARN 留 stable（W1 / W3 / I5）

### 7.3 不在 doge.14 范围（留 doge.14.x 或 doge.15）

- 共享 lib 抽 `has_dbus_forbidden_chars` 等 helper DRY 化
- 双轨 DNS per-Mode UI 编辑（Phase 3 仅 readonly 占位）
- per-rule 链式代理（proxy_chain:Y:X）从 collapse 到 out_main 改为真实 build chain outbound
- UI 重设计（[DNS 设置] / [访问控制] tab，audit §I 候选范围）

### 7.4 老用户升级路径（doge.13 → doge.14）

升级流程由 [install.sh::migrate_split_routing_v3](../../fancyss/install.sh) 一次性 + 幂等执行（`fss_doge14_migrated=1` 标志），步骤详见 §6.3 D23 伪代码。

**触发时机**：用户在 Web UI 离线安装 doge.14 包后，install.sh 在装包末尾自动调用 `migrate_split_routing_v3`。

**幂等保证**：第一次跑落 `fss_doge14_migrated=1`；之后跑或二次安装 doge.14 均 no-op return 0。

**用户感知**：
- `ss_basic_mode=7` xray 节点分流用户 → 自动切到 mode=2（大陆白名单），主节点 + 链式状态保留，rules 引用主节点的 action 自动经 `proxy_main` sentinel 转译
- 其他 mode (`0/1/2/3/5/6`) 用户 → mode 值不动，行为不变（分流路径已是唯一路径）
- 老 DNS upstream 数据已在 doge.13 beta migrate_v2 切到 `ss_split_dns_*` 系列 key，本次再清老 `ss_basic_chng_*` key 不影响实际工作
- 自定义 Rule 文件（rule_100+.txt）由 D25 rules_user 保护 fix 保留（含老 doge.13 升级时的 `rm -rf` BUG 一起 fix）

**验证清单**：详见 §6.3 D24 PASS 清单。

---

## 修订记录

- **2026-05-27 doge.14 stable 落地（物理删除收尾 / 分流架构成为唯一路径）** ⭐ milestone：
  - **`ss_split_enabled` 总开关物理移除**（D17 / audit §A）：`migrate_split_routing_v3` step 4 一次性 `dbus remove ss_split_enabled`；ssconfig.sh 6 处 fork else 分支 + L8775-8788 诊断日志 + install.sh L2604 状态读取 + ASP 5 处 JS handler 全部物理删除。路由层无 else 分支可回退。
  - **`ss_basic_mode=7` xray 节点分流整套退役**（D18 / audit §B + §C）：migrate_v3 step 1 把存量 mode=7 / acl_mode=7 自动迁到 2；ssconfig.sh 13 处 case 分支 + creat_shunt_json 函数体改 no-op；scripts/ 5 处环境检测 + ASP `<select>` mode=7 option 物理删。残留 11 处真业务逻辑分支留 W3（不阻塞 release，stable 后清）。
  - **`ss_node_shunt.sh` 整文件物理删除**（D19 / audit §C）：2121 行整文件清空（Phase 1+2 先 stub 化到 43 行容错升级，Phase 3 整文件物理删）+ 3 个 source 调用点删（ss_base.sh:16-17 / ss_node_postsave.sh:6 / ss_shunt_hot_reload.sh:4）。`ss_shunt_stats.sh` / `ss_shunt_hot_reload.sh` 整文件也物理删（dead）。
  - **老 `start_chinadns_ng()` 单实例 + 老 iptables/ipset 老分支移除**（D20 / audit §D + §E）：约 275 行单实例 chinadns 函数 + 调用方 4 处删；`load_iptables()` 老分支 35 行 + `flush_ipset()` 老分支 70 行 + `apply_ss()` fork 入口 3 行删。D16 老路径残留 bug 一并消失。
  - **老 [DNS 设置] section + 40+ `ss_basic_chng_*` dbus key 退役**（D21 / audit §F）：ASP `Module_shadowsocks.asp:18353-18428` 约 95 行老 section 物理删除（含 27 个 input + 6 个 select / checkbox + 8 个 IPv6 设置 + JS handler L10056-10084）；migrate_v3 step 2 `dbus remove` 40+ 个老 key。
  - **hint 220 / 221 退役**（D22 / audit §G）：ss-menu.js hint 定义 25 行 + ASP 4 处 openssHint 触发点物理删。
  - **`migrate_split_routing_v3` 设计 + 真机验证 PASS**（D23+D24）：4 step（mode 迁移 / ss_basic_chng_* 清 / ss_node_shunt_* 清 / ss_split_enabled remove）+ 幂等标志 `fss_doge14_migrated=1`；51.1 装机后 10 项验证全 PASS（含 LAN curl 出口 3.9.92.164 = Mode #3 default_action 出口）。
  - **真机暴露 2 个老 BUG 一并修**（D25）：① `install.sh:2348 rm -rf /koolshare/ss/*` 把 rules_user/ 清掉（doge.13 老 BUG），加 `cp -af` 备份 + restore；② `ss_split_rule_seed.sh` syntax error（busybox sh + alias `echo_date` 干扰 function 定义解析），function 前加 `unalias echo_date`。
  - **B1 P0 BLOCKER fix**（M.2）：`start_chinadns_ng_split` / `generate_chinadns_global_conf` 内 `ss_basic_chng_*` fallback 分支与 migrate_v3 step 2 (清 chng_*) 冲突 → 从未点过 [DNS 设置] 保存的老用户升级后国内 DNS 永久兜底 223.5.5.5。**修法**：删 fallback 分支 + 删未用 local CDNS_1/2/3 / FDNS_1/2/3 声明。
  - **净改动**：14 modified + 1 untracked（audit doc）；**净 -3310 行**（ssconfig.sh -1059 / ss_node_shunt.sh -2129 / ASP -257 / install.sh +51 -14）。
  - **CLAUDE.md 硬规则更新**：#14 改成 "doge.14 起物理移除，无兼容旧路径"；#11 改成 "历史警示" 标记保留；新候选硬规则 #21（共享 helper file source 多上下文前 unalias）。
  - **文档大重写**（本提交）：split-routing-implementation §0 / §1 / §4 / §6 / §7 重写为"doge.14 唯一路径"语境；split-routing-architecture §4 / §6.5 / §14 同步更新；audit doc 加 archive 标记。
  - **本文档相关章节更新**：§0.1 演进时间线 + §0.2 doge.14 物理删除收尾清单 + §1.1 `ss_split_enabled` 标 dbus 移除 + `fss_doge14_migrated` 加入迁移标志 + §1.8 旧 key 处置历史扩展 + §4.2 唯一路径约束 + §6.3 D17-D26 全套落地段 + §7 doge.14 物理删除范围总结。
  - **遗留收尾事项（doge.14 stable 后续，不阻塞 release）**：W1 install.sh 历史注释清理 / W3 ASP 11 处 mode=7 真业务逻辑分支扫一遍 / I5 ASP params_input 14 个 ss_basic_chng_* 字段引用清理 / L1605 + L2588 ssconfig.sh 老 chng_chk → UDP relay 检测 dead path 清理。
- **2026-05-23 doge.13 stable 发版（去 beta 后缀，flip switch）** ⭐ milestone：
  - **install.sh::ss_split_enabled 默认值 0 → 1**（[fancyss/install.sh:2600-2605](../../fancyss/install.sh#L2600)）。新装机自动走新分流路径；alpha/beta 老用户已显式设置过的值（含旧默认种下的 0）一律保留，不强切 opt-out 用户。migrate guard 沿用现成的 `[ -z "$(dbus get ...)" ] && dbus set` 单行模式（用户群只有 fork 维护者 + 1 朋友，决策最简方案）。
  - **ASP / ss-menu.js 标签去 alpha / 实验性 / V2 残留**：hint 210 警告框删除 + caption 改成 "分流架构"；hint 211/212/215/216/217 "alpha 阶段" / "TODO(doge.12-alpha)…doge.13" → "现阶段" / "doge.14"；ASP 顶部按钮 title "doge.12 智能分流架构" → "智能分流架构"；ss_split_enabled select 的 "(默认)" 标记从未启用翻到已启用 option。
  - **D16 老路径未补丁**：beta.4 修的 LAN DNS hijack mangle PREROUTING RETURN 只覆盖 load_iptables_split（新路径）。老路径 load_iptables 同款 TPROXY UDP + DNS hijack DNAT 模式同样的 bug 不修——本次 flip switch 后新装机和不显式 opt-out 老用户全部走新路径不踩这个 bug，剩下显式 opt-out 用户已知风险（用户群 = fork 维护者 + 1 朋友，已通报）。doge.14 物理删除老路径时该差异一并消失。
  - **§4.2 "alpha 兼容性硬约束" 标题升级 → "新旧并存阶段兼容性硬约束（doge.12 / doge.13 stable，doge.14 会解除）"**。
- 2026-05-22 doge.13 beta 实施完成（P0 7 条 + P1 2 条 + UI 方案 A）：
  - **D12 sentinel `proxy_main` 解决 stale 节点 ID**：install.sh 写入端 + ssconfig.sh::ss_split_action_to_tag 解析 + ASP action select option + Mode helper 接受 `proxy_main` 字面量。详见 §1.5 + §6.2 D12 兑现段。
  - **解除 out_main collapse**：新建 [fancyss/scripts/ss_split_node_outbound.sh](../../fancyss/scripts/ss_split_node_outbound.sh) 拆出 ss_chain_proxy.sh 节点 outbound 构建器；ssconfig.sh::generate_xray_json_split 构建 per-rule 独立 outbound + jq merge；graceful fallback 兜底 helper 未部署场景；新增诊断 dbus key `ss_split_node_outbound_count` / `ss_split_chain_outbound_count` + `fss_split_xray_warn` 失败码。
    * BLOCKER fix: fss_split_build_node_outbound_json 签名从 3 参扩 4 参(加 dialer_tag)+ jq 注入 streamSettings.sockopt.dialerProxy,与 ssconfig.sh::generate_xray_json_split chain build 循环 (L5598) 对齐
  - **D8 端口分配 gate 解除**：`__split_mode_port_by_id` / `__split_mode_dns_port_by_id` 去 `is_default || builtin` gate；新增 `__split_active_mode_indices` 动态枚举 active slot；用户自定义 Mode 拿到独立端口偏移。
  - **D13 ASP preflight**：`#ss_split_enabled change handler` 检测 `ss_basic_mode=7` 时触发 hint 221（取消 / 仅启用 / 同时切换）三按钮弹窗。
  - **D14 节点删除清理**：`collect_node_reference_delete_impact` 加 splitRules 数组 + `match_split_action_node` helper + `process_schema2_node_delete_queue` 合入；订阅刷新 / 手动删节点时自动改 action 字符串（landing 删 → `proxy_main`；front 删 → 降级为 `proxy_node:Z`）。
  - **D15 空节点 → proxy_main**：与 D12 sentinel 合并实施，install.sh cur_action 改为单行 `cur_action="proxy_main"` 字面量。
  - **Mode CRUD sanitize helper**：新建 [fancyss/scripts/ss_split_mode_save.sh](../../fancyss/scripts/ss_split_mode_save.sh) 545 行（对标 ss_split_rule_save.sh），Mode CRUD 改走专用 helper 加 case sanitize；§1.6.2 helper 协议契约。
  - **D5 dnsmasq 让位 65355**：独立 `dnsmasq_lan` 子实例占 127.0.0.1:65355（**方案 C-2**，不动主 dnsmasq；原计划的 pc_insert port=65355 方案已废弃）。详见 §6.2 D5 兑现段。
  - **D1 DNS upstream 真消费**：install.sh::migrate_split_routing_v2 把老 key 一次性切到新 key（保留老 key fallback），落 `fss_split_migrated_v2=1` 守卫；ssconfig.sh 优先读新 key、回退老路径。新 key 契约入 §1.6.1。
  - **§1.4.1 索引规范升级到方案 B**：Mode CRUD helper 解锁 index↔id 解耦，消费方改 `dbus list ss_split_mode_ | awk ...` 动态枚举。
  - **UI 方案 A**：asp 标签 "分流V2 (实验)" → "分流"，mode 7 option 隐藏 + stale 占位（老用户保留旧值）。
  - **新文件**：fancyss/scripts/ss_split_mode_save.sh / fancyss/scripts/ss_split_node_outbound.sh
  - **净改动**：install.sh +117/-9, ssconfig.sh +333/-71, ASP +248/-104, ss_chain_proxy.sh -205/+21, ss-menu.js +20/-7, +2 个新文件。
  - **已知收尾事项**：
    - D8 真机三 MAC 验证（default + builtin + user-defined Mode）仍待；
    - ACL UI select 扩展支持自定义 Mode 留 doge.13 后续。
- 2026-05-15 alpha 实施期初稿。
- 2026-05-20 alpha.13-16 修订汇总：
  - alpha.13：`ss_split_rule_to_json` ARG_MAX hotfix（1.6MB JSON 灌 shell 变量爆 busybox `[` 内置 → 改文件中转 + jq 流式）。详见 §6.2 D9。
  - alpha.14：同函数 awk O(n²) 性能优化（chnlist 11 万行 37.5s → 3.88s，9.7x 提升）。同 D9。
  - alpha.15：chinadns-ng DNS 层 reject 整套删除（`group-tag-noip` 是 doge.12 alpha 自己发明的伪语法，潜伏地雷一旦用户配 reject rule 即触发 chinadns 全挂；reject 语义由 xray blackhole outbound 接管）。详见 §6.2 D10。顺手加 `ss_proc_status.sh` 3 个 helper（split V2 / 链式 / 直连白名单状态） + ssconfig.sh:5465 链式代理注释修正。
  - alpha.16：Mode 级 `block_quic` / `udp_proxy` 写者写满、读者 0 人 → load_iptables_split 加 2 个 helper 接通 iptables 层 DROP / UDP TPROXY 跳过。详见 §6.2 D11。
  - §6.1 line 236 "block_quic 留 doge.13" 描述已用删除线标记 → 指向 D11。
- 2026-05-20 alpha.17 修订汇总（深度审计 + Agent A/B/C/D 平行 review）：
  - **后端 finding（6 个落地）**：
    - F-A-01：`fss_failover_internal_restart` 由两状态扩到三状态（`0`/`1`/`2`），新增 [scripts/ss_cron_restart.sh](../../fancyss/scripts/ss_cron_restart.sh) wrapper + 5 处显式 `dbus set fss_failover_internal_restart="2"`（[ss_status_main.sh:241](../../fancyss/scripts/ss_status_main.sh#L241) / [fss_rules_update.sh:331/378](../../fancyss/scripts/fss_rules_update.sh#L331) / [ss_rule_update.sh:258](../../fancyss/scripts/ss_rule_update.sh#L258)）。机制 + 路径清单详见 [failover-combo-implementation.md §4.7](failover-combo-implementation.md#47-cron--非用户路径-restart-wrapperalpha17-新增)。
    - F-A-02：`fss_export_global_json` / `fss_clear_global_config_storage` / `fss_export_native_backup_v2` 三处备份白名单补 `dbus list fss_split_` 抓取，避免 restore 时旧 `fss_split_migrated_v1` 阻止 install.sh 重新 migrate。
    - F-A-04：install.sh `migrate_split_routing_v1` 自愈 reseed 由"只查 rule_1/rule_2"扩到"枚举 rule_1~8 全集"，修 D7 同形漏修——Rule 4/5 等小文件被吃掉时无法自动恢复。
    - 启动日志 10 条 echo_date 增强（ssconfig.sh / install.sh 关键阶段进入/退出标记），便于真机故障复盘。
    - [ss_proc_status.sh:264-326](../../fancyss/scripts/ss_proc_status.sh#L264) 新加 3 个 helper（`GET_CHAIN_PROXY_STATUS` / `GET_SPLIT_V2_STATUS` / `GET_DIRECT_ASUSGO`）并接入 `check_status`，WebUI 状态页一眼可读 split V2 + 链式 + 直连白名单状态（D10 §6.2 "顺手做的事"在 alpha.15 文档化，alpha.17 实际落地代码）。
    - ssconfig.sh case start/restart 入口扩到 `[ "${__fofr}" = "1" ] || [ "${__fofr}" = "2" ]` 合并条件分支处理。
  - **前端 finding（5 个落地）**：Module_shadowsocks.asp 5 处小修（具体改动看 commit）。
  - **latent issue（4 个文档化，alpha 不修）**：F-A-03 / F-A-05 / F-A-06 / F-A-08 → §6.2 D12 / D13 / D14 / D15，全部因 generate_xray_json_split out_main collapse 掩盖、doge.13 解除 collapse 时必须兑现。
  - **reviewer PASS**：Agent A 深度审计 + 主代理交叉 review 通过。代码改动量 ~185 行（从 alpha.16 → alpha.17，源码 commit 未发版）。
- 2026-05-20 alpha.18 修订（用户 alpha.17 真机暴露的 2 bug + alpha.17 reviewer 2 条 WARN）：
  - **Q1-A**（asp）：内置 Mode 字段全锁过度，拆 `disName`（只锁名字）+ `disRun=''`（运行时字段放开）。撤销 alpha.17 F-B-7 对 `default_action` + rule action select 的额外 disable。用户现在能修改内置 Mode #1/#2 的 dns_mode / udp_proxy / block_quic / apply_blackwhite / default_action / 每条 rule 的 action。仍锁：name + rule list 顺序（add/move/del 操作），防止破坏 install.sh 种子标识。详见 §6.1 "UI 第一稿" 末尾 + [asp:7318-7340](../../fancyss/webs/Module_shadowsocks.asp#L7318)。
  - **Q1-B**（asp）：splitDlg Mode 弹窗 footer 三按钮（取消 / 保存 / 保存并立即生效）。`split_v2_persist(fields, cb, applyAfter)` 新增 applyAfter 参数；applyAfter=true 时 dbus 落盘后调 `push_data_ws('ss_config.sh', enabled?'start':'stop', {})` 复用主面板「保存&应用」路径（与 [asp:8771-8791](../../fancyss/webs/Module_shadowsocks.asp#L8771) 一致）。Rule 弹窗不传 `opts.showApply` 维持旧行为。
  - **Q2**（asp）：ACL UI 写者侧兑现 `ss_acl_split_mode_<i>` —— save() 同步翻译 `0/5/* → 0/1/2`，delTr() 同步清零。详见 §6.2 D8 alpha.18 段。
  - **W3**（ssconfig.sh）：[L7263 + L7285](../../fancyss/ss/ssconfig.sh#L7263) `block_quic` DROP 规则加 `-i "${default_iface}"` 限定 LAN 入站方向，防止 LAN 内自建 STUN/媒体服务器接收外部 UDP/443 被误伤。
  - **W6**（ssconfig.sh）：[L5504-5508](../../fancyss/ss/ssconfig.sh#L5504) 删 dead if/else（split=0/1 两分支调用相同），留单一行 `fss_chain_apply` 调用。
  - 改动量：asp +61 -19（净 +42）+ ssconfig.sh +7 -4（净 +3）= **总净 +45 行**。BOM/CRLF 字节级保留（CR=LF=18874）。Opus reviewer PASS。
