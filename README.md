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
2. **回馈上游**：`sync-pr-to-upstream.yml` 手动触发，输入镜像 PR 号，把改动套用到上游子目录，
   推成上游的一个新分支，你再去开 PR。

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
    └── setup.sh                          # 一键搭建
```

## 安全与边界

- **镜像仓库必须始终为 private（最重要）**：它含上游子目录的源代码，一旦 public 即等于
  源码外泄。`setup.sh` 强制以 private 创建；若复用到的仓库是 public 会**报错退出**；
  脚本不提供 public 选项。切勿把镜像仓库改为 public、fork 到公开位置或转发其内容。
- 上游**只读**：任何自动化都不向上游写入；推上游只由**人工手动**触发 workflow。
- 回馈上游时自动排除镜像专用文件，上游不会感知镜像的存在。
- 补丁应用失败会**报错停止**，绝不静默覆盖上游代码。

## 设计要点（为什么这么做）

- **两棵树直接 diff**：镜像 `main` 每天被 force 重置，历史对不上，不能用 merge-base；
  改为直接 diff 镜像 PR 与 `main` 两棵树取净改动。
- **`git apply --directory=<subdir>`**：给补丁所有路径加子目录前缀，把镜像根树铺回上游子目录。
- **force 前保留镜像专用文件**：否则日同步会把 workflow 自己和说明文档删掉（自毁）。
- **稀疏克隆**：`--filter=blob:none --sparse --depth 1` 只取目标子目录，节省磁盘与时间。
