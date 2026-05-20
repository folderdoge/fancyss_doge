# alpha.10 深度审计报告与修复决策清单

> **状态**：alpha.10 代码已落地工作树未 commit；tarball 已 build；测试机装的是 alpha.9（仅 asp 已热替换为 alpha.10 版本）
> **审计日期**：2026-05-19
> **审计方法**：4 subagent 并行（asp JS / shell helper / dbus 契约 / alpha.x 回归）
> **本文档定位**：为 alpha.11 修复提供唯一参考。新会话冷启动只需读：本文档 + CLAUDE.md + `doc/implementation/split-routing-implementation.md`
> **审计结论**：**alpha.10 不能 release**——骨架健康（alpha.1-9 14 项防御措施全部对齐），但 C1 弹窗这层新加代码有 **7 个 Critical / 11 个 High / 8 个 Medium / 6 个 Low**。

---

## 0. 新会话冷启动必读（在动代码之前）

1. **CLAUDE.md**（项目根）—— 15 条硬规则。特别：
   - #1 前端读 dbus key 必须 `ss_*` 前缀
   - #2 `Module_shadowsocks.asp` 是 UTF-8 with BOM + CRLF + tab 缩进。多行带前导 tab 的替换走 PowerShell `[System.IO.File]::WriteAllText` 而非 Edit
   - #9 select 控件 stale 占位机制
   - #10 运行状态 dbus key 必须配合轮询
   - #11 chinadns tag 优先级 `chnlist > gfwlist > group`
   - #13 doge.12 alpha 索引 1-indexed
   - #14 路由层 fork-not-replace 旧路径 byte-for-byte 保留
   - #15 `dbus list` 前缀匹配、`dbus remove` 精确匹配（不对称）

2. **`doc/implementation/split-routing-implementation.md`** —— alpha 合同
   - §1 dbus key 完整契约（**唯一真理之源**）
   - §1.4.1 1-indexed 规范
   - §1.5 Action 编码格式
   - §4 关键约束
   - §6.2 D1-D7 已知集成漂移

3. **代码热区**（本次 alpha.10 新加 / 未 commit）：
   - `fancyss/webs/Module_shadowsocks.asp:6451-6453` —— `_base64` 数组扩展 2 个 DNS upstream key
   - `fancyss/webs/Module_shadowsocks.asp:6963-7607` —— splitDlg 框架 + helper + Mode/Rule CRUD 弹窗（~650 行）
   - `fancyss/scripts/ss_split_rule_save.sh` —— 259 行新 helper（untracked，**runtime 未跑过**）

4. **工作树状态**（提交前）：
   ```
   M doc/implementation/split-routing-implementation.md  (D6 标误报 + dbus 语义注释)
   M fancyss/ss/version                                  (3.5.28-doge.12-alpha.9 → alpha.10)
   M fancyss/webs/Module_shadowsocks.asp                 (+648 行)
   M packages/version.json.js                            (md5 自洽)
   ?? fancyss/scripts/ss_split_rule_save.sh              (259 行新 helper)
   ```

5. **流程红线**：不主动 commit / push / amend / tag / release / bump 版本 / 跑 build_min.sh / 动测试机。

---

## 1. 总结：核心问题模式

三个模式问题串起 7 个 Critical：

**模式 A — tab 11 字段挂主 params_input/_base64，但默认 HTML 渲染值为空**：任何 tab 点保存都会把 tab 11 真实数据用空覆盖。范式 bug，影响 `ss_split_enabled` + 3 个 DNS upstream textarea。涉及 A-C-1 / A-C-2。

**模式 B — 渲染 `.html()` 拼接 `db_ss` 数据没 escape**：6+ 处 XSS 注入点。涉及 A-C-3 / A-C-4。

**模式 C — DNS upstream 写者写、读者不读**：asp 把新 key 写进 dbus，ssconfig.sh 仍读老 key。结合模式 A 后用户「改了不生效 + 还会被静默覆盖」。涉及 C-C-1（= A-C-2 同源）。

骨架本身（routing fork / 1-indexed / `ss_*` 前缀 / xray.json geoip:* 杜绝 / dbus remove 字面 / stale 占位 / `_base64` 对称 / alpha.8 三连陷阱防御 / alpha.9 base64 死循环防御）alpha.10 **完全没有破坏**。

