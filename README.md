# repo-subdir-mirror

把一个大型 GitHub monorepo（上游）里**某一个子目录**，镜像成你自己的一个只读仓库：
根目录就是那个子目录，每天自动同步；需要时一键把改动回馈成上游的 PR。

- 适用场景：你只想改大仓库里的一个小目录，不想 `git clone` 整个仓库。
- 上游**全程无感**：镜像配置（workflow、说明文档）永远不会回到上游。

## 它给你什么

```
上游 big-monorepo/               你的镜像仓库（必须 private）
  ├── backend/                     └── (根目录 = 上游某子目录的内容)
  ├── some/
  │     └── subdir/      ──镜像──▶   ├── src/
  └── ...                            └── .github/workflows/  (镜像专用，不回上游)
```

1. **每日同步**：`sync-upstream.yml` 用 `git filter-repo` 提取子目录，硬重置到镜像 `main`。
2. **回馈上游**：`sync-pr-to-upstream.yml` 手动触发，输入镜像 PR 号，把该 PR 的**每一个提交**
   逐条套用到上游子目录，推成上游的一个分支（同名分支可重复运行、就地刷新），你再去开/更新 PR。
3. **（可选）把子目录的 CI 搬进镜像**：`mirror-ci.sh` 从上游挑出与该子目录相关的
   workflow，自动改写后在镜像仓库里跑同样的检查，让你在提上游 PR 前就发现失败。

## 快速开始

前置：`git`、[`gh`](https://cli.github.com)（已 `gh auth login`）。

```bash
# 1) 只读预检（不写任何东西），确认参数与计划
./scripts/preflight.sh \
  --upstream-repo your-org/big-monorepo \
  --target-dir    path/to/subdir \
  --mirror-repo   yourname/mirror-repo

# 2) 一键搭建（只写你自己的镜像仓库，强制 private）
./scripts/setup.sh \
  --upstream-repo your-org/big-monorepo \
  --target-dir    path/to/subdir \
  --mirror-repo   yourname/mirror-repo \
  --cron "0 2 * * *"
```

然后到镜像仓库 **Settings → Secrets and variables → Actions** 添加 secret
`UPSTREAM_TOKEN`（对上游有写权限的 PAT，`contents: read/write`；仅回馈上游时用到）。

## 把子目录的 CI 搬进镜像仓库（可选，best-effort）

上游对 `path/to/subdir` 的那条 CI 检查（如 `frontend/workspace / Continuous Integration`），
可以在镜像仓库里跑同样的检查，让你**提上游 PR 前就发现失败**：

```bash
./scripts/mirror-ci.sh \
  --upstream-repo your-org/big-monorepo \
  --target-dir    path/to/subdir \
  --workflow      .github/workflows/xxx.yaml \
  [--workflow     .github/workflows/yyy.yaml] \
  [--out-dir ./.github/workflows] [--print]
```

它**只读上游**，产出：

- `./.github/workflows/mirror-*.yml`——改写后的**草稿**（自动把子目录前缀剥离为镜像根、
  把自托管 runner 换成 `ubuntu-latest`）。
- `MIRROR_CI_NOTES.md`——**人工确认清单**：逐条列出已自动改写（FIX）与必须人工处理
  （WARN：指向子目录之外的路径、`uses: ./...` 本地复用 workflow、私有 npm registry、
  secret、OIDC 等）的地方。

> 这是 **best-effort**：上游 CI 往往与 monorepo 深度耦合（依赖子目录之外的文件、内部 runner、
> Slack、私有包等），脚本只能机械改写一部分，**务必先 review 清单再提交**。
> 产物以 `mirror-` 前缀命名，日同步会自动保留它们、不会被每日 force 覆盖删除。

## 作为 Agent 技能使用

本目录同时是一个 agent skill：把整个 `repo-subdir-mirror/` 放到
`<workspace>/.trae/skills/repo-subdir-mirror/`（或全局 skills 目录），
让 agent 读 `SKILL.md`，它就能按流程自动收集参数、预检、一键搭建。

## 目录结构

```
repo-subdir-mirror/
├── SKILL.md                              # agent 执行手册
├── README.md
├── assets/
│   ├── sync-upstream.yml.tmpl            # 每日同步 workflow
│   ├── sync-pr-to-upstream.yml.tmpl      # PR → 上游 workflow
│   └── SUBTREE_PR.md.tmpl                # 镜像仓库内的操作说明
└── scripts/
    ├── preflight.sh                      # 只读预检
    ├── setup.sh                          # 一键搭建
    └── mirror-ci.sh                      # 把子目录 CI 搬进镜像（best-effort）
```

## 安全与边界

- **镜像仓库必须始终为 private（最重要）**：它含上游子目录的源代码，一旦 public 即等于
  源码外泄。`setup.sh` 强制以 private 创建；若复用到的仓库是 public 会**报错退出**；
  脚本不提供 public 选项。切勿把镜像仓库改为 public、fork 到公开位置或转发其内容。
- 上游**只读**：任何自动化都不向上游写入；推上游只由**人工手动**触发 workflow。
- 回馈上游时自动排除镜像专用文件，上游不会感知镜像的存在。
- 补丁应用失败会**报错停止**，绝不静默覆盖上游代码。

## 设计要点（为什么这么做）

- **逐条 commit 搬运**：回馈上游用 `git format-patch`（按提交拆分）+ `git am --directory=<subdir>`，
  保留每个提交及其提交信息/作者；镜像专用文件被 pathspec 排除。
- **固定分支名 + lease 幂等更新**：上游目标分支默认 `mirror-pr-<PR号>`；重跑时用
  `ls-remote` 取远端 SHA 做 `--force-with-lease` **就地更新**，同一个上游 PR 自动刷新、不新建分支。
- **force 前保留镜像专用文件**：否则日同步会把 workflow 自己和说明文档删掉（自毁）；
  搬进来的 `mirror-*` 前缀 CI workflow 也会被自动保留。
- **稀疏克隆**：`--filter=blob:none --sparse --depth 1` 只取目标子目录，节省磁盘与时间。
