# Fork 版本号与发版流程

> **目标**：fork 用独立版本号区别于上游 hq450，自有更新源避免被「检查更新」按钮覆盖。
> 用户在路由器 Web UI 看到 `3.5.23-doge.1`，点检查更新走 fork raw URL + GitHub Releases，永远不会拉到上游包。

---

## 1. 文件清单

| 文件 | 角色 |
|---|---|
| [fancyss/ss/version](../../fancyss/ss/version) | **真值源**。一行字符串（如 `3.5.23-doge.1`），下游所有地方读它 |
| [build.sh:4](../../build.sh) | 构建时 `VERSION=$(cat ./fancyss/ss/version|sed -n 1p)` |
| [build.sh:540-552](../../build.sh) `papare()` | 把 `VERSION` 写进 `packages/version_tmp.json.js` |
| [build.sh:498-514](../../build.sh) `build_pkg()` | 打 tarball，把 md5 追加进 `version_tmp.json.js` |
| [build.sh:554-559](../../build.sh) `finish()` | 用 jq 美化 → `packages/version.json.js`（commit 进 repo 的最终物） |
| [build_min.sh](../../build_min.sh) | 局部精简构建（只 hnd / hnd_v8 + 跳过 zig 工具校验），`papare()` 被 override |
| [fancyss/install.sh:1485](../../fancyss/install.sh) | 装机时 `local PLVER=$(cat ${DIR}/ss/version)` |
| [fancyss/install.sh:1969](../../fancyss/install.sh) | `dbus set ss_basic_version_local="${PLVER}"` |
| [fancyss/scripts/ss_update.sh:8-10](../../fancyss/scripts/ss_update.sh) | `main_url`（探测）+ `release_url_base`（下载）声明 |
| [fancyss/scripts/ss_update.sh:84](../../fancyss/scripts/ss_update.sh) | 字符串 `!=` 比较 local vs online |
| [fancyss/scripts/ss_update.sh:90](../../fancyss/scripts/ss_update.sh) | 拼下载 URL：`${release_url_base}/v${fancyss_version_online}/${PACKAGE}.tar.gz` |
| [fancyss/res/ss-menu.js:203](../../fancyss/res/ss-menu.js) | About 弹窗读 `db_ss["ss_basic_version_local"]` 显示 |
| [fancyss/webs/Module_shadowsocks.asp ~15765](../../fancyss/webs/Module_shadowsocks.asp) | 顶部「版本与更新」行的 HTML 结构 |
| [packages/.gitignore](../../packages/.gitignore) | 忽略 `*.tar.gz` 和 `MD5SUMS.txt`，只 commit `version.json.js` |

---

## 2. 版本号规则

格式：`<上游基线>-doge.<N>`，例如 `3.5.23-doge.1`、`3.5.23-doge.2`、`3.5.24-doge.3`

- **上游基线**：跟 fork 当前同步上游的版本一致（即 `git merge upstream/3.0` 拿到的版本）
- **doge.N**：fork 自己的迭代计数。每次发新版 +1
- **同步上游时 N 不重置，继续 +1**：例如 `3.5.23-doge.5` 同步到上游 3.5.24 后变 `3.5.24-doge.6`。这样所有历史 release tag 单调递增，不会因为重置导致版本号比较错乱（旧 fork 包看到 `3.5.24-doge.1` 可能误判为更老）

为什么这样选：
- `install.sh:1490` 的 `version_lt "${OLD_VER}" "3.6.0"` 用 awk `-F'[^0-9]+'` 切，`-doge.1` 部分被丢弃 → `3.5.23-doge.1` 数值化后是 `3005023`，**与上游 `3.5.23` 等价**。这意味着上游引入的 legacy 迁移检查仍然正确触发。
- `ss_update.sh:84` 是字符串 `!=`，`3.5.23-doge.1` ≠ `3.5.23-doge.2` → 触发更新下载。
- `version` 文件里直接写完整字符串 → build.sh / install.sh / About 弹窗显示一气呵成。

---

## 3. 更新源 URL 结构

| 用途 | URL 模板 | 在哪定义 |
|---|---|---|
| 版本探测 | `https://raw.githubusercontent.com/folderdoge/fancyss_doge/3.0/packages/version.json.js` | `ss_update.sh:9` `main_url` |
| Tarball 下载 | `https://github.com/folderdoge/fancyss_doge/releases/download/v${VERSION}/${PACKAGE}.tar.gz` | `ss_update.sh:10` `release_url_base` + `:90` 拼接 |

**`${VERSION}`** 来自下载到的 `version.json.js` 的 `.version` 字段（`ss_update.sh:81`），**`${PACKAGE}`** 是 `fancyss_${PLATFORM}_${PKGTYPE}`（`ss_update.sh:32`）。

Release tag **必须** = `v` + 完整版本字符串（含 `-doge.N`）。

---

