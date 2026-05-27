# 链式代理（前置节点）实现说明

> **目标**：在账号设置面板新增"前置节点"选项，把"节点选择"改名为"落地节点"。
> 当前置节点非空时，xray 走链式代理：`router → 前置节点 → 落地节点 → 目标`。

本文档汇总实现的全部改动、设计决策、注意事项与未来扩展路径。

> **最近修订（2026-05-02）**：
> - 加链式代理状态行（插件运行状态面板内显示「直连中 / 链式代理已开启 / 回落至直连」+ 路径）
> - 「前置节点」字段名改为蓝色可悬浮 hint（hint id `200`，定义在 `ss-menu.js`）
> - 移除 fancyss 自带的 ssLinks/Nexitally 等机场广告位（包括订阅空状态、首页 gist 拉取的滚动广告）
> - README + 插件介绍栏加「小狗 fork 版」标识，更新检测/更新日志 URL 指向 `folderdoge/fancyss_doge`
> - **关键陷阱已修复**：状态 dbus 键名前缀必须用 `ss_chain_*` 而非 `fss_chain_*`，详见 §10.2
>
> **后续修订（2026-05-11，v3.5.28-doge.9）**：
> - 修复链式代理开启时 AsusGo / 梅林软件中心系工具（rogsoft.ddnsto.com / merlin.koolcenter.com 等）30 秒超时卡死
> - 顺带清理上游 fancyss 长期硬编码但实际失效的 4 个白名单占位符（apple.com / microsoft.com / dns.msftncsi.com / worldtimeapi.org），引入「直连「梅林软件中心」生态域名」UI 开关（hint id `202`，dbus `ss_basic_direct_asusgo`，默认开启）
> - 调查发现 chinadns-ng tag 优先级为 `chnlist > gfwlist > group white`，详见 [asusgo-whitelist-toggle.md](asusgo-whitelist-toggle.md) §2.1（apple.com 失效根因）
> - 另一个长期被忽视的设计 bug：仓库自带的 `fancyss/ss/rules/white_list.txt` 在运行时被 [`ssconfig.sh:3297`](../../fancyss/ss/ssconfig.sh#L3297) 直接清空重建，**文件内容形同虚设**——见 CLAUDE.md 硬规则 #12

---

## 1. 范围与设计决策

### 1.1 协议支持矩阵

链式代理仅在 **落地与前置节点都属于 xray 内置 outbound 支持的协议**时启用：

| 协议 | type | 作前置 | 作落地 | 备注 |
|---|---|---|---|---|
| Shadowsocks | 0 | ✅ | ✅ | 仅在 `ss_obfs="0"` 时（不含 obfs-local 子进程） |
| SSR | 1 | ❌ | ❌ | 由 rss-redir 独立进程运行，不是 xray outbound |
| VMess (v2ray) | 3 | ✅ | ✅ | 仅 `v2ray_use_json="0"` |
| VLess / Vmess (xray) | 4 | ✅ | ✅ | 仅 `xray_use_json="0"` |
| Trojan | 5 | ✅ | ✅ | 不支持 `trojan_plugin="obfs-local"` 的 ws 伪装分支 |
| Naïve | 6 | ❌ | ❌ | 独立进程 |
| Tuic | 7 | ❌ | ❌ | 独立进程 |
| Hysteria2 | 8 | ✅ | ✅ | **xray 原生 outbound**（doge.10 加入），和 Trojan 共用 xray.json |

### 1.2 传输 & 安全层

**仅支持** `network ∈ {tcp, ws, grpc}`，`security ∈ {none, tls}`。
不支持：kcp / quic / h2 / xhttp / httpupgrade / reality。

> **为什么砍这么多？** 实现 outbound JSON 时要复制所有 transport 字段；首版只覆盖 90% 实际场景。需要扩展时按 §6.2 加 transport 即可。

### 1.3 不支持的运行模式

- **xray 分流模式（`ss_basic_mode=7`）** —— 由 `fss_shunt_build_xray_config` 接管，路径完全不同；本版本 `fss_chain_apply` 直接 no-op 并日志记录。

### 1.4 技术原理

xray 原生支持 `streamSettings.sockopt.dialerProxy`：当 outbound A 的 `dialerProxy` 指向 outbound B 的 `tag` 时，A 通过 B 拨号。

实现策略：
- 落地节点保持原 outbound（tag 默认 `"proxy"`，trojan 没有 tag 但是 `outbounds[0]`）。
- 前置节点构造一个新 outbound（tag `"proxy_front"`），追加到 `outbounds` 末尾。
- 在落地 outbound 的 `streamSettings.sockopt` 注入 `dialerProxy: "proxy_front"`。

**最终配置示意**：
```json
{
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vmess",
      "settings": {...},
      "streamSettings": {
        "network": "tcp",
        "sockopt": { "tcpFastOpen": false, "dialerProxy": "proxy_front" }
      }
    },
    {
      "tag": "proxy_front",
      "protocol": "shadowsocks",
      "settings": {...},
      "streamSettings": {...}
    }
  ]
}
```

---

## 2. 文件清单

### 2.1 新增

- **`fancyss/scripts/ss_chain_proxy.sh`**（约 460 行）
  链式代理的全部逻辑 + 状态写入函数，独立成一个文件便于调试与单独覆盖。

### 2.2 修改

- **`fancyss/ss/ssconfig.sh`** — 3 处插入：
  1. 顶部：`source ss_chain_proxy.sh`
  2. `start_xray()` 内：在 `run_bg ... xray run` 前调用 `fss_chain_apply`
  3. `start_trojan()` 内：同上，针对 trojan 配置文件

- **`fancyss/webs/Module_shadowsocks.asp`** — 多处改动：
  1. 表单定义：`节点选择` → `落地节点`，新增 `前置节点` select（用 `hint:'200'` 而非 suffix 文本，标题变蓝可悬浮）
  2. `refresh_options()` 末尾追加前置节点选项填充逻辑 + 调用 `render_chain_status()`
  3. 在 `function save() {` 之前插入空 `function ss_node_front_sel()` 占位
  4. `save()` 函数主体：持久化 `ssconf_basic_node_front` 到 dbus，校验前置≠落地
  5. **新增** `render_chain_status()` JS 函数（紧跟 `ss_node_front_sel`），按 `db_ss["ss_chain_status"]` 渲染插件运行状态面板里那一行
  6. **新增** `<tr id="ss_state">` 内 `ss_state_chain` / `ss_state_chain_path` / `ss_state_chain_path_break` 三个 span/br
  7. 介绍信息顶部 `<ul id="fixed_msg">` 加 `<li id="msg_doge">` fork 标识
  8. `version_show()` 的 `version.json.js` URL → 自己 fork
  9. 「更新日志」按钮 URL → 自己 fork
  10. 移除 `render_subscription_profiles_cards()` 空状态里的 ssLinks 广告
  11. `message_show()` 整体精简成只触发「无节点引导弹窗」，删掉 hq450 gist 拉取的广告/通知

- **`fancyss/res/ss-menu.js`** — 1 处插入：
  - 在 `openssHint()` 链尾新增 `itemNum == 200` 分支，文案「前置节点 (链式代理)」+ 协议范围/限制/失败处理说明

- **`README.md`** — 顶部加 fork 段落 + vibe coding `<sub>`，删除 3 行机场广告位

### 2.3 不动的文件

- 安装脚本 `install.sh`：不需要改（`cp -rf scripts/* /koolshare/scripts/` 自动覆盖新文件）
- 卸载脚本 `uninstall.sh`：会自动清理 `/koolshare/scripts/ss_*`
- DBus schema：使用普通 dbus key `ssconf_basic_node_front`，schema v1/v2 都兼容
- 路由/iptables 规则：完全不动（详见 §4）

---

## 3. ss_chain_proxy.sh 内部结构

```
fss_chain_log               日志格式（带时间戳 + [chain-proxy] 前缀）
fss_chain_set_status        写运行时状态到 dbus（ss_chain_status / ss_chain_path）
fss_chain_get_front_id      读 dbus key ssconf_basic_node_front
fss_chain_type_supported    校验某节点 type 是否支持作链式两端
fss_chain_jq_string         JSON 字符串转义辅助
fss_chain_bool_json         "1" → true / 其他 → false
fss_chain_build_stream_settings   构造 streamSettings 片段（jq 拼接）
fss_chain_build_front_outbound_json   构造完整前置 outbound JSON
fss_chain_apply             【主入口】对 xray.json 应用链式代理 + 写状态
```

`fss_chain_apply` 内每条 return 路径都通过 `fss_chain_set_status` 写状态：
- 入口先无条件 `disabled`，前置 ID 空则直接保留
- 凡是配置了前置但因约束不满足而跳过 → `fallback`
- jq 注入失败 / xray test 失败 → `fallback`
- 全部成功（含 xray test 通过）→ `enabled` + `<前置名> → <落地名> → 目标`

**`fss_chain_apply <xray.json>` 控制流**：
1. 读 `ssconf_basic_node_front`，空 → 返回 0（无操作）
2. 读 `ss_basic_mode`，等于 `7` → 跳过（分流模式）
3. 读当前节点 ID，若与前置相同 → 跳过（防御）
4. 校验落地 type 在 `{0,3,4,5}` 且通过约束检查
5. 校验前置 type 在 `{0,3,4,5}` 且通过约束检查
6. 调用 `fss_chain_build_front_outbound_json` 构造前置 outbound（jq 拼接）
7. 用 jq 把前置 outbound 注入 xray.json，加 `dialerProxy`
8. `xray run -test` 自检；失败 → 自动回滚到无链式版本

**任何错误路径都返回 0**（除非 jq 注入本身失败）。设计原则：**链式代理的失败不应导致代理整体不工作**。

---

## 4. 路由 / iptables 兼容性分析

### 4.1 担忧 vs 实际

最初担心：xray 自身发起的链路（`router → 前置节点`）会不会被 iptables redirect 重新捕获，导致死循环？

**结论：fancyss 标准设置下不会触发。**

### 4.2 fancyss iptables 拓扑

链 `SHADOWSOCKS / SHADOWSOCKS_GFW / SHADOWSOCKS_GLO / SHADOWSOCKS_CHN` 都只挂在 PREROUTING：

```
iptables -t nat -I PREROUTING -p tcp -j SHADOWSOCKS    # 只匹配 LAN→router 转发流量
```

OUTPUT 链（路由器自身发起的流量）只有两条很窄的规则：

```
nat -A OUTPUT -p tcp -m set --match-set router dst -j REDIRECT --to-ports 3333  # 仅 router ipset
nat -A OUTPUT -p tcp -m mark --mark "$ip_prefix_hex" -j SHADOWSOCKS_EXT          # 仅特定 mark
```

**xray 进程自己发起的 TCP 连接**：
- 不走 PREROUTING（那是从 br0/eth1 等接口进来的）
- OUTPUT 也命不中上述两条规则（除非用户主动把节点 IP 加到 `router` ipset）

所以前置节点的 IP **不需要**额外加入任何 bypass 列表。这一点也解释了为什么单节点模式下 fancyss 从来不需要把 `ss_basic_server` 的 IP 加进 ipset—— `get_proxy_server_ip()` 里的 `ss_real_server_ip` 只用于"国内/国外"日志判断，不写入任何 bypass。

### 4.3 反向验证

如果 fancyss 真需要 IP-level bypass，单节点模式现在就该跑不通——但显然能跑。所以链式代理也不需要。

---

## 5. 部署 / 升级方法

### 5.1 完整安装包（推荐）

走 fancyss 官方的软件中心离线安装。本仓库有 [build_min.sh](../../build_min.sh)（精简驱动）：

```bash
# 在 WSL Ubuntu 24.04 内
bash build_min.sh
# 产出：packages/fancyss_<plat>_full.tar.gz
```

`build_min.sh` 跳过的步骤（与完整 `build.sh` 的差异）：
1. **`prepare_geodata_assets`** —— 需要 git/go/网络，复用仓库内已有的 `rules_ng2/dat/{geosite,geoip}.dat`
2. **`sync_binary` + `verify_zig_tool_binaries`** —— 需要 zig/go 工具链编译 8 个 zig-tool，复用 `fancyss/bin-<plat>/` 已预置的 24 个二进制
3. **`do_backup`** —— 需要外部 `../fancyss_history_package/` 目录归档，stub 掉

要构建其他平台，在 `build_min.sh` 末尾加 `pack <plat> <pkgtype> release` 即可。可选平台：`hnd / hnd_v8 / qca / arm / mtk / ipq32 / ipq64`，pkgtype：`full / lite`。

**安装方式**：
- A. Web UI → 软件中心 → 离线安装 → 选 tar.gz
- B. SCP 到路由器 `/tmp/`，`tar xzf ... && cd shadowsocks && sh install.sh`

### 5.2 热补丁（surgical sed，不重启）

如果只想在已运行的版本上叠加 chain proxy，不动其他文件：

```bash
# 路由器侧手动备份
cp /koolshare/ss/ssconfig.sh /koolshare/ss/ssconfig.sh.before_chain
cp /koolshare/webs/Module_shadowsocks.asp /koolshare/webs/Module_shadowsocks.asp.before_chain

# 上传 3 个文件覆盖到对应位置：
#   scripts/ss_chain_proxy.sh -> /koolshare/scripts/ss_chain_proxy.sh （新建）
#   ss/ssconfig.sh            -> /koolshare/ss/ssconfig.sh
#   webs/Module_shadowsocks.asp -> /koolshare/webs/Module_shadowsocks.asp
```

**注意**：直接覆盖 `ssconfig.sh` 不会自动重启 xray，要等 Web UI 点保存才生效。这是好事——不会让你测试时断网。

回滚：把三个文件 cp 回 `.before_chain` 备份即可。

---

## 6. 测试 / 验证清单

### 6.1 安装后立即检查

```bash
# 文件就位
ls -la /koolshare/scripts/ss_chain_proxy.sh
grep -n 'fss_chain_apply\|ss_chain_proxy.sh' /koolshare/ss/ssconfig.sh   # 应有 3 行
grep -c 'ssconf_basic_node_front' /koolshare/webs/Module_shadowsocks.asp # 应 ≥ 5

# Web UI（强制刷新 Ctrl+F5 拿新 asp）
# 账号设置应看到「落地节点」+「前置节点」
```

### 6.2 链式行为验证

1. 把模式切到 GFWList / 全局 / ChnRoute（**不要用 xray 分流模式**，那个本版本不支持）
2. 落地节点选 SS/VMess/VLess/Trojan 中任一种
3. 前置节点选另一个同类型节点
4. 保存，等 xray 重启
5. 看日志 `tail -f /tmp/upload/ss_log.txt`，应有 `[chain-proxy] 启用链式代理：前置节点=X 落地节点=Y` 行
6. `cat /koolshare/ss/xray.json | jq '.outbounds | map({tag, protocol})'` 应看到两条 outbound
7. 手机/电脑访问外网，正常即生效

### 6.3 状态行 UI 验证（前端侧）

无 SSH 时也能用浏览器 console 直接读：

```javascript
(function(){
  ['ssconf_basic_node_front','ssconf_basic_node','ss_basic_mode',
   'ss_chain_status','ss_chain_path'].forEach(function(k){
    console.log(k + ' = ' + JSON.stringify(db_ss[k]));
  });
  console.log('chain text = ' + $("#ss_state_chain").text());
})();
```

期望（前置非空 + 全部约束满足时）：
- `ss_chain_status = "enabled"`
- `ss_chain_path = "<前置名> → <落地名> → 目标"`
- 状态面板显示「链式代理状态 - 链式代理已开启」+ 蓝色路径行

如果 `ss_chain_status` 是 `undefined`，**先看 §10.2**。

### 6.4 失败时的降级

- 链式 outbound JSON 构造失败 → 日志输出原因，使用原配置（无链式）继续
- xray 自检失败 → 自动从 xray.json 撤回 `dialerProxy` + 删除 `proxy_front` outbound，使用原配置继续

---

## 7. 已知限制 / 已显式跳过的场景

| 场景 | 行为 |
|---|---|
| 落地或前置节点的 type 不在 {0,3,4,5} | 跳过 + 日志说明 |
| 落地或前置使用了 `xxx_use_json=1` | 跳过 + 日志 |
| 落地或前置使用了 obfs-local（SS）/ trojan_plugin（Trojan） | 跳过 + 日志 |
| transport 是 kcp/quic/h2/xhttp/httpupgrade | 跳过 + 日志 |
| security 是 reality 或其他非 none/tls | 跳过 + 日志 |
| `ss_basic_mode=7`（xray 分流模式） | 跳过 + 日志 |
| 前置节点 ID == 落地节点 ID | 前端 alert 阻断 + 后端跳过 |

---

## 8. 未来扩展指引

### 8.1 增加协议支持

例如想支持 hysteria2 作落地：
- xray 不能直接 outbound hysteria2，需要本地起一个 hy2 client 监听 socks，再让 xray 通过这个 socks 拨。
- 改动点：`fss_chain_type_supported()` 加 `8 ➜ true`，`fss_chain_apply` 在 hy2 落地分支额外启动一个 hy2 子进程并构造 socks outbound，工作量较大。

### 8.2 增加 transport 支持

例如加 h2：
- `fss_chain_build_stream_settings` 里 `network` case 加 `h2`，emit `httpSettings`。
- 前端 `refresh_options` 不需要改，因为 transport 不影响节点是否能作前置（已经在 type 层面过滤）。
- 注意 xray 各 transport 的字段名：`grpcSettings`、`wsSettings`、`tcpSettings`、`kcpSettings`、`httpSettings` 等。

### 8.3 ~~支持 xray 分流模式~~（doge.14 已退役，本节失效）

> **doge.14 起本节不再适用**。`ss_basic_mode=7` xray 节点分流路径已在 doge.14 sprint Phase 1+2 中物理移除（`ss_node_shunt.sh` 整文件物理删除、`creat_shunt_json` 删除、14 处 `mode=7` case 清理、`migrate_split_routing_v3` 把 mode=7 老用户自动迁到 mode=2）。链式代理在 doge.13+ 分流架构下走 split path：`fss_chain_apply` 注入到 `out_main`（默认主节点 outbound），per-rule chain landing 走 `dialerProxy=chain_front_<Y>`（详见 [split-routing-implementation.md §6.2 D7 / D12](../implementation/split-routing-implementation.md)）。本节描述的 doge.6 时代 "xray 分流模式" 在新架构下已被 split routing 统一接管。

~~`ss_basic_mode=7` 走 `fss_shunt_build_xray_config`（在 `scripts/ss_node_shunt.sh`），本版本对它直接 no-op。要支持的话：~~
- ~~找到 shunt 模式的 outbound 列表生成位置~~
- ~~针对**每一条** shunt 规则匹配的 outbound（可能有多条），都注入对应的 `dialerProxy`~~
- ~~要想清楚：所有 shunt outbound 都共享同一个前置节点？还是每条规则可以独立配前置？UI 也要相应改~~

### 8.4 支持把前置节点 IP 加到 ipset

参考 §4 的分析：当前不需要。但如果未来 fancyss 改了 iptables 拓扑（比如 OUTPUT 链加了通配 REDIRECT），需要在 `fss_chain_apply` 里加：
- 解析前置节点的 `server` 字段
- 解析为 IP（可能是域名，需 DNS）
- `ipset add ignlist <ip>` 或类似的 bypass set

### 8.5 节点切换时清理旧的 chain 配置

目前每次启动 xray 都重新 apply chain（不会累加，因为 jq 是替换式注入）。但如果用户从「链式」切到「无链式」，xray.json 里上次的 chain outbound **不会自动清除**——下次 ssconfig.sh 完整重新生成 xray.json 时才会刷掉。这通常没问题，但如果未来引入热重载，要注意手动 clean。

---

## 9. 关键代码片段速查

### 9.1 dbus key

| key | 类型 | 写入方 | 取值 |
|---|---|---|---|
| `ssconf_basic_node_front` | string | 前端 save() | 节点 ID（数字字符串），空表示禁用 |
| `ss_chain_status` | enum | `fss_chain_set_status` | `disabled` / `enabled` / `fallback` |
| `ss_chain_path` | string | `fss_chain_set_status` | `<前置名> → <落地名> → 目标`（仅 enabled 时有值）|

> **前缀必须是 `ss_chain_*` 而不是 `fss_chain_*`**，原因见 §10.2。

### 9.2 ssconfig.sh 注入位置

```sh
# 顶部（约第 9 行后）
unset FSS_BASE_SKIP_SHUNT_SOURCE
[ -f /koolshare/scripts/ss_chain_proxy.sh ] && . /koolshare/scripts/ss_chain_proxy.sh

# start_xray() 内
type fss_chain_apply >/dev/null 2>&1 && fss_chain_apply /koolshare/ss/xray.json
run_bg /koolshare/bin/xray run -c /koolshare/ss/xray.json

# start_trojan() 内
type fss_chain_apply >/dev/null 2>&1 && fss_chain_apply "$TROJAN_CONFIG_FILE"
run_bg /koolshare/bin/xray run -c $TROJAN_CONFIG_FILE
```

### 9.3 asp 表单定义（第 ~15547 行）

```javascript
{ title: '落地节点', id:'ssconf_basic_node', type:'select',
  func:'onchange="ss_node_sel();"',
  style:'width:auto;min-width:164px;max-width:450px;', options:[], value: "1"},
{ title: '前置节点', id:'ssconf_basic_node_front', type:'select',
  func:'onchange="ss_node_front_sel();"',
  style:'width:auto;min-width:164px;max-width:450px;', options:[], value: "",
  suffix:'<span style="color:#888;font-size:12px;margin-left:6px;">非空启用链式代理（仅支持 SS/VMess/VLess/Trojan）</span>'},
```

### 9.4 测试用 jq filter（注入）

```jq
.outbounds[0].streamSettings = (.outbounds[0].streamSettings // {})
| .outbounds[0].streamSettings.sockopt = ((.outbounds[0].streamSettings.sockopt // {}) + {dialerProxy: $ftag})
| .outbounds += [$fb]
```

### 9.5 测试用 jq filter（回滚）

```jq
.outbounds = [ .outbounds[] | select(.tag != $ftag) ]
| if (.outbounds[0].streamSettings.sockopt.dialerProxy // "") == $ftag then
    del(.outbounds[0].streamSettings.sockopt.dialerProxy)
  else . end
```

---

## 10. 故障排查速查表 + 已踩过的坑

### 10.1 现象-排查表

| 现象 | 排查 |
|---|---|
| Web UI 看不到「前置节点」 | Ctrl+F5 强制刷新；`grep ssconf_basic_node_front /koolshare/webs/Module_shadowsocks.asp` 确认文件已更新 |
| 选了前置节点保存后不生效 | `tail /tmp/upload/ss_log.txt` 找 `[chain-proxy]` 行，看跳过原因 |
| 没有 `[chain-proxy]` 日志输出 | `grep fss_chain_apply /koolshare/ss/xray.json`；如果 xray.json 里没痕迹，说明 hook 没注入或 ssconfig.sh 没被重新执行 |
| xray 起不来 | `xray run -test -c /koolshare/ss/xray.json` 看具体报错；`fss_chain_apply` 应该会自动回滚，但如果没回滚成，把 `/koolshare/ss/xray.json.before_chain` 之类的备份还原（注意：ssconfig.sh 每次都会重写 xray.json，所以重新点保存即可恢复无链式） |
| 链式启用但访问不通 | 1) xray.json 里 `outbounds` 顺序对吗？2) `dialerProxy` 在落地 outbound 上吗？3) 前置 outbound 的 tag 是 `proxy_front` 吗？4) 单独测试前置节点能不能直连？|
| 状态行一直显示「直连中」但 chain-proxy 日志正常 | dbus 写到了但前端读不到 → 检查键名前缀是不是 `ss_chain_*`（不能是 `fss_chain_*` 等其它前缀），见 §10.2 |
| 状态行显示「直连」但实测网速是链式速度 | 前端 db_ss 快照滞后；v3.5.24-doge.4 已加 15s 轮询，等一会自然刷新；如还没刷新，强制 Ctrl+F5。见 §10.6 |
| 前置节点下拉框莫名"被清空" | 节点被删/订阅刷新后 ID 漂移 / 协议改了导致被链式约束过滤；v3.5.24-doge.4 后会显示「⚠️ 节点缺失或不兼容（ID X）」占位，且 save() 会保留原 dbus 值不覆盖。见 §10.5 |
| 重装包后 chain 没生效 | install.sh 装完会调 `ssconfig.sh restart`，但**只在 `ENABLE=1` 时**；如果跳过了，手动到帐号设置点一次「保存&应用」强制重启 |

