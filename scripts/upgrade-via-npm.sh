#!/bin/bash

# qqbot 通过 openclaw 原生插件指令升级（v3）
#
# 策略：
#   安装场景（插件不存在）：openclaw plugins install → 失败降级 npm pack 手动部署
#   更新场景（插件已存在）：openclaw plugins update  → 失败降级 npm pack 手动部署
#
# 用法:
#   upgrade-via-npm.sh                                    # 升级到 latest
#   upgrade-via-npm.sh --version <version>                # 升级到指定版本
#   upgrade-via-npm.sh --self-version                     # 升级到当前仓库 package.json 版本
#   upgrade-via-npm.sh --appid <appid> --secret <secret>  # 首次安装时配置 appid/secret
#   upgrade-via-npm.sh --no-restart                       # 只做文件替换，不重启 gateway
#   upgrade-via-npm.sh --timeout 600                      # 自定义安装超时时间（秒）

set -eo pipefail

# ============================================================================
#  进程隔离 — 脱离 gateway 进程组
# ============================================================================
if [ -z "$_UPGRADE_ISOLATED" ] && [ -f "$0" ] && command -v setsid &>/dev/null; then
    export _UPGRADE_ISOLATED=1
    exec setsid "$0" "$@"
fi

# ============================================================================
#  环境准备
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
PROJECT_DIR=""
[ -n "$SCRIPT_DIR" ] && PROJECT_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)" || true

cd "$HOME" 2>/dev/null || cd / 2>/dev/null || true

ensure_valid_cwd() {
    stat . &>/dev/null 2>&1 || cd "$HOME" 2>/dev/null || cd / 2>/dev/null || true
}

read_pkg_version() {
    node -e "try{process.stdout.write(JSON.parse(require('fs').readFileSync('$1','utf8')).version||'')}catch{}" 2>/dev/null || true
}

for _p in /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /bin /sbin; do
    case ":$PATH:" in *":$_p:"*) ;; *) [ -d "$_p" ] && export PATH="$PATH:$_p" ;; esac
done
[ -z "$npm_config_registry" ] && export npm_config_registry="https://registry.npmjs.org"

# ============================================================================
#  超时执行包装器（兼容 macOS 无 GNU timeout）
# ============================================================================
run_with_timeout() {
    local timeout_secs="$1" description="$2"; shift 2

    if command -v timeout &>/dev/null; then
        echo "  [超时保护] ${description}: 最长 ${timeout_secs}s"
        timeout --kill-after=10 "$timeout_secs" "$@" && return 0
        local rc=$?
        [ $rc -eq 124 ] && echo "  ⏰ ${description} 超时"
        return $rc
    fi

    # macOS fallback
    echo "  [超时保护] ${description}: 最长 ${timeout_secs}s"
    "$@" &
    local cmd_pid=$!
    ( sleep "$timeout_secs" 2>/dev/null
      kill -0 "$cmd_pid" 2>/dev/null && echo "  ⏰ ${description} 超时，终止中..." && \
          kill -TERM "$cmd_pid" 2>/dev/null && sleep 5 && \
          kill -0 "$cmd_pid" 2>/dev/null && kill -KILL "$cmd_pid" 2>/dev/null
    ) &
    local wd=$!; disown "$wd" 2>/dev/null || true
    wait "$cmd_pid" 2>/dev/null; local rc=$?
    kill "$wd" 2>/dev/null || true; wait "$wd" 2>/dev/null 2>&1 || true
    [ $rc -eq 143 ] || [ $rc -eq 137 ] && return 124
    return $rc
}

# ============================================================================
#  配置快照 / 回滚
# ============================================================================
CONFIG_SNAPSHOT_FILE=""

snapshot_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    CONFIG_SNAPSHOT_FILE="$(mktemp "${TMPDIR:-/tmp}/.qqbot-config-snapshot-XXXXXX")"
    cp -a "$CONFIG_FILE" "$CONFIG_SNAPSHOT_FILE"
    echo "  [快照] 已保存配置快照"
}

restore_config_snapshot() {
    [ -n "$CONFIG_SNAPSHOT_FILE" ] && [ -f "$CONFIG_SNAPSHOT_FILE" ] && [ -n "$CONFIG_FILE" ] && \
        cp -a "$CONFIG_SNAPSHOT_FILE" "$CONFIG_FILE" && echo "  ↩️  已恢复配置到安装前状态"
    return 0
}

cleanup_config_snapshot() {
    [ -n "$CONFIG_SNAPSHOT_FILE" ] && rm -f "$CONFIG_SNAPSHOT_FILE" 2>/dev/null || true
}

