#!/bin/sh
# ss_node_shunt.sh - doge.14 stub
#
# 老"节点分流"功能 (ss_basic_mode=7) 已在 doge.14 退役，迁移到 doge.12 分流架构 (Mode/Rule)。
# 本文件保留为空壳兼容 3 个 sourcer：
#   - scripts/ss_base.sh           (fss_require_shunt_lib)
#   - scripts/ss_node_postsave.sh  (顶部 source)
#   - scripts/ss_shunt_hot_reload.sh (顶部 source)
# 以及 ss_base.sh:68 / ssconfig.sh 多处的 `type fss_shunt_xxx >/dev/null 2>&1` 环境探测。
#
# 设计取舍：
#   - 保留所有「被外部直接调用」的函数符号 (17 个) 以避免 callers undefined-function 报错。
#   - 函数体一律 `return 0` 或 `return 1`（按调用方语义选 truthiness）。
#   - install.sh::migrate_doge14 已把 ss_basic_mode=7 迁到 mode=2，运行时不再走到任何 mode=7 分支；
#     这些 stub 本质是"防御性兼容"，给老 dbus 残留 / 升级途中半态 / 第三方脚本兜底。
#   - 计划 doge.15 物理删除整文件 + 3 个 sourcer 同步清理。

# --- 模式相关 (truthy = mode=7 启用；doge.14 起永远 return 1 = 未启用) ---
fss_shunt_mode_selected()       { return 1; }
fss_shunt_effective_mode()      { echo "${ss_basic_mode:-0}"; return 0; }

# --- 目标判定 (hot_reload.sh 用作 bool；任何 target_id 都不是 special target) ---
fss_shunt_target_is_direct()    { return 1; }
fss_shunt_target_is_reject()    { return 1; }

# --- runtime / 节点解析 (无返回值，调用方都用 `|| true` 兜底) ---
fss_shunt_cleanup_runtime()             { return 0; }
fss_shunt_prepare_runtime()             { return 1; }
fss_shunt_write_hot_reload_state()      { return 1; }
fss_shunt_sync_identity_shadows()       { return 0; }
fss_shunt_resolve_default_node_id()     { return 1; }
fss_shunt_get_default_node_id()         { return 0; }

# --- 资产/路径访问器 (空串输出 + 非 0 退出，调用方 `... || true` 兜底) ---
fss_shunt_xray_asset_dir()              { return 1; }
fss_shunt_export_runtime_base_rules()   { return 1; }
fss_shunt_get_runtime_chnroute4_file()  { return 1; }
fss_shunt_get_runtime_chnroute6_file()  { return 1; }
fss_shunt_get_proxy_domain_file()       { return 1; }
fss_shunt_resolve_proxy_domain_file()   { return 1; }

# --- xray 配置构建 (doge.14 mode=7 路径已死，不应被调用) ---
fss_shunt_build_xray_config()           { return 1; }
