# 协议路线图 — fork 战略文档

> **状态**：**设计草案**，未实施。记录 2026-05-13 与用户达成的战略共识，作为后续多个版本的指导文件。
>
> **核心战略**：本 fork 长期方向是**和上游 hq450/fancyss 彻底分离、全力押注链式代理（前置→落地）**。链式代理是 fork 存在的根本理由；任何与之冲突的上游遗产都应被剥离或重构。
>
> 关联背景文档：
> - [chain-proxy-implementation.md](../implementation/chain-proxy-implementation.md) — 链式代理当前实现（§1.1 协议矩阵）
> - [failover-combo-implementation.md](../implementation/failover-combo-implementation.md) — 故障转移已围绕链式代理重构
>
> **本文档不包含**：超远期猜想性方向（如私有协议自研）。仅记录已达成共识、有明确执行路径的事项。

---

## 1. 当前协议矩阵 + 链式代理支持现状

| type | 协议 | xray 原生 | 作前置 | 作落地 | 当前实际可用 |
|---|---|---|---|---|---|
| 0 | Shadowsocks | ✅ | ✅ | ✅ | 是（仅 `ss_obfs="0"`）|
| 1 | SSR | ❌ rss-redir | ❌ | ❌ | 否 |
| 3 | VMess (v2ray) | ✅ | ✅ | ✅ | 是（仅 `v2ray_use_json="0"`）|
| 4 | VLess/VMess (xray) | ✅ | ✅ | ✅ | 是（仅 `xray_use_json="0"`）|
| 5 | Trojan | ✅ | ✅ | ✅ | 是（不含 `trojan_plugin`）|
| 6 | Naive | ❌ 独立进程 | ❌ | ❌ | 否 |
| 7 | Tuic | ❌ 独立进程 | ❌ | ❌ | 否 |
| 8 | **Hysteria2** | ✅ **xray 原生 outbound** | ✅ | ✅ | **是**（doge.10 起加入链式，见下方修订）|
| 9 | **AnyTLS** | ❌ 但本地 socks5 | ❌ | ❌ | 否（但极易接入，见 §3）|

