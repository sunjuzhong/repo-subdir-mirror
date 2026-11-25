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

## 硬约束（务必遵守）

1. **镜像仓库必须始终为 private，绝不允许 public。** 它是上游子目录源代码的完整副本，
   一旦 public 即等于源码外泄。创建时强制 private；绝不可把镜像仓库改为 public、fork
   到公开位置或转发其内容。若用户要求把镜像仓库设为 public，**拒绝并说明风险**。
2. **上游全程只读**。任何自动化都不得向上游写入、开 PR 或推送。
3. **推上游只能由人工手动触发**：本 skill 只生成 workflow；实际触发由用户在自己仓库
   的 Actions 页面手动执行，agent 不要代为触发写上游的 workflow。
4. **不要把用户的业务流程相关文件带到上游**：镜像专用文件
   （`.github/workflows/*`、`SUBTREE_PR.md`）在回馈上游时必须被排除，让上游无感。
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

## 日常使用（写进镜像仓库的 SUBTREE_PR.md，此处速览）

- `main` 是只读镜像，每天被 force 重置 → **开发必须从 `main` 开功能分支**。
- 真正的合并发生在上游；改动经 PR 合入上游后，由日同步单向带回镜像 `main`。
- 回馈上游：合并镜像 PR 后，手动运行上游镜像仓库的
  `Sync a mirror PR to upstream branch` workflow，填 `pr_number`。
  它按“两棵树直接 diff”取净改动（排除镜像专用文件），以 `target-dir/` 前缀
  `git apply` 到上游，推送到上游**新分支**，并给出开 PR 的 compare 链接。
  冲突会报错停止，不会静默覆盖上游。

## 生成物说明（本 skill 的 assets）

| 文件 | 作用 |
|------|------|
| `assets/sync-upstream.yml.tmpl` | 每日把上游子目录 `git filter-repo` 到镜像 `main`；force 推送前保留镜像专用文件，防止自毁 |
| `assets/sync-pr-to-upstream.yml.tmpl` | 手动触发：把某个镜像 PR 的改动推成上游新分支 |
| `assets/SUBTREE_PR.md.tmpl` | 镜像仓库里的开发/PR 操作说明 |

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
- **`git apply` 冲突**：上游子目录已有不兼容改动；让用户把镜像分支 rebase 到最新 `main` 后重试。
- **PR 补丁为空**：镜像 PR 相对 `main` 无净改动（`main` 是只读镜像，改动须在功能分支上）。
