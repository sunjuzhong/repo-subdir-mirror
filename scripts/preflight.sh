#!/usr/bin/env bash
# preflight.sh —— 只读前置检查：确认搭建镜像仓库所需的一切条件就绪。
# 不做任何写操作（不建仓库、不推送、不改上游），只打印结论与“将要执行”的计划。
#
# 用法：
#   scripts/preflight.sh \
#     --upstream-repo your-org/big-monorepo \
#     --target-dir    path/to/subdir \
#     --mirror-repo   yourname/mirror-repo \
#     [--upstream-branch main] \
#     [--account yourname] \
#     [--cron "0 2 * * *"]
set -euo pipefail

UPSTREAM_REPO=""
UPSTREAM_BRANCH="main"
TARGET_DIR=""
MIRROR_REPO=""
ACCOUNT=""
CRON="0 2 * * *"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream-repo) UPSTREAM_REPO="${2:-}"; shift 2 ;;
    --upstream-branch) UPSTREAM_BRANCH="${2:-}"; shift 2 ;;
    --target-dir) TARGET_DIR="${2:-}"; shift 2 ;;
    --mirror-repo) MIRROR_REPO="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --cron) CRON="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

fail=0
ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [warn] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=1; }

echo "== 环境检查 =="
command -v git >/dev/null 2>&1 && ok "git 已安装（$(git --version)）" || bad "缺少 git"
command -v gh  >/dev/null 2>&1 && ok "gh 已安装（$(gh --version | head -1)）" || bad "缺少 gh（https://cli.github.com）"
command -v python3 >/dev/null 2>&1 && ok "python3 已安装" || warn "缺少 python3（仅本地渲染模板需要）"

echo
echo "== 参数校验 =="
[[ -n "$UPSTREAM_REPO" ]] && ok "upstream-repo = $UPSTREAM_REPO" || bad "缺少 --upstream-repo"
[[ -n "$TARGET_DIR"    ]] && ok "target-dir    = $TARGET_DIR"    || bad "缺少 --target-dir"
[[ -n "$MIRROR_REPO"   ]] && ok "mirror-repo   = $MIRROR_REPO"   || bad "缺少 --mirror-repo"
ok "upstream-branch = $UPSTREAM_BRANCH"
ok "cron            = $CRON"
if [[ "$MIRROR_REPO" == "$UPSTREAM_REPO" ]]; then
  bad "mirror-repo 不能等于 upstream-repo（镜像必须是你自己的仓库）"
fi

# 选择 gh 账号（可选）。
if [[ -n "$ACCOUNT" ]]; then
  echo
  echo "== gh 账号 =="
  if TOKEN=$(gh auth token --user "$ACCOUNT" 2>/dev/null); then
    export GH_TOKEN="$TOKEN"
    ok "已路由到账号 $ACCOUNT"
  else
    bad "gh 未登录账号 $ACCOUNT（先运行: gh auth login）"
  fi
fi

if command -v gh >/dev/null 2>&1; then
  echo
  echo "== gh 登录状态 =="
  if gh auth status >/dev/null 2>&1; then
    ok "gh 已登录：$(gh api user --jq .login 2>/dev/null || echo unknown)"
  else
    bad "gh 未登录（运行: gh auth login）"
  fi
fi

# 上游可读性 + 目标目录存在性（只读，不写）。
if command -v gh >/dev/null 2>&1 && [[ -n "$UPSTREAM_REPO" && -n "$TARGET_DIR" ]] && gh auth status >/dev/null 2>&1; then
  echo
  echo "== 上游检查（只读） =="
  if gh api "repos/${UPSTREAM_REPO}" --jq .full_name >/dev/null 2>&1; then
    ok "上游仓库可读：$UPSTREAM_REPO"
    if gh api "repos/${UPSTREAM_REPO}/contents/${TARGET_DIR}?ref=${UPSTREAM_BRANCH}" --jq .name >/dev/null 2>&1; then
      ok "目标目录存在：$TARGET_DIR @ $UPSTREAM_BRANCH"
    else
      bad "上游分支 $UPSTREAM_BRANCH 下找不到目录 $TARGET_DIR"
    fi
  else
    bad "无法读取上游仓库 $UPSTREAM_REPO（检查拼写或 token 权限）"
  fi
fi

# 镜像仓库可用性（强制 private）。
if command -v gh >/dev/null 2>&1 && [[ -n "$MIRROR_REPO" ]] && gh auth status >/dev/null 2>&1; then
  echo
  echo "== 镜像仓库检查 =="
  if gh api "repos/${MIRROR_REPO}" --jq .full_name >/dev/null 2>&1; then
    MIRROR_VIS=$(gh api "repos/${MIRROR_REPO}" --jq .visibility 2>/dev/null || echo unknown)
    if [[ "$MIRROR_VIS" = "public" ]]; then
      bad "镜像仓库 $MIRROR_REPO 当前是 public —— 含上游源码，必须设为 private 后才能继续"
    else
      warn "镜像仓库已存在：$MIRROR_REPO（$MIRROR_VIS，setup 将复用）"
    fi
  else
    ok "镜像仓库名可用（setup 将创建，强制 private）：$MIRROR_REPO"
  fi
fi

echo
echo "== 计划（setup.sh 将执行，均只作用于你的镜像仓库） =="
cat <<EOF
  1. 创建/复用镜像仓库     : $MIRROR_REPO（强制 private）
  2. 渲染并提交镜像专用文件 : .github/workflows/sync-upstream.yml
                            .github/workflows/sync-pr-to-upstream.yml
                            SUBTREE_PR.md
  3. 触发一次同步，把上游 $UPSTREAM_REPO:$UPSTREAM_BRANCH 的 $TARGET_DIR 拉到 main
  4. 之后每天按 cron（$CRON）自动同步
  注：向上游推送只发生在你手动运行 “Sync a mirror PR to upstream branch” 时。
EOF

echo
if [[ "$fail" -eq 0 ]]; then
  echo "结论：前置条件就绪，可以运行 setup.sh。"
else
  echo "结论：存在未通过项，请先修复再运行 setup.sh。" >&2
  exit 1
fi