rollback_plugin_dir() {
    local reason="${1:-未知原因}"
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR/$PLUGIN_ID" ]; then
        rm -rf "$EXTENSIONS_DIR/$PLUGIN_ID" 2>/dev/null || true
        mv "$BACKUP_DIR/$PLUGIN_ID" "$EXTENSIONS_DIR/$PLUGIN_ID" 2>/dev/null || \
            cp -a "$BACKUP_DIR/$PLUGIN_ID" "$EXTENSIONS_DIR/$PLUGIN_ID" 2>/dev/null || true
        [ -f "$EXTENSIONS_DIR/$PLUGIN_ID/package.json" ] && \
            echo "  ↩️  已回滚到旧版本 v$(read_pkg_version "$EXTENSIONS_DIR/$PLUGIN_ID/package.json")（原因: ${reason}）" && return 0
        echo "  ❌ 回滚后插件目录仍不完整！"; return 1
    fi
    echo "  ⚠️  无备份可回滚（原因: ${reason}）"; return 1
}

# ============================================================================
#  升级锁
# ============================================================================
UPGRADE_LOCK_FILE=""

acquire_upgrade_lock() {
    [ -z "$UPGRADE_LOCK_FILE" ] && return 0
    if [ -f "$UPGRADE_LOCK_FILE" ]; then
        local lock_pid="$(cat "$UPGRADE_LOCK_FILE" 2>/dev/null || true)"
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "❌ 另一个升级进程正在运行 (PID: $lock_pid)"; exit 1
        fi
        rm -f "$UPGRADE_LOCK_FILE" 2>/dev/null || true
    fi
    echo "$$" > "$UPGRADE_LOCK_FILE"
}

release_upgrade_lock() {
    [ -n "$UPGRADE_LOCK_FILE" ] && rm -f "$UPGRADE_LOCK_FILE" 2>/dev/null || true
}

# ============================================================================
#  临时配置副本（绕过 openclaw 3.23+ 配置校验）
# ============================================================================
setup_temp_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    local need_temp
    need_temp="$(node -e "
      try {
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
        if (cfg.channels?.qqbot || cfg.plugins?.allow?.includes('$PLUGIN_ID') || cfg.plugins?.entries?.['$PLUGIN_ID'])
          process.stdout.write('1');
      } catch {}
    " 2>/dev/null || true)"
    [ "$need_temp" != "1" ] && return 0

    TEMP_CONFIG_FILE="$(mktemp)"
    if node -e "
      const fs = require('fs');
      const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
      delete cfg.channels?.qqbot;
      cfg.channels && Object.keys(cfg.channels).length === 0 && delete cfg.channels;
      if (Array.isArray(cfg.plugins?.allow)) {
        cfg.plugins.allow = cfg.plugins.allow.filter(p => p !== '$PLUGIN_ID');
        cfg.plugins.allow.length === 0 && delete cfg.plugins.allow;
      }
      delete cfg.plugins?.entries?.['$PLUGIN_ID'];
      cfg.plugins?.entries && Object.keys(cfg.plugins.entries).length === 0 && delete cfg.plugins.entries;
      fs.writeFileSync('$TEMP_CONFIG_FILE', JSON.stringify(cfg, null, 4) + '\n');
    " 2>/dev/null; then
        echo "  [兼容] 创建临时配置副本以通过 3.23+ 配置校验"
        export OPENCLAW_CONFIG_PATH="$TEMP_CONFIG_FILE"
    else
        echo "  ⚠️  创建临时配置失败，继续使用原配置"
        rm -f "$TEMP_CONFIG_FILE" 2>/dev/null || true; TEMP_CONFIG_FILE=""
    fi
}

sync_temp_config() {
    [ -n "$TEMP_CONFIG_FILE" ] && [ -f "$TEMP_CONFIG_FILE" ] || return 0
    if [ ! -f "$EXTENSIONS_DIR/$PLUGIN_ID/package.json" ]; then
        echo "  ⚠️  插件目录不完整，跳过配置同步"
        rm -f "$TEMP_CONFIG_FILE"; unset OPENCLAW_CONFIG_PATH; return 1
    fi
    ensure_valid_cwd
    node -e "
      const fs = require('fs');
      const tmp = JSON.parse(fs.readFileSync('$TEMP_CONFIG_FILE', 'utf8'));
      const real = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
      let c = false;
      if (tmp.plugins?.installs) { (real.plugins ??= {}).installs = { ...real.plugins.installs, ...tmp.plugins.installs }; c = true; }
      if (tmp.plugins?.entries) { (real.plugins ??= {}).entries = { ...real.plugins.entries, ...tmp.plugins.entries }; c = true; }
      for (const id of tmp.plugins?.allow || []) {
        if (!(real.plugins ??= {}).allow) real.plugins.allow = [];
        if (!real.plugins.allow.includes(id)) { real.plugins.allow.push(id); c = true; }
      }
      if (c) fs.writeFileSync('$CONFIG_FILE', JSON.stringify(real, null, 4) + '\n');
    " 2>/dev/null || true
    rm -f "$TEMP_CONFIG_FILE"; unset OPENCLAW_CONFIG_PATH
    echo "  [兼容] 已同步配置并清理临时副本"
}

