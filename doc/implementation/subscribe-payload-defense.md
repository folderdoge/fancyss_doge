# 订阅 payload 解码前防御 — 三道闸门

## 0. 背景与适用范围

`fancyss/scripts/ss_node_subscribe.sh` 在收到机场返回的订阅内容后，要喂给 `base64 -d` 解码。机场偶尔会返回**非订阅内容**（错误页 / 登录提示 / 反爬虫页 / 二进制垃圾 / token 过期等）。如果直接灌进 busybox `base64 -d`，会触发两类灾难：

1. **ARG_MAX**：旧逻辑 `dec64 $(cat $file)` 把整个文件作为 argv 喂进 base64，1-2MB 就能 OOM 失败或卡死。
2. **死循环**：busybox 1.25.1 在 ARMv7 上，对**带高位字节（UTF-8 多字节）的非 base64 输入**会单核 25% CPU 死循环，实测 161 字节中文文本就足以让进程跑 24h+ 不退出（[GitHub issue 触发场景](https://github.com/folderdoge/fancyss_doge) — 2026-05-18 在 TUF-AX3000_V2 测试机定位）。

为防上述两类后果，订阅解码路径目前共有**三道串联的闸门**，必须按顺序通过才会真正调用 `base64 -d`。

---

## 1. 三道闸门

闸门在 `sub_validate_downloaded_payload_legacy` (line 1337+) 和 `sub_prepare_decoded_file` (line 2127+) 两个函数里**对称落地**。前者跑在「下载内容验证」阶段、后者跑在「真正解码」阶段，两次防御互为冗余。

| # | 引入版本 | 闸门 | 拦截什么 | 通过什么 |
|---|---------|------|---------|---------|
| ①  | alpha.2 (2026-05-17) | `wc -c < file > 2097152` | ≥ 2MB 的响应 | 典型订阅 < 100KB，大型机场 < 500KB，2MB 已是 4 倍 headroom |
| ②  | alpha.2 | 头 256 字节剥空白+BOM 后正则匹配 `^(<!DOCTYPE|<html|<head|<\?xml|<HTML|<HEAD)` | 标准 HTML / XML 错误页（含登录页、跳转页、404、反爬虫页） | 没有明显 HTML/XML magic byte 的响应 |
| ③  | alpha.9 (2026-05-18) | `sub_payload_looks_like_base64()`：头 8KB 采样 → `LC_ALL=C tr -d 'A-Za-z0-9+/=\-_\r\n\t '` → 必须为空 | 任何含**非 RFC 4648 base64 字母表**字符的响应（UTF-8 中文、JSON 大括号、控制字符、纯文本提示等） | 头 8KB 全部落在 base64 字母表 + URL-safe 别名 + 填充 + 空白 |

闸门 ③ 来源于 alpha.8 实测：某机场对未登录请求返回 161 字节纯中文 UTF-8 文本「请登录系统网站后台...」，Content-Type 是 `text/html` 但没有任何 HTML 标签 → 完美穿透闸门 ① 和 ② → 进 `dec64` → busybox base64 -d 死循环。

---

## 2. 上下游分工

- **sub_processor (Zig 二进制)** — `sub-tool-maintenance.md` 描述的工具。先于 shell 闸门跑，把响应分类成 `kind=html-page|html-login|text-error|json|...`。能识别就走 `sub_validate_downloaded_payload_with_tool` 的 case 分支，直接返回带 preview 的友好错误；**永远不进 legacy validator，永远不进闸门 ①②③**。
- **三道 shell 闸门** — sub_processor 把响应分类成 `unknown` 才会跌进 legacy fallback，由这三道兜住。

设计意图：sub_processor 是「快路径，分类丰富」，闸门是「慢路径，永不让 busybox base64 -d 死循环」。增强 sub_processor 的分类能识别更多 payload 形态（如纯文本错误页 → 应该判 `text-error`）是改善用户体验的工作，闸门是防御兜底，**两条都要存在**。

---

## 3. 已知漏检（写下来留给以后）

闸门 ③ 取头 8KB 采样。理论漏检：
- 一个真 base64 订阅，前 8KB 干净但 8KB 之后混入高位字节 — **不会发生**（合法 base64 不可能有高位字节）。
- 一个伪 base64 响应，前 8KB 全部是 ASCII 字母数字（比如某种英文错误页），8KB 之后才出现非字母表字节 — 可能漏检。busybox base64 -d 死循环到底是否依赖输入中混入高位字节才触发，目前没逐字符复现确认；如果纯 ASCII 也能触发死循环，需要把采样范围扩大或全文件扫描。当前阈值（8KB）是性能与覆盖率折中。

如果未来再出现「装了 alpha.9 还卡死」的报告，先 SSH 看 `cat /tmp/fancyss_subs/sub_file_encode_*.txt | head -c 8192 | LC_ALL=C tr -d 'A-Za-z0-9+/=\-_\r\n\t '` 是否为空。空 = 闸门 ③ 没拦住，需要扩大采样或换策略；非空 = 闸门 ③ 有 bug，是别的路径走漏。

---

## 4. 其他 `base64 -d` 调用点（不在闸门保护下、但安全）

`grep -n 'base64 -d' ss_node_subscribe.sh` 里还有 7 处调用，**它们都喂受控输入**，不需要闸门：

| 行号 | 上下文 | 输入来源 | 风险 |
|-----|--------|---------|------|
| 213, 8016, 8133 | `dbus get ss_online_links \| base64 -d` | dbus 持久化字段，前端 WebUI 写入时已是 base64 | 低，输入是 fancyss 自己生成的 base64 |
| 2920, 2946 | `printf '%s' "${blob}" \| base64 -d` | jq `@base64` 输出 | 低，jq 保证产出合法 base64 |
| 3788 | `printf '%s' "${rules_b64}" \| base64 -d` | dbus `ss_basic_shunt_rules` | 低，fork 自己写入的 |
| 4749 (dec64), 4762 (decode_urllink) | 单条订阅链接前缀 | 一条节点 URI（vmess:// / vless:// / ss://...） | 中，但单条节点 base64 部分都很短（< 1KB），busybox base64 -d 在小输入上不死循环（实测 < 64 字节中文都能秒退） |

如果未来加新的 `base64 -d` 调用点，输入来自**外部网络下载内容**，必须先过 `sub_payload_looks_like_base64`。
