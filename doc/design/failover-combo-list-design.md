# 故障转移备用组合列表 — 设计文档

> 状态：**设计已定稿，已实施完成**（详见 [doc/implementation/failover-combo-implementation.md](../implementation/failover-combo-implementation.md)）。本文档记录与用户达成共识的最终方案。
>
> 关联背景：本 fork 的核心新功能是「链式代理（前置→落地）」。当前的故障转移逻辑只切换"落地节点"，对前置无感知；且切换策略写死了"备用节点 / 下个节点 / web 延迟最低"三选一。本设计将其重构为「备用组合列表」模式。

---

## 1. 设计目的

把现有故障转移的"切换到 X"动作（`ss_failover_s4_1=2`）替换为更直观的「备用组合列表」机制：

- 用户预先定义一组 (前置, 落地) 组合作为备用
- 故障触发时按列表顺序切换到下一个可用组合
- 链式 / 直连模式由组合内容自动决定（前置为空=直连；非空=链式）
- 所有组合都失效时保持当前断网状态，让用户主动发现并处理

**移除**的旧行为：`ss_failover_s4_2`（备用 / 下个 / 最快 三选一）和 `ss_failover_s4_3`（单一备用节点）。

**保留**的旧行为：`ss_failover_enable`（开关）、`ss_failover_c1/c2/c3`（三种触发条件）、`ss_failover_s1/s2_*/s3_*`（条件参数）、`ss_failover_s4_1=0/1`（关闭/重启）、`ss_failover_s5`（日志保留行数）。

---

## 2. 关键决策（已与用户确认）

| 编号 | 问题 | 决策 |
|---|---|---|
| D1 | 允许"无前置"的组合吗？ | **允许**。前置为空 = 直连模式 |
| D2 | 主面板的前置/落地选择如何与故障转移列表关联？ | **方式 A**：不区分 intent/runtime。主面板就是当前运行节点。故障转移表格顶部加一个只读"当前运行"信息行 |
| D3 | 触发条件 `c1/c2/c3` 保留吗？ | **保留** |
| D4 | 故障转移开关关闭时列表怎么处理？ | **隐藏**整个表格（dbus 数据保留） |
| D5 | 没有任何组合 / 全部失效时怎么办？ | **什么都不做**，让网络保持断开状态，让用户主动发现 |
| D6 | 链式 vs 直连的切换 | **自动**。组合内容决定模式；配置错误自动回落到直连（复用现有 `ss_chain_proxy.sh` fallback 分支） |
| D7 | 删除当前运行中的组合 | **禁止**。UI 上将该行的删除按钮置灰，tooltip 提示"请先切换到其他组合" |
| D8 | 同一组合（同 front+landing）重复添加 | **禁止**。添加时检测重复 |
| D9 | "前置=落地"的组合 | **添加时即时校验**，禁止保存 |

---

## 3. dbus Schema

### 3.1 新增 keys

```
fss_failover_combo_count                 # 组合数量，整数字符串，"" 视为 "0"
fss_failover_combo_<i>_front_id          # "" 表示无前置=直连。i 从 1 开始
fss_failover_combo_<i>_front_identity    # 节点身份哈希，应对订阅刷新（前置为空时此字段也为空）
fss_failover_combo_<i>_landing_id        # 必填，非空
fss_failover_combo_<i>_landing_identity  # 必填，非空
fss_failover_combo_<i>_failed            # "0" / "1"
fss_failover_internal_restart            # "0" / "1"，故障转移内部 restart 前置位
fss_failover_last_switch_ts              # 上次切换组合的 Unix 时间戳（秒）。0 / 空 = 从未切换
fss_failover_cool_down_sec               # 切换冷却秒数，未设置时取默认 30
```

> ⚠️ **键前缀决定（2026-05-03 修订）**：原始设计假设"前端通过 `db_fss` 拿到 `fss_*` 即可"是错误的——koolshare 的 `/_api/<prefix>` 只对 `ss` 前缀（且不是 `ssconf_basic_` / `ss_acl_` / `ssid_`）回传，`fss_*` 前缀的 dbus key 在前端 reload 后**完全读不到**。实际落地代码已将所有需要前端读的 combo 字段改为 `ss_failover_combo_*` / `ss_failover_main_combo_seeded`；仅后端可读的 `fss_failover_internal_restart` / `_last_switch_ts` / `_cool_down_sec` / `_migrated_v*` 保留 `fss_*`。详见 [doc/implementation/failover-combo-implementation.md §3.1 / §5.7](../implementation/failover-combo-implementation.md)。