# ============================================================================
#  npm pack 降级安装（内联实现）
# ============================================================================
npm_pack_fallback() {
    echo ""
    echo "  ============================================"
    echo "  [降级] 尝试 npm pack + 手动安装"
    echo "  ============================================"

    # 前置检查
    for _cmd in npm tar node; do
        if ! command -v "$_cmd" &>/dev/null; then
            echo "  ❌ $_cmd 不可用，无法执行降级安装"; return 1
        fi
    done

    local pack_dir extract_dir
    pack_dir="$(mktemp -d "${TMPDIR:-/tmp}/.qqbot-pack-XXXXXX")"
    extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/.qqbot-extract-XXXXXX")"

    _cleanup_pack() {
        [ -n "$pack_dir" ] && rm -rf "$pack_dir" 2>/dev/null || true
        [ -n "$extract_dir" ] && rm -rf "$extract_dir" 2>/dev/null || true
    }

    # Step 1: npm pack（多 registry 兜底）
    echo "  [降级 1/4] 下载: $INSTALL_SRC"
    local pack_ok=false
    ensure_valid_cwd
    for registry in "https://registry.npmjs.org/" "https://mirrors.cloud.tencent.com/npm/"; do
        echo "    尝试 registry: $registry"
        if run_with_timeout "$INSTALL_TIMEOUT" "npm pack" npm pack "$INSTALL_SRC" \
                --pack-destination "$pack_dir" --registry "$registry" 2>&1; then
            pack_ok=true; break
        fi
    done
    if [ "$pack_ok" != "true" ]; then
        echo "  ❌ npm pack 失败（所有 registry 均不可用）"; _cleanup_pack; return 1
    fi

    local tgz_file
    tgz_file="$(find "$pack_dir" -maxdepth 1 -name '*.tgz' -type f | head -1)"
    if [ -z "$tgz_file" ]; then
        echo "  ❌ 未找到 tgz 文件"; _cleanup_pack; return 1
    fi
    echo "    已下载: $(basename "$tgz_file")"

    # Step 2: 解压
    echo "  [降级 2/4] 解压..."
    if ! tar xzf "$tgz_file" -C "$extract_dir" 2>&1; then
        echo "  ❌ 解压失败"; _cleanup_pack; return 1
    fi
    local package_dir="$extract_dir/package"
    if [ ! -f "$package_dir/package.json" ]; then
        echo "  ❌ 解压后未找到 package.json"; _cleanup_pack; return 1
    fi

    # Step 3: 检查 bundled dependencies
    echo "  [降级 3/4] 检查依赖..."
    local nm_dir="$package_dir/node_modules"
    if [ ! -d "$nm_dir" ] || [ ! -d "$nm_dir/ws" ]; then
        echo "    执行 npm install --omit=dev..."
        ensure_valid_cwd
        ( cd "$package_dir" && npm install --omit=dev --omit=peer --ignore-scripts --quiet 2>&1 ) || true
        if [ ! -d "$nm_dir/ws" ]; then
            echo "  ❌ 关键依赖 ws 缺失"; _cleanup_pack; return 1
        fi
    fi
    echo "    ✅ 依赖就绪"

    # Step 4: 部署到 extensions
    echo "  [降级 4/4] 部署..."
    local target_dir="$EXTENSIONS_DIR/$PLUGIN_ID"
    mkdir -p "$EXTENSIONS_DIR" 2>/dev/null || true

    # 备份旧目录（如果 BACKUP_DIR 尚未设置）
    if [ -z "$BACKUP_DIR" ] && [ -d "$target_dir" ]; then
        BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/.qqbot-upgrade-backup-XXXXXX")"
        cp -a "$target_dir" "$BACKUP_DIR/$PLUGIN_ID"
    fi
    rm -rf "$target_dir" 2>/dev/null || true

    if ! mv "$package_dir" "$target_dir" 2>&1; then
        echo "  ❌ 部署失败"; _cleanup_pack; return 1
    fi
    if [ ! -f "$target_dir/package.json" ]; then
        echo "  ❌ 部署后目录不完整"; _cleanup_pack; return 1
    fi

    # 写入配置
    local _ver; _ver="$(read_pkg_version "$target_dir/package.json")"
    local _cfg_target="${TEMP_CONFIG_FILE:-$CONFIG_FILE}"
    if [ -f "$_cfg_target" ]; then
        node -e "
          try {
            const fs = require('fs');
            const cfg = JSON.parse(fs.readFileSync('$_cfg_target', 'utf8'));
            if (!cfg.plugins) cfg.plugins = {};
            (cfg.plugins.installs ??= {})['$PLUGIN_ID'] = { source: 'npm', spec: '$INSTALL_SRC', version: '$_ver' };
            (cfg.plugins.entries ??= {})['$PLUGIN_ID'] ??= { enabled: true };
            if (!cfg.plugins.allow) cfg.plugins.allow = [];
            if (!cfg.plugins.allow.includes('$PLUGIN_ID')) cfg.plugins.allow.push('$PLUGIN_ID');
            fs.writeFileSync('$_cfg_target', JSON.stringify(cfg, null, 4) + '\n');
          } catch {}
        " 2>/dev/null || true
        echo "    ✅ 已写入配置"
    fi

    # postinstall SDK link
    if [ -f "$target_dir/scripts/postinstall-link-sdk.js" ]; then
        ensure_valid_cwd
        node "$target_dir/scripts/postinstall-link-sdk.js" 2>&1 && echo "    ✅ SDK 链接就绪" || \
            echo "    ⚠️  postinstall-link-sdk 失败（非致命）"
    fi

    _cleanup_pack
    echo "  ✅ npm pack 安装成功 (v${_ver:-unknown})"
    return 0
}

