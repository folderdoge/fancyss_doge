# 故障转移备用组合列表 — 实施文档

> 🗄️ **已归档（ARCHIVED）— 2026-06-15 / `3.5.28-doge.14-beta.3`**：故障转移功能已整体物理删除（~1500 行 / 14 文件 + ASP 标签页）。本文档描述的「备用组合列表」机制、所有 `ss_failover_*` / `fss_failover_*` key、`ss_status_main.sh` 轮询守护、`ss_cron_restart.sh` wrapper、`ss_status_reset.sh` 均已不存在；相关 dbus key 由 `install.sh::purge_failover_remnants()` 一次性清除（幂等标志 `fss_failover_purged_v1`）。**本文档仅作历史参考保留，不要据此修改代码**；如未来重新引入故障转移，应作为全新设计重写。

> 关联设计文档：[doc/design/failover-combo-list-design.md](../design/failover-combo-list-design.md)
>
> 本文记录"实际改了哪些代码、写在哪里"。新会话过来维护这块功能时，先扫一遍 §2 文件清单 + §3 dbus key 清单，然后回头看具体函数实现即可。

---

## 1. 状态摘要

把旧的"故障转移切换到 X 节点"机制（`ss_failover_s4_2/s4_3` + 单一备用节点）重构为「备用节点组合列表」：

- 用户在 ASP UI 维护一张 (前置, 落地) 组合表
- 故障触发时按列表顺序切换到下一个 `failed=0` 的组合
- 前置为空 = 直连模式；非空 = 链式（自动适配）
- 全部失效时不切换，保持当前断网状态让用户察觉
- 用户主动 restart 时清空 `failed` 标志；故障转移内部 restart 不清

旧字段一次性迁移：升级到此版本时 `install.sh` 把 `fss_node_failover_backup` / `ss_failover_s4_3` 转成一个直连 combo，然后清空旧 keys，并打 `fss_failover_migrated_v1=1` 标记。

---

## 2. 文件清单 / 函数清单

### 2.1 [fancyss/scripts/ss_node_common.sh](../../fancyss/scripts/ss_node_common.sh)

文件末尾新增 helper 段（约 +186 行，从 4565 行起）：

| 行号 | 函数 | 作用 |
|---|---|---|
| 4574 | `fss_failover_combo_count` | 返回组合数量；空 / 非数字时返回 0 |
| 4587 | `fss_failover_find_combo <front> <landing>` | 在列表里找匹配项的索引；找不到输出空 |
| 4610 | `fss_failover_pick_next_available <cur_front> <cur_landing>` | 顺序扫第一个 `failed=0` 且 ≠ runtime 的组合 |
| 4642 | `fss_failover_resolve_combo <i>` | 通过 identity 重解析为最新 id（订阅刷新场景），输出 `front_id<TAB>landing_id` |
| 4664 | `fss_failover_clear_all_failed` | 把所有 combo 的 `failed` 改为 "0"，并清 `fss_failover_last_switch_ts` |
| 4680 | `fss_failover_combo_clear_slot <idx>` | 把单个 combo 的全部字段清空（reindex 尾部用） |
| 4693 | `fss_failover_combo_drop <idx>` | 删除 combo[idx] 并把后续 reindex 前移 |
| 4721 | `fss_failover_combos_resync_after_subscribe` | 订阅刷新后批量重解析所有 combo 的 `_id`；landing 解析为空时整条移除 |

另外在已有的备份/导出/清理函数里把 `fss_failover_*` 加进白名单（避免备份恢复后丢失 combo）：

- `fss_export_global_json`（第 2511 行附近）：导出新增 `dbus list fss_failover_`
- `fss_clear_global_config_storage`（第 2528 行附近）：清理白名单加 `dbus list fss_failover_`
- `fss_export_native_backup_v2`（第 4046 行附近）：备份白名单加 `dbus list fss_failover_`

### 2.2 [fancyss/scripts/ss_status_main.sh](../../fancyss/scripts/ss_status_main.sh)

`failover_action` 第 243 行起，整段 `s4_1=2` 分支重写为「找匹配 → 标 failed → 找下一可用 → 切 runtime → 写时戳 → 标 internal_restart → restart」流水线。

新增辅助：

| 行号 | 函数 / 改动 | 作用 |
|---|---|---|
| 304 | `failover_cool_down_active` | 读 `fss_failover_last_switch_ts` + `fss_failover_cool_down_sec`（默认 30）判定是否仍在冷却期；返回 0=冷却中 |
| 322 / 337 / 354 附近 | `failover_check_1/2/3` 开头加 `failover_cool_down_active && return` | c1/c2/c3 三种触发条件统一在冷却期内跳过本轮判定 |