---

## 2. Critical 清单（**必修，阻塞 release**）

### C-CRIT-1（A-C-1）：`ss_split_enabled` 在主 params_input → 跨 tab 静默关闭新架构 ⚠️ 最致命

- **位置**：`Module_shadowsocks.asp:8261`（params_input）+ `:18719`（HTML select）
- **现象**：`<select id="ss_split_enabled">` 在 tablet_11，默认 HTML 渲染选中第一个 option `"0"`。只有用户切到 tab 11 时 `refresh_split_v2_panel()`（L6794）才把 `.value` 写成 `db_ss` 实际值。`ss_split_enabled` 在 `params_input` 里 → 任何 tab 的主 save() 都会读 `E('ss_split_enabled').value`，得到 `"0"`。`db_ss['ss_split_enabled']` 是 `"1"` → compfilter 检测到差异 → 把 `"0"` 写回 dbus。
- **后果**：alpha 用户开启新架构后，**只要在任何其他 tab 点保存就静默关闭**。下次 `ssconfig.sh restart` 又回到旧路径。用户完全不知道发生了什么。
- **修法**（任选其一）：
  - (a) 参考 L8156-8165 `ss_split_default_mode_id` 的 stale 防御写法：在 `refresh_split_v2_panel` 里给 select 设 `data-touched="1"`，save() 前查；
  - (b) **推荐**：把 `ss_split_enabled` 从 `params_input` 移除，让它只能通过专门的"启用/禁用"按钮持久化（走 `dummy_script.sh` 类似 `split_v2_persist`）。
- **验法**：alpha.10 装好 → `dbus set ss_split_enabled=1` → tab 0 改无关字段点保存 → `dbus get ss_split_enabled` 仍 `1`。

### C-CRIT-2（A-C-2 + C-C-1）：3 个 DNS upstream 在主 params_* → 同样被空覆盖 + 后端不读

- **位置**：
  - asp `params_input`（`:8261-8263`）含 `ss_split_dns_global_upstream`
  - asp `params_base64`（`:8309-8311`）含 `ss_split_dns_china_upstream` / `ss_split_dns_overseas_upstream`
  - asp `_base64` load 数组（`:6451-6453`）含两个 china/overseas key
  - HTML（`:18744-18746`）3 个 textarea/input
  - ssconfig.sh `generate_chinadns_split_conf`（约 L2229-2234）**完全不读**这三个新 key，仍读老 key `ss_basic_chng_china_dns_<N>_chk` / `get_dns china <N>` / `get_dns trust <N>`
- **现象**：同 C-CRIT-1 模型——textarea 默认 HTML 渲染 value 为空字符串。tab 11 没访问过 → 主 save() 读到空 → 编码空字符串还是空 → 覆盖到 dbus。**同时**用户改 textarea 写到 dbus 实际不生效（chinadns 配置仍用老页面值）。
- **后果**：用户在 tab 11 配好双轨 DNS → 看着保存了 → 实际没生效 → 跨 tab 保存又会清空。**与合同 §6.2 D1 alpha 决议直接矛盾**（D1 说选 placeholder 方案不直接 dbus set，alpha.10 反而做成真 dbus set）。
- **修法**（任选其一）：
  - (a) **推荐 alpha.11**：3 个 textarea/input 设 `readonly` + 文案改"alpha 阶段仅占位，doge.13 启用"。从 `params_input` / `params_base64` / `_base64` load 数组移除。回归 D1 决议。
  - (b) 完整接通：ssconfig.sh 两个 generator 加 fork 优先读新 key 缺失回退老 key + 加 `data-touched` 守卫防止跨 tab 覆盖。**alpha 不建议**（时间窗口）。
- **验法**：(a) 方案——`dbus set ss_split_dns_china_upstream=test` → tab 0 保存 → `dbus get ss_split_dns_china_upstream` 仍 `test`。

### C-CRIT-3（A-C-3）：`render_split_mode_list` / `render_split_rule_list` 拼 HTML 不 escape → 持久 XSS

- **位置**：
  - `Module_shadowsocks.asp:6850`（mode name + defAction）
  - `Module_shadowsocks.asp:6880`（rule name + src + srcShort + title 属性）