# ============================================================================
#  异常退出清理
# ============================================================================
INSTALL_COMPLETED=false
BACKUP_DIR=""
TEMP_CONFIG_FILE=""

cleanup_on_exit() {
    local exit_code=$?
    ensure_valid_cwd

    if [ "$INSTALL_COMPLETED" != "true" ] && [ $exit_code -ne 0 ]; then
        local reason="异常退出 (code=$exit_code)"
        case $exit_code in 124) reason="安装超时";; 130) reason="用户中断";; 143) reason="SIGTERM";; 129) reason="SIGHUP";; esac
        echo "  ⚠️  [cleanup] ${reason}"
        restore_config_snapshot
        rollback_plugin_dir "$reason"
    fi

    [ -n "$TEMP_CONFIG_FILE" ] && rm -f "$TEMP_CONFIG_FILE" 2>/dev/null || true
    [ -n "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR" 2>/dev/null || true
    cleanup_config_snapshot
    find "${EXTENSIONS_DIR:-/dev/null}" -maxdepth 1 -name ".openclaw-install-stage-*" -exec rm -rf {} + 2>/dev/null || true
    find "${TMPDIR:-/tmp}" -maxdepth 1 \( -name ".openclaw-install-stage-*" -o -name ".qqbot-pack-*" \
        -o -name ".qqbot-extract-*" -o -name ".qqbot-upgrade-backup-*" \) -exec rm -rf {} + 2>/dev/null || true
    release_upgrade_lock
    exit $exit_code
}
trap cleanup_on_exit EXIT
trap 'echo "  ⚠️  收到 SIGTERM"; exit 143' TERM
trap 'echo "  ⚠️  收到 SIGINT"; exit 130' INT
trap 'echo "  ⚠️  收到 SIGHUP"; exit 129' HUP

# 清理上次升级遗留（>60min）
find "${TMPDIR:-/tmp}" -maxdepth 1 \( -name ".qqbot-upgrade-backup-*" -o -name ".qqbot-pack-*" \
    -o -name ".qqbot-extract-*" \) -mmin +60 -exec rm -rf {} + 2>/dev/null || true

# ============================================================================
#  参数解析
# ============================================================================
PKG_NAME="@tencent-connect/openclaw-qqbot"
PLUGIN_ID="openclaw-qqbot"
TARGET_VERSION=""
APPID=""
SECRET=""
NO_RESTART=false
INSTALL_TIMEOUT=1000
LOCAL_VERSION="$(read_pkg_version "$PROJECT_DIR/package.json")"

print_usage() {
    cat <<EOF
用法:
  upgrade-via-npm.sh                              # 升级到 latest
  upgrade-via-npm.sh --version <版本号>            # 升级到指定版本
  upgrade-via-npm.sh --self-version               # 升级到当前仓库版本${LOCAL_VERSION:+ ($LOCAL_VERSION)}

  --pkg <scope/name>    指定 npm 包名
  --appid <appid>       QQ机器人 appid
  --secret <secret>     QQ机器人 secret
  --no-restart          只做文件替换，不重启 gateway
  --timeout <秒>        自定义安装超时（默认1000）

环境变量: QQBOT_APPID / QQBOT_SECRET / QQBOT_TOKEN (appid:secret)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag|--version) [ -z "$2" ] && echo "❌ $1 需要参数" && exit 1; TARGET_VERSION="${2#v}"; shift 2 ;;
        --self-version) [ -z "$LOCAL_VERSION" ] && echo "❌ 无法读取版本" && exit 1; TARGET_VERSION="$LOCAL_VERSION"; shift ;;
        --appid) [ -z "$2" ] && echo "❌ --appid 需要参数" && exit 1; APPID="$2"; shift 2 ;;
        --secret) [ -z "$2" ] && echo "❌ --secret 需要参数" && exit 1; Secret="$2"; shift 2 ;;
        --pkg) [ -z "$2" ] && echo "❌ --pkg 需要参数" && exit 1; _p="$2"; [[ "$_p" != @* ]] && _p="@$_p"; PKG_NAME="$_p"; shift 2 ;;
        --no-restart) NO_RESTART=true; shift ;;
        --timeout) [ -z "$2" ] && echo "❌ --timeout 需要参数" && exit 1; INSTALL_TIMEOUT="$2"; shift 2 ;;
        -h|--help) print_usage; exit 0 ;;
        *) echo "未知选项: $1"; print_usage; exit 1 ;;
    esac
