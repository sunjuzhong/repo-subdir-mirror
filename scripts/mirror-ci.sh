#!/usr/bin/env bash
# mirror-ci.sh —— 方案 B（best-effort）：把上游“某子目录”的 CI workflow 搬进镜像仓库。
#
# 只读上游。产出一份【草稿 workflow + 人工确认清单】：
#   - 机械改写：把子目录前缀剥离为镜像根（因为镜像根 == 该子目录）、
#              把自托管 runner 换成 ubuntu-latest。
#   - 无法机械处理的地方（指向子目录之外的路径、本地复用 workflow `./.github/...`、
#     私有 npm registry / secret、OIDC、多 job 依赖等）全部列进清单，需你人工确认。
#
# 它绝不向上游写入、也不提交/推送任何东西；产物落在本地，review 后再提交。
#
# 用法：
#   scripts/mirror-ci.sh \
#     --upstream-repo <owner/repo> \
#     --target-dir    <sub/dir> \
#     --workflow      .github/workflows/xxx.yaml [--workflow ...] \
#     [--out-dir ./.github/workflows] [--prefix mirror-] \
#     [--account <gh账号>] [--print]
#
# 说明：产出的 workflow 命名以 mirror- 前缀开头；日同步 workflow 会自动保留
#       .github/workflows/mirror-* ，因此它们不会被每日 force 覆盖删除。
set -euo pipefail

die() { echo "错误：$*" >&2; exit 1; }

UPSTREAM_REPO=""
TARGET_DIR=""
OUT_DIR="./.github/workflows"
PREFIX="mirror-"
ACCOUNT=""
PRINT=0
WORKFLOWS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream-repo) UPSTREAM_REPO="${2:-}"; shift 2 ;;
    --target-dir)    TARGET_DIR="${2:-}"; shift 2 ;;
    --workflow)      WORKFLOWS+=("${2:-}"); shift 2 ;;
    --out-dir)       OUT_DIR="${2:-}"; shift 2 ;;
    --prefix)        PREFIX="${2:-}"; shift 2 ;;
    --account)       ACCOUNT="${2:-}"; shift 2 ;;
    --print)         PRINT=1; shift ;;
    -h|--help)       sed -n '3,21p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$UPSTREAM_REPO" ]] || die "缺少 --upstream-repo"
