#!/usr/bin/env bash
# setup.sh —— 一键搭建“子目录镜像仓库”。
#
# 只会写你自己的镜像仓库（创建仓库、推镜像专用文件、触发一次同步）。
# 全程不向上游仓库写任何内容；推上游只在你日后手动运行 PR workflow 时才发生。
#
# 【安全铁律】镜像仓库必须始终为 PRIVATE。它包含上游子目录的源代码，
#   一旦 public 即等于源码外泄。本脚本强制 private，不提供 public 选项；
#   若复用到的仓库当前是 public，脚本会直接报错退出。
#
# 用法：
#   scripts/setup.sh \
#     --upstream-repo your-org/big-monorepo \
#     --target-dir    path/to/subdir \
#     --mirror-repo   yourname/mirror-repo \
#     [--upstream-branch main] [--mirror-branch main] \
#     [--account yourname] \
#     [--cron "0 2 * * *"] \
#     [--no-sync] [--yes]
#
# 注意：token 只通过 http.extraheader 传给 git，不写进 URL / .git/config，也不打印。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/../assets" && pwd)"

UPSTREAM_REPO=""
UPSTREAM_BRANCH="main"
TARGET_DIR=""
MIRROR_REPO=""
MIRROR_BRANCH="main"
ACCOUNT=""
CRON="0 2 * * *"
RUN_SYNC=1
ASSUME_YES=0

die() { echo "错误：$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream-repo) UPSTREAM_REPO="${2:-}"; shift 2 ;;
    --upstream-branch) UPSTREAM_BRANCH="${2:-}"; shift 2 ;;
    --target-dir) TARGET_DIR="${2:-}"; shift 2 ;;
    --mirror-repo) MIRROR_REPO="${2:-}"; shift 2 ;;
    --mirror-branch) MIRROR_BRANCH="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --cron) CRON="${2:-}"; shift 2 ;;
    --visibility) die "镜像仓库必须为 private，不接受 --visibility（防止源码外泄）" ;;
    --no-sync) RUN_SYNC=0; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '11,21p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

[[ -n "$UPSTREAM_REPO" ]] || die "缺少 --upstream-repo"
[[ -n "$TARGET_DIR"    ]] || die "缺少 --target-dir"
[[ -n "$MIRROR_REPO"   ]] || die "缺少 --mirror-repo"
# 统一去掉用户可能误加的首尾斜杠（模板里 __TARGET_DIR__/ 的写法依赖它没有尾斜杠）。
TARGET_DIR="${TARGET_DIR#/}"
TARGET_DIR="${TARGET_DIR%/}"
[[ -n "$TARGET_DIR" ]] || die "--target-dir 不能为空或仅是斜杠"
[[ "$MIRROR_REPO" != "$UPSTREAM_REPO" ]] || die "mirror-repo 不能等于 upstream-repo"
[[ -d "$ASSETS_DIR" ]] || die "找不到 assets 目录：$ASSETS_DIR"

# 选择 gh 账号（可选）。
if [[ -n "$ACCOUNT" ]]; then
  TOKEN=$(gh auth token --user "$ACCOUNT" 2>/dev/null) || die "gh 未登录账号 $ACCOUNT"
  export GH_TOKEN="$TOKEN"
fi
command -v gh >/dev/null 2>&1 || die "缺少 gh CLI"
gh auth status >/dev/null 2>&1 || die "gh 未登录，请先运行 gh auth login"
TOKEN="${GH_TOKEN:-$(gh auth token)}"
[[ -n "$TOKEN" ]] || die "无法获取 gh token"

# 用 http.extraheader 传凭据：token 不会出现在 URL、远程配置或输出里。
AUTH_HEADER="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"

echo "即将搭建镜像仓库："
echo "  上游        : $UPSTREAM_REPO @ $UPSTREAM_BRANCH  →  目录 $TARGET_DIR"
echo "  镜像仓库    : $MIRROR_REPO（强制 private）  main 分支"
echo "  同步 cron   : $CRON"
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "确认继续？(y/N) " ans
  [[ "$ans" = "y" || "$ans" = "Y" ]] || die "已取消"
fi

