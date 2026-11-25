---
name: repo-subdir-mirror
description: Set up and operate a read-only GitHub mirror repository that tracks a single subdirectory of a larger upstream monorepo. Use when the user wants to work on one subdirectory of a big repo without cloning the whole thing, wants a daily-synced mirror of a subdirectory, or wants to push changes from that mirror back to the upstream as a PR.
---

# Repo Subdir Mirror

为一个大型上游仓库（monorepo）的**单个子目录**，在你的账号下建一个只读镜像仓库：
根目录 = 该子目录内容，每天定时自动同步；需要回馈上游时，用一条手动触发的
workflow 把某个镜像 PR 的改动套用到上游子目录并推成上游的新分支。

## 何时使用

- 用户只想改上游大仓库里的某一个子目录，不想克隆/检出整个大仓库。
- 用户要一个“某子目录的每日自动镜像”。
- 用户想把自己在镜像仓库里的改动，以 PR 形式回馈到上游。
- 用户希望在自己镜像仓库里的 PR 也跑上游对该子目录的 CI 检查（见第 5 步，best-effort）。

## 硬约束（务必遵守）

1. **镜像仓库必须始终为 private，绝不允许 public。** 它是上游子目录源代码的完整副本，
   一旦 public 即等于源码外泄。创建时强制 private；绝不可把镜像仓库改为 public、fork
   到公开位置或转发其内容。若用户要求把镜像仓库设为 public，**拒绝并说明风险**。
2. **上游全程只读**。任何自动化都不得向上游写入、开 PR 或推送。
3. **推上游只能由人工手动触发**：本 skill 只生成 workflow；实际触发由用户在自己仓库
   的 Actions 页面手动执行，agent 不要代为触发写上游的 workflow。
4. **不要把用户的业务流程相关文件带到上游**：本 skill 生成的镜像专用文件
   （两个 `sync-*.yml`、`mirror-*` CI 草稿、`SUBTREE_PR.md`）在回馈上游时必须被排除，
   让上游无感。你在镜像里另外新建的其它 workflow 不在排除清单内，会随补丁落到
   `target-dir/.github/workflows/` 下（对上游通常无害，但请自行判断）。
5. 所有 workflow / secret 只放用户的镜像仓库，绝不放到上游。
6. token 不明文打印、不写入文件。

## 前置条件

- 已安装 `git` 与 `gh`（GitHub CLI），且 `gh auth login` 完成。
- 若目标 GitHub 账号非 gh 默认账号，需知道该账号名，用 `--account <name>` 指定。
  可用 `gh auth token --user <name>` 验证该账号存在。

## 操作流程

### 第 1 步：收集参数

向用户确认以下 5 个参数（缺一不可）：

| 参数 | 含义 | 示例 |
|------|------|------|
| `upstream-repo` | 上游仓库 `owner/repo` | `your-org/big-monorepo` |
| `upstream-branch` | 上游分支（默认 `main`） | `main` |
| `target-dir` | 要镜像的子目录（仓库内路径，不加首斜杠） | `path/to/subdir` |
| `mirror-repo` | 你自己的镜像仓库 `owner/repo`（**必须 private**） | `yourname/mirror-repo` |
| `cron` | 每日同步时间（cron，UTC） | `0 2 * * *` |

可选：`--account`（gh 账号名）。镜像仓库**强制 private**，脚本不提供 public 选项；
若传 `--visibility` 会被直接拒绝。

### 第 2 步：只读预检

先跑 preflight，把要执行的计划打印给用户确认（它不写任何东西）：

```bash
scripts/preflight.sh \
  --upstream-repo <owner/repo> \
  --target-dir    <sub/dir> \
  --mirror-repo   <you/mirror> \
  [--upstream-branch main] [--account <name>]
```

若出现 `[FAIL]`，先修复（多为 gh 未登录、目标目录不存在、仓库名冲突），不要继续。

### 第 3 步：一键搭建

参数与预检一致；把各自的真实值代入：

```bash
scripts/setup.sh \
  --upstream-repo <owner/repo> \
  --target-dir    <sub/dir> \
  --mirror-repo   <you/mirror> \
  [--upstream-branch main] [--account <name>] \
  [--cron "0 2 * * *"] [--yes]
```

`setup.sh` 会：创建/复用镜像仓库（**强制 private**，若复用到的仓库是 public 则报错退出）
→ 渲染并提交镜像专用文件 → 触发一次同步。它**只**写用户的镜像仓库，不碰上游。

### 第 4 步：交接给用户（一次性收尾）

提醒用户：

1. 到镜像仓库 Settings → Secrets and variables → Actions，
   添加 `UPSTREAM_TOKEN`：对上游有写权限的 PAT（fine-grained，`contents: read/write`）。
   仅“同步 PR 到上游”需要；日同步本身不需要。
2. 等首次 `Sync upstream subdirectory` 跑完，即可 `git clone` 镜像仓库开始开发。

### 第 5 步（可选）：把子目录的 CI 搬进镜像仓库（方案 B，best-effort）

当用户抱怨“推上游 PR 时撞上原仓库 actions 失败”“镜像里跑不了上游那条 CI”时，用
`scripts/mirror-ci.sh` 把上游对该子目录的 CI 搬到镜像里跑：

```bash
scripts/mirror-ci.sh \
  --upstream-repo <owner/repo> --target-dir <sub/dir> \
  --workflow .github/workflows/<该子目录的CI>.yaml \
  [--workflow ...] [--out-dir ./.github/workflows] [--prefix mirror-] [--account <name>] [--print]
```