- **现象**：两处用 `.html(html)` 渲染，`name` / `defAction` / `src` / `srcShort` / `id` 全部直接字符串拼接，**没有 escape**。同文件已有 `split_v2_html_escape`（L7155）和 `failover_combo_html_escape`（L7792）helper 都没用。
- **后果**：Mode/Rule 命名带 `<script>` → 持久 XSS。`source_url` 在 6880 进 `title="..."` 属性 → 输入 `" onmouseover="alert(1)` 即触发。将来 Rule 接 auto-update 从远程拉规则文件，远程 URL 来源不可信也能侧面注入。
- **修法**：6850/6880 用 `split_v2_html_escape(name)` / `split_v2_html_escape(defAction)` / `split_v2_html_escape(src)` / `split_v2_html_escape(srcShort)` 包装。`tag` 是字面常量安全免包。
  ```js
  // 6850 改造范例
  html += '<tr ...><td>#' + split_v2_html_escape(id) + ' ' +
    split_v2_html_escape(name) + tag +
    '</td>...<code>' + split_v2_html_escape(defAction) + '</code></td>';
  ```
- **验法**：Mode name 输入 `test<img src=x onerror=alert(1)>` → 保存 → 列表渲染时不触发 alert（应显示 raw 文本）。

### C-CRIT-4（A-C-4）：编辑弹窗标题 `data.id` 直接进 HTML → XSS（与 C-CRIT-3 同模式）

- **位置**：
  - `Module_shadowsocks.asp:7294`（Mode 编辑弹窗 `<b>' + data.id + '</b>`）
  - `Module_shadowsocks.asp:7549`（Rule 编辑弹窗同上）
  - `Module_shadowsocks.asp:7343`（option value=rid）
  - `Module_shadowsocks.asp:7346`（stale option value 属性 + body）
  - `Module_shadowsocks.asp:7209` / `:7230`（stale option value 属性）
- **现象**：开发者以为整数字段可信，但 db_ss 任何被污染路径（包括 C-CRIT-3 通过 name 注入后改 id）都能让 id 字段含 HTML payload。
- **修法**：所有从 db_ss 取出来后拼 HTML 的字段（包括整数 `id` / `rid` / `selectedRid` / `frontId` / `nodeId`）都过 `split_v2_html_escape`。
- **验法**：手动 `dbus set ss_split_mode_2_id="<img src=x onerror=alert(1)>"` → 打开 Mode 编辑弹窗 → 不触发 alert。

### C-CRIT-5（B-C-1）：helper slot shift 用 if-else 判空 → 误删用户"曾经空"字段

- **位置**：`fancyss/scripts/ss_split_rule_save.sh:236-243`
- **现象**：
  ```sh
  val="$(dbus get ss_split_rule_${next}_${f})"
  if [ -n "${val}" ]; then
    dbus set ss_split_rule_${s}_${f}="${val}"
  else
    dbus remove ss_split_rule_${s}_${f}     # <-- 这一行
  fi
  ```
  如果用户故意把某字段设为空字符串（如清空 source_url），下一次 slot shift 经过这个字段时会被 dbus remove，**值的语义从"曾经空"变成"不存在"**。
- **后果**：删一个 Rule 后剩下 Rule 的部分字段（source_url / update_hours 等）意外消失。前端读 `db_ss[key]` 得 undefined 而非空字符串，分支可能走错。
- **修法**：去掉 if-else 直接 `dbus set ss_split_rule_${s}_${f}="${val}"`（空字符串照写）。或在前端把 source_url 默认值统一为空字符串而非 unset。
- **验法**：建 2 个 Rule，把 Rule#100 的 source_url 设为空字符串 → 删 Rule#101 → 检查 Rule#100 的 source_url 仍是空字符串（不是 undefined）。

### C-CRIT-6（B-C-4）：helper 不 sanitize name 字段，含特殊字符破坏 dbus parse

- **位置**：`fancyss/scripts/ss_split_rule_save.sh:144-145, 205`
- **现象**：
  ```sh
  name="$(dbus get ${TMP_NAME_KEY})"
  # ...
  dbus set ss_split_rule_${slot}_name="${name}"
  ```
  `name` 如果含双引号、反引号、换行、`$`、`=`，写入 dbus 后续 `dbus list` 输出格式会被破坏（dbus 文本格式 `key=value`），下次 parse 会误读。