### 10.2 关键陷阱：前端 dbus key 前缀必须是 `ss`

**症状**：`fss_chain_apply` 跑成功了，shell 里 `dbus get fss_chain_status` 也能拿到 `enabled`，但浏览器 `db_ss["fss_chain_status"]` 永远是 `undefined`。

**根因**：前端拉 dbus 数据走 `/_api/ss` 这个 koolshare httpd endpoint（[asp:6280, 6303](../../fancyss/webs/Module_shadowsocks.asp)），它的 prefix 匹配规则是字符串以 `ss` **开头**——能匹配 `ss_basic_*`、`ssconf_basic_*`、`ssr_*`，但**不会**匹配 `fss_*`（首字母是 `f`）。

**结论**：所有需要前端读取的运行时状态键，前缀都必须是 `ss_*` / `ssconf_*` / `ssr_*`。仅供后端使用的可以用 `fss_*`（如 `fss_node_order`、`fss_node_current`）。

**修复**：本 fork 把 chain 状态键从 `fss_chain_status` / `fss_chain_path` 改成 `ss_chain_status` / `ss_chain_path`。`uninstall.sh` 的 `purge_fancyss_dbus()` 同时清 `ss`/`ssconf`/`fss` 三个前缀，所以早期错误版本写进去的 `fss_chain_*` 孤立键会在卸载时自然清理，无需特殊处理。