## 4. 发版工作流

```bash
# 1. 改版本号
echo "3.5.23-doge.2" > fancyss/ss/version

# 2. WSL 构建（生成 packages/*.tar.gz 和 packages/version.json.js）
wsl -d Ubuntu-24.04 -- bash -c "cd '/mnt/e/日本梯子/fancyss_doge' && bash build_min.sh"

# 3. commit + push（只提交源码改动 + version.json.js，tarball 被 .gitignore 忽略）
git add fancyss/ss/version packages/version.json.js  # + 任何源码改动
git commit -m "release 3.5.23-doge.2: <主题>"
git push origin 3.0

# 4. 推 tag（先用 git push 而不是 gh release create 自带的 tag 创建，避开 gh 的 workflow scope 误报）
git tag v3.5.23-doge.2 HEAD
git push origin v3.5.23-doge.2

# 5. 创建 release 并上传 tarball（必须加 --repo，否则 gh 会错认成 upstream/hq450）
gh release create v3.5.23-doge.2 \
  --repo folderdoge/fancyss_doge \
  packages/fancyss_hnd_v8_full.tar.gz \
  packages/fancyss_hnd_full.tar.gz \
  --verify-tag \
  --title "3.5.23-doge.2" \
  --notes "<release notes>"
```

PowerShell 等价命令见 CLAUDE.md「发版工作流」章。

---

## 5. 踩坑记录

### 5.1 `gh` 命令必须显式 `--repo folderdoge/fancyss_doge`

仓库本地有两个 remote：`origin`（fork）和 `upstream`（hq450）。`gh` 解析当前仓库时会扫描 remotes，**有时挑到 upstream**。结果：`gh release create v3.5.23-doge.1 --verify-tag` 报错说 tag 不存在于 `hq450/fancyss`。

**永远在所有 `gh` 命令上加 `--repo folderdoge/fancyss_doge`**。本仓库的所有发版命令都必须带这个参数。

### 5.2 `gh release create` 自动创建 tag 时报 "workflow scope may be required"

即使 token 已经有 `workflow` scope（`gh auth status` 能看到），让 `gh release create` 在没有现成 tag 时去创建 tag 偶尔会报这个错。

**绕过方法**：先用 `git tag` + `git push origin <tag>` 把 tag 推上去，然后 `gh release create <tag> --verify-tag` 引用现成 tag。本仓库的发版工作流第 4-5 步就是这个顺序。

### 5.3 `gh` 在 Windows 上不在默认 PATH

winget 装的 gh 在 `C:\Program Files\GitHub CLI\gh.exe`，但 `Path` 环境变量没自动加。每次 PowerShell 调用前要：

```powershell
$env:Path += ';C:\Program Files\GitHub CLI'
```

### 5.4 Edit 工具对 asp 文件的多行 + 前导 tab 匹配不可靠

[fancyss/webs/Module_shadowsocks.asp](../../fancyss/webs/Module_shadowsocks.asp) 是 UTF-8 BOM + LF + tab 缩进。Edit 工具理论支持，但实测**前导 tab 在传输层会丢失**（同一字面量在 Read 显示正常、Edit 报 not found）。

**规则**：单行无前导空格的字符串可以 Edit；任何**带前导 tab 的多行替换**直接走 PowerShell：

```powershell
$f = 'E:\日本梯子\fancyss_doge\fancyss\webs\Module_shadowsocks.asp'
$s = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($true))
$old = "`t`t`t...<line1>`n`t`t`t...<line2>"  # 显式 `t / `n
$new = "..."
$s2 = $s.Replace($old, $new)
[System.IO.File]::WriteAllText($f, $s2, [System.Text.UTF8Encoding]::new($true))
```

改完用 `git diff -U0` 确认只动了目标行。

### 5.5 顶部布局：行内 div 全部 `position: absolute` 会导致行高坍缩

[fancyss/webs/Module_shadowsocks.asp ~15765](../../fancyss/webs/Module_shadowsocks.asp) 「版本与更新」行最初让 [检查并更新 / 当前版本 / 更新日志] 三个 div 都用 `display:table-cell;float:left;position:absolute`。结果：absolute 把它们脱出文档流，行的自然高度变 0，下一行（插件运行状态）盖到上面。

**规则**：每行至少留一个子元素**不带 `position: absolute`**，让它撑住行高。当前实现里「检查并更新」div 是非 absolute 的，后两个 absolute 通过 `margin-left` 叠加定位。

---

## 6. 修订历史

- **2026-05-03**：初版。引入 `3.5.23-doge.N` 命名 + raw URL 探测 + Releases 下载。Commits `2b46e67`（核心切换）、`a7ed4c4`（顶部布局拆行）、`286e548`（修复行高坍缩）。Release: [v3.5.23-doge.1](https://github.com/folderdoge/fancyss_doge/releases/tag/v3.5.23-doge.1)。
