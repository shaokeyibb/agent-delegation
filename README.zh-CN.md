# agent-delegation

*[English](README.md) · [简体中文](README.zh-CN.md)*

**把任意 coding agent CLI 作为后台工作者派到 git worktree 上跑 —— 并且事后能【证明】它到底做了什么。**

`codex`、`cursor-agent`、`codebuddy`、`claude` 四条通路，一个入口。每次运行都写同一份四文件
哨兵，所以它的状态**从磁盘上就能答出来**，不必依赖 agent 对自己的复述。

## 为什么需要它

子代理（subagent）占用你的上下文预算和当前这一轮对话；后台 CLI 工作者两样都不占：它有自己的
窗口，在你这一轮结束后继续跑，代价只有你写的任务书和你读的结果。

难的从来不是把它启动起来，而是启动之后的一切：

- 一棵 `.git` 指针丢失的 worktree 会**向上解析到你的主仓** —— 存在性检查照样通过，而派发进去
  就直接改了主干。
- 把任务书当命令行参数传，某些 CLI 会**立刻返回**：日志几个字节、**退出码 0**，任何监视器都会
  把它报成成功。
- 上游鉴权失败写出的是一份**完整**哨兵，所以它报 `DONE` 而不是 `DEAD`。
- `git rebase` **不触发** pre-commit 钩子，所以「rebase 之后门禁是绿的」是一句空话 —— 而两边的
  提交时间戳看起来都很正常。
- 静态门禁全绿和测试红完全可以共存，只要你是靠 grep import 来取消费面的。
- 而一个什么都没锁住的锁，绿得和真锁一模一样。

这里的每一道防线，都是因为上面某一件事真的发生过。

## 快速开始

```bash
# 1. 为这次工作单独开一棵 worktree（永远不要往主干派）
git worktree add ../wt-feature -b feature/thing

# 2. 写任务书（templates/ 下有实现与复核两种起手模板）
cp ~/.agents/skills/agent-delegation/templates/brief.md /tmp/brief.md
$EDITOR /tmp/brief.md

# 3. 派发。模型是必填的 —— 本 skill 不内置任何模型 id
export AGENT_MODEL=<你的模型 id>
scripts/dispatch.sh --agent codex --name fixthing \
                    --worktree ../wt-feature --brief /tmp/brief.md

# 4. 一条命令看遍所有 agent 的所有运行
scripts/watch.sh
# DONE codex/fixthing exit=0 result=12268
# RUNNING cursor/probe log=48213

# 5. 读交付物 —— 通知只是指针，不是内容
cat ../.agent-runs/codex/fixthing.out

# 6. 复核方的结论【就是】下一件事时：续跑它的会话，别重新写一份任务书
scripts/relay.sh --agent codex --from review1 --name fix1 \
                 --worktree ../wt-feature --brief /tmp/fix.md
```

PowerShell 用户：每个脚本都有同名 `.ps1`，参数一致
（`dispatch.ps1 -Agent codex -Name fixthing -Worktree ..\wt-feature -Brief brief.md`）。

### 配置

| 变量 | 含义 |
|---|---|
| `AGENT_MODEL` | 所有通路共用的模型 id |
| `AGENT_MODEL_<AGENT>` | 单条通路覆盖，例如 `AGENT_MODEL_CODEX` |
| `AGENT_RUNS` | 哨兵目录（默认 `<repo>/.agent-runs/<agent>/`） |
| `AGENT_WATCH_INTERVAL` | `watch-loop.sh` 的轮询秒数（默认 20） |

## 唯一的那条规矩，其余都在为它服务

> **改了代码的那一次运行，永远不是给它签字的那一次。**

派**新的**运行去复核工作。把**复核方**续跑成修复方是可以的 —— 因为它的复核在拿到写权限之前
就已经写完并落盘了。但再续跑一次让它给自己的修复背书，就不行。

## 什么场景下最划算

**你装不进上下文的长重构。** 派出去、去做别的事、几小时后回来收货：拿现在的树对比派发那一刻
的快照 —— 一次悄悄装了 100 MB 依赖的运行，没法给你看一棵干净的树。

**不是走过场的复核。** 复核模板要求：把声称锁住的东西**打破**，并展示它变红，还要附
`git diff` 证明变异真的落到了文件上。它问的也是本源问题，而不是那个方便的代理指标 ——
*这条锁守的是哪个不变量？破坏它，有没有东西变红？* 数「要改几个地方」这种问法，对每一条
字符串断言都答「两个」，对每一条等值锁也都答「两个」。

**并行时有一本诚实的账。** 多个 agent 跑在多棵 worktree 上；`watch.sh` 对全部运行各输出一行，
并且能分开**跑完了但没产出**、**死在鉴权上**、**还在跑**这三种状态 —— 否则它们长得一模一样。

**抓住你自己任务书写错的地方。** 每份任务书都以「告诉我这份任务书哪里写错了」收尾。那些反驳
经常是对的，偶尔则是自信地错的 —— 所以本 skill 还告诉你要去核它：凡是一条命令能核的，自己核。

## 目录结构

```
agent-delegation/
├── SKILL.md              操作指南（主要内容在这里）
├── README.md / README.zh-CN.md
├── LICENSE               MIT
├── scripts/
│   ├── dispatch.sh/.ps1  派发（preflight + 哨兵）
│   ├── relay.sh/.ps1     在原会话里续跑一次已完成的运行
│   ├── watch.sh          跨全部 agent，每次运行输出一行状态
│   └── watch-loop.sh     只输出状态变化，供常驻监视器使用
└── templates/
    ├── brief.md          实现类任务书
    └── review.md         只读复核任务书
```

## 安装

放到任何你的 agent host 会发现 skill 的位置即可 —— 例如放在 `~/.agents/skills/` 再从
`~/.claude/skills/` 建一个符号链接，或者直接放进 `~/.claude/skills/`。脚本本身是独立的：
不需要任何 host，手动也能跑。

## 许可

MIT © HikariLan <i@hikarilan.life> —— 见 [LICENSE](LICENSE)。
