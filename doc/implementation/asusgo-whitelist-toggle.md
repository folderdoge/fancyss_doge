# 直连「梅林软件中心 / koolcenter 生态」开关实现说明

> **目标**：解决 AsusGo / 梅林软件中心 / 若快插件中心等内网工具在链式代理或低速代理下访问 koolcenter 系外部域名时 30 秒卡死的问题；同时清理上游 fancyss 硬编码白名单里失效或鸡肋的 4 个占位符域名。
>
> **版本**：v3.5.28-doge.9 引入。

---

## 1. 起源：AsusGo 卡顿调查

### 1.1 现象

用户开启链式代理（`狗_日本4_Aws1 → 狗_日本2_BBGL → 目标`）后，访问 192.168.50.1 路由器 WebUI 中的 AsusGo 面板，页面长时间卡住不显示内容。

### 1.2 抓包定位

浏览器 F12 Network 抓到两个红色 30 秒超时请求：

| URL | 状态 | 耗时 |
|---|---|---|
| `https://rogsoft.ddnsto.com/koolcenter/app.json.js?...` | `net::ERR_TIMED_OUT` | 30.02 s |
| `https://merlin.koolcenter.com/api/software/announcement?...` | `net::ERR_TIMED_OUT` | 30.01 s |

两个域名同时解析到 **`119.188.240.179`**（山东联通 IP，国内）。但流量经过 PREROUTING → SHADOWSOCKS → 主模式链 → REDIRECT 到 ss-redir → 经链式代理 `日本前置 → 日本落地` 出去，因前置节点延迟和稳定性问题，30 秒未完成 → 浏览器超时。

### 1.3 临时验证

用户进 WebUI → 黑白名单 → 域名白名单文本框加入 `rogsoft.ddnsto.com` / `merlin.koolcenter.com`，保存&应用，AsusGo 立刻正常加载。

确认根因是这些域名经过代理超时；强制直连即可解决。

---

## 2. 进一步发现：上游硬编码 4 个白名单**几乎全是占位符**