# 渲染模板：把 __PLACEHOLDER__ 替换为实际值。
render() { # render <tmpl> <out>
  local tmpl="$1" out="$2"
  sed \
    -e "s|__UPSTREAM_REPO__|${UPSTREAM_REPO}|g" \
    -e "s|__UPSTREAM_BRANCH__|${UPSTREAM_BRANCH}|g" \
    -e "s|__TARGET_DIR__|${TARGET_DIR}|g" \
    -e "s|__MIRROR_REPO__|${MIRROR_REPO}|g" \
    -e "s|__MIRROR_BRANCH__|${MIRROR_BRANCH}|g" \
    -e "s|__CRON__|${CRON}|g" \
    "$tmpl" > "$out"
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo
echo "[1/4] 创建或复用镜像仓库 $MIRROR_REPO ..."
if gh api "repos/${MIRROR_REPO}" --jq .full_name >/dev/null 2>&1; then
  VIS=$(gh api "repos/${MIRROR_REPO}" --jq .visibility 2>/dev/null || echo unknown)
  if [[ "$VIS" != "private" ]]; then
    die "镜像仓库 $MIRROR_REPO 当前可见性是 '$VIS'。镜像仓库必须为 private（含上游源码，public 即外泄），请先改为 private 再运行。"
  fi
  echo "      已存在且为 private，复用。"
else
  gh repo create "$MIRROR_REPO" --private \
    --description "Read-only mirror of ${UPSTREAM_REPO}/${TARGET_DIR}" >/dev/null
  echo "      已创建（private）。"
fi

echo "[2/4] 克隆镜像仓库并渲染镜像专用文件 ..."
git -c http.extraheader="$AUTH_HEADER" clone "https://github.com/${MIRROR_REPO}.git" "$WORK/repo"
cd "$WORK/repo"
if ! git rev-parse --verify -q HEAD >/dev/null; then
  git switch -c "$MIRROR_BRANCH"   # 空仓库：建立初始分支
fi
mkdir -p .github/workflows
render "${ASSETS_DIR}/sync-upstream.yml.tmpl"        ".github/workflows/sync-upstream.yml"
render "${ASSETS_DIR}/sync-pr-to-upstream.yml.tmpl"  ".github/workflows/sync-pr-to-upstream.yml"
render "${ASSETS_DIR}/SUBTREE_PR.md.tmpl"            "SUBTREE_PR.md"

git add -A
if git diff --cached --quiet && git rev-parse --verify -q HEAD >/dev/null; then
  echo "      无变化，跳过提交。"
else
  git -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
      -c user.name="github-actions[bot]" \
      commit -m "chore: bootstrap subdir mirror for ${UPSTREAM_REPO}/${TARGET_DIR}"
fi

echo "[3/4] 推送到 $MIRROR_REPO:$MIRROR_BRANCH ..."
git -c http.extraheader="$AUTH_HEADER" push origin "$MIRROR_BRANCH"

echo "[4/4] 触发一次同步（把上游 $TARGET_DIR 拉进 main）..."
if [[ "$RUN_SYNC" -eq 1 ]]; then
  gh workflow run sync-upstream.yml --repo "$MIRROR_REPO" --ref "$MIRROR_BRANCH" \
    && echo "      已触发。可在 Actions 页面查看进度。" \
    || echo "      触发失败（可稍后手动运行 Sync upstream subdirectory）。"
else
  echo "      已按 --no-sync 跳过。请稍后手动运行 Sync upstream subdirectory。"
fi

cat <<EOF

完成。后续步骤：
  0. 【安全】确认 $MIRROR_REPO 保持 private。它含上游 $UPSTREAM_REPO 的源码，
     切勿改为 public，也不要把它 fork 或转发到任何公开位置。
  1. 到 $MIRROR_REPO → Settings → Secrets and variables → Actions，
     添加 secret：UPSTREAM_TOKEN（对 $UPSTREAM_REPO 有写权限的 PAT）。
     只有“把镜像 PR 同步到上游”这一步需要它；日同步本身不需要。
  2. 等首次同步跑完，clone 你的镜像仓库即可开始开发：
       git clone https://github.com/${MIRROR_REPO}.git
  3. 详细开发/PR 流程见镜像仓库根目录的 SUBTREE_PR.md。
EOF