> **2026-05-13 修订**：HY2 之前被误归类为"独立进程"。实际上 [ssconfig.sh:824-828](../../fancyss/ss/ssconfig.sh#L824) 和 [`start_hy2()`](../../fancyss/ss/ssconfig.sh#L4938) 表明 fancyss 用 xray-core 原生 outbound 运行 HY2（和 Trojan 共用 xray.json）。没有独立 hysteria 二进制——`/koolshare/bin/hysteria2` 的清理代码是清理上游早期版本残留。`fss_chain_type_supported()` 当前只接受 type 0/3/4/5，没有技术原因，只是历史遗漏。doge.10 一并修复。

**统一接入模式**：所有"非 xray outbound"协议都可通过**本地 socks5 中转**接入链式 — 本地起 client 监听 `127.0.0.1:<port>`，xray 用 socks outbound 接到它。AnyTLS 已经在用这套架构（[ssconfig.sh:5139](../../fancyss/ss/ssconfig.sh#L5139)，固定端口 23456）。

### 1.1 落地端的物理限制

**作前置容易（理论上 8/8 协议都可以）**：流量方向 `xray → 本地 client → 远端前置 → 落地服务器 IP:port`，前置只负责搬运封装后的连接。

**作落地受限**：要求 client 支持"上游 socks/http 代理"配置项，且协议必须是 TCP-friendly。

| 协议 | 作落地可行性 | 原因 |
|---|---|---|
| SS / VMess / VLess / Trojan | ✅ | xray 原生 `dialerProxy` |
| Naive | ✅ | 天生支持 `listen+upstream` 链式 |
| SSR | ⚠️ 需 patch | rss-redir 无上游代理选项 |
| AnyTLS | ⚠️ 需 patch | `anytls-zig` CLI 当前无上游选项 |
| **Hysteria2** | **✅** | **xray 原生 outbound，`dialerProxy` 直接生效**（doge.10 已支持）|
| Tuic | ❌ 物理限制 | QUIC/UDP，TCP 前置无法搬运 |

**结论**：未来 UI 应设计为**前置下拉显示所有支持协议，落地下拉只显示能作落地的子集**。不对承诺"任意×任意"。

---

## 2. doge.10 — 砍协议方案

**目标**：把当前不支持链式代理的 3 个协议（SSR / Naive / Tuic）从可用路径上切除，但**保留数据通道和未来加回的可能性**。同时**给链式代理加 HY2 支持**（HY2 本就是 xray 原生 outbound，加 type 8 分支即可）。

### 2.1 切除范围

| 项 | 处理方式 |
|---|---|
| **节点 type ID** | **永久预留** 1/6/7（HY2=8 现已可用、不预留），新协议必须从 10+ 开始 |
| **节点订阅解析** | 保留进 dbus（不丢用户数据），UI 列表显示但灰显标注「⚠️ 暂不支持」 |
| **节点选择下拉**（落地/前置/故障转移组合） | 这 3 个协议的节点不可选 |
| **当前节点切换** | 切到这 3 种协议的节点时前端弹窗阻断 |
| **后端 `start_*` / `stop_*` 函数** | 注释保留（`# FORK: cut in doge.10, planned to restore via socks-relay`），**不物理删除** |
| **二进制文件** `naive / tuic-client / ssr-redir / ssr-local` | 从 `build_min.sh` / `build.sh` 打包步骤排除；`fancyss/bin-*/` 目录下保留（git 不删），将来加回不需要重新搞 toolchain。注意 HY2 无独立二进制，无需处理 |
| **install.sh / uninstall.sh** | 加 cleanup 逻辑：用户从老版本升级时主动清掉路由器上残留的 `/koolshare/bin/naive` 等，避免进程残留 |
| **Module_shadowsocks.asp 表单** | 这 3 个协议对应的字段块隐藏（保留 HTML 注释或 `display:none`），不删。HY2 字段保留正常显示 |
| **ss_chain_proxy.sh** | `fss_chain_type_supported()` 加 type 8 (HY2) 分支；`fss_chain_build_front_outbound_json` 加 HY2 outbound 模板 |

### 2.2 为什么"注释保留"而不是物理删除

1. **git log 友好**：将来加回时 git blame 直接定位历史代码作参考
2. **上游 merge 冲突小**：整块注释 vs 整块删除，前者三方合并更友好
3. **可读性**：阅读代码时能直接看到"为什么这里有个空洞"
4. **可逆性**：决策错了能快速回滚

### 2.3 不在切除范围内的事项

- **不要**重构 dbus key 前缀（保持 CLAUDE.md 硬规则 #1）
- **不要**改 `ss_basic_type` 编号体系
- **不要**动 sub-get / sub-tool（订阅解析器还得认出这些协议才能"保留进 dbus"）

### 2.4 验收标准

- [ ] 老用户升级后,原有 SSR/Naive/Tuic/Hy2 节点数据未丢失,UI 显示「不支持」灰显
- [ ] 节点选择下拉框里看不到这 4 类协议
- [ ] 路由器 `/koolshare/bin/` 下无残留的 `naive / tuic-client / ssr-redir / hysteria*`
- [ ] `fancyss_hnd_v8_full.tar.gz` 体积比 doge.9 明显减小（预期 -5MB 量级）
- [ ] `build_min.sh` 无错误,日志无残留协议引用警告

---

## 3. AnyTLS 特殊地位 + 依赖管理

### 3.1 为什么 AnyTLS 不在砍除名单里

虽然 AnyTLS 也是"非 xray outbound"协议（type=9），但它有**三个独特优势**让它值得保留：

1. **体积优势压倒一切**：`anytls-zig` 仅 **166KB**（对比 naive 3.2M / tuic 1.8M / xray 6.7M），是典型 Go 实现 AnyTLS 的 30-60 倍压缩。路由器场景下扔掉等于亏。
2. **TCP-based**：不受 QUIC/UDP 限制，作前置/落地都没物理障碍
3. **已经在用 socks5 中转架构**：本地 23456 端口监听已就绪，接链式代理近乎白送（只需端口管理）

### 3.2 依赖管理风险

`anytls-zig` 是 **hq450 用 GPT 辅助生成的 Zig 实现**（见 [.gitmodules:22-25](../../.gitmodules)），是本 fork 与上游唯一的强耦合点。

| 优势 | 风险 |
|---|---|
| 体积小、启动快、内存占用低 | GPT 生成代码，边角 bug 难根因排查 |
| 完美契合路由器场景 | Zig 不是大众语言，社区支持薄 |
| 已是 local socks5 架构 | hq450 一旦停更要自己维护 Zig 代码 |
| | AnyTLS spec 演进依赖 hq450 跟进 |

### 3.3 处置策略

**短期（doge.10 ~ 至少几个版本内）**：继续用 hq450 的 `anytls-zig` submodule。但：

- [ ] **submodule 切到 pinned tag**（不要跟 `branch = main`,避免 hq450 改了 main 下次构建突然 break）
- [ ] 把当前用的版本号在本路线图里记一次,方便回滚: **当前版本：3.5.28-doge.10**（执行 doge.10 时记录）

**中期（doge 任意空闲版本）**：**深度审计 `anytls-zig`**。利用 MAX 订阅,用 subagent 跑 systematic review:

- **内存安全**：Zig 不默认内存安全,查 use-after-free / 缓冲区越界 / 整数溢出
- **协议正确性**：TLS 握手完整性、重放防护、错误处理路径覆盖
- **AnyTLS spec 一致性**：和参考实现(sing-box 版)做行为对比,找静默偏差
- **性能优化点**：内存池、零拷贝、TLS resumption

预期产出：审计报告 + 可选的 PR 提交回 hq450 仓库(或在本 fork 自己维护补丁集)。

**长期触发条件**(满足任一即考虑 fork anytls-zig 到自己仓库)：

- hq450 停更超过 6 个月
- 发现关键 bug 而上游不响应
- AnyTLS 协议 spec 升级而上游不跟进

**永远不做**：换回 sing-box / Go 社区实现。体积代价不可接受。

---

## 4. 协议加回路线图

按"工作量小+收益大"排序。每个协议一个独立小版本,完成一个发一个,**不批量**。

### 优先级 P1 — AnyTLS 链式接入

- **版本目标**: doge.11 或 doge.12（A 阶段完成后立即做）
- **作前置**: 极易。`anytls-zig` 已经监听 socks5,xray 的 `proxy_front` 用 socks outbound 接到它即可。**核心工作**: 端口管理（不能再固定 23456,要支持多个本地 socks 端口共存）
- **作落地**: 需要给 `anytls-zig` 加 `--upstream-socks=<addr:port>` CLI 参数,然后整个流量经 xray 的前置 outbound 套一层。**工作量**: Zig 代码改动 + ssconfig.sh 集成
- **如果作落地工作量大**: 先只做作前置版本

### 优先级 P2 — Naive 双端

- **版本目标**: doge.13 或之后
- **作前置**: 本地起 naive 监听 socks5,xray 接入
- **作落地**: naive 本身就支持 `listen + upstream` 链式语法,配置层面就能拼出来
- **工作量**: 中等。Naive client 二进制要重新打包进去,UI 字段恢复

### 优先级 P3 — Tuic 仅作前置

- **版本目标**: 视用户需求
- **作前置**: 高速穿透 GFW 的刚需。本地起 tuic-client 监听 socks5,xray 接入
- **作落地**: ❌ 物理限制,不做(QUIC/UDP)
- **工作量**: 中等。UI 落地下拉要做"协议-按角色过滤"

> Hysteria2 不在加回路线图,因为 doge.10 已经直接接入(xray 原生 outbound,无需 socks 中转)。

### 优先级 P4 — SSR 双端

- **版本目标**: 最后,可能无限期延后
- **作前置**: 需要 patch rss-redir 加上游代理选项,或换 SSR client 实现
- **作落地**: 同上
- **工作量**: 大。SSR 用户群也最老,优先级最低
- **可能的替代方案**: 直接判定"SSR 在本 fork 永久弃用",从 dbus 数据中也清除

---

## 5. 与其他规划的关系

- **自定义分流（doge.11/12/13 已细化）**：已拆解为三个独立版本，参见 §7（doge.11 硬编码出土）/ §8（doge.12 分流架构落地）/ §9（doge.13 UI 完善 + DNS 极简化）。doge.10 砍协议先做，让 doge.12 在干净代码基上重构
- **上游源码排查优化（doge.14+）**：在窄表面（SS / VMess / VLess / Trojan / HY2 / AnyTLS 6 协议代码基）上做更值得。砍掉的 SSR/Naive/Tuic 代码已经不在视野里
- **协议加回路线（§4 P1~P4）推迟到 doge.20+**：doge.11/12/13 是 fork 的核心架构跃迁档期，不和协议加回抢档。AnyTLS 链式接入、Naive 双端等等到分流架构稳定后再启动
- **故障转移备用组合（已完成）**：已经围绕链式代理重构，与本路线图一致。doge.12 按 split-routing-architecture.md Q8 决议把 failover-combo 数据**保留但 UI 隐藏**，留作未来与 Mode 体系融合的可能性

---

## 6. 维护说明

- **本文档随版本演进**: 每发一个版本如果涉及协议变更,回来更新对应章节
- **协议加回时**: 在 `doc/implementation/` 下新建对应文档,本文档加链接
- **如果 anytls-zig 出问题或决定换实现**: §3 必须更新
- **不要往这个文档塞猜想性内容**: 远期方向用 issue / GitHub Discussion 记录,本文档只放"已确认要做"
- **doge.11/12/13 已细化**，参见 §7/§8/§9。后续版本继续按"一版一节"格式追加

---

## 7. doge.11 — "硬编码出土" 过渡版

> **主题**：把 Phase 1 审计发现的"绕过用户分流的硬编码点"拆出来变成变量 + dbus 开关，为 doge.12 分流架构铺干净的地。**不引入新功能，只把"看不见的强制行为"挪到台面上**。
>
> **工作量**：1-2 个工作日量级的小版本。
>
> **是否破坏性升级**：否。老用户升级后 UI 仅在"黑白名单"页多出两个 select 控件（紧挨 doge.9 的 `ss_basic_direct_asusgo`），默认值维持现状行为，无 regression。

### 7.1 范围（来自 Phase 1 审计）

> **实施备注**：下表 dbus key / 变量名为 doge.11 实际落地名（与最初规划略有简化，如 `chinadns → chndns`、`china_dns → chndns`、`reserved → reserve`、`online_check → online_ipcheck`）。实施时同步更新本表与 §7.3 / §8.2，避免 doge.12 迁移脚本因 key 名漂移失败。

| 审计编号 | 处理方式 |
|---|---|
| **G1 拆变量** | [ssconfig.sh:3249-3263](../../fancyss/ss/ssconfig.sh#L3249) 原 `ip_lan` 一行混了 RFC1918 私网地址 + 中国公共 DNS IP，拆成两个独立变量：<br>• `ip_lan_reserve` = RFC1918 + 127/8 + link-local + multicast（必须保留，不可关，即 R1）<br>• `ip_lan_chndns` = 10 个中国公共 DNS IP（阿里 / 腾讯 / 114DNS / CNNIC / OneDNS / 百度，如 223.5.5.5 / 114.114.114.114 / 119.29.29.29 / 180.76.76.76）<br>新加 dbus 开关 `ss_basic_direct_chndns`（默认 1，维持现状） |
| **G6 在线检测开关** | [ssconfig.sh:264/556/562/568/574](../../fancyss/ss/ssconfig.sh#L264) 启动时硬编码上送出口 IP / 时间到 worldtimeapi.org / ip.ddnsto.com / ip.clang.cn / akamai / api.myip.com 5 个外部 endpoint。<br>新加 dbus 开关 `ss_basic_online_ipcheck`（默认 1，维持现状） |
| **R1 与 G1 分离** | 纯粹是 G1 拆变量的副产品，文档明确"R1 RFC1918 部分作为 `ip_lan_reserve` 不可关；G1 中国 DNS 部分作为 `ip_lan_chndns` 可关"。无新增 dbus key |
| **Y4 注释标注** | [ss_rule_update.sh:9](../../fancyss/scripts/ss_rule_update.sh#L9) `URL_MAIN="https://raw.githubusercontent.com/hq450/fancyss/3.0/rules_ng"` 加 `# TODO(doge.13)` 注释段（含切换原因 + 候选方案 A/B），**只标注不动逻辑**。实际切换留到 doge.13 |
| **修文档勘误** | doge.9 的 [asusgo-whitelist-toggle.md](../implementation/asusgo-whitelist-toggle.md) 错误地说 worldtimeapi.org "fancyss 代码无引用"，实际 [ssconfig.sh:264](../../fancyss/ss/ssconfig.sh#L264) 还在调，修文档 |
| **顺手补丁** | 修复 doge.9 引入的 `ss_basic_direct_asusgo` 漏挂 `params_input` 的 bug（select 改值未写 dbus）——同问题套到 doge.11 新增的两个 select 上一并解决 |

### 7.2 不在 doge.11 范围内

- **G2 / G3 / G4 / G5 / G7**：这些"硬编码强制走 ipset/代理域名"留给 doge.12 的 Rule 系统消化（自然变成内置预设 Rule 的条目）
- **Y1 / Y2 / Y3**：海外 DNS / asuscomm 缓存豁免 / 订阅解析硬编码 DNS，推迟（等更明确的需求场景）
- **任何 UI 重构**：分流模式 UI 整体留给 doge.12。doge.11 两个新 select 借位放在「黑白名单」tab 紧挨 `ss_basic_direct_asusgo`（与 doge.9 一致）；doge.12 重构 UI 时可再分组到「启动行为」/「附加功能」

### 7.3 验收标准

- [ ] G1 拆完后，用户禁用 `ss_basic_direct_chndns` 后访问国内 DNS 时确实经代理（验证方式：`tcpdump -i br0 host 223.5.5.5` 或 chinadns-ng 日志）
- [ ] G6 在线检测禁用后，`ssconfig.sh restart` 日志里无对 ddnsto / clang / akamai / myip.com 的 curl
- [ ] 老用户升级无 regression：默认值都为 1，行为完全等价于 doge.10
- [ ] Y4 注释能 grep 到，方便 doge.13 收尾时定位
- [ ] UI 切 select 后点「保存&应用」，路由器 SSH 看 `dbus get ss_basic_direct_chndns` / `ss_basic_online_ipcheck` 应该立刻为 0/1（验证 params_input 修复有效，同时回归 doge.9 `ss_basic_direct_asusgo`）

---

## 8. doge.12 — 分流架构落地（主菜）

> **主题**：实施 [split-routing-architecture.md](split-routing-architecture.md) 定稿的全部内容（Rule + Mode + per-User 三层模型 + xray sniffing-based routing + 双轨 DNS）。**这是 fork 最大的一次架构跃迁**。
>
> **工作量**：1-2 周量级。
>
> **是否破坏性升级**：是（架构层面）。但通过 `install.sh::migrate_split_routing_v1` 自动迁移保证老用户行为等价。建议提前发 beta release 做回归测试。

### 8.1 核心交付里程碑

具体设计细节不在本文展开，**详见 [split-routing-architecture.md](split-routing-architecture.md) 全文**。这里仅列里程碑：

| 里程碑 | 参考章节 |
|---|---|
| Rule + Mode + per-User 三层数据模型（dbus key 全套 `ss_split_*` / 后端 `fss_split_*`） | [split-routing-architecture.md §2 / §3](split-routing-architecture.md) |
| xray sniffing-based routing（替代 ipset 域名匹配，消解 CLAUDE.md 硬规则 #11） | [split-routing-architecture.md §4.2](split-routing-architecture.md) |
| 双轨 DNS（分流 DNS + 全局 DNS）+ per-Mode `dns_mode` | [split-routing-architecture.md §6](split-routing-architecture.md) |
| iptables 极简化（per-user TPROXY 端口分流，IP CIDR 类规则仍走 ipset） | [split-routing-architecture.md §5](split-routing-architecture.md) |
| 8 个内置预设 Rule（大陆白名单_常用 / GFW列表_常用 / 中国公共DNS / 查IP常用站 / Bing加速 / Telegram加速 / 在线状态检测站 / 广告统计屏蔽） | [split-routing-architecture.md §8.2](split-routing-architecture.md) |
| 2 个内置预设 Mode（全局代理 `dns_mode=global` / 大陆白名单 `dns_mode=split`）+ 删除保护 | [split-routing-architecture.md §8.1](split-routing-architecture.md) |
| 模式管理页 + 规则管理页 + 运行状态页（合并原"账号设置"/"访问控制"）+ DNS 设定页改造（拆分流 DNS + 全局 DNS） | [split-routing-architecture.md §8](split-routing-architecture.md) |
| 快速节点设置（默认 Mode 是预设时显示） | [split-routing-architecture.md §8.4](split-routing-architecture.md) |
| 数据迁移 `install.sh::migrate_split_routing_v1`（GLO→全局代理 Mode / 非全局→大陆白名单 Mode / 节点灌入兜底 / 黑白名单保留 / 故障转移 UI 隐藏数据保留 / "xray 半成品分流" 物理移除） | [split-routing-architecture.md §14](split-routing-architecture.md) |
| 统一 cron `fss_rules_update.sh` 30 分钟轮一次 | [split-routing-architecture.md §10](split-routing-architecture.md) |
| 规则文件格式（纯文本一行一条，自动识别域名/IP；suffix 默认，`+` 前缀 = exact） | [split-routing-architecture.md §9](split-routing-architecture.md) |
| 导入/导出 Mode (JSON)（Q14 提前到 doge.12，导出 Mode + 其引用所有 Rule） | [split-routing-architecture.md §3.7](split-routing-architecture.md) |

### 8.2 与 doge.11 的衔接

- doge.11 拆出的 `ss_basic_direct_chndns` 在 doge.12 中**降级为兼容键**：迁移脚本读它一次，灌入"中国公共 DNS"内置 Rule 的初始 action（=1→direct，=0→default_action）后弃用
- doge.11 拆出的 `ss_basic_online_ipcheck` 在 doge.12 中**保留不变**：在线检测是启动期一次性行为，不进 Rule 系统
- doge.11 标注的 Y4 注释由 doge.13 兑现切换

### 8.3 验收标准

- [ ] 所有 doge.11 之前的用户场景（GFW / CHN / HOM / GAM / SHU / 全局）行为不变（自动迁移到对应 Mode）
- [ ] 新场景：用户能新建 Mode、配 Rule、per-MAC 分配、per-Rule 选链式代理（前置→落地）
- [ ] microsoft.com 在 `dns_mode=global` 的 Mode 下访问拿到英文站 IP（验证双轨 DNS 生效）
- [ ] CLAUDE.md 硬规则 #11 不再适用——用户加 bilibili.com 到自定义 Rule 标"屏蔽"能真生效（不被 chnlist tag 抢走）
- [ ] 性能：xray restart < 5s、内存增长 < 20MB、CPU 增长 < 10%（典型家用配置下，详见 [split-routing-architecture.md §11](split-routing-architecture.md)）
- [ ] failover-combo 数据保留但 UI 隐藏（Q8）
- [ ] 协议矩阵不变：本架构跃迁不动 §1 的协议支持表，6 个有效协议（SS / VMess / VLess / Trojan / HY2 / AnyTLS）继续可用

---

## 9. doge.13 — UI 完善 + DNS 极简化（次菜）

> **主题**：doge.12 的"用户友好化"补丁。**doge.12 是底层架构，doge.13 是把它磨成产品**。
>
> **工作量**：根据用户反馈灵活调整，可发多个 doge.13.x 补丁。
>
> **是否破坏性升级**：否。doge.13 是渐进式增强，每条候选独立交付。

### 9.1 候选范围（按优先级，每条独立可发）

| 优先级 | 候选 | 说明 |
|---|---|---|
| P1 | **快速向导** | 新装用户首次进入运行状态页弹一次性向导（"用大陆白名单？/ 全局代理？/ 自己配？"），三选一一键完成 Mode 分配。落标志位 `ss_split_wizard_done=1`（install-once 语义，参照 CLAUDE.md 硬规则 #8 的 main_combo_seeded） |
| P1a | **Y4 兑现：rules_ng 镜像切换** | 建立 fork 仓库下 `rules_ng/`，[ss_rule_update.sh:9](../../fancyss/scripts/ss_rule_update.sh#L9) 的 `URL_MAIN` 切换到 `https://raw.githubusercontent.com/folderdoge/fancyss_doge/3.0/rules_ng/`。fork 仓库 CI 周期性同步上游规则集 |
| P1b | **I4 兑现：xray binary 镜像切换** | 建立 fork 仓库下 `binaries/xray/`，[ss_xray.sh:15](../../fancyss/scripts/ss_xray.sh#L15) 的 `url_main` 切换到 `https://raw.githubusercontent.com/folderdoge/fancyss_doge/3.0/binaries/xray`（或对接 XTLS official release）。fork 仓库 CI 周期性同步上游 |
| P2 | **Q15 兑现** | 删 Rule 时若有 Mode 引用，提供"批量替换为另一 Rule"快捷操作（doge.12 仅做了删除保护拦截，doge.13 加批量替换） |
| P2 | **DoH/DoT 客户端检测** | UI 加一栏"检测到客户端绕过路由器 DNS"（监听 53/853/443 出向并标记），提示用户在客户端关 DoH 或路由器加 DoH 拦截规则。doge.12 双轨 DNS 已为该检测打下基础 |
| P2 | **DNS 缓存清理助手** | 用户切换 Mode 时自动调用 `dnsmasq SIGHUP` 清服务器侧缓存 + 弹提示"建议客户端清缓存以立即生效" |
| P3 | **导入/导出体验完善** | doge.12 已经能导入/导出 Mode JSON，doge.13 加"扫描二维码导入"或"URL 一键导入" |
| P3 | **Mode 模板市场**（可选） | 提供一些社区贡献的 Mode 模板（如 "AI 友好型" / "游戏加速型" / "学术研究型"），用户一键导入。需要 fork 仓库下建一个 `templates/modes/` 目录 |

### 9.2 验收标准

每条候选独立验收，做完一条就算一个 doge.13.x。具体验收清单在落地时分别细化，不在本文档堆。

---