[ssconfig.sh:3310](../../fancyss/ss/ssconfig.sh#L3310) 上游硬编码：

```bash
for wan_white_domain2 in "apple.com" "microsoft.com" "dns.msftncsi.com" "worldtimeapi.org"; do
    echo "${wan_white_domain2}" >>/tmp/white_list.txt
done
```

### 2.1 实地验证每个域名的实际效果

#### `apple.com` —— **完全失效**

- 主验证：用户在 GLO 全局模式访问 `https://www.apple.com`，看到日文版（出口节点在日本）
- 数据：`nslookup www.apple.com 127.0.0.1` 返回 `218.58.101.229`（中国联通山东）
- 关键：`ipset test white_list 218.58.101.229` → **NOT in set**；`ipset test chnlist 218.58.101.229` → **IS in set**
- 解释：apple.com 在 `chnlist.gz` 里。chinadns-ng 处理顺序是 **chnlist tag → gfwlist tag → groups**，chnlist 抢在 `group white` 之前生效，IP 写进 chnlist ipset 而非 white_list ipset。GLO 模式下 [`SHADOWSOCKS_GLO`](../../fancyss/ss/ssconfig.sh#L6253-L6259) 只检查 white_list 做 RETURN，剩下全部 REDIRECT → apple.com 全程走代理

#### `microsoft.com` —— **半失效**（不可预测）

- 验证：`zcat .../chnlist.gz | grep '\.microsoft\.com$'` 命中大量子域：
  ```
  azuremigrate.download.prss.microsoft.com
  azurestackhub.download.prss.microsoft.com
  devblogs.microsoft.com
  developer.microsoft.com
  dl.delivery.mp.microsoft.com
  ...
  ```
- 解释：这些具体子域被 chnlist 抢走，white_list 对它们失效。但 `microsoft.com` 本身和某些子域（如 `www.microsoft.com`）不在 chnlist → group white 命中 → 进 white_list ipset → 直连。结果是"看运气"——部分子域直连、部分走代理，对用户体验是混乱的不可预测行为

#### `dns.msftncsi.com` —— **覆盖错域**

- 设计意图：保护 Windows 的"无 internet 访问"NCSI 检测，避免在代理状态下 Windows 误报无网
- 实际机制：Windows NCSI 检测分两步——① 查 `dns.msftncsi.com` DNS（必须返回固定 IP `131.107.255.255`，所有 DNS 都这样，**不需保护**）；② HTTP GET `http://www.msftncsi.com/ncsi.txt`（验证返回正文 `Microsoft NCSI`，**这才是关键步骤**）
- `group-dnl` 后缀匹配特性：`dns.msftncsi.com` 只能匹配 `dns.msftncsi.com` 自己和其子域，**不会**匹配 `www.msftncsi.com`（后者不是 `dns.msftncsi.com` 的子域）
- 结论：上游写错了子域，本规则**对真正需要保护的 HTTP 步骤完全覆盖不到**，DNS 步骤又不需要保护 → 净效果为零

#### `worldtimeapi.org` —— **代码有引用但失败可优雅 fallback**

> **勘误（doge.11，2026-05-15）**：本节早期版本（doge.9）错误地写"`grep -r worldtimeapi.org fancyss/` → fancyss 代码无任何引用 / NTP 时间检测用的是 `time.nist.gov / time.windows.com / time.apple.com`"。**这是错的**——worldtimeapi.org 实际在 [ssconfig.sh:264](../../fancyss/ss/ssconfig.sh#L264) 被用作时间+IP 同源检测的首选；`time.windows.com / time.apple.com` 完全不存在于 fancyss 代码；`nist.time.gov` 只在最末尾 fallback 节点（line 316）被用作纯时间源。下方为修订内容。
>
> 删 `worldtimeapi.org` 出 white_list 占位符的决策**仍然成立**（理由见下），但**理由不再是"代码无引用"**。

- **实际代码引用**：[ssconfig.sh:264](../../fancyss/ss/ssconfig.sh#L264) 在路由器启动期通过 `curl-fancyss` 拉取 `http://worldtimeapi.org/api/timezone/Asia/Shanghai`，同时获取 `unixtime`（时间检测）和 `client_ip`（公网出口 IP 检测）
- **失败 fallback 设计**：worldtimeapi 拉取失败时，fancyss 自动 fallback 到 [ssconfig.sh:285-319](../../fancyss/ss/ssconfig.sh#L285) 的时间源链 `www.weibo.com → www.baidu.com → www.qq.com → www.taobao.com → www.jd.com → https://nist.time.gov/`（这些只查时间不上送 IP）；IP 检测则 fallback 到 [ssconfig.sh:554-576](../../fancyss/ss/ssconfig.sh#L554) 的 `ip.ddnsto.com → ip.clang.cn → whatismyip.akamai.com → api.myip.com`
- **anycast 直连未必快**：worldtimeapi.org 本身是 Cloudflare anycast，国内 ISP 路由经常劣化；走代理（日本节点）反而可能更稳
- **结论**：保留 `worldtimeapi.org` 到 white_list 占位符没有强收益（fancyss 已设计 fallback 容错；anycast 直连不见得快）。**删除不影响功能**——失败后下一个时间源会接管。
- **doge.11 后续动作**：doge.11 引入 `ss_basic_online_ipcheck` 开关（dbus key，默认 1）让用户**彻底关闭** worldtimeapi + ddnsto/clang/akamai/myip 这一整组"启动期上送公网 IP" 的探测，不需要靠 white_list 拼凑控制。对应 hint id 204；细节参见 [ssconfig.sh:264](../../fancyss/ss/ssconfig.sh#L264) 与 [ssconfig.sh:554-576](../../fancyss/ss/ssconfig.sh#L554)。

### 2.2 总结表

| 上游硬编码 | 实际状态 | 是否保留 |
|---|---|---|
| `apple.com` | chnlist 抢走，GLO 模式完全失效 | ❌ 删 |
| `microsoft.com` | 半失效，行为不可预测 | ❌ 删 |
| `dns.msftncsi.com` | 覆盖错域，净效果为零 | ❌ 删 |
| `worldtimeapi.org` | 代码有引用但失败可优雅 fallback；anycast 直连未必快；doge.11 已加专属开关 | ❌ 删 |

---

## 3. 设计决策

### 3.1 为什么不"直接把硬编码列表换掉"

最朴素方案：直接把 4 个原始域名换成 koolcenter 家族 4 个，一行改完。但这有两个问题：

1. **fork 强加白名单**——用户没选择权，海外用户 / 不用梅林软件中心的用户被无声地加入 fancyss 不曾告知的硬编码列表
2. **不符合 fancyss 风格**——fancyss 几乎所有功能行为都有 WebUI 开关（DNS 劫持、IPv6 代理、UDP 代理、QUIC 阻断、链式代理…），凭空多一个隐性硬编码不一致

### 3.2 改用 UI toggle

WebUI 黑白名单标签页顶部加一行 `<select>`：「直连「梅林软件中心」生态域名」（开启/禁用，默认开启）。

- 默认开启 = 解决 AsusGo 卡顿的开箱即用体验
- 用户禁用 = 4 个域名按主模式走（仍可通过下方文本框手动加白名单实现等价效果）
- UI 上明明白白展示 fork 做了什么，文档/hint 解释为什么

### 3.3 dbus key 命名：`ss_basic_direct_asusgo`

- 前缀 `ss_basic_*` 符合 fancyss "操作型 toggle" 约定（与 `ss_basic_dns_serverx` / `ss_basic_internet6_flag` 等并列），不是 `ssconf_basic_*`（后者用于节点配置）
- 满足 CLAUDE.md 硬规则 #1（`ss` 开头，前端 `db_ss` 可读）
- 默认值 `1`（开启），install.sh 在 `install_now` 流程里 idempotent 写入

### 3.4 hint id：202

接续 [ss-menu.js](../../fancyss/res/ss-menu.js) 已用号段（链式代理 200，故障转移 201）。

### 3.5 替换域名清单

| 域名 | 来源 | chnlist 检查 | gfwlist 检查 | white_list 有效？ |
|---|---|---|---|---|
| `koolcenter.com` | 梅林软件中心主域 | 不在 | 不在 | ✅ |
| `ddnsto.com` | 花生壳 DDNS / Rogsoft 分发 | 不在 | 不在 | ✅ |
| `koolddns.com` | 同 ddnsto 备用 | 不在 | 不在 | ✅ |
| `ngrok.wang` | 国内 ngrok 镜像，部分插件用 | 不在 | 不在 | ✅ |

验证命令（v3.5.28-doge.9 实地跑过）：

```sh
zcat /koolshare/ss/rules/gfwlist.gz | grep -E 'koolcenter|ddnsto|koolddns|ngrok\.wang' | head
# 输出空 → 都不在 gfwlist
zcat /koolshare/ss/rules/chnlist.gz | grep -E 'koolcenter|ddnsto|koolddns|ngrok\.wang' | head
# 输出空 → 都不在 chnlist
# → group white 优先级最低但因为前两者都没匹配，本规则真正生效
```

### 3.6 Steam 系刻意不加

上游 [rules_ng/white_list.txt](../../rules_ng/white_list.txt) 写了 `cm.steampowered.com / steamserver.net / steamcontent.com`，但 [ssconfig.sh:3297](../../fancyss/ss/ssconfig.sh#L3297) 在运行时把整个文件清空重建（参见硬规则 #12）→ 这 3 个 steam 域名**运行时根本不被加载**。

判断：这是上游的留权决策。Steam 用户偏好分裂：
- 下载用户想 `steamcontent.com` 直连（国内 CDN 起飞）
- 切区购物用户想 `steampowered.com` 走代理
- 国际服匹配用户想 `cm.steampowered.com / steamserver.net` 走代理

fork 保持同样的克制——不入硬编码列表。需要的用户自行 WebUI 加 `steamcontent.com` 到白名单文本框即可。

---

## 4. 文件清单

### 4.1 修改

#### [fancyss/ss/ssconfig.sh:3310](../../fancyss/ss/ssconfig.sh#L3310)

替换原 4 域名硬编码 for 循环为：

```bash
if [ "${ss_basic_direct_asusgo:-1}" = "1" ]; then
    for wan_white_domain2 in "koolcenter.com" "ddnsto.com" "koolddns.com" "ngrok.wang"; do
        echo "${wan_white_domain2}" >>/tmp/white_list.txt
    done
fi
```

`:-1` 默认值保护：即使 dbus 键意外丢失，运行时仍按"开启"行为执行（安全侧）。

#### [fancyss/install.sh](../../fancyss/install.sh)（`install_now` 末尾）

```bash
[ -z "$(dbus get ss_basic_direct_asusgo)" ] && dbus set ss_basic_direct_asusgo=1
```

幂等。老用户升级到 doge.9 时若 dbus 没有该键，默认置 1（保持"开箱即用"语义）。

#### [fancyss/res/ss-menu.js](../../fancyss/res/ss-menu.js)（`openssHint()`）

新增 `else if (itemNum == 202)` 分支，包含完整的悬浮 hint 文案（4 个域名清单、用途、何时关闭、技术细节链接）。

#### [fancyss/webs/Module_shadowsocks.asp](../../fancyss/webs/Module_shadowsocks.asp)（`#table_wblist` forms 数组首行）

新增：

```javascript
{ title: '直连「梅林软件中心」生态域名<br><br><font color="#ffcc00">koolcenter / ddnsto / koolddns / ngrok.wang 等强制不走代理</font>', 
  id:'ss_basic_direct_asusgo', type:'select', hint:'202', style:'width:auto', 
  options:[["0", "禁用"], ["1", "开启"]], value:'1'},
```

注：本文件 UTF-8 BOM + CRLF + tab 缩进（CLAUDE.md 硬规则 #2），多行带 tab 替换用 PowerShell `[System.IO.File]::WriteAllText` 完成。

#### [fancyss/ss/version](../../fancyss/ss/version)

`3.5.28-doge.8` → `3.5.28-doge.9`

#### [CLAUDE.md](../../CLAUDE.md)

新增硬规则 #11（chinadns-ng tag 优先级 chnlist > gfwlist > group white）和 #12（仓库自带 `white_list.txt` 运行时不加载）。hint id 号段加上 `202`。

### 4.2 新增

- **[doc/implementation/asusgo-whitelist-toggle.md](.)** —— 本文档

### 4.3 不修改

- `fancyss/ss/rules/white_list.txt` —— 保持现状（包含 steam 等域名，但运行时不读）
- `rules_ng/white_list.txt` —— 同上，构建期拷贝源，运行时无效
- chinadns-ng / smartdns 配置生成逻辑 —— 不调整 tag 优先级（动 chinadns-ng 内部行为风险大，文档化限制即可）

---

## 5. 用户行为变化

### 5.1 新装用户

进 WebUI → 黑白名单标签页 → 顶部看到「直连「梅林软件中心」生态域名」select，默认「开启」。AsusGo 等内网工具开箱即用。

### 5.2 老用户从 doge.8 升级到 doge.9

`install.sh::install_now` 检测到 dbus `ss_basic_direct_asusgo` 不存在 → 自动置 1 → 行为与新装一致。

如果用户**不希望**这 4 个域名被强制直连，进 WebUI 切换为「禁用」保存即可。

### 5.3 用户禁用后

- 4 个 koolcenter 系域名按主模式（GFW/智能/全局/回国等）走
- 仍可通过下方「域名白名单」文本框手动添加（fancyss 现有机制）
- 状态由 dbus `ss_basic_direct_asusgo=0` 持久化

---

## 6. 同步上游时的注意事项

如果将来从 hq450/fancyss 拉新版本，并且发现 [ssconfig.sh:3310](../../fancyss/ss/ssconfig.sh#L3310) 区域上游做了改动（例如加了新域名或换了实现），需要：

1. 评估上游新增域名是否符合"应当强制直连"的标准
2. 用本文档 §3.5 的双查命令验证它们不在 chnlist/gfwlist
3. 决定是合入到 fork 的 if 块内，还是另起一个新 toggle
4. 不要复活 apple.com / microsoft.com / dns.msftncsi.com / worldtimeapi.org —— 它们的失效原因记录在本文档，未来如果上游"修复"了 chinadns-ng 优先级（极不可能）可再评估

---

## 7. 相关文档

- [chain-proxy-implementation.md](chain-proxy-implementation.md) —— 链式代理实现（AsusGo 卡顿暴露问题的入口）
- [CLAUDE.md](../../CLAUDE.md) —— 硬规则 #1（dbus key 前缀）、#2（asp 文件格式）、#3（hint id）、#11（chinadns-ng tag 优先级）、#12（`white_list.txt` 运行时不加载）
