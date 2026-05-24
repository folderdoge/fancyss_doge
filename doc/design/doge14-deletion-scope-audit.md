# doge.14 sprint — 物理删除范围 Audit

> **状态**：2026-05-24 doge.13.1 hotfix release 后由 Explore subagent 完整扫描产出。
> doge.14 sprint **未启动**，本文档供 sprint 启动前查阅。
> **总估计净删除：-2786 行**（比早期 handoff 估计的 -2300 偏高 20%）。
>
> 关联：
> - 上游设计：[../implementation/split-routing-implementation.md §0](../implementation/split-routing-implementation.md)
> - 上次 sprint handoff（memory，仅本地）：`project_session_handoff_2026_05_23_doge13_stable.md`

---

## 0. 总览

doge.14 目标：物理移除 doge.12 alpha 起作为回退兜底保留的所有旧路径，让分流架构成为**唯一路径**。`ss_split_enabled` 开关变常量永远 `1`。

**估算总删除行数：-2786 行**（vs +少量 stub / migrate 代码）。

按风险等级：
- 🟢 **绿（可直接删）**：诊断日志 + hint 220/221 + 老 [DNS 设置] section
- 🟡 **黄（需谨慎，需同步删调用点）**：6 处 fork else 分支 + 老 `start_chinadns_ng()` + 老 iptables 老分支
- 🔴 **红（不能直接删，需 stub 化或 migrate）**：`ss_node_shunt.sh` 2121 行整文件 + 14 处 `mode=7` case

---

## A. `ss_split_enabled` fork 入口（11 处，比早期估计的 14 少）

| 文件 | 行号 | 类型 |
|---|---|---|
| ssconfig.sh | 1653-1657 | **路由层 fork** — DNS 启动 |
| ssconfig.sh | 5739-5748 | **路由层 fork** — xray json 生成 |
| ssconfig.sh | 6366-6369 | **路由层 fork** — ipset 清空 |
| ssconfig.sh | 7267-7270 | **路由层 fork** — iptables 加载 |
| ssconfig.sh | 8699-8701 | **路由层 fork** — ipset 创建 |
| ssconfig.sh | 8775-8788 | **诊断日志**（绿色，安全删） |
| ssconfig.sh | 9010-9015 | **路由层 fork** — chinadns 重启 |
| install.sh | 519, 729-730 | 文档注释 |
| install.sh | 2604 | **状态读取** — `dbus set ss_split_enabled="1"`（doge.14 变常量删除） |
| webs/Module_shadowsocks.asp | 6850-8601 | **UI 层** — 5 个 JS handler |

---

## B. `ss_basic_mode=7` 引用（14 处，分布 6 个文件）

| 文件 | 行号 | 类型 |
|---|---|---|
| ssconfig.sh | 245, 1393, 1988-91, 2017, 3631, 3703-18, 5753, 5763-65, 6543, 6617, 6647, **8708-31**, 8770 | 13 处 |
| scripts/ss_base.sh | 68, 137, 140, 143 | 4 处 mode=7 环境检测 |
| scripts/ss_chain_proxy.sh | 212 | chain proxy fallback |
| scripts/ss_node_shunt.sh | 154 | node shunt 模块检测 |
| scripts/ss_shunt_stats.sh | 352 | shunt stats 可用检测 |
| scripts/ss_node_subscribe.sh | 3627 | mode=7 订阅逻辑 |

🔴 **L8708-8731 `creat_shunt_json` 分支不能直接删** — 需保留兼容存量 mode=7 用户（doge.14 在 install.sh 加 migrate `ss_basic_mode=7 → mode=2`，迁移后才能删）。

---

## C. `ss_node_shunt.sh` 调用方

| 项 | 值 |
|---|---|
| 整文件大小 | **2121 行**（早期估计 600，实际 3.5×） |
| 调用方 | `ss_base.sh:16-17` / `ss_node_postsave.sh:6` / `ss_shunt_hot_reload.sh:4` |
| 模式检测 | `ss_base.sh:68` 检查 `type fss_shunt_effective_mode` |
| ASP UI 引用 | 无直接 dbus key |