### 3.2 已废弃的 keys（需迁移）

```
ss_failover_s4_2          # 旧：1=备用/2=下个/3=最快。直接删除
ss_failover_s4_3          # 旧：备用节点 id。直接删除
fss_node_failover_backup  # 旧：identity 化的备用节点 id
fss_node_failover_identity # 旧：备用节点 identity
```

迁移策略：升级到本版本时，自动把旧的 `ss_failover_s4_3` 转换为一个备用组合（front 为空 + landing = 旧值），然后清空旧 keys。在 [install.sh](fancyss/install.sh) 或 [ssconfig.sh](fancyss/ss/ssconfig.sh) start 路径里做一次性迁移。

### 3.3 `ss_failover_s4_1` 的新语义

```
0 = 关闭插件
1 = 重启插件
2 = 切换备用组合     ← 唯一切换动作（替代旧的"切换到 X"）
（旧值 2 的子选项 s4_2/s4_3 全部移除）
```

---

## 4. 后端逻辑

### 4.1 故障转移触发流程（`ss_status_main.sh` 的 `failover_action`）

替换 [ss_status_main.sh:243-301](../../fancyss/scripts/ss_status_main.sh) 当前的 `s4_1=2` 分支为：

```sh
elif [ "$ss_failover_s4_1" == "2" ]; then
    # 1. 当前 runtime
    local cur_front=$(dbus get ssconf_basic_node_front)
    local cur_landing=$(fss_get_current_node_id)

    # 2. 在列表里找匹配项 → 标记 failed=1（找不到说明 runtime 不在列表里，跳过这步）
    local match_idx=$(fss_failover_find_combo "$cur_front" "$cur_landing")
    [ -n "$match_idx" ] && dbus set fss_failover_combo_${match_idx}_failed="1"

    # 3. 顺序扫描，找第一个 failed=0 的（且不是当前 runtime）
    local next_idx=$(fss_failover_pick_next_available "$cur_front" "$cur_landing")
    if [ -z "$next_idx" ]; then
        LOGM "$LOGTIME1 fancyss：所有备用组合已失效，保持当前状态以便用户察觉..."
        return
    fi

    # 4. 切换 runtime
    local new_front=$(dbus get fss_failover_combo_${next_idx}_front_id)
    local new_landing=$(dbus get fss_failover_combo_${next_idx}_landing_id)
    local new_landing_name=$(get_node_name_by_id "$new_landing")
    local mode_label="链式"
    [ -z "$new_front" ] && mode_label="直连"
    LOGM "$LOGTIME1 fancyss：切换到备用组合 #${next_idx}（${mode_label}）→ 落地：[${new_landing_name}]"

    fss_set_current_node_id "$new_landing"
    dbus set ssconf_basic_node_front="$new_front"

    # 5. 写切换时间戳（用于抖动防护，§4.5）
    dbus set fss_failover_last_switch_ts="$(date +%s)"

    # 6. 标记内部 restart（避免被误清失效标志）
    dbus set fss_failover_internal_restart="1"
    run start-stop-daemon -S -q -b -x /koolshare/ss/ssconfig.sh -- restart
    dbus set ss_heart_beat="1"
fi
```

### 4.2 新 helper 函数（建议放在 [ss_node_common.sh](../../fancyss/scripts/ss_node_common.sh)）

```sh
fss_failover_find_combo <front_id> <landing_id>
    # 输出匹配的 i（1..N），找不到输出空。前置都为空也算匹配

fss_failover_pick_next_available <cur_front> <cur_landing>
    # 顺序扫描 combo_1..N，跳过 failed=1 和与当前 runtime 完全相同的
    # 输出第一个匹配的 i，找不到输出空

fss_failover_resolve_combo <i>
    # 把 combo_<i> 通过 identity 解析回当前最新 id（对应订阅刷新场景）
    # 输出 "front_id<TAB>landing_id"

fss_failover_clear_all_failed
    # 把所有 combo 的 failed 改为 "0"，同时清空 fss_failover_last_switch_ts（见 §4.5）

fss_failover_combo_count
    # 返回组合数（空 / 非数字时返回 0）
```

### 4.3 失效标志清理（`ssconfig.sh` 入口）