老的 `pick_fastest_webtest_node`、`fss_set_failover_node_id` 调用（"切换到备用 / 下个 / 最快"三选一）整段移除。

### 2.3 [fancyss/ss/ssconfig.sh](../../fancyss/ss/ssconfig.sh)

入口 case 分支处加失效清理逻辑（[ssconfig.sh:8633-8689](../../fancyss/ss/ssconfig.sh#L8633)）：

```sh
case $ACTION in
start)
    __fofr="$(dbus get fss_failover_internal_restart)"
    if [ "${__fofr}" = "1" ] || [ "${__fofr}" = "2" ]; then
        # 内部触发的 restart（failover 自切 / cron / wan-start / legacy 故障检测），不清 failed
        dbus set fss_failover_internal_restart="0"
    else
        # 用户主动操作，清空所有 combo 的 failed 标志（同时清切换时戳解除冷却）
        fss_failover_clear_all_failed
    fi
    unset __fofr
    # ...
restart)
    # 同样的判定逻辑
```

要点：
- start 和 restart 两条入口都要加（`stop` 不需要）。`fss_failover_internal_restart` 是单次握手标志，无论清不清 failed，立即重置防遗留。
- alpha.17 起 flag 由两状态扩到**三状态**（`0` / `1` / `2`），把 cron / wan-start / legacy 路径与 failover 自切并列为"内部 restart"，避免周期性 restart 清空失败知识。完整语义与全部上游路径见 §4.7。

### 2.4 [fancyss/install.sh](../../fancyss/install.sh)

新增一次性迁移函数：

| 行号 | 函数 | 作用 |
|---|---|---|
| 406 | `migrate_failover_v1` | 看到 `fss_failover_migrated_v1 != 1` 时执行：识别旧的 `fss_node_failover_backup` 或 `ss_failover_s4_3` → 建立 combo #1（直连模式）→ remove 旧 keys → 打标记 |
| 1897 | `install_now` 末尾调用 `migrate_failover_v1` | 每次 install 流程都跑一次（幂等） |

迁移规则：
- 优先 `fss_node_failover_backup`（identity 化、稳定）
- 退回 `ss_failover_s4_3`
- 都是 0 / 空 → 不创建 combo，仅清旧 keys
- 节点不存在（`fss_node_id_exists` 检测失败）→ 跳过创建
- 用户已经手动配过 combo（`fss_failover_combo_count >= 1`）→ 不动 combo 内容，仅清旧 keys

### 2.5 [fancyss/scripts/ss_node_subscribe.sh](../../fancyss/scripts/ss_node_subscribe.sh)

订阅刷新 / 节点删除路径的 3 个收尾点都加上 combo 重解析（第 4411、4439、5326 行附近）：

```sh
fss_set_current_node_id "${restore_current}"
fss_set_failover_node_id "${restore_failover}"
fss_failover_combos_resync_after_subscribe >/dev/null 2>&1   # ← 新增
```

triggers：
- `sub_restore_active_nodes_after_rewrite` 两条 return 路径
- `remove_sub_node` 收尾

### 2.6 [fancyss/webs/Module_shadowsocks.asp](../../fancyss/webs/Module_shadowsocks.asp)

最大的改动文件，+373 / -43 行。分两块：

**A. 移除旧故障转移字段（11 处）**

- 第 4019 行：删除 `get_failover_node_id()` 函数
- 第 6479 行：`refresh_options()` 里删 `option3 = $("#ss_failover_s4_3")` 及其 append/val 逻辑
- 第 6986 / 7459 行：`save()` 里从 `fields_basic` 删除 `s4_2/s4_3`，并删 schema2 的 `fss_node_failover_backup` / `_identity` 写入
- 第 8499 行：`verifyFields` 里删除 `showhide("ss_failover_s4_2"/"s4_3")` 联动
- 第 9270 / 9305 行：`apply_schema2_node_delete_local` / `process_schema2_node_delete_queue` 里删除对 `fss_node_failover_backup` 的清理（被 combo 路径取代）
- 第 11240 行：`save_new_order` 里删 `ss_failover_s4_3` 的索引重排
- 第 15826 行：`save_failover` 里 `fov_inp` 删 `s4_2/s4_3`
- 第 16405 行起：`fa4_1` 改为 `[["0","关闭插件"],["1","重启插件"],["2","切换备用组合"]]`，删除 `fa4_2` 数组和它的 form 项 `s4_2/s4_3`
- 第 2174 / 2218 行：`collect_node_reference_delete_impact` / `show_deleted_node_reference_notice` 把旧的 `failover` 字段换成新的 `combos` 字段

**B. 新增备用组合 UI + 数据维护（约 +320 行集中在 6620–6932 段）**

| 行号 | 函数 | 作用 |
|---|---|---|
| 6621 | `failover_combo_count()` | 读 `db_fss["fss_failover_combo_count"]` |
| 6626 | `failover_combo_get(i)` | 拼前缀 `fss_failover_combo_<i>_*` 取出整条 combo |
| 6636 | `failover_combo_status(combo)` | 算状态：running / failed / available |
| 6645 | `failover_combo_node_label(id)` | 渲染节点标签（含【SS】【Vmess】等前缀） |
| 6666 | `failover_combo_html_escape(s)` | 防 XSS |
| 6669 | `render_failover_combo_panel()` | 渲染整个 `<div id="failover_combo_panel">` 表格 + 添加行 + select 选项填充 |
| 6743 | `failover_combo_persist(fields, cb)` | 通过 `dummy_script.sh` 路由把字段批量写到 dbus（不重启代理） |
| 6767 | `failover_combo_add()` | UI 添加：校验 front≠landing、不重复、landing 必填 → 写新行 |
| 6807 | `failover_combo_remove(i)` | UI 删除：禁止删运行中行，confirm 后 reindex |
| 6850 | `failover_combo_compute_delete_fields(impact)` | 节点删除时算 combo 清理 fields（landing 被删整体移除 + reindex；front 被删仅清空前置变直连）|
| 6913 | `failover_combo_apply_delete_fields_local(fields)` | ajax 成功后同步 db_fss 缓存 |
| 6921 | `refresh_failover_combo_panel_visibility()` | 故障转移开关切换时整段 show/hide |

接入点：
- 第 6587 行：`refresh_options()` 末尾 `render_failover_combo_panel()`
- 第 8502 / 8508 行：`verifyFields` 中故障转移开关分支同步 show/hide `#failover_combo_section`
- 第 9311–9320 行：`process_schema2_node_delete_queue` 中合入 combo 清理 fields，ajax 成功后 `failover_combo_apply_delete_fields_local` + 重新 `render_failover_combo_panel`
- 第 11244 行：`save_new_order` 加 combo 的 `_id` 同步重排（前置 / 落地都看一遍）
- 第 16456 行：在 `$('#table_failover').forms([...])` 末尾追加 `备用节点组合` block：

```js
{ title: '备用节点组合', rid:'failover_combo_section', hint:'201', multi: [
    { suffix:'<div id="failover_combo_panel"></div>' },
]},
```

### 2.7 [fancyss/res/ss-menu.js](../../fancyss/res/ss-menu.js)

`openssHint()` 加 itemNum=201 分支（约 +11 行，第 1075 行附近）：

```js
} else if (itemNum == 201) {
    width = "560px";
    statusmenu = "<b>备用节点组合列表</b>用于故障转移时按列表顺序切换备选 (前置, 落地) 组合。<br /><br />";
    // ... 切换规则 / 状态说明 / 失效处理
    _caption = "备用节点组合";
}
```

---

## 3. dbus key 清单

### 3.1 dbus key 清单

> ⚠️ 前缀变更：combo 字段一律走 `ss_failover_*` 前缀。原因是 koolshare `/_api/<prefix>` 的返回白名单仅包含 `ss` 前缀（且 `ssconf_basic_` / `ss_acl_` / `ssid_` 三类被 grep -v 过滤），用 `fss_*` 前缀写的 key 前端 reload 后无法被 `db_ss` 拉到。详见 [CLAUDE.md](../../CLAUDE.md) 硬规则 #1。本变更通过 `install.sh::migrate_failover_v2` 一次性迁移已有用户的 `fss_failover_combo_*` / `fss_failover_main_combo_seeded`。

**前端可读（`ss_failover_*` 前缀，落到 `db_ss`）**

| Key | 写入时机 | 清空时机 |
|---|---|---|
| `ss_failover_combo_count` | UI 添加/删除组合时 | 一次性迁移、用户清空全部 |
| `ss_failover_combo_<i>_front_id` | UI 添加 / 订阅刷新 / 节点删除 reindex | UI 删除该行 / 节点删除-清前置场景 |
| `ss_failover_combo_<i>_front_identity` | UI 添加 | UI 删除 / 前置被删（清前置） |
| `ss_failover_combo_<i>_landing_id` | UI 添加 / 订阅刷新 / reindex | UI 删除该行 |
| `ss_failover_combo_<i>_landing_identity` | UI 添加 | UI 删除该行 |
| `ss_failover_combo_<i>_failed` | failover_action 标记当前组合失效 | 用户主动 restart（`fss_failover_clear_all_failed`） |
| `ss_failover_main_combo_seeded` | 首次进入故障转移 ASP 页面、`ensure_main_combo_seeded` 落地后 set 1 | 不清（install-once 标志）；用户清空所有 combo 也不重置——同 v1 标记的语义 |
| `ss_failover_combo_migrated_v2` | install.sh `migrate_failover_v2` 完成后 set 1 | 不清（永久幂等标记） |

**后端专用（`fss_failover_*` 前缀；前端不需要直接读，故不受硬规则 #1 约束）**

| Key | 写入时机 | 清空时机 |
|---|---|---|
| `fss_failover_internal_restart` | failover_action 切换前 set `1`；cron / wan-start / legacy 故障检测路径走 `ss_cron_restart.sh` wrapper 或显式 set `2`（详见 §4.7） | ssconfig.sh 入口握手即 set 0（无论清不清 failed） |
| `fss_failover_last_switch_ts` | failover_action 切换成功后 = `date +%s` | 用户主动 restart（连同 clear_all_failed 清成 0） |
| `fss_failover_cool_down_sec` | （未在 UI 暴露，留作未来配置项） | 不主动清；空 → 默认 30 |
| `fss_failover_migrated_v1` | install.sh 迁移成功后 set 1 | 不清（永久幂等标记） |

### 3.2 已废弃（需迁移）

| 旧 Key | 处理 |
|---|---|
| `ss_failover_s4_2` | install.sh `migrate_failover_v1` 中 `dbus remove` |
| `ss_failover_s4_3` | 同上；其值若有效则迁成 combo #1 的 landing |
| `fss_node_failover_backup` | 同上；优先用此键作为迁移源 |
| `fss_node_failover_identity` | 同上 |
| `fss_failover_combo_*`（旧 fork） | install.sh `migrate_failover_v2` 一次性迁移到 `ss_failover_combo_*`，迁完 `dbus remove` |
| `fss_failover_main_combo_seeded`（旧 fork） | 同上，迁移到 `ss_failover_main_combo_seeded` |

### 3.3 备份恢复白名单更新

[ss_node_common.sh:2511 / 2528 / 4046](../../fancyss/scripts/ss_node_common.sh) 三个地方都把 `dbus list fss_failover_` 加进了导出 / 清理 / 备份的扫描范围，所以本机恢复或跨设备迁移都能带上 combo 配置。

---

## 4. 关键流程

### 4.1 故障触发 → 切换组合

`failover_check_1/2/3` (status_main.sh) 命中 → `failover_action $FLAG`：

1. 取 runtime `(cur_front, cur_landing)`
2. `fss_failover_find_combo` 找匹配 → 有则标 `failed=1`；没有则 LOG 提示 runtime 不在列表
3. `fss_failover_pick_next_available` 找下一个；找不到 → LOG "全部失效" + return
4. 写新 runtime：`fss_set_current_node_id` + `dbus set ssconf_basic_node_front`（前置为空时改 `dbus remove`）
5. `dbus set fss_failover_last_switch_ts=$(date +%s)`
6. `dbus set fss_failover_internal_restart=1`
7. `start-stop-daemon ... ssconfig.sh restart`

冷却期保护：`failover_check_*` 入口先 `failover_cool_down_active && return`。`fss_failover_cool_down_sec` 未设时默认 30 秒。

### 4.2 用户主动 restart → 清失效

帐号设置点"保存&应用"（[scripts/ss_config.sh:89](../../fancyss/scripts/ss_config.sh#L89)）或路由器 SSH `ssconfig.sh restart`：

1. ssconfig.sh case 分支检查 `fss_failover_internal_restart`
2. = "1" 或 = "2"：内部触发（failover 自切 / cron / wan-start / legacy），仅置 0，**不**清 failed（保留切换历史）
3. 其他（含空、未 set）：视为用户主动，`fss_failover_clear_all_failed` 把所有 combo 的 `failed` 设 "0"，同时把 `fss_failover_last_switch_ts` 清 0（解除冷却）

三状态语义的展开与"哪些路径必须走 wrapper / 必须显式 set 2"的清单见 §4.7。

### 4.3 节点删除 → combo 维护

`process_schema2_node_delete_queue` (asp:9270 附近) 删除节点前：

1. `collect_node_reference_delete_impact(nodeId)` 扫所有 combo，记录 `{i, role}` 数组
2. `failover_combo_compute_delete_fields(impact)` 算清理字段：
   - role=landing → 整条 combo 移除并 reindex
   - role=front → 仅清空前置（变直连）
3. 把 fields 合入主提交 ajax
4. ajax 成功后 `failover_combo_apply_delete_fields_local` 同步 db_fss + `render_failover_combo_panel`

### 4.4 订阅刷新 → identity 重解析

`sub_restore_active_nodes_after_rewrite` / `remove_sub_node` 收尾时调用 `fss_failover_combos_resync_after_subscribe`：

1. 遍历每个 combo，`fss_failover_resolve_combo` 通过 identity 找最新 id
2. landing 解析为空 → combo 损坏，记入 drop_list
3. 否则 `dbus set ..._id=<新值>`（identity 不动作为锚点）
4. 倒序逐一 `fss_failover_combo_drop` 受损 combo（从大到小避免索引错位）

### 4.5 节点排序 → combo 索引重排

`save_new_order` (asp:11240 附近)：与节点本身的 id 重排同时跑一轮 combo 扫描，匹配旧 rowid 就把 `_id` 写为新位置。

### 4.6 主组合自动种子（首次进入故障转移 UI）

旧问题：用户初次打开故障转移页时，列表是空（或仅有迁移过来的旧直连 combo），主面板的当前 (front, landing) 组合不在列表里——意味着如果 UI 上没手动添加，故障触发时 `failover_action` 找不到匹配 combo，会 LOG "runtime 不在列表" 并直接退出，不会切换。

解决方案：[Module_shadowsocks.asp](../../fancyss/webs/Module_shadowsocks.asp) 新增 `ensure_main_combo_seeded(cb)` (≈ L6747)，在 `render_failover_combo_panel()` 入口被调用一次。逻辑：

1. **第一行检查 `db_fss["fss_failover_main_combo_seeded"] === "1"`** → 已种子过 → 立即 cb(false) 返回（递归终止保证）
2. 读 `db_ss["ssconf_basic_node_front"]` 和 `db_ss["ssconf_basic_node"]`（落地兜底走 `db_fss["fss_node_current"]`）作为主面板组合
3. 主面板没有有效落地 → 仅落标志位（`fss_failover_main_combo_seeded=1`），不种子（不创建空 combo）
4. 已有 combo 与主面板组合完全匹配 → 仅落标志位
5. 不匹配 → 把现有 combo_1..n 倒序 shift 到 combo_2..n+1，把主面板插入到 combo_1，`fss_failover_combo_count = n+1`，落标志位

调用模式（"立即渲染 + 异步刷新"）：
```js
function render_failover_combo_panel() {
    var $panel = $("#failover_combo_panel");
    if (!$panel.length) return;
    ensure_main_combo_seeded(function(seeded) {
        if (seeded) { render_failover_combo_panel(); }  // 仅当真种子了才再渲染
    });
    var n = failover_combo_count();
    /* ... 原渲染逻辑不变 */
}
```

第二次进入 render 时，`ensure_main_combo_seeded` 第一行的标志位检查命中 → cb(false) → 不会再触发 render，递归在第二轮终止。

写入路径仍然走 `failover_combo_persist`（`dummy_script.sh` 路由），不重启代理。ajax 失败时 cb(false) → 不重渲染、不落标志，下次进页面再试，是合理降级。

后端 [ss_status_main.sh](../../fancyss/scripts/ss_status_main.sh) 不需要改动——主组合一旦被种子写入，自动成为 #1 参与 `fss_failover_pick_next_available` 扫描流程。

### 4.7 cron / 非用户路径 restart wrapper（alpha.17 新增）

**背景**：alpha.16 之前 `fss_failover_internal_restart` 是两状态标志（`0` / `1`）——只有 `failover_action` 自己切主备时 set 1。**任何其他路径**调 `ssconfig.sh restart` 都被 ssconfig.sh 入口当成用户主动操作，无差别清空 combo 的 failed 字段。

后果：用户配了"每 6 小时 cru 自动重启"或 fancyss 触发"规则更新后重启"或 `failover_check_*` 的 `s4_1=1` 整体重启分支命中——每次重启都把 failover 学到的"哪些 combo 失败过"知识抹掉，下一轮 `failover_check_*` 又得从头探。alpha.16 一段较稳定的 failover 验证里反复观察到这种"重新学习"行为，alpha.17 修。

**新合同 — 三状态语义**（[ssconfig.sh:8633-8689](../../fancyss/ss/ssconfig.sh#L8633)）：

| `fss_failover_internal_restart` | 写者 | ssconfig.sh case 入口行为 |
|---|---|---|
| `0`（默认 / 未 set / 空） | — | **清** failed + 清 `fss_failover_last_switch_ts`（用户主动 = "重新洗牌"） |
| `1` | `failover_action` 自切主备时 set | **不清** failed（保留切换历史，握手即重置为 0） |
| `2` (**alpha.17 新增**) | cron / wan-start / legacy 故障检测路径预先 set | **不清** failed（与 `1` 同语义，但区分语义来源） |

`1` 和 `2` 在 ssconfig.sh 入口被同一条 `if` 合并处理（`[ "${__fofr}" = "1" ] || [ "${__fofr}" = "2" ]`），分两个码值只是为了将来运维时一眼能区分"是 failover 自己切的"还是"周期任务触发的"。

**wrapper 脚本**：[fancyss/scripts/ss_cron_restart.sh](../../fancyss/scripts/ss_cron_restart.sh)（部署到 `/koolshare/scripts/ss_cron_restart.sh`）

```sh
#!/bin/sh
dbus set fss_failover_internal_restart="2"
exec /bin/sh /koolshare/ss/ssconfig.sh restart
```

调用约定：所有由 `cru` 注册的定时任务必须通过此 wrapper 路径，不要直接 `cru ... ssconfig.sh restart`。

**必须走 wrapper 的路径**（cru 注册点，由 [ss_reboot_job.sh::set_ss_reboot_job](../../fancyss/scripts/ss_reboot_job.sh#L20) 和 [ssconfig.sh::set_ss_reboot_job](../../fancyss/ss/ssconfig.sh#L8044) 写入 cru 表）：

| 文件 / 行 | 触发条件 |
|---|---|
| [ss_reboot_job.sh:24/27/30/34/37/40/45](../../fancyss/scripts/ss_reboot_job.sh#L24) | "插件定时重启"功能各分支（每天 / 每周 / 每月 / 每 N 分 / N 时 / N 天 / 自定义小时） |
| [ssconfig.sh:8048/8051/8054/8058/8061/8064/8069](../../fancyss/ss/ssconfig.sh#L8048) | 同上（ssconfig.sh 内部副本，apply_ss 重建 cru 表时写） |

**必须显式 `dbus set fss_failover_internal_restart="2"` 的路径**（非 cru 触发但属内部 restart）：

| 文件 / 行 | 触发场景 |
|---|---|
| [ss_status_main.sh:241-242](../../fancyss/scripts/ss_status_main.sh#L241) | `failover_check_*` 命中后 `ss_failover_s4_1=1`（整体重启分支，legacy 故障检测） |
| [fss_rules_update.sh:331-332](../../fancyss/scripts/fss_rules_update.sh#L331) | 内置 Rule 自动更新成功，cron mode 批量重启 |
| [fss_rules_update.sh:378-379](../../fancyss/scripts/fss_rules_update.sh#L378) | 单条 Rule 强制更新成功重启 |
| [ss_rule_update.sh:258-259](../../fancyss/scripts/ss_rule_update.sh#L258) | 旧 rule 自动更新流程的"自动重启 fancyss"分支 |
| [ss_status_main.sh:289](../../fancyss/scripts/ss_status_main.sh#L289) | `failover_action` 自切（继续用 `=1` 保留"failover 自己切的"语义） |

注意 `ss_status_main.sh:289` 用 `=1` 而非 `=2`——这是 failover 自身切换路径，与 cron / legacy 区分；但两者在 ssconfig.sh 入口都进入"不清 failed"分支。

**必须保留默认清除行为的路径**（这些路径**不**预 set，意图就是"用户主动 = 清 failed"）：

| 文件 / 行 | 触发场景 |
|---|---|
| [install.sh:2589](../../fancyss/install.sh#L2589) | install_now 装包末尾的 `sh /koolshare/ss/ssconfig.sh restart`（用户装包 = 重新洗牌） |
| [scripts/ss_config.sh:89](../../fancyss/scripts/ss_config.sh#L89) | WebUI "保存&应用"路由的 `start_fancyss()`（用户保存 = 重新洗牌） |
| 路由器 SSH 终端手动 `ssconfig.sh restart` | 同上，用户意图明确 |

**已知遗留**（acceptable degradation）：

用户从 alpha.16 升级到 alpha.17 时，旧 cru 表里 `ss_reboot` 那条仍然是直接调 `ssconfig.sh restart`——`set_ss_reboot_job` 只在被调用时才用新模板重写 cru 表。新模板生效路径：

1. 路由器重启 → wan-start → `apply_ss` → `set_ss_reboot_job` 重新注册 → cru 表里换上 wrapper ✓
2. 用户在 ASP "插件定时重启"区块改一下任意字段并保存 → `set_ss_reboot_job` 重跑 ✓
3. 用户安装更新版本（装包末尾的 `ssconfig.sh restart` → `apply_ss` → `set_ss_reboot_job`） ✓

直到上述任一事件发生前，旧 cru 任务触发的 restart 会继续清 failed。设计上接受这一过渡窗口——路由器重启或更新一次就自动修。

---

## 5. 踩过的坑 / 设计偏离

### 5.1 ASP 编辑回退 PowerShell

前面 §2.6 的旧字段移除涉及多处带 tab 缩进的多行替换，参考 [CLAUDE.md 规则 2](../../CLAUDE.md)，这部分用 PowerShell + `[System.IO.File]::WriteAllText` 写入。新增的 `failover_combo_*` 函数段是整块插入，可以用 Edit 单行匹配。

### 5.2 `dummy_script.sh` 路由

UI 持久化 combo 字段不应触发 `ssconfig.sh restart`（用户在 UI 加几行不希望代理被反复重启）。沿用 koolshare 的"只写 fields 不跑 method"模式：`POST /_api/` + `method: "dummy_script.sh"` + `fields: {...}`。前端 `failover_combo_persist` 全用此机制。

### 5.3 `fss_failover_cool_down_sec` 不 UI 暴露

设计文档 §10 已说明：一期硬编码默认 30 秒，先观察实际效果。代码侧已经实现读取，只是没在 UI 加配置项。未来如要暴露，加在故障转移设置区即可，dbus key 已就位。

### 5.4 设计偏离：UI 节点删除路径走主提交合并

设计 §4.4 说"节点被删除时…遍历所有 combo"，原本想做单独 ajax。但 koolshare 的 `process_schema2_node_delete_queue` 已经有一次主提交（写 `fss_nodes_v2` 等），把 combo 清理 fields 合入这次提交比独立 ajax 更鲁棒（避免半更新状态）。所以新增了 `failover_combo_compute_delete_fields(impact)` + `failover_combo_apply_delete_fields_local(fields)` 一对——前者只算 fields 不动 db_fss（让 compfilter 能判差），后者在 ajax 成功后同步缓存。

### 5.5 hint id 占用

新加 hint id = 201，更新到 [CLAUDE.md 规则 3](../../CLAUDE.md) 的已用号段。

### 5.6 install.sh 顶部已 source ss_node_common.sh

`migrate_failover_v1` 直接调用 `fss_node_id_exists` / `fss_get_node_identity_by_id`，依赖 install.sh 顶部已经 source 了 `ss_node_common.sh`。如果未来重构 install.sh 的 source 顺序，要确认 helper 仍可用。

### 5.7 fss_/ss_ 前缀错位 bug 与修复（v2 重命名）

**症状**：用户在备用组合列表里加了几行 combo 后，刷新页面 / 重新进入故障转移 ASP 页面，列表被"重置"——`ensure_main_combo_seeded` 错误地把主面板当前 (front, landing) 当成第一行重新种子，把用户加的 combo 都挤掉。

**根因**：原始设计把 combo 字段放在 `fss_failover_combo_*` 前缀。但是 koolshare 前端 `db_ss` 是通过 `/_api/ss` 拉的——只有 `ss` 前缀（且不是 `ssconf_basic_` / `ss_acl_` / `ssid_`）才会被返回。`fss_*` 前缀的 dbus key 在前端 reload 后**完全读不到**——`db_ss["fss_failover_combo_count"]` 永远 undefined → `failover_combo_count()` 返回 0 → `ensure_main_combo_seeded` 第一行检查 `db_ss["fss_failover_main_combo_seeded"]` 也读不到 → 永远走"种子"分支，于是每次进页面都重新插入主面板组合，覆盖用户已有数据。

（当时之所以没在写入路径暴露，是因为 `failover_combo_persist` 通过 `dummy_script.sh` ajax 路由确实把 fss_* 写到了 dbus 里——但它只能写、不能让前端 reload 后读。所以"加完立刻看"是好的，"刷新后再看"就崩。）

**修复**（本次 commit）：
1. 所有 combo dbus key 前缀 `fss_failover_combo_*` → `ss_failover_combo_*`
2. `fss_failover_main_combo_seeded` → `ss_failover_main_combo_seeded`
3. ASP 内对应的 `db_fss[...]` 引用改为 `db_ss[...]`
4. `migrate_failover_v1` 直接写 `ss_*` 前缀（不需要再过 v2 转换）
5. 新增 `migrate_failover_v2`：检测旧 fork 用户残留的 `fss_failover_combo_*`，逐字段 `dbus set ss_<key> <value>` + `dbus remove fss_<key>`，落 `ss_failover_combo_migrated_v2=1` 幂等

**保留 fss_* 前缀的 keys**（无需前端读，受硬规则 #1 不约束）：
- `fss_failover_internal_restart` `fss_failover_last_switch_ts` `fss_failover_cool_down_sec` `fss_failover_migrated_v1`

**保留的 helper 函数名**（虽然名称仍带 `fss_failover_`，但只是 bash 函数标识符，与 dbus key 解耦）：
- `fss_failover_combo_count` / `fss_failover_combo_clear_slot` / `fss_failover_combo_drop` / `fss_failover_combos_resync_after_subscribe` / `fss_failover_find_combo` / `fss_failover_pick_next_available` / `fss_failover_resolve_combo` / `fss_failover_clear_all_failed`

---

## 6. 测试场景检查表

复用设计文档 §8 清单。⚠️ 标记为待实机验证。

- ⚠️ 单个组合：触发故障 → 不切换（没有备用），保持断网
- ⚠️ 两个组合（A 主 / B 备）：A 故障 → 切到 B；B 又故障 → 不切换
- ⚠️ 三个组合（A/B/C），A 失效 → B → C，全失效后不动
- ⚠️ 用户手动重启（点保存&应用）→ 所有 failed 清空（代码逻辑见 §4.2，已 grep 验证）
- ⚠️ 故障转移内部 restart → failed 不被清空
- ⚠️ "纯直连"组合（前置空）能正确切换为非链式 xray 配置（依赖 ss_chain_proxy.sh fallback，已存在）
- ⚠️ "链式"组合切到"直连"组合再切回链式 → xray 配置正确切换
- ⚠️ 故障转移开关关闭 → `#failover_combo_section` 隐藏；重新打开 → 数据还在
- ⚠️ 节点删除后，combo 引用该节点的状态合理（landing 整删 / front 仅清前置）
- ⚠️ 订阅刷新导致节点 id 重排 → combo 通过 identity 自动指向新 id
- ⚠️ 添加重复组合被拒绝（UI 端校验，`failover_combo_add`）
- ⚠️ 前置=落地的组合被拒绝（UI 端校验）
- ⚠️ 删除当前运行中的组合按钮置灰（UI 端校验 + 后端无校验，UI 是唯一防线）
- ⚠️ 老用户从旧版本升级 → 旧 `ss_failover_s4_3` 自动迁移为一个 combo
- ⚠️ 抖动防护：人为把组合都搞坏，观察短时间内是否被冷却限制
- ⚠️ 抖动防护：用户手动 restart 后，`fss_failover_last_switch_ts` 被清零

✅ 静态：
- ✅ 旧 dbus keys 在备份 / 恢复路径已加白名单（`fss_export_global_json` / `fss_clear_global_config_storage` / `fss_export_native_backup_v2` 三处都改了）
- ✅ helper 函数全部 grep 验证存在并被调用
- ✅ `fss_failover_combos_resync_after_subscribe` 在 3 个订阅 / 删除路径 hook 上

---

## 7. 未来 todo

实施过程中识别但本次不做的：

1. **删除当前运行组合的后端校验**：当前仅 UI 拦截。如果有人用 dbus 命令绕过 UI 直接 set，后端不会拒绝。低优——绕过 UI 操作的用户应该自己负责。
2. **`fss_failover_cool_down_sec` UI 暴露**：默认 30 秒先观察。如要做，在故障转移设置区加一行 select。
3. **combo 内部排序**：当前列表顺序由用户添加顺序决定，没有"上移/下移"按钮。如需要可参考 ACL list 实现。
4. **当前运行节点的"一键转 combo"**：用户改主面板节点后想把当前 (front, landing) 加进 combo，目前要手动选两个 select 重选一遍。可加一个"快速添加当前组合"按钮。
5. **健康探测细分**：设计 §10 已列。要求新增 socks5 inbound，工作量大，本期不做。
6. **大量 combo 的展示分页**：目前 N 不限，UI 不分页。若 N>20 体验下降，可加滚动或分页。
7. **failed 状态在 UI 上的手动复位**：目前用户必须 restart 整个插件才能清。可加每行一个"复位"按钮，仅清单条 failed。
8. **审计日志**：故障切换时 LOGM 已写入状态历史日志。但 combo 增删改没单独日志。如需事后审计可加。

---

## 修订记录

- 2026-05-03：初稿，对应设计文档 §7 实施步骤 1–6 全部落地。
- 2026-05-03：补充 §4.6「主组合自动种子」机制 + §3.1 新增 `fss_failover_main_combo_seeded` key（解决首次进入页面时主面板组合不在列表导致故障转移无法触发切换的 UX 问题）。
- 2026-05-03：combo dbus key 前缀重命名 `fss_failover_combo_*` → `ss_failover_combo_*`、`fss_failover_main_combo_seeded` → `ss_failover_main_combo_seeded`。原因详见 §5.7：`fss_*` 前缀不在 koolshare `/_api/ss` 返回白名单内导致前端 reload 后读不到 combo 数据，`ensure_main_combo_seeded` 反复重新种子覆盖用户加的备用组合。同步新增 `install.sh::migrate_failover_v2` 一次性迁移老用户已有数据。
- 2026-05-20 alpha.17：`fss_failover_internal_restart` 由两状态扩到三状态（`0`/`1`/`2`），新增 [ss_cron_restart.sh](../../fancyss/scripts/ss_cron_restart.sh) wrapper + 6+ 处显式 `set 2` 保留 failed 状态，避免 cron / 规则更新 / wan-start / legacy 故障检测路径无差别清空失败知识。详见 §4.7 完整路径清单。`fss_failover_internal_restart=2` 的码值仅用于"区分语义来源"，在 ssconfig.sh 入口与 `=1` 同条件分支合并处理。