🔴 **直接删整文件 = mode=7 path 全部 type check 失效 = 升级用户 BLOCKER**。

建议路径：
1. doge.14 初期：把所有 export func stub 化（`return 0`），文件保留 ≤50 行
2. doge.15（或 doge.14.1）：完全移除文件 + 3 个 source 调用点

---

## D. 老 `start_chinadns_ng()` 单实例

| 函数 | 行号 | 状态 |
|---|---|---|
| `start_chinadns_ng_split()` | 2453-2505 | V2 多实例（**保留**） |
| `start_chinadns_ng()` | 2517-2790 (估 ~275 行) | 老单实例（**删除**） |
| `stop_chinadns_ng_split()` | 2507-2515 | V2（保留） |

调用方（必须同步删）：
- ssconfig.sh:1656 — 旧 DNS 启动 fork else
- ssconfig.sh:2465, 2473 — split 内降级 fallback
- ssconfig.sh:9014 — restart_chinadns_ng case 分支

---

## E. 老 iptables 老分支

| 函数 | 行号 | 净删 |
|---|---|---|
| `load_iptables()` 老分支 | 7265-7293 | ~35 行 |
| `load_iptables_split()` 新版 | 7449-7860 | 保留 |
| `flush_ipset()` 老分支 | 6370-6435 | ~70 行 |
| `flush_ipset_split()` 新版 | 6437-6462 | 保留 |
| `apply_ss()` fork | 8699-8701 | ~3 行 |

**D16 注**：load_iptables 行 7272-7295 含 D16 老路径未补丁的等待 nat table 老代码，删除时 D16 老路径残留 bug 一并消失。

---

## F. 老 [DNS 设置] section（ASP）

精确范围：`fancyss/webs/Module_shadowsocks.asp:18353-18428` (~95 行)

涉及 dbus key（40+ 个）：
- `ss_basic_chng_*`（select / checkbox）
- `ss_basic_chng_china_dns_1/2/3_*`（3 套 China DNS）
- `ss_basic_chng_trust_dns_1/2/3_*`（3 套 Trust DNS）
- `ss_basic_chng_china_udp/tcp/dot_*_opt/usr`（27 个 input）
- `ss_basic_chng_ipv6_drop_direc/proxy`

同步删项：
- L10056-10084 JS handler 读取逻辑
- L8494-8496 params_input 数组引用

---

## G. hint 220 / 221 退役

| 位置 | 行号 |
|---|---|
| `ss-menu.js` hint 220 定义 | 1247-1257 |
| `ss-menu.js` hint 221 定义 | 1258-1271 |
| ASP openssHint(220) | 7747, 7758, 7795-96 |
| ASP openssHint(221) | 7771 |

🟢 doge.14 `ss_split_enabled` 变常量后所有触发点消失，安全删。

---

## H. AnyTLS TODO

**搜索结果：无匹配**。`ss_split_node_outbound.sh` 和 `ss_chain_proxy.sh` 均无 anytls 字串。早期 handoff 的 D7 残留 TODO 已在 doge.13 beta 期解决，doge.14 不需要再做。

---

## I. UI 重设计范围（用户脑暴范围，非必做）

doge.14 用户提出可顺手做 UI 重设计，候选范围：
- **[DNS 设置]** tab：老 schema（F 段 18353-18428）删除后该 tab 内容空了大半，自然变成"分流 V2 DNS upstream 编辑面板"。可借机做卡片化 / chip UI 替代散乱的 select+input 组合。
- **[访问控制]** tab：当前 ACL UI 是 doge.12 时代设计，per-MAC 只能绑定 Mode，没有批量操作 / 设备名展示 / Mode 跳转。doge.14 顺手重设计：设备列表卡片 + 拖拽分配 Mode + 设备别名持久化（dbus）。

UI 重设计 ≠ 物理删除 sprint 范围。建议先做物理删除 + 简单清理（H 已完成），UI 重设计另开 sprint（doge.14.x 或 doge.15）。但如果在 doge.14 范围内顺手做，老 [DNS 设置] section 删完直接接 UI 重写最自然。