在 [ssconfig.sh](../../fancyss/ss/ssconfig.sh) 的 start / restart 入口最早处加：

```sh
case "$1" in
start|restart)
    if [ "$(dbus get fss_failover_internal_restart)" = "1" ]; then
        # 故障转移内部触发的 restart，不清失效标志
        dbus set fss_failover_internal_restart="0"
    else
        # 用户主动操作，清空所有 combo 的 failed 标志
        fss_failover_clear_all_failed
    fi
    ;;
esac
```

要点：标志清完一定要立即重置 `fss_failover_internal_restart="0"`，避免遗留。

### 4.4 节点订阅 / 删除时的稳定性

参考现有 [Module_shadowsocks.asp:8961-9005](../../fancyss/webs/Module_shadowsocks.asp) 对 `fss_node_failover_backup` 的清理逻辑：

- 节点被删除时：遍历所有 combo，匹配 identity → 把 `_id` 字段清空（保留 identity 作为孤立标记）；如果是 landing 被删，整个 combo 视为损坏，可以选择删除整个 combo
- 节点 id 重排（如订阅刷新）时：通过 identity 重新解析 id，更新 `_id` 字段

### 4.5 切换抖动防护

**问题**：连续故障期间可能在很短时间内多次触发切换，导致：
- 新组合还没稳定就被判定失败（probe 还没足够样本）
- 串联的 c1/c2/c3 检测可能在同一轮里都触发，连切两次

**现有的隐式机制**：[ss_base.sh:723-727](../../fancyss/scripts/ss_base.sh) 每次 start/restart 往 `ssf_status.txt` / `ssc_status.txt` 写 `===` 分隔符；`failover_check_1/2/3` 开头先扫 `tail -n (window+3) | grep "==="`，发现就 return。这等价于一个 cool-down ≈ `(window + 3) × probe_interval`。但当 probe_interval 取最快档（1s）时，cool-down 缩到 ~6-23s，对慢启动的链式组合不够。

**显式叠加机制**（本设计新增）：

引入 `fss_failover_last_switch_ts`（Unix 时间戳，秒）和 `fss_failover_cool_down_sec`（默认 30 秒，未来可考虑暴露到 UI）。

在每个 `failover_check_*` 函数的最开头加一段：

```sh
local last_switch_ts=$(dbus get fss_failover_last_switch_ts)
local cool_down=$(dbus get fss_failover_cool_down_sec)
[ -n "$cool_down" ] || cool_down=30
if [ -n "$last_switch_ts" ] && [ "$last_switch_ts" != "0" ]; then
    local now_ts=$(date +%s)
    local elapsed=$((now_ts - last_switch_ts))
    if [ "$elapsed" -lt "$cool_down" ]; then
        # 还在冷却期内，本轮不做判定
        return
    fi
fi
```

**写入时机**：见 §4.1 第 5 步，每次 `failover_action` 成功切换组合后写入。

**清空时机**：在 §4.3 的"用户主动 restart"分支里，连同 failed 清空时把 `fss_failover_last_switch_ts="0"` 一起清掉，让用户主动重启后立即能响应新故障。`fss_failover_clear_all_failed` 这个 helper 内部就一起清。

**默认值选取**：30 秒兼顾以下场景：
- 最快 probe 间隔档（~1s）下，至少能积累 ~25 个样本
- 最慢 probe 间隔档（~32-63s）下，30s 不会显得过长（因为 c1/c2 的窗口本身就要等几个样本）
- 链式代理 xray 重启后冷启动 + DNS warmup 时间通常在 5-15s 范围

**与隐式 `===` 机制的关系**：两者并存，取并集。`===` 机制保护"刚启动后日志稀少"的场景；显式时间戳保护"日志已经堆得很快但实际时间未到"的场景。任一机制触发都不会进入判定。

---

## 5. UI / asp 改动

### 5.1 故障转移设置区结构