done

INSTALL_SRC="${PKG_NAME}@${TARGET_VERSION:-latest}"

# 环境变量 fallback
APPID="${APPID:-$QQBOT_APPID}"; SECRET="${SECRET:-$QQBOT_SECRET}"
if [ -z "$APPID" ] && [ -z "$SECRET" ] && [ -n "$QQBOT_TOKEN" ]; then
    APPID="${QQBOT_TOKEN%%:*}"; SECRET="${QQBOT_TOKEN#*:}"
fi

# 检测 openclaw
command -v openclaw &>/dev/null || { echo "❌ 未找到 openclaw"; exit 1; }

# 解析数据目录（支持 OPENCLAW_STATE_DIR 覆盖）
OPENCLAW_HOME="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
EXTENSIONS_DIR="$OPENCLAW_HOME/extensions"
CONFIG_FILE="$OPENCLAW_HOME/openclaw.json"

UPGRADE_LOCK_FILE="$OPENCLAW_HOME/.upgrading"
acquire_upgrade_lock

OPENCLAW_VERSION="$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"

echo "==========================================="
echo "  qqbot 升级: $INSTALL_SRC"
echo "  openclaw: v${OPENCLAW_VERSION:-unknown}"
echo "  隔离: ${_UPGRADE_ISOLATED:+✓ setsid}${_UPGRADE_ISOLATED:-✗}  超时: ${INSTALL_TIMEOUT}s"
echo "==========================================="

# 记录旧版本
OLD_VERSION=""
OLD_PKG="$EXTENSIONS_DIR/$PLUGIN_ID/package.json"
[ -f "$OLD_PKG" ] && OLD_VERSION="$(read_pkg_version "$OLD_PKG")"
[ -n "$OLD_VERSION" ] && echo "  当前版本: $OLD_VERSION"

# ============================================================================
#  [1/4] 安装/升级插件
# ============================================================================
echo ""
echo "[1/4] 安装/升级插件..."
snapshot_config
setup_temp_config

UPGRADE_OK=false

# 检测安装状态
INSTALL_RECORD_INFO="$(node -e "
  try {
    const cfg = JSON.parse(require('fs').readFileSync('$CONFIG_FILE', 'utf8'));
    const inst = cfg.plugins?.installs?.['$PLUGIN_ID'];
    if (inst) process.stdout.write('yes|' + (inst.spec || ''));
  } catch {}
" 2>/dev/null || true)"
HAS_INSTALL_RECORD="${INSTALL_RECORD_INFO%%|*}"
INSTALL_SPEC="${INSTALL_RECORD_INFO#*|}"
HAS_PLUGIN_DIR=false
[ -d "$EXTENSIONS_DIR/$PLUGIN_ID" ] && [ -f "$OLD_PKG" ] && HAS_PLUGIN_DIR=true

# 决策：配置有记录 + 目录存在 + 未指定版本 → update，其他 → install
USE_UPDATE=false
if [ "$HAS_INSTALL_RECORD" = "yes" ] && [ "$HAS_PLUGIN_DIR" = "true" ] && [ -z "$TARGET_VERSION" ]; then
    USE_UPDATE=true
    echo "  [检测] 配置 ✓ | 目录 ✓ | 未指定版本 → update"
    # spec 解锁
    if [ -n "$INSTALL_SPEC" ]; then
        SPEC_SUFFIX="${INSTALL_SPEC##*@}"
        if echo "$SPEC_SUFFIX" | grep -qE '^[0-9]+\.[0-9]+'; then
            echo "  [spec 解锁] '$INSTALL_SPEC' → @latest"
            node -e "
              try {
                const fs = require('fs'), p = process.env.OPENCLAW_CONFIG_PATH || '$CONFIG_FILE';
                const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
                if (cfg.plugins?.installs?.['$PLUGIN_ID']) {
                  cfg.plugins.installs['$PLUGIN_ID'].spec = '$PKG_NAME@latest';
                  fs.writeFileSync(p, JSON.stringify(cfg, null, 4) + '\n');
                }
              } catch {}
            " 2>/dev/null || true
        fi
    fi
