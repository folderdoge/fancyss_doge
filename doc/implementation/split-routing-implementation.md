# 分流架构实施说明 (doge.12 alpha)

> **状态**：alpha 骨架实施期文档。**会随实施进度持续更新**。
> 关联设计：[../design/split-routing-architecture.md](../design/split-routing-architecture.md)
> 关联路线图：[../design/protocol-roadmap.md §8](../design/protocol-roadmap.md)

---

## 0. alpha 范围与"零侵入"承诺

doge.12 是 1-2 周量级的架构跃迁，单次 release 全切风险极大。alpha 版本（doge.12.alpha）采用**新旧并存**策略：

- **总开关** `ss_split_enabled` (dbus, 默认 `0`)
  - `=0`：路由层完全走旧路径（沿用 `ss_basic_mode` GFW/CHN/HOM/GAM/全局/回国/xray分流）。**老用户升级零感知。**
  - `=1`：路由层走 doge.12 新架构（per-Mode TPROXY + sniffing + 双轨 DNS）。
- **migrate 总是跑**（写 dbus + 拷规则文件），但不切换路由层。提供"实验性架构启用"按钮供 alpha 用户主动 opt-in。
- **失败降级**：新架构启动失败时，`ssconfig.sh restart` 兜底回退到旧路径（保留 `ss_split_enabled=1`，日志告警）。
- **完整切换里程碑**：等 alpha 充分测试后，doge.13 默认 `ss_split_enabled=1`，doge.14 物理移除旧路径代码（含 `ss_node_shunt.sh` 物理删除）。

> **设计文档 §7 "ss_node_shunt 物理移除" 的修订**：alpha 阶段**不物理删除** `ss_node_shunt.sh`，保留旧路径作为回退兜底。等新架构充分验证后再删。

---

## 1. dbus key 完整契约（**所有 subagent 必须严格遵守**）

### 1.1 总开关 + 迁移标志

| Key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `ss_split_enabled` | "0"/"1" | "0" | alpha 总开关。`=1` 时路由层走新架构 |
| `fss_split_migrated_v1` | "0"/"1" | "0" | install.sh::migrate_split_routing_v1 幂等标志 |

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

### 1.4.1 索引规范（**新增 — 修复 BLOCKER R2.8**）

dbus key 中的 `<m>` (Mode 索引) / `<r>` (rule 序号) / `<i>` (Rule 索引) 在 alpha 阶段约定为：

- **从 1 开始连续**（与 `install.sh::migrate_split_routing_v1` 写入 `mid=1, mid=2 ...` 一致）
- **index == id** — alpha 阶段不区分（避免编辑弹窗未实现时的 gap 问题）
- **消费方必须用 `for X in $(seq 1 count); do` / `for (X=1; X<=n; X++)` 1-indexed 枚举**
- **禁用** `for X in $(seq 0 ${count-1})` / `for (X=0; X<n; X++)` 0-indexed

doge.13 引入 Mode/Rule 删除弹窗后，**升级到方案 B**：消费方改用 `dbus list ss_split_mode_ | awk -F_ '$4 ~ /^[0-9]+$/ {print $4}' | sort -nu` 动态枚举 actual slot，解耦 index 与 id；本规范届时废止。

### 1.5 Action 编码格式

单字符串、`:` 分隔：

| 动作 | 编码 |
|---|---|
| 直连 | `direct` |
| 屏蔽 | `reject` |
| 代理（节点 X） | `proxy_node:<node_id>` |
| 代理（链式 Y→Z） | `proxy_chain:<front_id>:<landing_id>` |

### 1.6 运行状态（后端写，前端读，**必须配合轮询**）