新结构（伪布局）：
```
┌─ 故障转移开关 [✓]
├─ 故障转移设置（条件 c1/c2/c3 保留不变）
├─ 状态检测时间间隔
├─ 历史记录保存数量
├─ 查看历史状态
└─ 备用节点组合 ←────────────── 新增区块
   ┌────────────────────────────────────────────────┐
   │ 当前运行：[Vmess]香港-A → [Vless]美国-B 🟢在线  │
   ├──┬──────────────┬──────────────┬─────────┬────┤
   │ #│  前置节点    │  落地节点    │ 状态    │操作│
   ├──┼──────────────┼──────────────┼─────────┼────┤
   │ 1│ 香港-A       │ 美国-B       │ 启用中  │ ✕  │← 当前运行项删除按钮置灰
   │ 2│ 日本-C       │ 美国-D       │ 可用    │ ✕  │
   │ 3│ (无前置/直连)│ 美国-E       │ 已失效  │ ✕  │
   ├──┴──────────────┴──────────────┴─────────┴────┤
   │ [前置 select▼] [落地 select▼] [+ 添加]         │
   └────────────────────────────────────────────────┘
```

### 5.2 文件改动点（[Module_shadowsocks.asp](../../fancyss/webs/Module_shadowsocks.asp)）

**移除**：
- 第 16078-16079 行：`fa4_1` 改为 `[["0","关闭插件"], ["1","重启插件"], ["2","切换备用组合"]]`，删除 `fa4_2`
- 第 16112-16113 行：删除 `ss_failover_s4_2` 和 `ss_failover_s4_3` 这两个 form 项
- 第 4004-4014 行：移除 `get_failover_node_id()` 函数
- 第 6472, 6475, 6480, 6547 行：移除对 `#ss_failover_s4_3` 的所有引用
- 第 7146-7149 行：移除 save() 里的 `fss_node_failover_backup` 处理
- 第 8961-8965, 9003-9006, 10926-10927 行：移除旧故障转移备用节点的清理逻辑
- 第 8199-8200 行：移除 `s4_2/s4_3` 的 showhide 联动
- 第 6668-6676, 15499 行：从 `db_ss` / `fov_inp` 数组移除 `ss_failover_s4_2` `ss_failover_s4_3`

**新增**：
- 备用组合表格的 HTML 模板（参考访问控制 [Module_shadowsocks.asp:15129-15146](../../fancyss/webs/Module_shadowsocks.asp) 的 `acl_lists` table 模式）
- 渲染函数 `render_failover_combo_table()`：从 `fss_failover_combo_count` 读出 N，循环渲染
- 状态计算：`(front_id, landing_id) == 当前 runtime` → 启用中；`failed==1` → 已失效；其他 → 可用
- 添加行处理：
  - 前置 select 选项过滤复用第 6549-6569 行已有逻辑（type ∈ {0,3,4,5} 且非 obfs / 非 json），加一个"(无前置/直连)"选项 value=""
  - 落地 select 复用主面板节点选择器
  - 添加前校验：(a) front ≠ landing；(b) 不与已有组合重复
- 删除行处理：禁止删除当前运行项；其他正常删除并 reindex
- 故障转移开关 off 时整个区域 hide

**hint id**：如果加帮助提示按钮，用 200+ 段（参考 CLAUDE.md 规则 3）。当前已用 200，本功能可用 201（"备用组合列表说明"）等。

### 5.3 dbus 同步

走现有 `db_fss` 链路。在 `db_ss` 的 setup 里把 `fss_failover_combo_*` 全部带上即可（搜索 `db_fss` 的 fetch 模式）。

---

## 6. 工程量分解

| 工作 | 估时 | 涉及文件 |
|---|---|---|
| dbus schema + 后端 helper（4.2 节列出的 5 个函数） | 4 小时 | `ss_node_common.sh` |
| `failover_action` 的 `s4_1=2` 分支重写（4.1 节） | 2 小时 | `ss_status_main.sh` |
| 切换抖动防护：每个 check 开头的 cool-down 判定 + 切换时戳写入（4.5 节） | 1 小时 | `ss_status_main.sh` |
| `ssconfig.sh` 入口加失效清理（4.3 节） | 1 小时 | `ss_ss/ssconfig.sh` |
| 旧字段迁移逻辑（一次性，3.2 节） | 2 小时 | `install.sh` 或 `ssconfig.sh` start 早期 |
| ASP 备用组合表格渲染 + 增删行 | 1 天 | `Module_shadowsocks.asp` |
| ASP 旧故障转移设置移除 + showhide / db_ss 整理 | 4 小时 | `Module_shadowsocks.asp` |
| 节点订阅刷新 / 删除时的 combo 清理（4.4 节） | 4 小时 | `ss_node_subscribe.sh`, `Module_shadowsocks.asp` |
| 文档 + 实机联调测试 | 半天 | doc/implementation/ |
| **合计** | **约 3.5 天** | |