[[ -n "$TARGET_DIR" ]]    || die "缺少 --target-dir"
[[ ${#WORKFLOWS[@]} -gt 0 ]] || die "至少需要一个 --workflow"

# 允许用户误写的首尾斜杠：target-dir 统一去掉。
TARGET_DIR="${TARGET_DIR#/}"
TARGET_DIR="${TARGET_DIR%/}"
[[ -n "$TARGET_DIR" ]] || die "--target-dir 不能为空或仅是斜杠"

command -v gh >/dev/null 2>&1 || die "未找到 gh（GitHub CLI）"
command -v python3 >/dev/null 2>&1 || die "未找到 python3"

# 选定 gh 账号（可选）。
if [[ -n "$ACCOUNT" ]]; then
  TOK="$(gh auth token --user "$ACCOUNT" 2>/dev/null || true)"
  [[ -n "$TOK" ]] || die "无法获取账号 $ACCOUNT 的 token（gh auth token --user $ACCOUNT）"
  export GH_TOKEN="$TOK"
fi

# 临时区：失败/退出时一并清理，不在磁盘上留半套产物。
STAGE="$(mktemp -d)"
REPORT="$STAGE/report.md"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
: > "$REPORT"

{
  echo "# 搬入的 CI workflow —— 人工确认清单"
  echo
  echo "来源：\`${UPSTREAM_REPO}\`，子目录：\`${TARGET_DIR}\`"
  echo
  echo "> 本清单由 \`scripts/mirror-ci.sh\` 生成。**草稿仅供 review**，"
  echo "> 提交前请逐条确认 FIX / WARN / INFO，尤其是指向子目录之外的引用。"
  echo
} >> "$REPORT"

# ---- 第一阶段：先把所有 workflow 拉下来 ----
# 任何一个拉取失败就直接退出，避免只写出“半套”草稿。
SRC_FILES=()
WF_PATHS=()
for WF in "${WORKFLOWS[@]}"; do
  WF="${WF#./}"
  WF="${WF#/}"
  [[ -n "$WF" ]] || die "--workflow 不能为空"
  echo "== 拉取上游 ${WF} =="
  SRC="$STAGE/src-$(( ${#SRC_FILES[@]} + 1 )).yaml"
  if ! gh api "repos/${UPSTREAM_REPO}/contents/${WF}" \
         -H "Accept: application/vnd.github.raw" > "$SRC"; then
    die "读取上游 ${WF} 失败（路径是否正确？账号是否有权限？）"
  fi
  [[ -s "$SRC" ]] || die "上游 ${WF} 内容为空（是不是目录或文件不存在？）"
  SRC_FILES+=("$SRC")
  WF_PATHS+=("$WF")
done

# ---- 第二阶段：改写并落盘 ----
idx=0
while [[ "$idx" -lt "${#SRC_FILES[@]}" ]]; do
  SRC="${SRC_FILES[$idx]}"
  WF="${WF_PATHS[$idx]}"
  idx=$(( idx + 1 ))

  BASE="$(basename "$WF")"
  BASE="${BASE%.*}.yml"
  OUT_NAME="${PREFIX}${BASE}"

  echo "   改写中 -> ${OUT_NAME}"

  # 把转换逻辑放在这个函数里，供「写文件」与「--print」两条分支复用。
  run_transform() {
    python3 - "$1" "$2" "$REPORT" "$TARGET_DIR" "$UPSTREAM_REPO" "$WF" "$OUT_NAME" <<'PY'
import re, sys

src_path, out_path, report_path, target, upstream, wf_path, out_name = sys.argv[1:8]
text = open(src_path, encoding="utf-8").read()
target = target.strip("/")

fixes, warns, infos = [], [], []

# ---- 1) 自托管 runner -> ubuntu-latest ----
def runner_sub(m):
    indent, val = m.group(1), m.group(2).strip()
    if re.match(r'^(ubuntu|windows|macos)-', val) or val.startswith('${{') or val.startswith('['):
        return m.group(0)
    fixes.append(f"runs-on: `{val}` -> `ubuntu-latest`")
    return f"{indent}ubuntu-latest"
text = re.sub(r'^([ \t]*runs-on:[ \t]*)(.+?)[ \t]*$', runner_sub, text, flags=re.M)
for lst in re.findall(r'^[ \t]*runs-on:[ \t]*\[(.*?)\]', text, re.M):
    if 'self-hosted' in lst:
        warns.append(f"`runs-on: [{lst}]` 是列表形式且含自托管 runner，无法机械改写，请人工改为 `ubuntu-latest`。")

# ---- 2) working-directory 指向子目录 -> . ----
def wd_sub(m):
    indent, raw = m.group(1), m.group(2).strip()
    v = raw.strip('"\'')
    variants = {target, "./" + target, target + "/", "./" + target + "/"}
    if v in variants:
        fixes.append(f"working-directory: `{raw}` -> `.`")
        return f"{indent}."
    if v.startswith("./" + target + "/"):
        newv = "./" + v[len("./" + target + "/"):]
        fixes.append(f"working-directory: `{raw}` -> `{newv}`")
        return f"{indent}{newv}"
    if v.startswith(target + "/"):
        newv = "./" + v[len(target + "/"):]
        fixes.append(f"working-directory: `{raw}` -> `{newv}`")
        return f"{indent}{newv}"
    warns.append(f"step 的 `working-directory: {raw}` 指向子目录之外，镜像里不存在该路径，请人工删除或改写该 step。")
    return m.group(0)
text = re.sub(r'^([ \t]*working-directory:[ \t]*)(.+?)[ \t]*$', wd_sub, text, flags=re.M)

# ---- 3) 路径里的子目录前缀 -> 镜像根 ----
before = text
text = text.replace("./" + target + "/", "./")
text = text.replace('"' + target + "/", '"./')
text = text.replace("'" + target + "/", "'./")
text = text.replace(target + "/", "./")
# 独占一行的裸子目录（如 sparse-checkout 列表项） -> .
text = re.sub(r'^([ \t]*)' + re.escape(target) + r'[ \t]*$', r'\1.', text, flags=re.M)
if text != before:
    fixes.append(f"路径中的子目录前缀 `{target}/` 已改写为镜像根 `./`（含独占行的 `{target}` -> `.`）。")

# ---- 4) 警告扫描 ----
if re.search(r'uses:[ \t]*\./', text):
    warns.append("存在 `uses: ./...`（本地复用 workflow / 复合 action）。镜像里通常没有这些文件，"
                 "对应 step 或 job 需人工删除或替换。")
secs = sorted(set(re.findall(r'secrets\.([A-Za-z0-9_]+)', text)))
if secs:
    warns.append("引用了 secret：" + ", ".join(f"`{s}`" for s in secs) +
                 "。需在镜像仓库 Settings → Secrets 里配置同名 secret，否则该步骤会失败。")
if re.search(r'id-token|aws-actions|configure-aws-credentials|role-to-assume|OIDC', text, re.I):
    warns.append("涉及 OIDC / AWS 凭证：镜像仓库一般没有同样的 OIDC 信任，请人工移除或替换。")
if re.search(r'npm\.pkg\.github\.com|registry-url|NODE_AUTH_TOKEN', text):
    warns.append("使用 GitHub Packages（npm.pkg.github.com）。镜像仓库属主不同，默认 GITHUB_TOKEN "
                 "可能无权读取上游组织的私有包；通常需要配置一个有 read:packages 权限的 PAT 作为 secret。")
if re.search(r'^\s*sparse-checkout:', text, re.M):
    infos.append("含 `sparse-checkout`：其中可能引用了子目录之外的路径（镜像里不存在），请人工精简。")
if re.search(r'^\s*(paths|paths-ignore):', text, re.M):
    infos.append("含 `paths` / `paths-ignore` 过滤：这些 glob 按上游仓库布局书写，镜像里需 reconfirm。")
if 'merge_group' in text:
    infos.append("含 `merge_group` 触发：镜像仓库一般用不到，可保留或删除。")
if re.search(r'^\s*needs:', text, re.M):
    infos.append("含多 job 依赖（`needs`）/条件（`if`）：搬进镜像后请人工精简 job 图，"
                 "避免依赖已被删除的 job（如 check-paths / slack-*）。")
infos.append(f"路径替换是**字面量替换**，可能改到内嵌的正则/glob（如 `grep -E` 模式里的 `{target}/`），请人工核对。")
jobs_section = text.split("\njobs:", 1)
if len(jobs_section) == 2:
    jobs = re.findall(r'^  ([A-Za-z0-9_.-]+):[ \t]*$', jobs_section[1], re.M)
    if jobs:
        infos.append("包含的 job：" + ", ".join(f"`{j}`" for j in jobs) + "。")

# ---- 5) 组装输出 ----
header = (
    "# ⚠️ 由 repo-subdir-mirror skill 的 mirror-ci 生成的【草稿】（best-effort）。\n"
    f"# 来源：{upstream} : {wf_path}\n"
    f"# 已自动改写：自托管 runner -> ubuntu-latest；子目录前缀 `{target}/` -> 镜像根 `./`。\n"
    "# 提交前请先阅读 MIRROR_CI_NOTES.md 的清单并逐条确认。\n"
)
out_text = header + text

# ---- 6) 语法自检（装了 PyYAML 才做，失败只提示不阻断）----
try:
    import yaml
except ImportError:
    yaml = None
if yaml is not None:
    try:
        yaml.safe_load(out_text)
    except Exception as exc:
        warns.append(f"改写后的内容不是合法 YAML（{type(exc).__name__}），请人工检查缩进与结构。")

if out_path == "-":
    sys.stdout.write(out_text)
else:
    open(out_path, "w", encoding="utf-8").write(out_text)

with open(report_path, "a", encoding="utf-8") as r:
    r.write(f"## `{out_name}`（来源 `{wf_path}`）\n\n")
    if fixes:
        r.write("### 已自动改写（FIX）\n")
        for x in fixes:
            r.write(f"- {x}\n")
        r.write("\n")
    if warns:
        r.write("### 需人工处理（WARN）\n")
        for x in warns:
            r.write(f"- {x}\n")
        r.write("\n")
    if infos:
        r.write("### 请确认（INFO）\n")
        for x in infos:
            r.write(f"- {x}\n")
        r.write("\n")
    if not (fixes or warns or infos):
        r.write("_未发现需要处理的地方。_\n\n")

# 屏幕摘要
print(f"    FIX={len(fixes)} WARN={len(warns)} INFO={len(infos)}")
for x in fixes: print(f"      [FIX]  {x}")
for x in warns: print(f"      [WARN] {x}")
for x in infos: print(f"      [INFO] {x}")
PY
  }

  if [[ "$PRINT" -eq 1 ]]; then
    run_transform "$SRC" "-"
  else
    mkdir -p "$OUT_DIR"
    run_transform "$SRC" "$OUT_DIR/$OUT_NAME"
    echo "    已写入 $OUT_DIR/$OUT_NAME"
  fi
done

echo
if [[ "$PRINT" -eq 1 ]]; then
  echo "（--print 模式：未写任何文件）"
  echo "==================== 人工确认清单 ===================="
  cat "$REPORT"
else
  # 清单放在仓库根目录（有 git 仓库时用 toplevel，否则当前目录）。
  if NOTES_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    NOTES="${NOTES_ROOT}/MIRROR_CI_NOTES.md"
  else
    NOTES="./MIRROR_CI_NOTES.md"
  fi
  cp "$REPORT" "$NOTES"
  echo "已写出人工确认清单：$NOTES"
  echo "请 review 后自行 git add / commit（本脚本不提交、不推送、不碰上游）。"
fi