| Key | 类型 | 写者 | 说明 |
|---|---|---|---|
| `ss_split_active_mode_count` | int | restart 时 | 活跃 Mode 数 |
| `ss_split_xray_outbound_count` | int | restart 时 | xray 实际生成 outbound 数（去重后） |
| `ss_split_last_restart_ts` | int | restart 完成时 | 最近重启时间戳 |
| `ss_split_dns_split_status` | "ok"/"down" | cron 检测 | 分流 DNS 实例状态 |
| `ss_split_dns_global_status` | "ok"/"down" | cron 检测 | 全局 DNS 实例状态 |

### 1.7 后端专用 (`fss_*` 前缀，不上前端)

| Key | 类型 | 说明 |
|---|---|---|
| `fss_split_rules_update_lock` | "0"/"1" | cron 互斥锁 |
| `fss_split_rules_update_log` | string | 最近一次 cron 摘要 |
| `fss_split_outbound_dedup_cache` | string | xray 生成器去重缓存（可选） |
| `fss_split_xray_warn` | string | xray 生成器失败码：`baseline_missing` / `jq_missing` / `jq_merge_failed` / `output_empty` / `xray_test_failed` / `no_active_mode` / "" (空=正常) |

### 1.8 旧 key 处置（alpha 阶段）

| 旧 key | alpha 处置 |
|---|---|
| `ss_basic_mode` / `ss_acl_mode_<i>` | **保留并继续生效**（`ss_split_enabled=0` 时是唯一路径） |
| `ss_basic_shunt_*`（ss_node_shunt 系列） | **保留**（mode=7 仍使用） |
| `ssconf_basic_node` / `ssconf_basic_node_front` | **保留**——doge.12 新架构作为"快速节点设置"的兜底 |

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
- **#3**：新加 hint id 选 200+。已用：0, 1, 11, 24, 27, 31, 32, 34, 29, 35-41, 44, 47-49, 54-56, 104-118, 133-156, 200, 201, 202, 203, 204。**doge.12 起从 210 开始用**（200-204 已被 doge.9~11 占用）。
- **#9**：select 控件 `refresh_options` 时若 dbus 值找不到对应 option，**不能** `val('')`——必须插 `data-stale="1"` 占位 option，`save()` 检测到 stale 跳过 dbus 覆盖。
- **#10**：运行状态 dbus key 必须配合前端轮询（参考 `refresh_chain_status_only`），不能假设 `db_ss` 新鲜。
- **#11**：alpha 阶段（`ss_split_enabled=0`）继续受 chinadns tag 优先级约束。doge.12 切换后新架构不受 #11 约束。

### 4.2 alpha 兼容性硬约束

- **不删除任何现有 dbus key**（不要 `dbus remove`）。设计文档 §14 Step 6 "ss_node_shunt_* 物理移除" alpha 阶段**不做**。
- **不修改 `rules_ng2/site/*.txt` `rules_ng2/ip/*.txt`**——这些是上游资产，alpha 期间复用，未来 doge.13+ 才考虑改造为本地源。
- **不修改 `ss_node_shunt.sh`**（保留 mode=7 旧路径）。
- **ssconfig.sh 改造采用 fork 分支**：在涉及路由层的函数里加 `if [ "${ss_split_enabled}" = "1" ]; then ...新逻辑...; else ...旧逻辑...; fi`。旧逻辑保持位字节级不变（除非有 alpha 总开关引入的小幅参数化）。

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
- `proxy_node:X` 当 X 不是当前 `ssconf_basic_node` 时，xray 生成器折回 `out_main`（不构建独立 outbound）。理由：跨节点 outbound 构建要复用所有协议 creat_*_json，alpha 不做。
- `proxy_chain:Y:X` per-rule 链式 alpha 不支持，回退 `out_main` 并继续走主节点链式 (fss_chain_apply)。
- `block_quic` Mode 级开关 alpha 在 iptables 层不实现（xray sniffing 已能识别 QUIC SNI 但无 DROP；doge.13 加 `iptables -A SHADOWSOCKS -p udp --dport 443 -j DROP`）。
- active Mode 判定粗放：alpha 把"内置 Mode + default Mode"都激活，不严格按 acl 引用过滤。
- 单条 dbus 调用 fork 多个 jq 子进程，50 mode × 10 rule 量级启动 ~3s。alpha 接受。