---

## 7. 实施顺序建议

按这个顺序提交，每步可独立验证：

1. **dbus 读写 helper + 后端 failover_action 重写**（无 UI，先用现有 dbus 命令手动建 combo 测试切换逻辑）
2. **ssconfig.sh 失效清理 + internal_restart 标志**（手动 dbus set failed=1 后重启验证清除）
3. **旧字段迁移逻辑**（升级路径走通）
4. **ASP UI 备用组合表格**（先实现读 + 渲染，再加增删）
5. **ASP 旧故障转移设置区清理**（移除 s4_2/s4_3）
6. **订阅 / 删除节点时的 combo 维护**
7. **完整实机测试 + 文档**

每步独立 commit，方便出问题时回滚。

---

## 8. 测试场景清单

实施完后必须验证的场景：

- [ ] 单个组合：触发故障 → 不切换（没有备用），保持断网
- [ ] 两个组合（A 主 / B 备）：A 故障 → 切到 B；B 又故障 → 不切换，保持断网
- [ ] 三个组合（A/B/C），A 失效 → B → C，全失效后不动
- [ ] 用户手动重启（点保存&应用） → 所有 failed 清空
- [ ] 故障转移内部 restart → failed 不被清空
- [ ] "纯直连"组合（前置空）能正确切换为非链式 xray 配置
- [ ] "链式"组合切到"直连"组合再切回链式 → xray 配置正确切换
- [ ] 故障转移开关关闭 → 表格隐藏；重新打开 → 数据还在
- [ ] 节点删除后，combo 引用该节点的状态合理（孤立标记 / 自动移除）
- [ ] 订阅刷新导致节点 id 重排 → combo 通过 identity 自动指向新 id
- [ ] 添加重复组合被拒绝
- [ ] 前置=落地的组合被拒绝
- [ ] 删除当前运行中的组合按钮置灰
- [ ] 老用户从旧版本升级 → 旧 `ss_failover_s4_3` 自动迁移为一个 combo
- [ ] 抖动防护：人为把组合都搞坏，观察短时间内是否被冷却限制（不会出现 1s 内连切多组合）
- [ ] 抖动防护：用户手动 restart 后，`fss_failover_last_switch_ts` 被清零，立即能响应新故障

---

## 9. 与上游 fancyss / 其他模块的兼容

- **节点分流模式（mode=7）**：现有 [ss_chain_proxy.sh:343-347](../../fancyss/scripts/ss_chain_proxy.sh) 在 mode=7 下直接 fallback。本设计不变，组合中含前置但当前 mode=7 时自动退化为直连即可。
- **备份恢复**：备份恢复脚本 [ss_node_subscribe.sh:3432-4436](../../fancyss/scripts/ss_node_subscribe.sh) 处理了节点 identity 恢复。新的 combo identity 字段需要加入备份白名单。
- **webtest**：现有 webtest 不受影响，不再用于故障转移决策。

---

## 10. 不在本设计范围

以下问题暂不解决，未来如需可在新文档讨论：

- 区分前置故障 vs 落地故障的健康探测（要求新增第二个 socks5 inbound）
- combo 内的"延迟优先级排序"或"自动测速重排"
- 主面板 intent 与 runtime 的显式拆分（即决策 D2 的方式 B）
- `fss_failover_cool_down_sec` 的 UI 暴露（一期硬编码默认 30 秒，先观察实际效果再决定是否值得做配置项）

---

## 修订记录

- 2026-05-03：初稿，与用户对齐 9 项决策后定稿，待实施。
- 2026-05-03：补充 §4.5 切换抖动防护（显式 cool-down 时间戳叠加在现有"==="日志标记机制之上）。
- 2026-05-03：实施完成，详见 [doc/implementation/failover-combo-implementation.md](../implementation/failover-combo-implementation.md)。
- 2026-05-03：补充主组合自动种子机制（避免首次访问列表为空 / 与 migrated 状态分离），详见实施文档 §4.6。
- 2026-05-03：修正 §3.1 "fss_* 前缀即可"的错误判断——koolshare `/_api/ss` 只返回 `ss` 前缀，`fss_*` 前端读不到。实际落地代码已把 combo 字段改为 `ss_failover_combo_*`；后端 hot-only keys 保留 `fss_*`。新增 `migrate_failover_v2` 处理升级路径。详见实施文档 §5.7。