- **后果**：用户给 Rule 起名 `测试"规则` 就把整个 dbus 数据库的 list 切分污染，后续 awk 切 `=` 错位 → 找不到正确 slot → 数据看似消失。
- **修法**：双层防御：
  - 前端 `split_v2_save_rule_dialog` 校验 name `if (/["`$\n\r=]/.test(name)) { splitDlg.error('名字不能包含 " \` $ = 或换行'); return; }`
  - 后端 helper 入口加 `case "${name}" in *[\"\`\$$'\n''\r''=']*) fail "name contains forbidden chars" "${REQ_ID}";; esac`
- **验法**：Rule name 输入 `测试"规则` → 前端拦截。绕过前端用 curl 直接 POST → 后端 fail。

### C-CRIT-7（C-C-2）：`ss_acl_split_mode_<i>` 写者一人、读者 0 人 → acl-per-Mode 路由层不兑现

- **位置**：
  - 写：`install.sh::migrate_split_routing_v1` L791-807
  - 读：asp L7110-7115（展示用）+ L7484-7486（删 Mode 时清零）
  - **ssconfig.sh `load_iptables_split`（约 L7060-7150）完全不读**
- **现象**：合同 §1.4 定义 `ss_acl_split_mode_<acl_node>` = 该 acl 行分配的 Mode.id（0=不通过代理）。install.sh 写了，asp 读了显示，但 ssconfig.sh 路由层 acl 行装配区域全文 grep 无引用——意味着 `ss_split_enabled=1` 启用后**所有客户端都走 default Mode**，per-user Mode 分配形同虚设。
- **后果**：alpha 用户开启新架构后，acl 表里给每个 MAC 选的 Mode 完全没用——所有客户端走同一个 default Mode。
- **修法**（任选其一）：
  - (a) 文档化为 alpha 已知简化：在 `split-routing-implementation.md §6.1` 加一条"acl per-Mode 未在路由层兑现，全部走 default Mode"。
  - (b) ssconfig.sh `load_iptables_split` 接通 acl 读取 + per-MAC mark + per-Mark iptables 跳转。**alpha 不建议**（与现有 fwmark 体系深度交互，doge.12-stable 工作量）。
- **建议**：选 (a)。alpha 阶段把这块明确为"已知简化 + doge.13 兑现"。

---

## 3. High 清单（强烈建议修，但不阻塞 release）

| ID | 一句话 | 修法成本 | 修法概要 |
|---|---|---|---|
| A-H-1 | `proxy_node:` / `proxy_chain::` 空尾巴可写脏数据进 dbus | 低 | `split_v2_save_mode_dialog` 收集后校验非空 |
| A-H-2 | helper `_result` 不清理跨次串号 | 低 | 脚本入口清桩 `dbus remove ss_split_rule_save_result _error` |
| A-H-3 | 删 Mode 时 stale rule 槽位累积（dbus 体积膨胀） | 中 | shift 后对超出新 rule_count 的旧 slot 软删，或下沉到 backend helper |
| A-H-4 | textarea 切 tab 11 二次访问覆盖未保存修改 | 低 | `refresh_split_v2_panel` 加 `data-loaded` 守卫，只填空 textarea |
| B-C-2 | helper dbus set 中途失败 cleanup_tmp 已删临时但永久 key 残缺 | 中 | 每个 `dbus set` 检查返回，失败回滚已写 + fail |
| B-C-3 | 前端连点两次 save → slot shift 交叉污染 | 低 | 前端按钮 disabled + helper 入口 flock 互斥（busybox 有 flock） |
| B-C-5 | base64 字母表合法但非 4n 长度可能仍死循环 | 低 | b64_safe 加 `[ $(( ${#1} % 4 )) -eq 0 ]` 长度检查 |
| B-H-2 | `recount_stats_file` 100k 行 = 300k fork（alpha.3 教训未完全吸收） | 中 | 复用 alpha.3 的 awk 单次扫描模式重写 |
| B-H-5 | tmp_file SIGTERM/HUP 不 trap → 残留 | 极低 | 入口加 `trap 'rm -f ${rule_file}.tmp.$$' EXIT INT TERM HUP` |
| B-H-6 | op=update 空 payload 误清空规则 | 低 | helper 增 op=update 时 payload_b64 为空 → fail |
| C-H-1 | helper create 不写 `last_update`，cron 后认为"永远到期" | 极低 | helper L212 后加一行 `dbus set ss_split_rule_${slot}_last_update="$(date +%s)"` |
| C-H-2 | Mode 的 `udp_proxy` / `block_quic` 写了没人读 | 中 | 补合同 §6.1 alpha 简化清单 + doge.13 兑现 |
| C-H-3 | `ss_split_default_mode_id` 必须非 0 缺校验 | 低 | 删 Mode fallback 写死 `'1'` 改为查 dbus 验证存在 |
| C-H-4 | `fss_split_xray_warn` 7 种状态码全是 write-only 黑洞 | 中 | 前端走 `/_api/get` 独立轮询，或合同 §6.1 降级为"SSH 调试用"备注 |
| D-H-1 | helper `b64_safe` 缺体积上限预检 | 极低 | `b64_safe` 首行加 `[ ${#1} -gt 67108864 ] && return 1` |

---

## 4. Medium 清单（酌情修）

| ID | 一句话 | 修法 |
|---|---|---|
| A-M-1 | `_modeDlgState.modeId` 解析失败时静默换 id | 编辑模式 parseInt NaN → splitDlg.error 拒绝 |
| A-M-2 | Mode/Rule save 中提示不一致 | Mode 保存中也加 `splitDlg.error('保存中...')` |
| A-M-3 | `split_v2_persist` 失败后 db_ss 不一致语义易误解 | 加注释说明设计意图 |
| B-M-1 | log() 写 /tmp/syslog.log 与 syslogd 冲突 | 改 `logger -t fancyss` 或 `/tmp/fancyss/split_rule_save.log` |
| B-M-4 | `set --` 拆 recount 输出销毁 $1 隐患 | 加注释提醒，或改 `read d i <<< "$(recount...)"` |
| B-M-5 | dbus 调用失败兜底缺失 | 入口探活 `dbus get ssconf_basic_node >/dev/null` 失败 abort |
| C-M-1 | 内置 builtin=1 标志可能被 asp 编辑覆盖（Mode 端缺显式守卫） | Mode save 显式 `if (edit && existing.builtin === '1') fields[...builtin] = '1'` |
| C-M-2 | Mode rule 软删空字符串 vs helper dbus remove 不一致 | 文档备注 doge.13 统一走 helper |
| D-M-1 | helper `b64_safe` 跟 alpha.9 订阅路径采样策略不一致 | b64_safe 注释说明差异和理由 |
| D-M-2 | recount_stats_file alpha.3 教训未完全吸收（B-H-2 同根因） | 同 B-H-2，合并修 |
| D-M-3 | Mode dummy_script.sh 错误回显缺失（vs Rule 路径有 result/error） | alpha 接受 doc 备注 |

---

## 5. Low 清单（记 backlog，doge.13+ 解决）

| ID | 一句话 |
|---|---|
| A-L-1 | helper 名字 `split_v2_*` 过长，doge.13 升级方案 B 时易拼错 |
| A-L-2 | `render_split_mode/rule_list` 全表重渲染性能（50+ 条时卡顿） |
| B-L-1 | `KSROOT=/koolshare` 直接覆盖 vs `${KSROOT:-/koolshare}` 容错 |
| B-L-2 | helper 没用 `set -u`（busybox ash 支持） |
| B-L-3 | `printf '%s' \| tr \| sed` 三 fork-per-line（B-H-2 同根因） |
| B-L-4 | find_rule_slot_by_id 双 awk 可合并为单 awk |
| C-L-1 | `fss_split_rules_update_lock` / `_log` / `outbound_dedup_cache` 全空集（fss_rules_update.sh 未落地） |
| D-L-1 | Rule 弹窗 textarea 无硬规则 #11 chinadns tag 优先级提示 |
| D-L-2 | 临时 dbus key 在 helper crash 时不清理（应加 `trap cleanup_tmp INT TERM EXIT HUP`） |

---

## 6. 推荐修复顺序与决策点

### Phase 1（alpha.11 必修，~3-5 小时）

按依赖性顺序（**强烈建议按此顺序，前一步是后一步的前提**）：

1. **C-CRIT-3 + C-CRIT-4 XSS 修复**（机械、低风险）
   - 全文 grep `\.html\(.*db_ss\|\.html\(.*data\.\|\.html\(.*+ id +` 收集 6+ 处
   - 每处包 `split_v2_html_escape()`
   - **验法**：6 处 escape 注入 alert payload 都不触发
   - **改完 sh -n / node --check + git diff -U0 自检**

2. **C-CRIT-2 + C-CRIT-1 模式 A 范式修复**（推荐方案 a：textarea 设 readonly + 移出 params_*）
   - `ss_split_enabled` 从 `params_input` 删除
   - 3 个 DNS upstream 从 `params_input` / `params_base64` / `_base64` load 数组删除
   - HTML（`:18719` select、`:18744-18746` textarea）改为 readonly + 文案"alpha 阶段仅占位，doge.13 启用"
   - 提供专门的"启用/禁用新架构"按钮（参考 `failover_combo_dlg` 套路走 `dummy_script.sh`）
   - **验法**：alpha.10 装好 → dbus set ss_split_enabled=1 → tab 0 改无关字段保存 → ss_split_enabled 仍 1

3. **C-CRIT-5 + C-CRIT-6 helper 数据完整性**
   - C-CRIT-5：去掉 if-else 直接 dbus set
   - C-CRIT-6：前后双层 sanitize name 字段
   - **验法**：见各条单测验法

4. **C-CRIT-7 文档化 acl 路由层简化**
   - 编辑 `doc/implementation/split-routing-implementation.md §6.1`：加 "acl per-Mode 未在路由层兑现，alpha 阶段全部走 default Mode，doge.13 兑现"
   - **改文档而非代码**

### Phase 2（alpha.11 强烈建议，~1-2 小时）

**修 High 里成本低的**：A-H-1 / A-H-2 / A-H-4 / B-C-5 / B-H-5 / B-H-6 / C-H-1 / C-H-3 / D-H-1 / D-L-2（trap 兜底）

每条修法概要在第 3 节表格。批量修 + 一次 sh -n / node --check 验证。

### Phase 3（alpha.11 可选）

**B-H-2 / D-M-2 重写 recount_stats_file 用 awk**——alpha.3 教训。1 万行起卡顿，但 alpha 阶段用户大概率不会编辑超大 Rule，可推 alpha.12。

### Phase 4（doge.13 backlog）

所有剩余 Medium / Low + C-H-2（udp_proxy / block_quic 真正接通路由层）+ C-H-4（fss_split_xray_warn 接消费者）+ A-H-3（Mode delete 下沉 backend）。

---

## 7. 修复后的整体验收清单

### 静态检查
- [ ] `git diff -U0` 验证只动目标行，没有意外编辑
- [ ] `sh -n fancyss/scripts/ss_split_rule_save.sh` 通过
- [ ] `node --check` 或浏览器 console parse Module_shadowsocks.asp 的 JS 区块通过
- [ ] 全文 grep `\.html\(.*db_ss\|\.html\(.*data\.` 无新 XSS 注入点
- [ ] 验证 BOM/CRLF 完整：
  ```powershell
  $b = [System.IO.File]::ReadAllBytes("fancyss\webs\Module_shadowsocks.asp")
  $b[0..2]  # 应该是 239 187 191 (EF BB BF)
  ```

### 路由器场景测试（用户在测试机 WebUI 装 alpha.11 包后跑）

**场景 1 — 跨 tab 不破坏分流设置**
1. `dbus set ss_split_enabled=1`
2. 切到 tab 0「帐号设置」，改任意无关字段，点保存
3. `dbus get ss_split_enabled` 应为 `1`（不被覆盖）

**场景 2 — XSS 不触发**
1. 创建 Mode 名字 `测试<img src=x onerror=alert(1)>`
2. 列表渲染时不触发 alert，名字显示为 raw 文本（含 `<img...>` 字符）
3. 编辑弹窗标题中 id 字段同样不触发

**场景 3 — Rule helper CRUD 闭环**
1. 装 alpha.11 → `ls -la /koolshare/scripts/ss_split_rule_save.sh` 应存在
2. 创建 Rule#100 `test_rule`，payload 含 `example.com` + `1.2.3.4`，保存成功
3. `dbus get ss_split_rule_count` / `_id` / `_name` / `_stat_domains` / `_stat_ips` / `_last_update` 全部正确
4. `/koolshare/ss/rules_user/rule_100.txt` 内容正确
5. 编辑 Rule#100，删一行 payload，保存成功，stats 更新
6. 删除 Rule#100，dbus 永久 key 全删，规则文件删，count -1

**场景 4 — Mode 弹窗 + 内置守护**
1. 编辑内置 Mode#2，能改 rules[]、不能改 builtin 标志
2. 删除内置 Mode#1 → 前端 alert 拦截 + 后端绕过测试不动 dbus

**场景 5 — Critical 验法（见各条）**
- C-CRIT-5：建 Rule#100 source_url 空 → 删 Rule#101 → Rule#100 source_url 仍空
- C-CRIT-6：Rule name 含特殊字符前端拦截 + curl 绕过后端 fail

**场景 6 — 总开关 fork-not-replace 保持**
1. `ss_split_enabled=0`：完整跑一遍 GFW / CHN / 全局模式（旧路径未破坏）
2. `ss_split_enabled=1`：新路径启动成功，分流 DNS 双轨工作（保留 alpha.8/9 已验过的场景）

---

## 8. 流程红线（新会话必遵守）

- ❌ 不主动 `git commit` / `push` / `amend` / `tag` / `release`
- ❌ 不主动 bump 版本号（这一步留用户实测通过后授权统一做）
- ❌ 不主动跑 `build_min.sh`
- ❌ 不动测试机（alpha.10 包已在 /tmp/，但等用户 WebUI 装）
- ✅ 改路由层代码前 grep `ss_split_enabled` ssconfig.sh 看现有 fork 入口，byte-for-byte 保留旧路径
- ✅ 改 `Module_shadowsocks.asp` 用 PowerShell BOM/CRLF 兜底写法（多行带前导 tab 替换 Edit 经常失败）
- ✅ 每次改完用 `git diff -U0` 自检只有目标行变化

### asp 安全写法（硬规则 #2 复述）

```powershell
$f = "E:\网络幽灵\fancyss_doge\fancyss\webs\Module_shadowsocks.asp"
$s = [System.IO.File]::ReadAllText($f, (New-Object System.Text.UTF8Encoding $true))
$s = $s.Replace("`r`n旧字符串`r`n", "`r`n新字符串`r`n")
[System.IO.File]::WriteAllText($f, $s, (New-Object System.Text.UTF8Encoding $true))
```

old/new 字符串里的 tab 用 `` `t ``，行尾用 `` `r`n ``。

---

## 9. 不在本次修复范围的事项（明确划定）

- **D5 dnsmasq 让位 65355**：合同 §6.2 D5 已 WARN alpha 不修，留 doge.13。本次不动。
- **D7 fss_chain_apply 与 split 路径 out_main tag 兼容性**：合同 §6.2 D7 留 doge.12-stable 验证。本次不动。
- **新 hint id 220-224 跳过未加**：决定改用弹窗内 inline 帮助文字。本次不动。
- **立即更新规则文件 / 回滚到 .bak / 导入导出 Mode JSON / 拖动重排**：留 doge.13。本次不动。
- **协议层面任何决策**（如 anytls-zig、type ID）：完全不在 alpha.10/.11 范围。

---

## 10. 文档与上游同步（独立工作流）

修复完成后，建议（但不强求新会话同会话做）：

1. **更新 `doc/implementation/split-routing-implementation.md §6.2`**：
   - D1 状态从"placeholder 决议"标记为"alpha.11 落地：textarea readonly"
   - 新增 D8（C-C-2 文档化）：acl per-Mode 路由层 alpha 简化
   - 新增 D9（C-H-4 文档化）：fss_split_xray_warn 仅 SSH 调试用

2. **若决定做 D5 设计 pass**：新建 `doc/design/split-routing-dnsmasq-yield.md`。

3. **上游 hq450 合并冲突预演**（独立任务）：
   ```
   git fetch upstream
   git merge-tree $(git merge-base 3.0 upstream/master) 3.0 upstream/master | grep -E "^\+<<<<<<<|^changed in both"
   ```
   不实际 merge，只产出冲突点清单。

---

## 修订记录

- 2026-05-19 初版（4 subagent 并行审计：A=asp JS、B=helper shell、C=dbus 契约、D=alpha.x 回归）