elif [ "$HAS_PLUGIN_DIR" = "true" ]; then
    echo "  [检测] 目录 ✓ | 指定版本或无配置记录 → reinstall"
else
    echo "  [检测] 目录 ✗ → 全新安装"
fi

mark_success() {
    UPGRADE_OK=true; INSTALL_COMPLETED=true
    [ -n "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR" 2>/dev/null && BACKUP_DIR="" || true
}

# ── 更新路径 ──
if [ "$USE_UPDATE" = "true" ]; then
    echo "  尝试 openclaw plugins update..."
    ensure_valid_cwd
    UPDATE_RC=0
    run_with_timeout "$INSTALL_TIMEOUT" "plugins update" openclaw plugins update "$PLUGIN_ID" 2>&1 || UPDATE_RC=$?

    if [ $UPDATE_RC -eq 0 ]; then
        POST_VER=""; [ -f "$OLD_PKG" ] && POST_VER="$(read_pkg_version "$OLD_PKG")"
        if [ -n "$POST_VER" ] && [ "$POST_VER" != "$OLD_VERSION" ]; then
            mark_success; echo "  ✅ update 成功 ($OLD_VERSION → $POST_VER)"
        elif [ -z "$OLD_VERSION" ]; then
            mark_success; echo "  ✅ update 成功"
        else
            echo "  ℹ️  版本未变 ($POST_VER)，查询 npm latest..."
            NPM_LATEST="$(npm view "$PKG_NAME" version 2>/dev/null || true)"
            if [ -n "$NPM_LATEST" ] && [ "$NPM_LATEST" = "$POST_VER" ]; then
                mark_success; echo "  ✅ 已是最新版本 $POST_VER"
            else
                echo "  ⚠️  npm latest=${NPM_LATEST:-unknown}，当前=$POST_VER，降级..."
            fi
        fi
    else
        [ $UPDATE_RC -eq 124 ] && echo "  ⏰ update 超时" || echo "  ⚠️  update 失败 (exit=$UPDATE_RC)"
    fi

    [ "$UPGRADE_OK" != "true" ] && npm_pack_fallback && mark_success
fi

# ── 安装路径 ──
if [ "$UPGRADE_OK" != "true" ]; then
    # 备份旧目录
    if [ -d "$EXTENSIONS_DIR/$PLUGIN_ID" ]; then
        BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/.qqbot-upgrade-backup-XXXXXX")"
        cp -a "$EXTENSIONS_DIR/$PLUGIN_ID" "$BACKUP_DIR/$PLUGIN_ID"
        echo "  已备份旧目录"
    fi

    # 清理历史遗留
    for d in qqbot openclaw-qq; do
        [ -d "$EXTENSIONS_DIR/$d" ] && rm -rf "$EXTENSIONS_DIR/$d" && echo "  已清理: $d"
    done
    [ -d "$EXTENSIONS_DIR/$PLUGIN_ID" ] && rm -rf "$EXTENSIONS_DIR/$PLUGIN_ID"

    # 多 registry 重试
    NATIVE_OK=false
    for registry in "https://registry.npmjs.org/" "https://mirrors.cloud.tencent.com/npm/"; do
        echo "  尝试 install (registry: $registry)..."
        ensure_valid_cwd
        RC=0
        npm_config_registry="$registry" run_with_timeout "$INSTALL_TIMEOUT" \
            "plugins install" openclaw plugins install "$INSTALL_SRC" --pin 2>&1 || RC=$?
        if [ $RC -eq 0 ] && [ -f "$EXTENSIONS_DIR/$PLUGIN_ID/package.json" ]; then
            NATIVE_OK=true; echo "  ✅ install 成功"; break
        fi
        echo "  ⚠️  失败 (exit=$RC)"
        [ -d "$EXTENSIONS_DIR/$PLUGIN_ID" ] && [ ! -f "$EXTENSIONS_DIR/$PLUGIN_ID/package.json" ] && \
            rm -rf "$EXTENSIONS_DIR/$PLUGIN_ID" 2>/dev/null || true
        find "${EXTENSIONS_DIR:-/dev/null}" "${TMPDIR:-/tmp}" -maxdepth 1 -name ".openclaw-install-stage-*" \
            -exec rm -rf {} + 2>/dev/null || true
    done

    if [ "$NATIVE_OK" = "true" ]; then
        mark_success
    else
        echo "  原生 install 均失败，降级..."
        npm_pack_fallback && mark_success || {
            rollback_plugin_dir "安装失败"; restore_config_snapshot
            [ -n "$TEMP_CONFIG_FILE" ] && rm -f "$TEMP_CONFIG_FILE" 2>/dev/null || true
            unset OPENCLAW_CONFIG_PATH 2>/dev/null || true
            echo "QQBOT_NEW_VERSION=unknown"
            echo "QQBOT_REPORT=❌ QQBot 安装失败（已回滚），请检查网络"
            exit 1
        }
    fi
fi

sync_temp_config
cleanup_config_snapshot
INSTALL_COMPLETED=true

# ============================================================================
#  [2/4] 验证安装
# ============================================================================
echo ""
echo "[2/4] 验证安装..."

TARGET_DIR="$EXTENSIONS_DIR/$PLUGIN_ID"
NEW_VERSION=""; [ -f "$TARGET_DIR/package.json" ] && NEW_VERSION="$(read_pkg_version "$TARGET_DIR/package.json")"

PREFLIGHT_OK=true
[ -z "$NEW_VERSION" ] && echo "  ❌ 无法读取版本号" && PREFLIGHT_OK=false || echo "  ✅ 版本: $NEW_VERSION"

ENTRY=""; for f in "dist/index.js" "index.js"; do [ -f "$TARGET_DIR/$f" ] && ENTRY="$f" && break; done
[ -z "$ENTRY" ] && echo "  ❌ 缺少入口文件" && PREFLIGHT_OK=false || echo "  ✅ 入口: $ENTRY"

if [ -d "$TARGET_DIR/dist/src" ]; then
    JS_COUNT=$(find "$TARGET_DIR/dist/src" -name "*.js" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "  ✅ dist/src/ 含 ${JS_COUNT} 个 JS"
    [ "$JS_COUNT" -lt 5 ] && echo "  ❌ JS 数量异常偏少" && PREFLIGHT_OK=false
else
    echo "  ❌ 缺少 dist/src/"; PREFLIGHT_OK=false
fi

MISS=""
for m in "dist/src/gateway.js" "dist/src/api.js" "dist/src/admin-resolver.js"; do
    [ ! -f "$TARGET_DIR/$m" ] && MISS="$MISS $m"
done
[ -n "$MISS" ] && echo "  ❌ 缺少:$MISS" && PREFLIGHT_OK=false || echo "  ✅ 关键模块完整"

if [ -d "$TARGET_DIR/node_modules" ]; then
    BOK=true
    for dep in ws silk-wasm; do [ ! -d "$TARGET_DIR/node_modules/$dep" ] && echo "  ⚠️  缺失: $dep" && BOK=false; done
    $BOK && echo "  ✅ bundled 依赖完整"
fi

if [ "$PREFLIGHT_OK" != "true" ]; then
    echo ""; echo "❌ 验证未通过"
    echo "QQBOT_NEW_VERSION=unknown"; echo "QQBOT_REPORT=⚠️ 验证未通过"
    exit 1
fi
echo "  ✅ 验证全部通过"

# 轻量健康检查
echo ""
echo "  [健康检查] 确认插件注册..."
ensure_valid_cwd
PLIST="$(run_with_timeout 10 "plugins list" openclaw plugins list 2>&1 || true)"
echo "$PLIST" | grep -q "$PLUGIN_ID" && echo "  ✅ 插件已注册" || \
    echo "  ⚠️  未在 plugins list 中找到（非致命，重启后可能自动修复）"

# postinstall SDK link（原生 install 路径已由 openclaw 处理，npm pack 降级路径已在函数内处理，
#   这里再执行一次确保覆盖 update 路径——update 不会执行 lifecycle scripts）
if [ -f "$TARGET_DIR/scripts/postinstall-link-sdk.js" ]; then
    echo "  执行 postinstall-link-sdk..."
    ensure_valid_cwd
    node "$TARGET_DIR/scripts/postinstall-link-sdk.js" 2>&1 && echo "  ✅ SDK 链接就绪" || \
        echo "  ⚠️  postinstall-link-sdk 失败（非致命）"
fi

# ============================================================================
#  [3/4] 升级结果
# ============================================================================
echo ""
echo "[3/4] 升级结果..."
echo "QQBOT_NEW_VERSION=${NEW_VERSION:-unknown}"
[ -n "$NEW_VERSION" ] && [ "$NEW_VERSION" != "unknown" ] && \
    echo "QQBOT_REPORT=✅ QQBot 升级完成: v${NEW_VERSION}" || \
    echo "QQBOT_REPORT=⚠️ 无法确认新版本"

echo ""
echo "==========================================="
echo "  ✅ 安装完成"
echo "==========================================="

[ "$NO_RESTART" = "true" ] && echo "" && echo "[跳过重启] --no-restart 已指定" && exit 0

# ============================================================================
#  [配置] appid/secret
# ============================================================================
if [ -n "$APPID" ] && [ -n "$SECRET" ]; then
    echo ""
    echo "[配置] 写入 qqbot 通道配置..."
    DESIRED="${APPID}:${SECRET}"
    CURRENT=""
    [ -f "$CONFIG_FILE" ] && CURRENT=$(node -e "
        try {
            const cfg = JSON.parse(require('fs').readFileSync('$CONFIG_FILE', 'utf8'));
            for (const k of ['qqbot','openclaw-qqbot','openclaw-qq']) {
                const ch = cfg.channels?.[k]; if (!ch) continue;
                if (ch.token) { process.stdout.write(ch.token); break; }
                if (ch.appId && ch.clientSecret) { process.stdout.write(ch.appId+':'+ch.clientSecret); break; }
            }
        } catch {}
    " 2>/dev/null || true)

    if [ "$CURRENT" = "$DESIRED" ]; then
        echo "  ✅ 配置已是目标值"
    elif [ -f "$CONFIG_FILE" ] && node -e "
        const fs = require('fs'), cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
        (cfg.channels ??= {}).qqbot = { ...cfg.channels.qqbot, appId: '$APPID', clientSecret: '$SECRET' };
        fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 4) + '\n');
    " 2>&1; then
        echo "  ✅ 通道配置写入成功"
    else
        echo "  ❌ 写入失败，请手动编辑 $CONFIG_FILE"
    fi
elif [ -n "$APPID" ] || [ -n "$SECRET" ]; then
    echo ""; echo "⚠️  --appid 和 --secret 必须同时提供"
fi

# ============================================================================
#  [4/4] 重启 gateway
# ============================================================================
echo ""

# startup-marker 防重复通知
if [ -n "$NEW_VERSION" ] && [ "$NEW_VERSION" != "unknown" ]; then
    MARKER_DIR="$OPENCLAW_HOME/qqbot/data"; mkdir -p "$MARKER_DIR"
    NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
    echo "{\"version\":\"$NEW_VERSION\",\"startedAt\":\"$NOW\",\"greetedAt\":\"$NOW\"}" > "$MARKER_DIR/startup-marker.json"
fi

echo "[重启] 重启 gateway..."
ensure_valid_cwd
GW_RC=0; run_with_timeout 90 "gateway restart" openclaw gateway restart 2>&1 || GW_RC=$?

if [ $GW_RC -eq 0 ]; then
    echo "  ✅ gateway 已重启"
    [ -n "$NEW_VERSION" ] && echo "" && echo "🎉 QQBot 插件已更新至 v${NEW_VERSION}，在线等候你的吩咐。"
else
    [ $GW_RC -eq 124 ] && echo "  ⏰ gateway restart 超时"
    echo "  ⚠️  重启失败，尝试 doctor --fix..."
    ensure_valid_cwd

    _bak=""; [ -f "$CONFIG_FILE" ] && _bak="$(mktemp "${TMPDIR:-/tmp}/.qqbot-pre-doctor-XXXXXX")" && cp -a "$CONFIG_FILE" "$_bak"
    run_with_timeout 30 "doctor --fix" openclaw doctor --fix 2>&1 | head -20 | sed 's/^/    /' || true

    if [ -n "$_bak" ] && [ -f "$_bak" ] && [ -f "$CONFIG_FILE" ]; then
        _damaged=$(node -e "
          try {
            const fs = require('fs');
            const b = JSON.parse(fs.readFileSync('$_bak','utf8')), a = JSON.parse(fs.readFileSync('$CONFIG_FILE','utf8'));
            if (b.channels?.qqbot && !a.channels?.qqbot) process.stdout.write('channels.qqbot');
            else if (b.plugins?.installs?.['$PLUGIN_ID'] && !a.plugins?.installs?.['$PLUGIN_ID']) process.stdout.write('installs');
            else if (b.plugins?.entries?.['$PLUGIN_ID'] && !a.plugins?.entries?.['$PLUGIN_ID']) process.stdout.write('entries');
          } catch {}
        " 2>/dev/null || true)
        [ -n "$_damaged" ] && echo "  ⚠️  doctor 误删 $_damaged，恢复中..." && cp -a "$_bak" "$CONFIG_FILE" && echo "  ✅ 已恢复"
        rm -f "$_bak" 2>/dev/null || true
    fi

    echo ""; echo "  [重试] gateway restart..."
    ensure_valid_cwd
    RR=0; run_with_timeout 90 "gateway restart (重试)" openclaw gateway restart 2>&1 || RR=$?
    if [ $RR -eq 0 ]; then
        echo "  ✅ 重启成功"
        [ -n "$NEW_VERSION" ] && echo "" && echo "🎉 QQBot 插件已更新至 v${NEW_VERSION}，在线等候你的吩咐。"
    else
        echo "  ❌ 仍无法重启，请手动排查:"
        echo "    openclaw doctor && openclaw gateway restart"
    fi
fi