---

## J. 推荐分阶段策略

### Phase 1（最小安全集，单会话可完成，~ -1500 行）
- 🟢 诊断日志删（8775-8788）
- 🟢 hint 220/221 删
- 🟡 ASP [DNS 设置] section 删（18353-18428 + JS handler）
- 🟡 6 处 fork else 分支删
- 🟡 老 `start_chinadns_ng()` + 老 `load_iptables` + 老 `flush_ipset` 老分支删
- **保留** `ss_node_shunt.sh` + mode=7 case（暂不动）

装机验证 → release `3.5.28-doge.14-beta.1` 真机跑 1 周。

### Phase 2（mode=7 退役，单会话 + 装机）
- install.sh 加 migrate `ss_basic_mode=7 → mode=2`（一次性，幂等标志 `fss_doge14_migrated`）
- 14 处 mode=7 case stub 化（`return 0` / 删 case 选项）
- `ss_node_shunt.sh` stub 化（export func 全 `return 0`，文件压到 50 行内）
- `creat_shunt_json` L8708-31 真删

装机验证 → release `3.5.28-doge.14-beta.2` 真机跑 1 周。

### Phase 3（清理与 UI 重设计）
- `ss_node_shunt.sh` 整文件物理删除 + 3 个 source 调用点删除
- `ss_split_enabled` 开关变常量 `=1` 永远（变量删除，代码用 `1` 字面量）
- `migrate_split_routing_v3` final cleanup（删 `ss_basic_chng_china_dns_*` 等 40+ 老 dbus key）
- 架构文档大重写
- （可选）UI 重设计：[DNS 设置] + [访问控制] page

装机验证 → release `3.5.28-doge.14`（去 beta 后缀）。

### Phase 4（doge.15+）
- 全部稳定后才考虑彻底重构（如把多个 helper 合并到共享 lib、common sanitize 抽出）

---

## K. 风险红线

1. **不能跳过 mode=7 migrate 直接删 case** — 任何 dbus `ss_basic_mode=7` 的存量用户升级 doge.14 会瞬间断网
2. **不能不 stub 直接删 `ss_node_shunt.sh`** — 3 个 sourcer 立即报错全套 mode=7 path 报错
3. **不能在 Phase 1 同时做 UI 重设计** — 删除 commit 必须干净 review，重设计另起 commit
4. **不能跳过装机验证连续推 3 个 phase** — 每 phase 装机 + 1 周真机才进下一阶段

---

## L. 进入 doge.14 sprint 前的准备

- ✅ doge.13.1 hotfix 已 release
- ⏳ 50.1 daily 升 doge.13.1（用户当前还在 doge.13-beta.3）
- ⏳ 多 Mode/Rule CRUD 边界测试（用户已开始：新建 Mode #3 + Rule 100，验证分流命中正确）
- ⏳ Failover 备用组合 V2 路径下验证（未做）
- ⏳ ACL Mode 多设备测试（手机 / Steam Deck / 笔记本，未做）

用户决策 (2026-05-24)：**跳过 2 周观察期，乐观推进 doge.14**。预期 doge.14 完成后小范围"不太碍事"设备先试，再大规模稳定性测试。

---

## M. Phase 1+2 真机验证记录（2026-05-24，build #2）

### M.1 实施摘要

走路线 2（Phase 1+2 一气呵成）。4 个 implementor subagent 并发 + reviewer 独立审查 + 主代理整合 + 装机验证。

| 维度 | 结果 |
|---|---|
| 文件变动 | 14 modified + 1 untracked (本 audit doc) |
| 净行数 | +236 / -3546 = **-3310** |
| ssconfig.sh | -1059 行（fork unwrap + 老函数 + creat_shunt_json no-op） |
| ss_node_shunt.sh | -2129 行（2121→43 stub） |
| Module_shadowsocks.asp | -257 行（老 [DNS 设置] section + 5 个 JS fork handler） |
| install.sh | 净 +51 -14（migrate_v3 + rules_user 保护） |
| reviewer 评级 | 1 P0 BLOCKER + 1 W2（顺手）+ 3 WARN（留 stable） |

