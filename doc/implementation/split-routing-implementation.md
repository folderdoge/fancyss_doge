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
| `ss_split_rule_<i>_kind` | "host"/"port" | **FORK doge.14.x 新增**：规则类型。`host`=IP/域名混排（原行为），`port`=端口列表。**空/缺省 = host**（兼容存量无 kind 的规则，前端读空当 host、`__split_rule_kind_by_id` 读空当 host）。内置规则由 install.sh `write_builtin_rule_meta` 种 `host`；用户规则由 `ss_split_rule_save.sh` 按前端选择写入。类型创建后不可改（UI 编辑时只读）。 |
| `ss_split_rule_<i>_stat_ports` | int | **FORK doge.14.x 新增**：端口条数缓存（`kind=port` 时有效；host 规则恒 0） |

> 规则文件路径不进 dbus，按 id 推：`/koolshare/ss/rules_user/rule_<id>.txt`（port 类型规则同样存这里，每行一个端口 `25` 或端口段 `6881-6889`）

> **端口规则路由生成（FORK doge.14.x）**：`generate_xray_json_split` 的 Mode rule 循环用 `__split_rule_kind_by_id <rid>` 判类型。`kind=port` 时读 `rule_<id>.txt`，awk 过滤出合法端口/段拼成逗号串，emit **单条** `{type:"field",inboundTag:[mode],port:"...",outboundTag:<rtag>}`——端口是 L4 信息 TCP/UDP 都可见，**不拆 domain/ip、不写 network**，故不踩 [§6.3 D27/D29](#) 的 UDP AND 陷阱。Rule helper 临时 key 增加 `ss_split_rule_save_kind`（"host"/"port"，空=host）。

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
| 1 | 大陆白名单_场景 | install 期 zcat 现有 `fancyss/ss/rules/chnlist.gz` + 加 `rules_ng2/ip/cn.txt` IP | 留空 alpha；doge.13 起指向 fork raw | 0（alpha 不自动更新） |
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
| 1 | 全局代理 | global | 1 | 1（doge.14-beta.6 起，见 §6.3 D28；早期误种 0） | 0 | [] | 取自 `ssconf_basic_node` / `ssconf_basic_node_front` |
| 2 | 大陆白名单 | split | 1 | 1（同上） | 0 | [Rule 1（大陆白名单_场景）→ direct]（doge.14-beta.10 起精简为单条，见 §6.3 D32；其余内置 Rule 保留在库默认不挂载） | 取自 `ssconf_basic_node` |

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

#### D28: 内置 Mode UDP 代理默认关闭回归 — migrate_v1 从 vestigial `ss_basic_udp_relay` 误种 0（doge.14-beta.6 修复）

2026-06-17 用户报 doge.14-beta.5 大量节点 WebRTC STUN 报 `701 STUN host lookup received error`、需要 UDP 的游戏进不去；旧版 doge.13-beta.2 无此问题。51.1 实证根因 + 修复：

- **根因**：`install.sh::migrate_split_routing_v1` 写内置 Mode 1/2 的 `udp_proxy` 时取 `cur_udp="$(dbus get ss_basic_udp_relay)"`、空则默认 `0`。但 `ss_basic_udp_relay` 在 doge.14 已是 **vestigial key**（无 UI、无默认初始化；旧路径真正的 UDP 开关是 `ss_basic_udpoff`/`ss_basic_udpall`，全仓库只此一处读它）→ 几乎恒空 → 内置「全局代理」「大陆白名单」`udp_proxy=0`。`load_iptables_split` 在 `udp_proxy=0` 时**不下 UDP TPROXY 规则**（§6.2 D11）→ 这两个内置 Mode 的 UDP 全部走原生路由直连 → 国内被墙 → STUN 701 / 游戏 UDP 失败。TCP 始终 TPROXY 故网页浏览正常，掩盖了 bug。
- **为何是回归**：beta.2 走 legacy 路径（`ss_split_enabled` 默认 0），legacy 对 gfw 目标 UDP **无条件** TPROXY（老 `SHADOWSOCKS_GFW -p udp ... TPROXY`，不读 `ss_basic_udp_relay`）→ UDP 正常。doge.14 物理删除 legacy 后分流成唯一路径，被 vestigial key 误种的 0 才暴露。自定义 Mode 不中招（asp 默认 `udp_proxy=1`），所以只有人人都用的两个内置 Mode 出问题。
- **修复**：① `migrate_v1` 默认 `cur_udp` 由 0 改 1（对齐自定义 Mode asp 默认 1 + `__split_mode_udp_proxy_by_id` 缺失兜底 1）——修新装；② 新增一次性幂等 `repair_builtin_udp_proxy_v1`（marker `fss_split_builtin_udp_on_v1`），把已迁移老用户存量内置 Mode 的 `udp_proxy=0` 翻 1（只动 `builtin=1`、只翻 0→1，用户事后手动关仍保留）——修升级（migrate_v1 有幂等守卫不会重跑）。
- **51.1 实证**：预置内置 Mode1/2 `udp=0` + 清 marker → 装 beta.6 → install 日志打印 repair 翻转 2 个内置 Mode（marker=1）；ACL 设备 POCO(mode1) 得 13333 UDP TPROXY；LAN STUN reflexive=海外代理 IP（无 701、无泄露，UDP 经代理出口）。
- **影响面**：仅内置 Mode 的 UDP（自定义 Mode / 非默认行为不变）；§2.2 内置 Mode 表 Mode1/2 `udp_proxy` 默认由"沿用 `ss_basic_udp_relay`"更正为 **1**。

#### D29: UDP/STUN 701 + UDP 游戏进不去（真因）— TPROXY 的 UDP `-m socket` DIVERT 黑洞掉每条流第 2 包起（doge.14-beta.7 修复）

2026-06-17 用户报 doge.14-beta.6（D28 修了 UDP 代理默认关）后 WebRTC STUN 仍频繁 `701`、UDP 游戏进不去：**第一次/偶发能用，ip.skk.moe 快速刷新几次后所有节点全 701**（"像被限速"）；doge.13-beta.2 开 UDP 代理则一直流畅。51.1 多轮 A/B 实证根因 + 修复：

- **先排除的假设（避免重蹈"想当然"覆辙）**：① 不是资源耗尽——conntrack count ~330/300000、xray fd 22–30/16384、CPU/线程全程平稳；② 不是 DNS-over-UDP 耗尽——外网 DNS 压测 240/240 @210qps 零失败（外网 DNS 走 TCP/DoT 过 SOCKS，本就不经 UDP）；③ **不是嗅探**——把 mode inbound `sniffing.enabled=false` 后仍 1/6、首包延迟不变（~1.1s），QUIC 嗅探 / `metadataOnly` 全部无关；④ 不是 vless/vision outbound——强制走 `out_direct` freedom 仍 1/6。
- **根因（debug log 实证）**：mangle `SHADOWSOCKS` 链里 `-A SHADOWSOCKS -p udp -m socket -j SHADOWSOCKS_DIVERT` 这一条。对一条 UDP 流：第 1 包早于 xray 建透明 socket → 不命中 socket-match → fall-through 到 `TPROXY --on-port` → 进 xray listener、转发成功；xray 随即为该流开一个 per-flow IP_TRANSPARENT UDP socket（走**回程**、不从中读"客户端→服务端"方向数据）。第 2 包起 `-m socket` 命中这个 per-flow socket → DIVERT 打 mark 经 lo 投进去 → 落进 xray 不读的 socket → **黑洞**。xray 调 `loglevel:debug`：同一 socket 发 6 包，`transport/internet/udp: UDP original destination` 只打印 **1 次** → listener 只收到第 1 包。iptables 计数器同证：TPROXY-udp 计数不动、`SHADOWSOCKS_DIVERT` udp 计数随包数 +1。
- **为何 beta.6 才暴露 / 为何是回归**：split 路径 UDP 在 doge.13 stable 翻 split + D28（beta.6）把内置 Mode `udp_proxy` 翻 1 **之前**，几乎没被默认用户真正走过 → 这条 socket-match 一直是潜伏 bug；beta.6 把 UDP 真正送进 xray TPROXY 后才引爆。doge.13-beta.2 走 legacy UDP relay（ipt2socks/老 TPROXY，无 xray per-flow 透明 socket 抢包问题）故一直好。D28 把 UDP 路径"打开"，D29 才是这条路径自身的 bug。
- **修复**：删掉 UDP 那条 `-m socket` DIVERT，**保留 TCP 那条**（[ssconfig.sh `load_iptables_split`](../../fancyss/ss/ssconfig.sh)）。无 xray.json 改动、无端口/iptables 重定向改动。原理：xray dokodemo-door 的 UDP 按"源地址"在 listener 内 demux，要求每个 datagram 都 fall-through 到 TPROXY 投给 listener；UDP 不存在 TCP 的 accept()→established-socket 模型，故 UDP 不需要也不能要 socket-match 豁免。TCP 那条必须留：TCP 握手后续包必须投到 accept() 出的 established socket，否则握手/连接断。
- **51.1 实证（改源码 + `ssconfig.sh restart` 真实重建链路，非手删规则）**：单 socket 长连 Google 8/8、Cloudflare 8/8（修前 1/6）；快速刷新 15 个新 socket 15/15（= 用户"快速刷新后全挂"场景）；TCP 海外 `api.ip.sb`→UK 代理节点、`api.ipify.org`→AWS London 同节点（分流/TPROXY TCP 不回归）；mangle 链 udp socket-match 缺席、tcp 在席；`fss_split_xray_warn` 空（无 fallback）。
- **影响面**：所有走分流的 UDP（STUN/WebRTC、UDP 游戏、任意 UDP 应用）现在连续可用；DNS 不受影响（dport 53 在 socket-match 之前已 RETURN，见 D16）；TCP 完全不受影响（删的是 `-p udp` 规则）；`block_quic` 不受影响（DROP udp/443 在 TPROXY 之前、socket-match 之后，逻辑不变）。首包仍 ~1.1s（代理首跳 UDP association 建立的固有延迟，非 bug；③ 已证与嗅探无关），后续包 ~300ms。

#### D30: 多模式大配置启动慢 — 内置大表规则改发 geosite/geoip 共享引用（doge.14-beta.8）

2026-06-17 用户报"模式下存在多个大配置启动慢"。根因 + 治本方案 + 51.1 实证：

- **根因**：`generate_xray_json_split` 把每条 Rule 的域名/IP **内联**进 xray.json（`ss_split_rule_to_json` → `domain:`/CIDR 数组）。内置「大陆白名单」Rule 1 = chnlist 11.8 万域名 + cn IP 1 万条，内联成 JSON ≈ 每个用到它的 Mode **~3MB**，且 **每个 Mode 各一份**（routing rule 按 `inboundTag` 区分，xray 无法跨 inbound 复用同一条 rule）。3 个 Mode 都用 → xray.json ~9MB + xray 启动解析 + 建 3 套匹配表 + 每 Mode 一次 126k 行 awk 生成。
- **方案（用户选"只提速、行为不变"）**：内置大表规则改发 xray 原生 `geosite:`/`geoip:` **引用**而非内联。仓库早已备好整套 geodata 管线（`rules_ng2/` 源 + `scripts/build_geo*_fancyss.sh` 用 v2fly Go 工具在**构建期**编译 + `binaries/geotool` 只读提取工具 + `fancyss/ss/rules_ng2/dat/{geosite,geoip}.dat` 已打进包、install 已部署到 `/koolshare/ss/rules_ng2/dat/`），仅差"运行时把它接进 xray 配置生成"。
- **行为不变性（关键）**：`geosite:cn` 由**同一份 `chnlist.gz`** 编译（assets.json `cn` site source = `local_gzip_domain_suffix: rules_ng/chnlist.gz`，rule_counts `cn`=118209 与设备 chnlist 一致）、`geosite:gfw` 由 `gfwlist.gz`、`geoip:cn` 由 `chnroute`。匹配类型同为 `domain:`（后缀/子域）+ CIDR。domain(geosite)/ip(geoip) 仍**各自独立成条 rule** → D27/D29 的 UDP 修复不回归。geotool 实测 `baidu.com/taobao.com/ipip.net` 均在 cn 分类。
- **实现**（5 处，全在 [ssconfig.sh](../../fancyss/ss/ssconfig.sh) + [install.sh](../../fancyss/install.sh)，behavior-preserving 最小改）：
  1. `SS_XRAY_ASSET_DIR="/koolshare/ss/rules_ng2/dat"` 全局常量。
  2. Rule 循环：读 `ss_split_rule_<rid>_geosite` / `_geoip`，非空**且对应 .dat 存在非空**时发 `{domain:["geosite:cn"...]}` / `{ip:["geoip:cn"...]}` 引用并 `geo_emitted=1`，否则 fall through 到原内联路径（`geo_emitted=0`）。
  3. **安全闸**：`.dat` 缺失绝不发引用（否则 xray -test 失败 → 回滚基线 → LAN 断，= D"陷阱 1"/alpha.8）。
  4. xray 自检（`xray -test`）+ 主进程启动两处都注入 `XRAY_LOCATION_ASSET=${SS_XRAY_ASSET_DIR}`。**坑**：主进程那行是 `env -i PATH=... xray`，`env -i` 会清空环境 → 必须把 `XRAY_LOCATION_ASSET=` 直接写进 `env -i` 这一行（export 会被 `env -i` 吃掉）。
  5. `install.sh::migrate_split_geo_meta_v1`（幂等 `fss_split_geo_meta_v1`，每次 install 都跑覆盖新装 + 已迁移老用户）给 builtin Rule 1 种 `geosite=cn`+`geoip=cn`、Rule 2 种 `geosite=gfw`。`ss_split_rule_seed.sh` 仍按原样灌 chnlist 进 rule_1.txt 作 **fallback**（geo 不可用时内联兜底）。
- **51.1 实证（armv7l，TUF-AX3000）**：① `xray -test` PoC `geosite:cn`+`geoip:cn` → "Configuration OK"（无 asset path 则 `open /data/geosite.dat: no such file` 失败，印证 #4 的 env 注入是关键）；② xray.json **4,332,707 → 11,534 字节（375×）**；③ 整机 `ssconfig.sh restart` 总耗时 **43s（内联）→ 32s（geo）**，仅 1 个 Mode 用 chnlist 就省 11s（多 Mode 收益更大；纯 xray -test 7.2s→4.2s）；④ **A/B 路由完全一致**（Mode 2 大陆白名单：`myip.ipip.net`→直连同一 CN IP `123.158.55.243`、`cloudflare`→代理同一 UK IP `86.53.160.85`，新旧逐字节相同）；⑤ `fss_split_xray_warn` 空、无回滚。
- **xray 匹配表 per-rule（非全局共享）**：3 个 Mode 各引用 `geosite:cn` → 仍各建一次匹配表（实测 1 Mode 4.2s / 3 Mode 10.2s）；要做到"模式再多启动不变"（实测合并成一条 `inboundTag:[m1,m2,m3]` → 4.2s 持平）需**跨模式合并 rule**，但合并会改变各 Mode 内规则顺序 → 有改动分流结果的风险，与"行为不变"冲突，**本期不做**，留作未来需单独安全性论证的增强。
- **更新节奏（无 drift，故不需 Step 2）**：doge.14 下 `ss_rule_update.sh` 下载 chnlist.gz/gfwlist.gz 后只 `ssconfig.sh restart`，**不重 seed `rule_1.txt`**（reseed 仅在文件缺失时触发），且老 ipset 消费者已物理删除 → **即便老内联路径，on-device "更新规则" 也不刷新内置白名单的生效域名**。chnlist.gz 与 geosite.dat 都只随**插件版本**更新且一起更新。故 geo 改动**不改变更新节奏**、无引入 drift。（未来增强方向：让 `ss_rule_update.sh` 也下载 fork 发布的 `geosite.dat`/`geoip.dat` → 反而能让"更新规则"真正对内置 CN/GFW 生效，优于现状；非本期范围。）

#### D31: 端口规则 — Rule 增加 kind（host/port），支持「指定端口走指定代理/直连」（doge.14.x）

2026-06-17 用户需求："某个模式某几个端口不过代理"，并希望能"指定端口走指定代理"。采用方案 B（端口作为独立 Rule 类型，可在 Mode 里指定任意 action，是"直连豁免"的超集）。

- **数据模型**：Rule 增加 `ss_split_rule_<i>_kind`（`host`=IP/域名原行为；`port`=端口列表；**空=host** 兼容存量）+ `ss_split_rule_<i>_stat_ports`。端口内容复用 `rule_<id>.txt`（每行一个端口 `25` 或端口段 `6881-6889`），复用现有 payload base64 / 备份 / 体积行数校验通道。类型创建后不可改（UI 编辑只读）。
- **路由生成**（[ssconfig.sh](../../fancyss/ss/ssconfig.sh) `generate_xray_json_split`）：新增 `__split_rule_kind_by_id <rid>`（by rid 查 slot 读 kind，空=host；**不能像 D30 geosite 那样直接 `ss_split_rule_<rid>_*`**——那只对内置 slot==id 成立，用户规则 id≥100 slot≠id 会读错）。Mode rule 循环里 `kind=port` 时读端口文件、awk 过滤合法端口/段拼逗号串，emit **单条** `{type:"field",inboundTag:[mode],port:"...",outboundTag:<rtag>}` 后 `continue`（跳过 host 的 geosite/内联路径）。**端口是 L4 信息 TCP/UDP 都可见 → 单条 rule 通吃，不拆 domain/ip、不写 network**，天然不踩 D27/D29 的 UDP AND 陷阱（与 host 规则相反：host 必须拆，port 绝不能拆）。端口走哪由该 Rule 在 Mode 里的 action 决定。
- **后端校验**（[ss_split_rule_save.sh](../../fancyss/scripts/ss_split_rule_save.sh)）：新增临时 key `ss_split_rule_save_kind`；`validate_port_payload` 校验每行 1-65535 或 lo-hi（lo≤hi，落地前校验非法不覆盖原文件）；`count_port_entries` 算 stat_ports；slot-shift 字段列表加 `kind stat_ports`。
- **内置规则**（[install.sh](../../fancyss/install.sh) `write_builtin_rule_meta`）：种 `kind=host`（新装机）；存量老用户内置规则无 kind → 消费方读空当 host（零迁移）。
- **UI**（[Module_shadowsocks.asp](../../fancyss/webs/Module_shadowsocks.asp)）：规则卡片加类型泡【IP 域名】/【端口】（CSS `.split-badge-kind`）；端口规则卡片显示"端口 N 个"；新建弹窗加类型下拉（host/port），编辑时类型只读；内容区 label/placeholder 随类型切（`split_v2_rule_dlg_kind_changed`）；保存前端预校验端口格式；`split_v2_rule_persist` 加 `kind` 参数透传（2 个调用点同步改：save_dialog 传选定 kind / delete_rule 传 `'host'` 占位）。
- **决策（用户拍板）**：不区分协议（TCP+UDP 一起，不写 network）；匹配目标端口；支持端口范围。
- **真机验证（2026-06-17，51.1 热替换 3 运行时文件）**：① save.sh 建端口规则 OK、非法端口 `99999` 被拒、stat_ports 正确；② `generate_xray_json_split` 生成**单条** `{port:"25,465,587,6881-6889",outboundTag:...}`（`network` 字段为 null = TCP/UDP 通吃）；③ **实测路由翻转**——同域名 `ifconfig.me`：443（命中端口规则→direct）出口=WAN 直连 `123.x`，80（默认→proxy_node:448）出口=代理 `3.9.x`，证明按端口分流生效且不影响其他端口；④ UI 弹窗"类型"下拉 + 内容区随类型切换 label/placeholder + 规则卡片【端口】/【IP 域名】类型泡 + 创建闭环（kind 透传持久化）均 OK。
- **真机发现并修复的 bug（while-read 末行）**：`count_port_entries` / `validate_port_payload` / `recount_stats_file` 的 `while read line; do …; done < file` 在**最后一行无结尾换行符**时漏读该行（UI textarea 存的单端口 `8080` 无结尾 `\n` → stat 显 0、且末行单个非法端口能绕过后端校验）。修为 `while IFS= read -r line || [ -n "${line}" ]; do`。**路由不受影响**（ssconfig 用 awk，awk 正确处理无换行末行），仅 stat 显示与后端兜底校验受影响。复测：单端口 `8080` stat=1、单个非法端口无换行被拒。
- **状态**：源码落地（4 文件 + 文档）+ **51.1 热替换真机验证通过**；**未 build 整包 / 未发版**（等用户授权）。

#### D32: 默认「大陆白名单」精简为单条规则「大陆白名单_场景」（doge.14-beta.10）

2026-06-17 用户需求：把内置「大陆白名单」Mode 的默认规则集从 7 条精简为 1 条，命名「大陆白名单_场景」（= 国内直连、其余走代理的经典大陆白名单）。

- **改动**：① [ss_split_rule_seed.sh](../../fancyss/scripts/ss_split_rule_seed.sh) 把内置 Rule 1 显示名 `大陆白名单_常用` → `大陆白名单_场景`（内容不变 = chnlist 域名 + cn IP，仍带 geosite:cn/geoip:cn 共享引用）；② [install.sh](../../fancyss/install.sh) `migrate_split_routing_v1` 把 Mode 2 的 7 条 `add_mode_rule` 收敛为单条 `add_mode_rule 2 1 1 "direct"` + `rule_count=1`（新装路径）；③ 新增幂等迁移 `repair_builtin_mainland_single_rule_v1`（marker `fss_split_mainland_single_v1`）把存量用户的 Mode 2 也收敛为单条 + 改名（在 install_now() 的 migrate_split_geo_meta_v1 之后调用）。
- **保留（用户决策）**：其余内置 Rule（2~8：GFW列表 / 中国公共DNS / 广告统计屏蔽 / Telegram加速 / 在线状态检测站 / 查IP常用站 / Bing加速）仍 seed 进规则库，只是默认不挂载到 Mode 2，用户可在「模式规则」页按需加回任意 Mode。
- **dbus remove 坑（CLAUDE.md #15）**：repair 清旧挂载用 `dbus list ss_split_mode_<m>_rule_ | cut | while read k; do dbus remove "$k"; done` 逐键删（裸前缀 `dbus remove` 精确匹配删不掉 `_<i>_*`）；`dbus list` 前缀会连 `_rule_count` 一并列出删除，紧接重置 `rule_count=1` 覆盖。只动 `builtin=1 && name=大陆白名单` 的 Mode（按 name+builtin 匹配，不靠 slot 号，兼容删模式后的 slot 压缩）。
- **行为**：单条 Rule 1（geosite:cn 域名 + geoip:cn IP，direct）+ default_action=proxy_main → 国内直连 / 其余走代理；domain 与 ip 仍各自独立成条（D27/D29 不回归）。移除的额外规则里 `广告统计屏蔽`(reject) 不再拦广告（改随默认走代理），其余 direct/proxy 多为冗余或细化。
- **真机验证（2026-06-17，51.1 整包安装 beta.10）**：安装日志 `#2=大陆白名单(1规则)`、`split_xray_warn` 空、xray -test OK；dbus Mode 2 `rule_count=1`/`rule_1_rid=1`/`action=direct`、Rule 1 改名 `大陆白名单_场景`、marker=1、库仍 9 条；xray.json mode_2 路由 = `domain:[geosite:cn]→out_direct` + `ip:[geoip:cn]→out_direct` + 兜底 `→out_main`，无 out_reject（额外规则确已移除）。3 审查 agent 一致 SHIP-READY。

#### D33: 对外服务/端口转发「连入」被代理（RDP/NAS/游戏服务器从外网连入失效）——回归修复（doge.14-beta.14）

2026-06-19 客户报告：开启代理后，外网经端口转发连入局域网设备的连接失效（RDP 连不上）；doge.13-beta.2 无此问题。

- **根因**：分流路径（doge.14 唯一路径）TCP/UDP 都靠 mangle `SHADOWSOCKS` 链逐包 TPROXY，链尾 catch-all（`-A SHADOWSOCKS -p tcp/udp -j TPROXY`）只看协议+目标、**无连接方向感知**。`SHADOWSOCKS` 挂在 `-A PREROUTING -i br0`，故局域网内被端口转发对外提供服务的设备**回复外网客户端**时（src=LAN server，dst=外网 client）方向也是「LAN→外网」、目标非保留段（不在 `ignlist_minimal`）→ 落到 catch-all → 被 TPROXY 抓进 xray → 回程发不出去 → 连入端三次握手 SYN-ACK 收不到 → 超时。老 fancyss 路径 TCP 走 nat `REDIRECT`，NAT 天生只对 conntrack **NEW + ORIGINAL** 方向改写、不碰回程（ESTABLISHED reply 由 conntrack 直接放行），故 doge.13 及更早无此问题；doge.14 物理删除老路径、TPROXY 成唯一路径后暴露 = **回归**。
- **TCP 与 UDP 同源**：UDP 在 udp_proxy=1（doge.14-beta.6 起内置 Mode 默认开，见 D28）时同样有 catch-all UDP TPROXY，回程同样被抓 → 入站 UDP 服务（WireGuard / 联机游戏服务器等）一样失效。
- **修复**（[ssconfig.sh](../../fancyss/ss/ssconfig.sh) `load_iptables_split`，DNS RETURN 之后、socket-DIVERT 之前）：`append_if_not_exists mangle -A SHADOWSOCKS -m conntrack --ctdir REPLY -j RETURN`。凡 conntrack **REPLY 方向**的包（= 连接由对端先发起、本机只是回程）一律 RETURN、不进 TPROXY。**不限 -p**：一条规则同治 TCP/UDP。正常上网 = LAN 设备主动发起 = ORIGINAL 方向，不被命中，仍正常 TPROXY 走代理；放在所有 TPROXY / block_quic DROP 之前（顺序敏感）。
- **为何这条够用**：br0 PREROUTING 上「该走代理」的流量恒为 LAN 主动发起（ORIGINAL）；任何在 br0 上出现的 REPLY 方向包都意味着连接由 WAN 侧发起（端口转发 / 对外服务），绝不应代理。LAN→LAN（dst 私网）本就被 `ignlist_minimal` RETURN，与本条无关。
- **IPv6 不受影响**：`_start_ipv6_iptables` 的 IPv6 TCP 仍走 nat `REDIRECT`（不碰回程）；IPv6 入站 UDP 是另一条少见旧路径，未纳入本次修复（如需可同法加固）。
- **真机验证（2026-06-19，51.1 = TUF-AX3000 armv7l）**：因 `ignlist_minimal` 含 `192.168.0.0/16`、实验室客户端都是内网会被豁免掩盖 bug，故在路由器侧用 SNAT 把测试客户端来源改写成 TEST-NET-3 `203.0.113.50`（非保留段）忠实模拟公网连入。结果：**TCP** 修复前 connect 超时 6s / 加守卫后秒回 banner / 部署源码 + 整机 restart 后 3/3 成功；**UDP** 三段开关（有守卫成功 → 删守卫失败 → 复原成功）逐一坐实。**回归**：LAN 客户端访问海外站仍走代理节点（ipinfo.io 出口 GB `3.9.92.164`）、Google generate_204=204、百度 200 直连。
- **CLAUDE.md 硬规则 #28**。

#### D34: 黑白名单 IP/CIDR + 梅林软件中心开关失效（迁 xray emit）+ 全局变量二次解码乱码（doge.14.x 修复）

2026-06-19 客户报告「直连梅林软件中心生态域名」开关失效（开/关无区别）。全仓库根因排查的波及面与修复：

- **域名白/黑名单**：`generate_xray_json_split` §4.4 #2 早已 emit（doge.12 alpha 起），受 `apply_blackwhite` 控制、排在 Mode 自身规则前（最先触发）。**本就正常**，不动（曾一度误判为"整页失效"，真机只实锤了 ipset 那条死路，未先读 generate 全路径 → 教训：报告波及面前先读全部消费路径）。
- **IP 白/黑名单**（`ss_wan_white_ip`/`ss_wan_black_ip`）：从未在 generate 里 emit，只靠 `add_white_black` 的 `ipset add white_list/black_list`；doge.14 `creat_ipset_split` 只建 `ignlist_minimal`、不建 white_list/black_list ipset → 运行时 ipset 不存在 → **IP 黑白名单完全失效**。
- **梅林开关**（`ss_basic_direct_asusgo`，doge.9）：4 域名只硬编码写 `/tmp/white_list.txt`；doge.14 该文件全仓库**只写不读**（chinadns split conf 只读 chnlist.gz/gfwlist.gz，无 white group）→ **开关失效**。
- **修复**（`generate_xray_json_split` §4.4 #2）：黑白名单段从「仅域名」扩成 4 条独立 emit——白名单域名（**含梅林开关注入的 4 域名**）→ out_direct / 白名单 IP → out_direct / 黑名单域名 → default_action / 黑名单 IP → default_action。domain 与 ip **各自独立成 rule**（D27/D29）。`apply_blackwhite` 判断改 `${apply_bw:-1}`（空默认开，与 asp 兜底 `|| '1'` 对齐）。
- **D34 坑：IP 段不能用全局 `${ss_wan_white_ip}`/`${ss_wan_black_ip}`**。`add_white_black`（apply_ss 里在 generate 之前调用）**就地把这俩全局变量解码成明文**（ssconfig.sh:2437/2404，无 `local`）。IP 段若再 `fss_b64_decode` → 对明文二次解码 → 乱码 IP（`invalid IP: …`）→ xray -test 失败 → 分流回退基线（`fss_split_xray_warn=xray_test_failed`，LAN 分流全废）。域名段无此问题（white_domain 用 `local`、black_domain 只 pipe，全局未污染）。**修法**：IP 段从 dbus 重读原始 base64（`local _wip_b64=$(dbus get ss_wan_white_ip)`）再解码，使 generate 自包含、不依赖另一函数副作用。
- **梅林开关 UI/语义**：留在「黑白名单」页最上面（不搬家），作为白名单**内置预设项**——跟着 `apply_blackwhite` 走（默认所有 Mode 开 → 默认全模式全设备生效）。hint 202 文案 + asp 编辑弹窗 `apply_blackwhite` 兜底 `|| '1'` 同步更新。
- **真机验证（2026-06-19，51.1）**：restart 后 warn 空（test 通过不回退）、xray.json 10368B（回退基线仅 1115B）、3 Mode 各含 koolcenter + 白名单 IP 66.92.50.164 + 黑名单 IP 160.79.104.1。**开关 on/off 对比坐实**：`=0` → koolcenter 出现 0 次；`=1` → 3 次。
- **残留**：`add_white_black` 写 `/tmp/white_list.txt` + `ipset add white_list/black_list` 整段 doge.14 已是死代码（无消费者），本次未清（梅林已迁 xray，留着冗余无害），另开任务清理。
- **CLAUDE.md 硬规则 #29**。

#### D35: DNS 泄露——检测站探测域名 `whoami.akamai.net` 在 chnlist → split 走 china-dns 暴露国内解析器（doge.14-beta.16 修复）

2026-06-20 客户报告：全局模式设备做 DNS 泄露测试仍「部分泄露，大多是检测 IP 的网站」。多轮真机排查（用户给测试路由器套国内 IP 复现）。

- **根因**：检测 IP/DNS 泄露网站常用 `whoami.akamai.net`（akamai resolver-reveal 端点，A 记录 = 递归解析器的出口 IP）来「问」你的 DNS 是谁。该域名在 `chnlist.gz`（akamai/apple CDN 族 93 条）→ 大陆白名单(split)实例 65353 打 `tag=chn` → 走 `china-dns`(223.5.5.5/114) **直连**解析 → 检测站的权威 NS 看到一个国内解析器 = 用户看到的「泄露」。**只漏 akamai 这类探测**（cloudflare/google/dnscrypt/bash.ws 的探测域名都不在 chnlist → `tag=gfw` 走代理 → 不漏）= 用户说的「部分」。
- **全局实例(65354)本就干净**（三证）：① verbose 日志逐条 `tag:gfw → forward to trust group → tcp://1.1.1.1`，连 `baidu.com`/`qq.com` 都走代理；② 实测 `whoami.akamai.net` 经 65354 → `172.69.x`(Cloudflare 海外)；③ 配置无 `china-dns`、无 chnlist、`default-tag gfw`。所以会漏的「全局设备」其 DNS 实际走到了 split 实例（见下「架构事实」）。
- **修复**：`generate_chinadns_split_conf` 把 split conf 的 `gfwlist-file` 从单路径 `gfwlist.gz` 改为 `gfwlist.gz,/tmp/fss_dns_leak_probe.txt`，并 `printf '%s\n' 'whoami.akamai.net' 'akahelp.net' > /tmp/fss_dns_leak_probe.txt`。**本版 chinadns-ng(2026.01.29) 默认 gfwlist-first**（`-M/--chnlist-first` 未设）→ gfwlist 命中即 `tag=gfw` **覆盖 chnlist** → 强制走 `trust-dns`(经 socks5→xray→节点) → 检测站只看到海外解析器。`whoami.akamai.net` 精确匹配（不动 `akamai.net` 其它 CDN 子域）、`akahelp.net` suffix 匹配（akamai 另一诊断域族，纯诊断无内容）。**真实国内 CDN（baidu/apple 命中 chnlist）仍 `tag=chn` 走 china-dns，速度零影响。** ⚠️注意与旧版相反：CLAUDE #11「chnlist>gfwlist」是旧单实例/旧路径，本版 split 实例 **gfwlist-first**。
- **架构事实（排查副产物）——「按设备分 DNS」与 DNS 重定向的绑定**：主 dnsmasq(端口 53)上游**写死** `server=127.0.0.1#65353`(split)。per-device DNS 路由靠 **DNS 重定向**（hijack：nat PREROUTING DNAT `-i br0 --dport 53`，此阶段源 MAC/IP 可见 → 按设备选 65353/65354）实现。三种组合：① 重定向**开** → DNAT 把设备查询送到其模式对应实例（全局设备→65354 干净）；② 重定向**关** + 设备 DNS=路由器 IP → 查询落到 dnsmasq（路由器自身 IP 在 `ignlist_minimal` 192.168/16 放行、不进 TPROXY）→ dnsmasq 转 65353(split) → **per-device 失效、全局设备也吃 split DNS → 漏 akamai**；③ 设备 DNS=外部解析器(8.8.8.8) → 目标外部 IP 经全局路由 TPROXY 整体代理 → 海外解析器、不漏（不需重定向、可与自定义 dnsmasq 共存）。**修复点统一在 65353，故重定向开/关两条路（per-device DNAT→65354 与 dnsmasq→65353）都覆盖**（dnsmasq 也转 65353）。结论：「按设备 DNS 分流必须开 DNS 重定向」；重定向关时只能靠设备自己指外部 DNS 来得到海外解析。
- **真机验证（2026-06-20，51.1，套国内 IP / 英国节点 3.9.92.164）**：`whoami.akamai.net` 经 split 路径 `123.156.198.67`(联通) → 修后 `172.69.79.104`(Cloudflare)；经 dnsmasq(53) 同样 Cloudflare；`baidu.com` 两路仍国内 IP；`google.com` 两路都海外。
- **CLAUDE.md 硬规则 #30**。

#### D36: 自定义 dnsmasq（address=/server=）在 DNS 重定向开启时也生效——chinadns `group custom` 转发到 65355 卫星 dnsmasq（doge.14-beta.17）

2026-06-20 用户需求：DNS 重定向开启时（per-device DNS 分流所必需，见 D35），LAN 设备 53 端口查询被 nat DNAT 直送 chinadns-ng(65353/65354)、**绕过主 dnsmasq** → 用户在【自定义 dnsmasq】(dbus `ss_dnsmasq`) 写的 `address=`/`server=`（屏蔽广告、改写 KMS/autodesk 到指定 IP 等）全部失效（D35 架构事实的副作用）。

- **方案**：复用现有 chinadns `group` 机制（与 `group lan`/`group node` 同款）。把自定义 dnsmasq 涉及的域名做成 group-dnl，两个 chinadns 实例（split 65353 + global 65354）一看到这些域名就转给 65355 卫星 dnsmasq（卫星已加载这些 `address=`/`server=` 规则）→ 命中拿用户指定结果（`0.0.0.0`/`127.0.0.1`/指定 IP）返回，未命中域名照常走分流。**不动 DNS 重定向、不碰 iptables。**
- **关键前提（真机 A/B 实证，CLAUDE #31）**：本版 chinadns-ng(2026.01.29) **用户 group 优先级最高、覆盖 chnlist + gfwlist**（dnl 加载序 custom→gfw→chn，先加载抢域名）。所以 group custom 里即便是 chnlist/gfwlist 内的域名（adobe 在 gfwlist、xmind.cn 可能在 chnlist）也被 custom 抢走 → 走卫星 → 用户规则生效。是 D35「gfwlist-first 覆盖 chnlist」同源机制延伸到 user group 层。
- **实现**（`ssconfig.sh`，1 新函数 + 3 处改）：
  1. `__build_custom_dns_rules()`（新）：`dbus get ss_dnsmasq | base64_decode | awk` 抽 `^[[:space:]]*(address|server)=` 行 → `/tmp/fss_custom_dns_rules.conf`（**catch-all `/#/` 跳过**，免污染卫星 LAN 解析），涉及域名（支持多域名行 `address=/a/b/ip`）→ `/tmp/fss_custom_dns_domains.txt`。**fail-safe**：规则整体 `dnsmasq --test` 不过 → 清空两表（功能静默关、不连累其它解析）。空 `ss_dnsmasq` → 两表空 → 行为同旧版。
  2. `start_dnsmasq_lan_listener()`：开头调 `__build_custom_dns_rules`；65355 卫星 `--conf-file=/dev/null` → `--conf-file=/tmp/fss_custom_dns_rules.conf`（卫星保持 `--no-resolv`：无规则域名 REFUSED、**fail-closed 不成环不外泄**；只过滤后 address=/server= 进卫星，`--port`/`--listen-address` 不被用户配置覆盖）。
  3. `generate_chinadns_split_conf` + `generate_chinadns_global_conf`：group lan/node 之后追加 `if [ -s /tmp/fss_custom_dns_domains.txt ]; then cat>>conf <<EOF / group custom / group-dnl ... / group-upstream 127.0.0.1#65355 / EOF; fi`（域名表非空才发，两实例都发）。
- **为何卫星 fail-closed 而非指向主 dnsmasq#53**：主 dnsmasq 默认上游=65353，若 group custom→#53 则未精确命中的域名会被主 dnsmasq 回转 65353 → 成环 DNS 风暴；65355 卫星 `--no-resolv` 对未命中域名 REFUSED，安全。
- **真机验证（2026-06-20，51.1=TUF-AX3000_V2 armv7l，热部署 ssconfig.sh + `restart_chinadns_ng`，`ss_dnsmasq`=baidu[chnlist]+google[gfwlist]+xmind[neither]→0.0.0.0）**：
  - **优先级 A/B 铁证**：无 group custom → gfw `added:6451`；有 group custom → custom `added:3`、gfw `added:6450`(−1=google 进 custom)、chn `−1`(baidu 进 custom)。
  - **生成产物**：rules.conf/domains.txt 内容对、group custom 块在 split+global 两 conf、dnl_init `tag:custom loaded:3`。
  - **端到端（PC 经路由器，DNS 重定向开）**：`nslookup baidu.com/google.com/xmind.com 192.168.51.1` 全 `0.0.0.0`（覆盖 chnlist+gfwlist）、`example.org`=真实 IP（非自定义不受影响）。链路：PC→router:53→DNAT→65353→group custom→65355 卫星→0.0.0.0。
  - busybox 限制：测试机**无 `nc`/`od`/`printf`(独立)/`socat`**、`nslookup` 无端口 → 验证靠 chinadns dnl_init `added` 计数差 + 经主 dnsmasq 链的 PC 查询（无法直查 65353/65398 端口）。
- **同会话清理**：删 smartdns 时代死 DNS 代码 **~323 行**（12 函数 `gen_xray_dns_inbound`/`append_xray_dns_relay_inbounds`/`get_dns`/`get_dns_para`/`format_dns_endpoint`/`parse_dns_addr_port`/`get_proxy_type`/`detect_domain`/`get_dns_selected_net`/`get_dns_effective_net`/`iter_dns_udp_relay_targets`/`has_dns_udp_relay_targets` + 5 空转调用 + 2 append-if 块；保留 `is_domain`/`append_xray_ipv6_tproxy_inbound`/`proxy_core_supports_udp`）。`iter_dns_udp_relay_targets` doge.14 删 smartdns 后即 `return 0`，整条 UDP-DNS-relay inbound 链已死。`dash -n`/`sh -n` 过、零残留引用。
- **状态**：✅ 已随 doge.14-beta.17 发版（commit aeb70fe）。CLAUDE.md #31。

#### D37: 卫星 dnsmasq(65355) 启动健壮性——被固件异步 `service restart_dnsmasq` 的迟到 killall 误杀（doge.14-beta.18）

2026-06-20 排查 D38 时发现的次要 bug：beta.17 安装后 `ss_split_dnsmasq_lan_status=down`、65355 无进程，但手动跑同一条命令秒起。

- **根因**：`restart_dnsmasq()` 用 `service restart_dnsmasq >/dev/null 2>&1 &`（**异步**），其 `killall dnsmasq` 会杀掉**所有** dnsmasq（含卫星）。`apply_ss` 两分支都是 `restart_dnsmasq → start_dns_x（起卫星）`，异步 killall 常在卫星起来**之后**才触发 → 把刚起的卫星一并杀掉。重启时碰巧 killall 早于卫星则幸存（故"安装死、重启活"时好时坏）。卫星死 = `group lan`/`group custom` 上游(65355)失效（**非致命**：常规 gfw/chn 上网不受影响，仅 LAN 域名反查 + 自定义 dnsmasq 域名失效）。
- **修复**（`ssconfig.sh` 3 处）：
  1. `start_dnsmasq_lan_listener()`：单次 `sleep 1` 检查 → **轮询最多 5s + 幂等（已监听即 ok 返回，供二次确认复用）+ 启动前清理半死实例（kill 旧 pid）**。
  2. `apply_ss`：`load_iptables` 后（所有 dnsmasq 重启都结束、异步 killall 已落定）**二次确认/拉起卫星**（调 `start_dnsmasq_lan_listener`，幂等、活着即跳过）。
  3. `restart_dnsmasq()`：异步 `service restart_dnsmasq &` 后加 `sleep 2` 再 `detect_running_status`，让迟到的 killall 先触发，避免 detect 误判到 killall 前的旧 dnsmasq 就返回。
- **验证**（51.1 armv7l）：beta.18 install → `dnsmasq_lan 启动成功`、`卫星 dnsmasq 状态=ok`（修复前为 down）；整机重启后卫星仍 ok、pid 稳定存活。

#### D38: 开机时钟死锁——TLS 节点 + 重启时钟停在 2024 → 代理永久卡死（doge.14-beta.18，本次主修复）

2026-06-20 客户报「doge.16 更新到 doge.17 后重启路由器，启动日志一切正常但最后无法正常链接」（代理失效 / DNS 失效 / 出口检测失败）。在 51.1 用客户的确切自定义 dnsmasq 配置 + 整机重启**完整复现**。

- **根因（死锁闭环）**：路由器重启后系统时钟在 NTP 同步前停在 `2024-01-01`（`ntp_ready=0`）→ 节点 TLS 证书（有效期 2025~2026）被 xray 判「尚未生效」、握手失败 → xray 连不上节点、代理失效 → 国外域名（含 NTP 服务器 `pool.ntp.org`）走 `trust-dns` 经代理无法解析 → NTP 永远同步不了 → 时钟一直卡 2024 → **永久死锁**。固件自身 NTP 配的是 `pool.ntp.org` 域名、自己是死锁的一环救不了自己。
- **为何看似 doge.17 回归实则不是**：死锁的 TLS/时钟/NTP 路径在 doge.14+ 一直存在、与 beta.17 的 DNS 改动无关。触发取决于**节点证书 notBefore 相对 2024-01-01**——节点最近换了证书（2025+ 生效）后，开机的"2024"开始顶不住；客户恰在此时更新到 doge.17，两件事赶到一起。（beta.17 唯一实质改动 = 卫星 dnsmasq，已由 D37 单独修复，非主因。客户已确认：节点为 TLS、故障时确实见过路由器时间错乱。）
- **症状迷惑性**：启动日志全绿——DNS 核心正常、节点域名能解析（`group node` 走 china-dns **直连**、不受代理死锁影响）、卫星 ok；唯独出口检测失败 + 所有 gfw 域名解析失败。
- **铁证**：`date -s "2026-..."` 手动设对时钟 → 代理瞬间全恢复（86.x 海外出口、`curl --socks5` rc=0）。
- **修复**（`ssconfig.sh` 新增 `fss_fix_bogus_clock()`，`apply_ss` 中 `prepare_system` 后、`start_xray` 前调用）：年份 < 2025 时用**硬编码国内 NTP IP**（`203.107.6.88` 阿里云 / `120.25.115.20` / `119.28.183.184`）`ntpd -n -q -p IP` **直连校时**（纯直连、不依赖 DNS/代理；每 IP 轮询超时 5s；成功即 return、全失败也不阻塞启动）。打破死锁：时钟回正 → TLS 通过 → xray 连上 → 代理正常。
- **诊断增强**：`check_status` 启动尾部加 DNS 链路诊断（卫星状态 / 65353-65355 监听 / **系统时钟 + ntp_ready** / `www.baidu.com` 本地解析自检），今后"启动正常但连不上"一眼可定位。
- **验证**（51.1 armv7l 整机重启，gold-standard）：启动日志 `⏰ 校时成功…2026`、出口检测 `86.53.160.85` 通过（修复前同场景死锁卡死）；DNS / 代理 / 自定义规则全恢复。代码纯 shell、与架构无关，hnd_v8(aarch64) 同适用。
- **状态**：✅ 已随 doge.14-beta.18 发版（commit b4a41d2）。CLAUDE.md #32。

#### D39: 国外/全局 DNS 支持 UDP 也经代理——`proxy-protocol tcp,tls` → `tcp,tls,udp`（doge.14-beta.19）

2026-06-20 用户需求：国内 DNS 不论协议都直连、国外/全局 DNS 不论协议（含 UDP）都经代理。探索结论 = 可行且改动极小（核心 2 行）。

- **现状根因**：两实例（split 65353 / global 65354）都用 `proxy-server socks5://127.0.0.1:23456` + `proxy-group gfw` + `proxy-protocol tcp,tls` 把可信上游（trust-dns，tag=gfw）经代理走。`proxy-protocol` 只列 tcp,tls → **UDP 上游不经代理、直接发出 → 直连泄露/被墙投毒**（用户在 DNS 设定页下拉能选「普通 UDP」却静默走直连，UI 与后端不一致）。
- **国内 DNS 本就直连**：chinadns-ng 帮助文本 `proxy-server` = "socks5 proxy for trust upstream dns"——proxy 只作用于 trust/gfw 组，china-dns（tag=chn，不在 proxy-group）**永远直连、与 proxy-protocol 无关**。故"国内不论协议都直连"是结构性保证，无需改。
- **可行性三前提（全满足，二进制实证）**：① chinadns-ng 2026.01.29 `--proxy-protocol <list>` 合法值 = `tcp,tls,udp`（帮助文本原文 "proxy only these upstream protos: tcp,tls,udp"）；② 二进制含 `socks5.request_udp_associate` / `build_udp_datagram` → 实现 SOCKS5 UDP ASSOCIATE；③ xray socks 入站(23456) 所有 `creat_*_json` 均 `"udp": true`，`generate_xray_json_split` 重写时保留该入站。
- **修复**：两处 `proxy-protocol tcp,tls` → `tcp,tls,udp`（[ssconfig.sh:1692](../../fancyss/ss/ssconfig.sh#L1692) split + [:1825](../../fancyss/ss/ssconfig.sh#L1825) global）。`__filter_valid_split_dns_lines`（:1636）本就放行 `udp://` 与裸 IP（case `udp://*` 在 `*://*` 丢弃前命中），无需改。文案：「仅支持 TCP/DoT」→「仅支持 普通UDP/TCP/DoT，不支持 DoH」（:1667/:1807）；兜底提示「经代理需 TCP/DoT，故用 TCP」→「经代理默认用 TCP，也支持 UDP/DoT」（:1679/:1811，默认值仍保留 TCP）。
- **新增 UI 提醒**（[Module_shadowsocks.asp:16787](../../fancyss/webs/Module_shadowsocks.asp#L16787)）：国外/全局 DNS 选「普通 UDP」**需节点支持 UDP 转发**，否则解析超时——split 模式 = 国外域名解析失败、国内正常；global 模式 = 全 DNS 失败近乎断网；chinadns 不会自动回退 TCP，需手改。
- **风险**：纯增强，原 TCP/DoT 用户零影响（`tcp,tls ⊂ tcp,tls,udp`），顺带修了「选 UDP 静默直连泄露」。UDP 大响应理论上有分片顾虑，故默认仍 TCP。
- **验证**：自审 `bash -n` + git diff 越界检查 + asp BOM/CRLF 字节核对（EF BB BF / CR==LF==17408）；独立 reviewer subagent 判 SHIP 零 BLOCKER（重点复核 `__filter_valid_split_dns_lines` 不丢 udp、conf 语法不 exit(1)）。**未真机测**（用户无"不支持 UDP 的节点"环境，改动小风险低，用户授权静态检查通过即发版）。
- **状态**：✅ 已随 doge.14-beta.19 发版（commit 785e4ca）。CLAUDE.md #33。

#### D40: 修 TCP DNS 在重定向下失败（chinadns `bind-port @udp`）+ 国外/全局 DNS 改只支持 TCP/DoT（doge.14-beta.20）

2026-06-21 用户报"开代理后经常 `ERR_NAME_NOT_RESOLVED`，所有设备都可能、手机概率高，关 DNS 重定向就好"。同会话先排查 D39 的 UDP 上游经代理为何不通，再揪出本 TCP DNS bug。两个独立根因，合并 beta.20 修复。

**根因 1（D39 续）：UDP 上游经代理在 chinadns-ng + xray 组合下根本不通——是 chinadns 客户端 bug，非节点、非 xray。** 真机三段实证：
- socat MITM 抓 SOCKS5 控制连接：握手完全成功（xray 回 `05 00 00 01 7f000001 5ba0` = REP 0 + BND 127.0.0.1:23456）。
- 手工用 socat 发标准 SOCKS5 UDP 数据报（**全程保持 TCP 控制连接打开**）：xray 完美中继、经 vless 节点拿回真实 google.com 应答（证 xray socks UDP 中继 + 节点 UDP 都好）。
- socat `-d -d` 时间戳坐实 **chinadns 收到 BND 回复的同一毫秒就关闭 TCP 控制连接**（`socket fd is at EOF`），而非等 5s 超时。按 RFC 1928 §6「UDP 关联随承载 ASSOCIATE 的 TCP 连接终止而销毁」，xray 严格遵守 → 关联即销毁 → chinadns 随后发的 UDP 落到死关联被丢（xray 从无 `client UDP connection` 日志）。chinadns 假设 socks 服务端"宽松"（TCP 断后 UDP 中继仍在，如作者自家 ss-local/ipt2socks），与 xray 不兼容。**fancyss/xray 任何配置改不动 chinadns 二进制。**
- 决策（用户）：UDP-via-proxy 不值得为它重编 chinadns（DNS over TCP/DoT 功能等价、DoT 更安全）。**国外/可信 + 全局 DNS 只支持 TCP/DoT，删 UDP 选项**；D39 的 `proxy-protocol +udp` 回退。

**根因 2（本次主修，潜伏自 doge.14）：DNS 重定向把设备 TCP DNS 也 DNAT 到 chinadns，但 chinadns `bind-port @udp` 只监听 UDP → TCP 查询撞 RST。**
- live iptables：`SHADOWSOCKS_DNS_0` 链对 `-i br0` 的 **udp 与 tcp** dport 53 都 DNAT 到 `127.0.0.1:65353/65354`（PREROUTING 跳转 `-j SHADOWSOCKS_DNS_0` 无协议过滤 → 链内两条规则都生效）。
- chinadns `bind-port 65353@udp` → 只 UDP listener（netstat 无 tcp 65353/65354）。
- 故设备 **TCP DNS** → DNAT 到 chinadns 的 TCP 端口 → 无监听 → 内核 RST（`Connection refused`）→ 解析失败 → `ERR_NAME_NOT_RESOLVED`。
- 间歇性 = 多数 DNS 走 UDP（正常），只有用到 TCP 的查询失败（UDP 响应超 512B 按 RFC 必须 TCP 重试 / 部分客户端偏好 TCP）；手机概率高 = 更易触发 DNS-over-TCP；关重定向就好 = 走主 dnsmasq（tcp+udp 都监听）。**与 D39 的 UDP-via-proxy 无关**（那是 chinadns 当客户端、本条是 chinadns 当服务端）。
- 真机复现（Ubuntu LAN 客户端，Python 构造 UDP/TCP DNS 打路由器:53）：UDP 全通、TCP 全 `Connection refused`；改 bind-port 去 `@udp` 后 TCP 全返回真实 IP。

**修复（2 文件）**：
- [ssconfig.sh](../../fancyss/ss/ssconfig.sh)：① 两实例 `bind-port …@udp` → 去 `@udp`（= tcp+udp 双协议，:1687 split / :1843 global）——**不动任何 iptables**（TCP DNAT 规则本就在，只是之前撞死端口）；② 新增 `__force_tcp_proxied_dns_lines()` helper（:1656），把国外/全局上游的 `udp://` 与裸地址一律改 `tcp://`（tcp://、tls:// 原样），在 `__filter_valid_split_dns_lines` 之后、建 FDNS_LINE 之前对 `_oversea_ok`/`_global_ok` 调用——兜底老用户存量 udp 值；③ `proxy-protocol tcp,tls,udp` → 回退 `tcp,tls`（两实例）；④ 文案对齐。**国内（直连）DNS 不调 force-tcp、保留 UDP**。
- [Module_shadowsocks.asp](../../fancyss/webs/Module_shadowsocks.asp)：`dns_make_proto_select(proto, allowUdp)` 对 trust（国外/全局）跳过 UDP option；`add_dns_upstream_row` 按 `dns_pick_which(key)` 传 allowUdp（仅 `'cn'` 为 true）并把老 udp 显示为 tcp；`render_dns_global_upstream` 同理（全局恒 trust）；卡片提醒改「仅支持 TCP/DoT，已移除 UDP 选项」。

**验证**：① bind-port 修复——Ubuntu 真机 TCP DNS 修前全 refused、修后 google/baidu/youtube/github 全返回真实 IP（经 `restart_chinadns_ng` 真实代码路径）；② force-tcp helper 隔离单测（`udp://`→`tcp://`、裸→`tcp://`、tls/tcp 原样、多行）全对；③ 重生成 conf = `bind-port 65353/65354`(无 `@udp`) + `proxy-protocol tcp,tls` + trust 全 `tcp://`；④ 双协议监听 tcp+udp 都在；⑤ Chrome 真机：国内下拉 udp/tcp/tls、国外/全局 tcp/tls（无 UDP）、老 udp 值渲染为 TCP、无 JS 报错。

**状态**：✅ 已随 doge.14-beta.20 发版。CLAUDE.md #33（修正）+ #34（新）。

#### D41: DNS 重定向"冷连接 SERVFAIL"（DNS_PROBE_FINISHED_BAD_CONFIG / ERR_NAME_NOT_RESOLVED）——加 dnsmasq 重试前端（doge.14-beta.21）

2026-06-21 用户报"装 beta.20 后 DNS 还有意料外问题"：刚重启后任何网页都解析不到（`nslookup` 返回 `Server failed`=SERVFAIL）；节点起来后"电脑+手机一起断 30秒-1分钟 → 正常几秒 → 电脑正常、手机先拿不到 DNS 再等很久"；Chrome 报 `DNS_PROBE_FINISHED_BAD_CONFIG` / `ERR_NAME_NOT_RESOLVED`。**与 D40（TCP DNS bind-port）是不同的根因**：D40 是 chinadns 没监听 TCP，本条是 chinadns 解析路径本身的瞬时 SERVFAIL 被原样透给设备。

**根因（chinadns-ng 设计 + 重定向架构错配，潜伏自 doge.14）**：chinadns-ng 源码（zfl9/chinadns-ng commit ab6c74f, `Upstream.zig::TCP.send_query`）对走代理的上游 TCP 连接，若连接尚未建立（冷启动 / 空闲关闭后），**不排队，直接回 SERVFAIL 让客户端重试**（注释原文 `let server reply SERVFAIL and rely on client retry`）；外加熔断（`--upstream-fail-threshold` 默认 3 次连续失败 → `--upstream-down-ms` 默认 10s 内全部秒回 SERVFAIL）。chinadns **设计上就坐在会重试的 dnsmasq 后面**。但 doge.14「DNS 重定向」把设备 53 端口 DNAT **直连 chinadns**（65353 分流 / 65354 全局），绕过了主 dnsmasq 的重试 → 设备拿到生 SERVFAIL。手机最重 = 休眠→上游连接空闲断开→醒来首查命中冷连接。"关 DNS 重定向就好" = 设备落回主 dnsmasq（自带重试 + 路由器自身流量一直保活 65353）。

**真机实证（armv7l 测试路由器 + Ubuntu LAN 客户端 Python 裸 DNS）**：
- 设备直连 chinadns（重定向路径）：冷缓存每轮 2 个 SERVFAIL（首个触发冷连接的查询秒回 SERVFAIL ~2ms，连接随即 ~270ms 建好、后续正常）。
- 同样查询经主 dnsmasq（重定向关）：**0 SERVFAIL**（dnsmasq 重试吸收，失败域名 693ms 拿到答案）——印证 chinadns「靠客户端重试」+ 重定向绕过重试 = bug。
- 启动后"30-60s 全断"= 节点未起时上游全失败 → 熔断连续触发 10s 锁定窗口叠加。

**修复（方案：给重定向路径补上 chinadns 设计所依赖的"会重试的 dnsmasq"，全在 [ssconfig.sh](../../fancyss/ss/ssconfig.sh)）**：
- ① 两个轻量 dnsmasq「重试前端」：`127.0.0.1:65356`→chinadns 65353（分流）、`127.0.0.1:65357`→chinadns 65354（全局）。`__start_one_dns_front` / `start_dns_redirect_fronts`（gate `ss_basic_dns_hijack=1`）/ `stop_dns_redirect_fronts`；端口常量 `SS_SPLIT_DNS_SPLIT_FRONT_PORT` / `SS_SPLIT_DNS_GLOBAL_FRONT_PORT`。
- ② DNS 重定向 DNAT 目标由 chinadns 端口改前端端口：新增 `__dns_front_port()`（65353→65356 / 65354→65357），`load_iptables_split` 的 per-device `dns_port` 与 `default_dns_port` 都过它。
- ③ 生命周期：`start_chinadns_ng_split` 末尾起前端；`stop_chinadns_ng_split` 停；`apply_ss` 末尾（所有 `restart_dnsmasq` 之后）幂等二次确认——因为固件异步 `service restart_dnsmasq` 的 `killall dnsmasq` 会连这俩前端一起杀（与卫星 dnsmasq 65355 同机制）。
- ④ 放宽熔断（两 conf）：`upstream-fail-threshold 10` + `upstream-down-ms 1000`——让冷启动时设备的快速重试不再 3 次就触发 10s 锁定（这才是"等很久/持续失败"的真凶）。
- ⑤ 前端 dnsmasq 关键 flag：`--conf-file=/dev/null`（**必须**——不给则读 `/etc/dnsmasq.conf` 的 `bind-dynamic` 与本前端 `--bind-interfaces` 冲突、起不来）、`--no-resolv --server=127.0.0.1#<chinadns> --no-negcache --cache-size=2000 --dns-forward-max=1500 --edns-packet-max=1232`（对齐主 dnsmasq 的 DNS 行为）。

**为什么不做保活/不改 chinadns**：① 保活（周期查国外域名让连接不空闲）实测被 chinadns 缓存命中绕过、且空闲断开间隔 < 测试间隔，finicky 且加守护进程复杂度；② chinadns「首查 SERVFAIL」是硬编码、无配置可关。前端重试 + 熔断放宽已足够：真机 retry-sim（客户端遇 SF 重试，模拟真实浏览器/OS resolver）**最终 0 失败**=用户不再见 `ERR_NAME_NOT_RESOLVED`。

**验证（测试路由器全程真机）**：前端 tcp+udp 都监听、重定向 DNAT 指向前端、chinadns 带熔断参数正常启动；冷 chinadns + 前端：raw 单发 0 SERVFAIL、retry-sim 0 失败；端到端路由不变（国外出口=英国节点、国内直连）。

**状态**：✅ 随 doge.14-beta.21 发版。CLAUDE.md #35。⚠️ 前端是 dnsmasq，受固件 `killall dnsmasq` 影响——任何新增 `restart_dnsmasq` 调用点后须确保 `start_dns_redirect_fronts` 被幂等重confirm。

#### D42: 全局模式 DNS 单点上游不可达 → 整盘解析失败（"海外单一DNS全部无法解析"）——全局改多上游 + 自动备用（doge.14-beta.22）

2026-06-21 用户报"装 beta.21 后分流 DNS 正常了，但全局模式（海外单一 DNS）配置全部无法解析"，截图为 `nslookup` 对 `8.8.8.8` 全部 **超时**（不是 SERVFAIL）。**与 D40/D41 不同根因**：D40/D41 是 chinadns 自身的监听/冷连接问题（影响所有实例）；本条是**全局实例的结构性脆弱**——全局模式把*所有*域名都发给那唯一一个海外上游、全程经代理，既无国内直连兜底、也无第二个上游做备用。

**根因（结构性，非代码 bug 的触发 + 缺乏冗余）**：
- 全局实例 `default-tag gfw` → 所有域名 → trust-dns（单一上游）→ socks5 经代理。分流实例则有两层冗余：国内域名走 china-dns **直连**（与代理无关）、国外域名走 trust 的**多个**上游（`8.8.8.8,1.1.1.1` 轮询取最快）。
- 用户节点（出口）**连得上 `1.1.1.1`、连不上 `8.8.8.8`**（节点出口屏蔽 Google DNS 很常见）→ 分流国外靠 `1.1.1.1` 兜底仍正常（故"分流看起来好的"）；全局只有 `8.8.8.8` 一个、无备用 → 全部解析失败。
- **为什么是"超时"不是"Server failed"**：设备 `nslookup` 默认 2s 放弃，chinadns 上游响应超时 5s，2s < 5s → 设备先超时（与 D41 的"秒回 SERVFAIL"症状正好相反，是另一类故障的判别特征）。

**真机定位（armv7l 测试路由器）**：
- 健康节点上 `8.8.8.8` / `1.1.1.1` / 两者 作全局上游均能解析 → **8.8.8.8 本身没问题**，问题是"用户节点到 8.8.8.8 的可达性"+"全局无备用"。
- 把全局上游改成不可路由地址（`tcp://192.0.2.53`）模拟"节点连不上该上游"→ **完整复现**：全局对所有域名超时（google/youtube 3s 超时、命中缓存的 baidu 例外），分流照常 → 与用户症状一致。

**修复（[ssconfig.sh](../../fancyss/ss/ssconfig.sh) + [Module_shadowsocks.asp](../../fancyss/webs/Module_shadowsocks.asp)）**：
- ① 后端 `generate_chinadns_global_conf`：去掉 `head -1`，改 `__join_split_dns_lines` 支持**多上游**（与"国外/可信"对称，chinadns 同组并发取最快）；空默认从 `tcp://1.1.1.1` 升级为 `tcp://8.8.8.8,tcp://1.1.1.1`。
- ② 后端安全网 `__ensure_global_dns_fallback()`：当全局只配 1 个上游时，自动追加一个**不同的**公共备用（`8.8.8.8`↔`1.1.1.1`，DoT/其它也兼容），保证全局始终 ≥2 个上游 → 单点不可达不再全盘失效。**存量用户升级即生效，无需迁移**（运行时补，不写回 dbus；用户在 UI 里仍看到自己填的那一个 + 可自行增删）。日志会提示已自动补备用。
- ③ UI：全局上游从专属"单行输入"（`render_dns_global_upstream`/`sync_dns_global_upstream`，已删）改为复用"国内/国外"的通用多行渲染器 `render_one_dns_upstream('ss_split_dns_global_upstream')`，带"+添加"/删除/预设；协议只给 TCP/DoT（经代理）。`ss_split_dns_global_upstream` 早已在 `_base64` / `params_base64` 存取数组里，多行 base64 存取与"国外"完全一致。

**链式代理（前置节点）验证（用户特别问到）**：经代理的 DNS 走的是 `out_main` 出站，而链式代理恰好把前置节点注入到 `out_main`（[ssconfig.sh](../../fancyss/ss/ssconfig.sh) `fss_chain_apply` 设 `.outbounds[0].streamSettings.sockopt.dialerProxy=proxy_front`）→ **DNS 与其它流量一样走完整条链**。D42 只改"用哪些上游"、不碰代理路径，对链式透明。测试路由器在链式开启（日本前置 433 → 英国落地 447）状态下实测：全局 DNS 经链路解析正常；把全局设为单一不可达上游后，**自动补的 `1.1.1.1` 备用仍经日本→英国链路解析成功**；LAN 设备出口=英国落地 IP（经日本前置），github 经链路解析+访问正常、国内直连。**链式下能否解析取决于"落地节点能否连上该上游"（前置只是隧道），与非链式同一条件，未引入新限制。**

**验证（测试路由器全程真机）**：helper 单元测试 6 组输入均产出 ≥2 个不同上游；单一不可达上游 → 自动补备用后全局正常解析（直连节点 + 链式两种都过）；多行 UI 渲染/增删/保存 base64 round-trip 无 control char（不触发 skipd）；语法 `dash -n`/`sh -n` 通过；asp BOM+CRLF 保留。

**状态**：✅ 随 doge.14-beta.22 发版。CLAUDE.md #36。

#### D43: DNS「重试前端」+ 卫星 dnsmasq 被固件 out-of-band `restart_dnsmasq` 杀掉后不自愈 —— 加 watchdog（doge.14-beta.23）

**背景**：D41（beta.21）给 DNS 重定向加了两个「重试前端」dnsmasq（65356/65357），D37 有卫星 dnsmasq（65355）。这三个都是 fancyss 自起的**独立 dnsmasq 实例，不在固件管理内**。**问题**：固件 out-of-band 的 `service restart_dnsmasq`（DHCP/WAN 续约、固件「重启 dnsmasq」按钮等）会 `killall dnsmasq` 把它们一并杀掉，而固件只会把主 dnsmasq(53) 重新拉起 → 这三个不自愈、不到下次 apply_ss 不恢复。DNS 重定向开启时被 DNAT 到这些端口的设备 DNS 全断。老版本（直连 chinadns）免疫（chinadns 不是 dnsmasq、`killall dnsmasq` 不杀它）= **回归**。这是 beta.21 对抗 review 提的待办 #5。

**真机复现（测试路由器 51.1）**：`service restart_dnsmasq` → 主 `:53` 重起、但 `65355/65356/65357` 全 0（被 killall 杀掉、不恢复）。

**修复（watchdog cron + 幂等 heal action + 4 个 nit，[ssconfig.sh](../../fancyss/ss/ssconfig.sh) + [fss_dns_front_watchdog.sh](../../fancyss/scripts/fss_dns_front_watchdog.sh) + [uninstall.sh](../../fancyss/uninstall.sh)）**：
- ① 新增 `fss_dns_front_watchdog.sh`：cron 每分钟，cheap `netstat` 检查（卫星 65355 插件运行即需要；前端 65356/65357 仅 DNS 重定向开启时需要），缺失即调 `ssconfig.sh heal_dns_fronts`。脚本顶部**显式 `export PATH`**——cron 的 PATH 不含 `/koolshare/bin`（dbus 在那），否则 `dbus`/`netstat` 找不到 → 判为「未启用」静默退出 → 永不自愈。
- ② 新 ACTION `heal_dns_fronts`：`start_dnsmasq_lan_listener` + `start_dns_redirect_fronts`（都幂等：先 `netstat` 再 spawn、只补缺失的；**不重启 chinadns、不碰主 dnsmasq、无递归**）。
- ③ cron 生命周期：`write_cron_job` 装 `fancyss_dns_front_wd`、`kill_cron_job` 删（disable_ss 调 `kill_cron_job` → 关插件即移除 watchdog，避免关后被它重起）、`uninstall.sh` 加 `cru d`。
- ④ `disable_ss` 加 `stop_dns_redirect_fronts` + `stop_dnsmasq_lan_listener` 清残留进程/pidfile。
- ⑤ review #5 nit：`__start_one_dns_front` / `stop_dns_redirect_fronts` 的 `kill -9 "$(cat pidf)"` 加**空 pid 守卫**（pidfile 空时不 `kill -9 ""`）；`stop_dns_redirect_fronts` 的 `_pf`/`_op` 加 `local`。

**为什么用 cron 而非 `dnsmasq.postconf` hook**：postconf 有「迟到 killall」时序竞争（D37 踩过——killall 可能晚于 postconf 到达）+ 不能干净调 fancyss 的 spawn 函数（要么重复实现、要么 source ssconfig.sh 有递归风险）；cron watchdog **不管死因**（固件重启 / 裸 kill / 进程崩溃）都能在 ≤1min 恢复，简单可靠。1min 恢复窗口对间歇性固件事件可接受（远好于「到下次 apply_ss 才恢复 / 永不恢复」）。

**真机验证（51.1 全程）**：① 直接 `heal_dns_fronts`：杀三实例→0、heal→3 ✓；② **真实 `service restart_dnsmasq` → 三实例全 0（复现）→ watchdog cron `02:39:00` 自动 heal → 全恢复 ✓**（启动日志留 `🩺 ... watchdog` 行）；③ 健康时 watchdog 为 cheap no-op（再跑不产生新 heal）✓；④ `dash -n` 通过。

**状态**：✅ 随 doge.14-beta.23 发版。CLAUDE.md #37。

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