### 10.3 hint id 命名空间

ss-menu.js 里的 `openssHint()` 是个长 if/else 链，目前已用号段：0, 1, 11, 24, 27, 31, 32, 34, 29, 35-41, 44, 47-49, 54-56, 104-118, 133-156, **200**（前置节点）。新加 hint 选 200+ 段即可避免冲突。

### 10.4 文件行尾 / 编码

`Module_shadowsocks.asp` 是 **UTF-8 with BOM、CRLF 行尾、tab 缩进**（实测字节验证：`[System.IO.File]::ReadAllBytes` 数 CR/LF 字节数应相等）。任何用 PowerShell `[System.IO.File]::WriteAllText()` 重写都会丢 BOM——必须显式：
```powershell
[System.IO.File]::WriteAllText($f, $newContent, (New-Object System.Text.UTF8Encoding $true))
```
行尾要用 `` `r`n ``（保持 CRLF），old/new 字符串里的 tab 要写 `` `t ``。建议改这文件优先走 Edit/sed，PowerShell 兜底。Edit 工具对带前导 tab 的多行替换经常匹配失败（前导 tab 在传输层会被吃掉），单行无前导空格的字符串 Edit 一般 OK。

### 10.5 关键陷阱：前端 select 控件不能静默 `val("")`（v3.5.24-doge.4 修复）

**症状**：用户配了前置节点，更新插件后发现前置"被清掉了"，但实测网速仍然是链式速度。

**根因**：[Module_shadowsocks.asp `refresh_options()`](../../fancyss/webs/Module_shadowsocks.asp) 旧版逻辑：
```js
var savedFront = db_ss["ssconf_basic_node_front"] || "";
if (savedFront && optionFront.find('option[value="' + savedFront + '"]').length) {
    optionFront.val(savedFront);
} else {
    optionFront.val("");   // ❌ 静默置空
}
```
当 `savedFront` 在选项列表里找不到（节点被删 / 协议被链式约束过滤掉 / 订阅刷新后 ID 漂移），**下拉框被静默置空**。然后用户点"保存&应用"，`save()` 读到空字符串写回 dbus → 真实数据丢失。

**修复方案**：`else` 分支不再 `val("")`，而是**插入一个标记 `data-stale="1"` 的占位 option**保留 ID：
```js
} else if (savedFront) {
    optionFront.append($('<option>', {
        value: savedFront,
        text: '⚠️ 节点缺失或不兼容（ID ' + savedFront + '）',
        'data-stale': '1'
    }));
    optionFront.val(savedFront);
} else {
    optionFront.val("");
}
```
配套修改 `save()`：检测当前选中的 option 若有 `data-stale="1"`，**完全跳过** `dbus["ssconf_basic_node_front"]` 覆盖，让 dbus 保持原值。这样用户没主动改的话不会误清。

**通用启示（写新代码要避免）**：任何"读 dbus 值 → 反向定位 select option → 如果找不到就 val('')"的模式都有这种丢数据风险。**新加 select 时**，遇到 saved value 找不到选项时要么插占位 option 保留原值，要么在 save() 那边做"没显式选过就不写 dbus"判断。这条规则也写进了项目根 CLAUDE.md。

### 10.6 关键陷阱：`ss_chain_status` 显示会滞后于实际 xray 状态

**症状**：UI 状态行显示"直连代理已开启"，但实测网速跟链式代理时一样。

**根因**：前端 `db_ss` 是页面打开时一次性 `/_api/ss` 拉的快照，之后不会自动刷新。`render_chain_status()` 读的是 `db_ss[]`。`ssconfig.sh restart` 后 `fss_chain_apply` 写新的 `ss_chain_status` / `ss_chain_path` 到 dbus，但前端不知道，UI 一直显示打开瞬间的旧值。**实际 xray 跑链式 vs UI 显示直连**就这么对不上。

**修复方案**：v3.5.24-doge.4 加了一个 15 秒一次的轮询 `refresh_chain_status_only()`，只拉 `ss_chain_status` / `ss_chain_path` / `ss_basic_enable` 三个 key 重渲染状态行。`start_chain_status_polling()` 在 `refresh_options()` 末尾调一次，幂等（用 `_chainStatusPollTimer` 变量挡）。

**通用启示**：所有由 ssconfig.sh / 后端脚本运行时写的"运行状态" dbus key（`ss_chain_status` / 类似的将来要加的 key），都不能假设前端 db_ss 是新鲜的。要么走轮询、要么 hook 到现有的 `refresh_dbss(cb)` 全量刷新里。

### 10.7 落地/前置节点配置可折叠区块（v3.5.24-doge.4 实现）

**做法**：把 `<table id="table_basic">` 的内容拆成 3 个 `<tbody>`：
- `tb_main` — 落地节点 / 前置节点 / 模式（始终显示）
- `tb_landing_section` — 折叠表头 + 现有所有协议字段
- `tb_front_section` — 折叠表头 + 动态渲染的前置节点只读信息

`forms()` 调用拆成两次：`$('#tb_main').forms([头 3 项])` 和 `$('#tb_landing_section').forms([协议字段])`。前置区块由 `render_front_props()` 按 `confs[frontId]` 的协议（type 0/3/4/5）动态生成只读行（密码/UUID 自动 `props_mask` 脱敏）。

**关键 CSS**：
```css
.props-section.is-collapsed > tr:not(.props-section-head) { display: none; }
```
折叠态隐藏整个 tbody 内的非头部行；`applyVisibility` 用 `querySelectorAll("[data-show]...")` 还能正常工作（多套一层 tbody 不影响后代查找）。展开后 `verifyFields` / `applyVisibility` 自然接管，协议联动逻辑零改动。

**完整性检查**：拆 `forms()` 数组时，用 `[regex]::Matches($content, '(?m)^\s*\{ title:').Count` 数总条目数，改前改后必须相等（当前是 260 条）。这是改大块 forms 数组时最快的回归验证。

---

## 11. 构建产物

| 平台 | 包名 | 适用机型 |
|---|---|---|
| hnd_v8 | `fancyss_hnd_v8_full.tar.gz` | aarch64 Broadcom（RT-AX86U 等）|
| hnd | `fancyss_hnd_full.tar.gz` | armv7hf Broadcom（部分 AX3000、RT-AC 系列）|

其他平台没构建，需要时按 §5.1 加 `pack <plat> full release`。

---

## 12. 附录：相关文件路径

| 路径 | 用途 |
|---|---|
| `fancyss/scripts/ss_chain_proxy.sh` | **新增** 链式代理逻辑 |
| `fancyss/ss/ssconfig.sh` | 修改：3 处 hook |
| `fancyss/webs/Module_shadowsocks.asp` | 修改：4 处 |
| `build_min.sh` | 精简构建驱动 |
| `packages/fancyss_*_full.tar.gz` | 离线安装包产物 |
| `packages/router_3520/` | 升级前路由器原版文件备份（参考） |
| `packages/router_3520_patched/` | 路径上 surgical sed 后的局部补丁产物 |
| `doc/implementation/chain-proxy-implementation.md` | 本文档 |