它**只读上游**，产出 `./.github/workflows/mirror-*.yml`（草稿）与镜像仓库根目录的
`MIRROR_CI_NOTES.md`（人工确认清单；有 git 仓库时写到仓库根）。机械改写：子目录前缀 →
镜像根、自托管 runner → `ubuntu-latest`；无法机械处理的部分（指向子目录之外的路径、
`uses: ./...` 本地复用 workflow、私有 npm registry、secret、OIDC、多 job 依赖等）全部列进清单。
拉取阶段只要有一个 workflow 读不到就直接退出，不会留下半套草稿；本机装有 PyYAML 时
还会对改写结果做一次 YAML 语法自检（不合法只记 WARN）。

**必须做的事**：把清单里的 FIX/WARN/INFO 原样呈现给用户，让他逐条确认后再提交。
这是 best-effort，产物是草稿，**不要**声称“已完全等价于上游 CI”。草稿以 `mirror-`
前缀命名，日同步会自动保留（见 `sync-upstream.yml` 的 `mirror-*` 保留逻辑）。

## 日常使用（写进镜像仓库的 SUBTREE_PR.md，此处速览）

- `main` 是只读镜像，每天被 force 重置 → **开发必须从 `main` 开功能分支**。
- 真正的合并发生在上游；改动经 PR 合入上游后，由日同步单向带回镜像 `main`。
- 回馈上游：合并镜像 PR 后，手动运行上游镜像仓库的
  `Sync a mirror PR to upstream branch` workflow，填 `pr_number`。
  它把该 PR 的**每个提交**逐条生成补丁（排除镜像专用文件），以 `target-dir/` 前缀
  `git am` 到上游，推送到上游分支 `mirror-pr-<PR号>`，并给出开 PR 的 compare 链接。
  冲突会报错停止，不会静默覆盖上游。**同一 PR 重复运行会就地刷新同名分支**
  （`--force-with-lease`），已开的上游 PR 自动更新、不新建分支。
  `target_branch` 不能填上游主分支（填了会直接拒绝），分支名不合法也会被拦下。
- 若某天上游把 `target-dir` 改名/删除，同步任务会在 force 推送前发现“过滤结果为空”
  并**报错退出**，不会把镜像 `main` 清空。

## 生成物说明（本 skill 的 assets）

| 文件 | 作用 |
|------|------|
| `assets/sync-upstream.yml.tmpl` | 每日把上游子目录 `git filter-repo` 到镜像 `main`；force 推送前保留镜像专用文件（含 `mirror-*`）防止自毁 |
| `assets/sync-pr-to-upstream.yml.tmpl` | 手动触发：把某个镜像 PR 的每个提交逐条推成/更新上游分支 |
| `assets/SUBTREE_PR.md.tmpl` | 镜像仓库里的开发/PR 操作说明 |

脚本：

| 文件 | 作用 |
|------|------|
| `scripts/preflight.sh` | 只读预检（含镜像仓库强制 private 校验） |
| `scripts/setup.sh` | 一键搭建（强制 private） |
| `scripts/mirror-ci.sh` | 方案 B：把子目录 CI 搬进镜像（best-effort 草稿 + 人工确认清单） |

模板占位符：`__UPSTREAM_REPO__` `__UPSTREAM_BRANCH__` `__TARGET_DIR__`
`__MIRROR_REPO__` `__MIRROR_BRANCH__` `__CRON__`，由 `setup.sh` 渲染。

## 排错

- **镜像仓库被误设为 public**：立即到 Settings → General → Danger Zone 改回 private。
  GitHub 不会自动撤回已被抓取的内容，应视同已泄露并按需作废相关凭据。
- **同步超时 / No space left on device**：大 monorepo 克隆吃磁盘；两个 workflow 已内置
  “清理预装 SDK”步骤，必要时再删更多预装组件。
- **workflow 自己消失**：日同步用 `--force` 覆盖 `main`，务必确保 force 前用
  `git restore --source=dest/main` 把 `.github/workflows/*` 和 `SUBTREE_PR.md` 带回来
  （模板已含此步骤，勿删）。
- **`git filter-repo` 报路径错误**：`--path-rename` 目标为根目录写 `dir/:`，不要写 `dir/:/`。
- **`git am` 冲突**：上游子目录已有不兼容改动（或该 PR 已被合并）；让用户把镜像分支
  rebase 到最新 `main` 后重试。模板捕获失败后会 `git am --abort` 并报错停止，不会留下半套改动。
- **日同步报“过滤结果为空”**：上游把 `target-dir` 改名/删除，或参数写错。同步会中止、
  镜像 `main` 保持原状；确认新路径后用新参数重新渲染 workflow（重跑 `setup.sh`）即可。
- **保留了 `mirror-*` 却不见了**：`git ls-tree` 的 pathspec **不支持通配符**，模板因此
  先取 `.github/workflows` 目录再按 `mirror-` 前缀过滤；若你自行改过这一步，注意别写回
  `git ls-tree ... -- '.github/workflows/mirror-*'`（会静默匹配不到）。
- **搬进来的 CI workflow 消失了**：日同步只保留文件名以 `mirror-` 前缀的 workflow；
  用 `mirror-ci.sh` 产出的草稿天然带此前缀。若你手动改名去掉了前缀，请加回或加入保留清单。
- **PR 补丁为空 / 重跑后上游 PR 未更新**：补丁为空说明 PR 相对 `main` 无净改动（改动须在
  功能分支上）；重跑未更新则确认两次填写的 `target_branch` 是否一致、上游分支是否被他人改过
  （`--force-with-lease` 会因此拒绝）。