**install.sh 迁移层**（A）：
- 旧 key 物理删除（设计 §14 Step 6 / Step 7.5）alpha 跳过，新旧并存。
- ipset 销毁 alpha 跳过（旧路径仍用）。
- helper `write_builtin_mode_meta` 硬编码 `apply_blackwhite=1`，doge.13 视需要扩展签名。

**UI 第一稿**（C）：
- 新建/编辑/删除 Mode/Rule 对话框用 `alert()` 占位文字。doge.13 做漂亮弹窗。
- 拖动重排未实现（依赖编辑弹窗）。
- 立即更新 / 回滚到 .bak 按钮无 UI 入口（脚本能力已就绪 by D，UI 后接）。
- 访问控制 UI 改造留 doge.13。
- 导入/导出 Mode (JSON) 留 doge.13。
- Mode/Rule 子字段写入路径（如 `ss_split_mode_<m>_udp_proxy`）依赖编辑弹窗。

**cron**（D）：
- `recount_stats` 用 grep 单行处理，10 万行规则路由器上估算 5-10s（alpha 阶段 update_hours=0 cron 不实际跑）。doge.13 改 awk 单遍。
- UTF-8 校验罕见环境下 isutf8/iconv 都不在则降级到行数/字节数兜底。
- busybox ash trap EXIT 在 SIGKILL 下不释放锁——下轮 cron 卡 30 分钟。doge.13 加 stale-lock 检测。

### 6.2 已知集成漂移（**需要主代理协调 / 由审查 subagent 复查**）

#### D1: 分流 DNS upstream 读写两套 key
- **症状**：C 的 UI 新增 textarea 写入 `ss_split_dns_china_upstream` / `ss_split_dns_overseas_upstream` / `ss_split_dns_global_upstream`，但 B 的 `generate_chinadns_split_conf` / `generate_chinadns_global_conf` 仍从老 key `ss_basic_chng_china_dns_*` / `ss_basic_chng_trust_dns_*` 读取。
- **alpha 决议**：C 的 textarea 应改为 placeholder / hint 提示用户去"DNS 设置"老页面配置，**或** B 的生成器加优先级 fork（先读新 key，缺失回退老 key）。**主代理选 placeholder 方案**——alpha 阶段新 UI 仅展示老页面的配置不可直接编辑，避免分裂用户心智模型。
- **doge.13 完成**：新增"分流 DNS 设置 V2"独立 ASP 入口，统一 ss_split_dns_* 命名 + migrate 把老 key 一次性切到新 key 后删老 key。

#### D2: Mode index `m` 与 Mode.id 在 alpha 时等同
- **症状**：A 写入用 `mid=1, mid=2` 同时作为索引和 id；设计文档 §3.1 说"索引与 id 解耦（删除时不重排 id）"。
- **alpha 决议**：alpha 阶段（用户不能删内置 Mode 也没编辑弹窗）等同没问题。doge.13 起，编辑弹窗实现 Mode 删除时**必须**重构为索引-id 解耦，否则 B 的 `for m in $(seq 1 ${mode_count})` 会漏掉中间 gap。

#### D3: data-skip-save 通用机制 vs 设计文档的 data-stale
- **症状**：设计文档 §8 通用 select 约束讲 `data-stale="1"` 模式（save() 时跳过 dbus 覆盖）。C 实现的是更通用的 `data-skip-save="1"` 属性，save() 收集循环检测此属性跳过。
- **alpha 决议**：通用化是改进，**接受**。在本文档备注以便后续 ASP 改造遵循同一机制。

#### D4: ss_split_runtime_status / ss_split_enabled_state 是 C 内部状态
- **症状**：C asp 引入了 `ss_split_runtime_status` / `ss_split_enabled_state` 两个 key 不在合同 §1。
- **审查结论**（Reviewer 3）：纯 DOM `<span id=>`，仅 `.html()` 渲染，**未** `dbus set`。属命名巧合，无需进合同。