### M.2 Reviewer 发现 + 修复（B1 + W2）

**B1（P0）**：`start_chinadns_ng_split` / `generate_chinadns_global_conf` 内有读 `ss_basic_chng_*` 的 fallback 分支，但 migrate_v3 step 2 把 chng_* 全清 → 从未点过 [DNS 设置] 保存的老用户升级 doge.14 后国内 DNS 永久兜底成 223.5.5.5。

**修法**：删 fallback 分支 + 删未用 local CDNS_1/2/3 / FDNS_1/2/3 声明。兑现 audit §D 承诺。

**W2**：`creat_shunt_json()` 函数体保留（dead code）但其中 `fss_shunt_build_xray_config` stub return 1 → 触发 `close_in_five flag` 错误弹窗。误调任何路径 = 用户面前弹窗。

**修法**：函数体改 `return 0` no-op + 标注 doge.15 物理删。

### M.3 真机暴露的 2 个 fix（audit 没列）

**fix #1：`ss_split_rule_seed.sh` syntax error（真根因诊断）**

build #1 装机时报 `line 35: syntax error: unexpected "(" (expecting "fi")`，rule_100.txt 自愈被中断。

**根因**：koolshare `base.sh:7` 等文件定义 `alias echo_date='echo 【$(...)】:'`（含 `$()` 复杂展开）。busybox sh 1.25.1 解析 `echo_date(){` 函数定义时**会展开 alias**，把它变成 `echo 【$(...)】:(){` → syntax error。

**修法**：在 ss_split_rule_seed.sh 的 `if ! type echo_date` 之前加 `unalias echo_date >/dev/null 2>&1`，让 alias 离场，下面的 function 定义解析时无 alias 干扰。sh 逐 statement parse+execute，unalias 先跑，function 定义后续解析 clean。

**新 CLAUDE.md 硬规则候选**：busybox sh + `alias X='...'` + 后续 `X()(){...}` function 定义 = syntax error。共享 helper 文件（被多个上下文 source）定义 function 前先 `unalias`。

**fix #2：`install.sh:2348 rm -rf /koolshare/ss/*` 把 rules_user/ 清掉（doge.13 老 BUG）**

升级 doge.14 时所有用户自定义 Rule 文件（rule_100+.txt）会被 `rm -rf` 清光，install.sh 后续 migrate_v1 自愈只重建内置 1~8。user data 永久丢。

**这不是 doge.14 引入**，doge.13/12 升级时一样炸——但当时 split routing 不是唯一路径，user rule 缺失影响小。doge.14 后是唯一路径，user rule 缺失 = 用户配置无法工作。

**修法**：rm 前 `cp -af rules_user/. /tmp/__fss_rules_user_backup_doge14/`，rm 后 restore。

### M.4 真机验证 PASS 清单（51.1 build #2 装机）

| 项 | 结果 |
|---|---|
| migrate_v3 mode 7→2 | ✅ 日志 `ss_basic_mode 7 → 2（节点分流已退役）` |
| ss_node_shunt_* 全清 | ✅ 2 个伪装 key 全 dbus remove |
| ss_basic_chng_* 全清 | ✅ 85 个真实 key 全 dbus remove |
| ss_split_enabled 清 | ✅ dbus remove 后 dbus get 空 |
| fss_doge14_migrated=1 | ✅ |
| rules_user 保护 fix 触发 | ✅ 日志双行 `备份` + `已恢复` |
| rule_100.txt 数据完整 | ✅ `# 测试 rule_100 内容\nipip.net\nip.sb` 没丢 |
| 无 syntax error | ✅ ss_split_rule_seed.sh unalias fix 兑现 |
| xray pid 监听 4 端口 | ✅ 23456 + 13333 + 13334 + 13335 |
| chinadns 双轨 | ✅ split @65353 + global @65354 |
| split iptables 装配 | ✅ default_mode=100 default_port=13335 |
| 51.2 LAN curl 出口 | ✅ `3.9.92.164`（UK AWS eu-west-2，Mode #3 default_action 出口） |
| 启动状态摘要 split_xray_warn | ✅ 空（无警告） |