#### D5: dnsmasq 让位 65355 未接线（**审查发现 → alpha 降级 WARN**）
- **症状**：ssconfig.sh L42 定义 `SS_SPLIT_DNS_LAN_PORT="65355"`，分流/全局两个 chinadns conf 都把 LAN 域名 `group-upstream` 指向 `127.0.0.1#65355`，但**没有任何代码**把 dnsmasq 实际 listen 改到 65355。
- **后果**：ss_split_enabled=1 模式下 `*.lan` / `<asusrouter>` / LAN hostname 解析可能静默失败（chinadns 转发到 65355 → 那里啥也没监听 → 超时）。
- **alpha 决议**：**降级为 WARN，留 doge.13 解决**。理由：dnsmasq 让位涉及 fancyss `postscripts/dnsmasq.postconf` + 路由器 nvram 联动，alpha 时间窗口完成风险高；alpha 默认 `ss_split_enabled=0` 不影响老用户；alpha 用户开启时已被 hint 210 警告"LAN hostname 解析可能失败"。
- **doge.13 解决方案**：在 `start_chinadns_ng_split` 起 chinadns 前通过 `postscripts/dnsmasq.postconf` 追加 `listen-address=127.0.0.1` + `port=65355`，`service restart_dnsmasq`；在 `stop_chinadns_ng_split` 中还原。

#### D6: ACL 清空连带删 ss_acl_split_mode_* （**审查发现 → alpha WARN**）
- **症状**：现有 `ssconfig.sh::clean_acl()` 有 `dbus remove ss_acl_mode`（前缀匹配），新迁移的 `ss_acl_split_mode_<i>` 在用户点 ACL 清空按钮时会跟着被删。
- **alpha 决议**：alpha 阶段 ss_split_enabled=0 默认关，影响有限。doge.13 默认开后，把 `clean_acl()` 改为显式 `dbus remove ss_acl_mode_` (加下划线)，避免前缀串到 `ss_acl_split_mode_*`。

#### D7: fss_chain_apply 与 split 路径下 out_main tag 兼容性（**审查发现 → alpha WARN**）
- **症状**：B 的 `generate_xray_json_split` 把基线 outbounds[0].tag 改为 `out_main`，但旧 `fss_chain_apply` 历史上按 outbound 索引 / tag 注入 `dialerProxy`。
- **审查结论**（Reviewer 3）：建议主代理读 fss_chain_apply 源码后判定。**主代理后续验证**：fss_chain_apply 是基于 `tag == "shadowsocks"` 等老 tag 匹配，还是按 outbounds[0] 索引匹配。alpha 路径下 fss_chain_apply 仍被调用，若 tag 不匹配则链式静默失效。
- **doge.12 后续动作**：实际测试时若链式代理在 ss_split_enabled=1 下失效，把 ssconfig.sh L5366-L5369 处的 fss_chain_apply 调用改为 split 路径专用版本（或直接 skip，让 split 路径由生成器自己处理 chain）。

### 6.3 实施期约定的回溯修订

- 合同 §0 "alpha 不物理删除旧 key" — 由 A 完全遵守 ✓
- 合同 §4.1 "硬规则 #2 asp 编码" — 由 C 完全遵守 ✓（BOM+CRLF 字节级验证通过）
- 合同 §4.1 "硬规则 #3 hint id 200+" — C 使用 210-218 ✓
- 合同 §4.1 "硬规则 #9 select stale 占位" — C 用 data-skip-save 通用化实现 ✓
- 合同 §4.4 "不打包不发版" — 4 个 subagent 全部遵守 ✓
- 合同 §4.2 "不动 rules_ng2" — 全部遵守 ✓
- 合同 §4.2 "不删 ss_node_shunt.sh" — 全部遵守 ✓

---

## 修订记录

- 2026-05-15 alpha 实施期初稿。