### M.5 已知非阻塞告警

- `dnsmasq_lan: 启动失败，chinadns LAN 反查可能超时` —— 不影响主代理（curl PASS 证实 DNS 链路正常），Phase 3 排查
- `❌ split: 自愈失败仍缺: rule_100.txt` —— expected behavior（自愈分支只重建内置 1~8，user rule 由 rules_user 保护 fix 处理，本案例已恢复）

### M.6 状态收尾

- ✅ 本地 commit（不 push / 不 tag / 不 release）
- ⏳ origin/3.0 仍停在 doge.13.1 commit
- ⏳ 51.1 装机后跑着 doge.14-beta.1，等 Phase 3 续接验证
- ⏳ 50.1 daily 不动（按用户授权），等 doge.14 stable 一并升级

---

## N. Phase 3 范围（doge.14 stable 发版前）

### N.1 物理删除 + 注释清理（必做）

- `ss_node_shunt.sh` 整文件物理删（43 行 stub → 0）+ 3 sourcer 删（ss_base.sh:16-17 / ss_node_postsave.sh:6 / ss_shunt_hot_reload.sh:4）
- `ss_basic_mode=7` case 选项物理删（保留 stub 现在是防御性，stable 后可清，已无可达路径）
- `ss_shunt_stats.sh` 整文件物理删（已 main no-op，dead）

### N.2 UI 重设计（用户原意「直接做」）

按 [audit §I] 候选：
- **[DNS 设置] tab 重做**：老 section 删完空了大半，做卡片化双轨 DNS upstream 编辑面板（per-Mode dns_mode + 两轨 upstream 编辑）
- **[访问控制] tab 重做**：device ↔ Mode 绑定卡片化 + 拖拽分 Mode + 设备别名 dbus 持久化
- **[账号设置] / [故障转移]**：用户脑暴顺手做，范围待定

### N.3 Reviewer 留的 WARN（doge.14 stable 清完）

- **W1**：install.sh:516-518 + 723-725 历史注释指向 migrate_v3 step 3
- **W3**：ASP 11 处 mode=7 真业务逻辑分支（audit §B 漏列）—— 2021 / 2023 / 4158 / 4161 / 6563 / 6590 / 8242 / 8480 / 8502 / 8521 / 8905 / 12935 / 17185
- **W4**：ss_shunt_stats.sh:354+ 80 行 dead code（在 N.1 整文件删时一并清）
- **I5**：params_input 数组 8303-8317 仍含 14 个 `ss_basic_chng_*` 字段引用（save() 写空 → install 又删，无害但 noisy）
- **L1605 / L2588**：ssconfig.sh 老 chng_chk → UDP relay 检测 dead path

### N.4 老 dbus key 物理清理（migrate_split_routing_v3 扩 step）

- 40+ 个老 `ss_basic_chng_china_dns_*` / `_trust_dns_*` / `_china_udp/tcp/dot_*` key 已在 step 2 清
- doge.14 stable 加 step：清 ASP params_input 删完之后的 dead key（确认 N.3 W4 / I5 处理后）

### N.5 文档大重写

- `doc/implementation/split-routing-implementation.md` §0 / §4 / §14：从「fork-not-replace」改成「唯一路径」语境
- `doc/design/split-routing-architecture.md` §4 sniffing-routing：更新为 doge.14 之后无 fallback
- 本 audit doc 改 archive 标记（任务完成）

### N.6 不在 doge.14 范围（留 doge.14.x 或 doge.15）

- 共享 lib 抽 `has_dbus_forbidden_chars` 等 helper DRY 化
- 双轨 DNS per-Mode UI 编辑（仅 readonly 占位，Phase 3 开放编辑）
- per-rule 链式代理（proxy_chain:Y:X）从 collapse 到 out_main 改为真实 build chain outbound
