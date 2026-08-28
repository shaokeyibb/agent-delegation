# agent-delegation

*[English](README.md) · [简体中文](README.zh-CN.md)*

**一个 Skill：教会你的 coding agent 把长活派给其它 agent CLI —— 并且事后能【证明】它们到底做了什么。**

你的 agent 早就会写代码。它不会的是：把三小时的活交给 `codex` 或 `cursor-agent`，转身去忙别的，
回来之后还能分清**跑完了**、**跑完了但什么都没产出**、**死在鉴权上**、以及**声称跑了一个它
根本没跑的测试**。这个 Skill 就是把这套本事打包起来。

装上之后，你的 agent 就有了一套可用的工作方法：把活隔离到 git worktree 里、派出后台 CLI 工作者、
盯住一份四文件哨兵，并且**凡是它自己能核的说法，一律不轻信**。

## 安装

```bash
npx skills add shaokeyibb/agent-delegation
```

常用参数：`-g` 装到用户目录而不是当前项目，`-a claude-code`（可重复）指定 agent，`-y` 跳过确认。

```bash
npx skills add shaokeyibb/agent-delegation -g -a claude-code -y
```

## 使用

**没有什么需要你去执行。** Skill 会在相关时自己加载 —— 你只管跟 agent 说事，它自己会用上：

> 「这个重构要好几个小时，开棵 worktree 派给 codex，回头再看。」

> 「codex 那边报 DONE，但我没看到任何产出。怎么回事？」

> 「复核方找出了三个真 bug，让它直接去修，别再写一份新任务书了。」

> 「它说自己加了四条锁。合入前先验一下。」

这四句分别落在 Skill 的不同部分：派发、诊断「报成功却没产出」的运行、把复核方续跑成修复方、
以及逼它把声称锁住的东西打破并展示变红。

### 配置

在 agent 派发之前先设好模型 —— **本 Skill 不内置任何模型 id**，因为 id 会变，而一个过期的默认值
**失败得很晚，看起来像任务问题而不是配置问题**。

| 变量 | 含义 |
|---|---|
| `AGENT_MODEL` | 所有通路共用的模型 id |
| `AGENT_MODEL_<AGENT>` | 单条通路覆盖，例如 `AGENT_MODEL_CODEX` |
| `AGENT_RUNS` | 哨兵目录（默认 `<repo>/.agent-runs/<agent>/`） |
| `AGENT_WATCH_INTERVAL` | 监视器轮询秒数（默认 20） |

自带的脚本就是普通的 bash 与 PowerShell —— 由你的 agent 调用，但你想手动跑也完全可以，
不需要任何 agent host。

## 你的 agent 会学到什么

**四条 CLI，一个接口。** `codex`、`cursor-agent`、`codebuddy`、`claude` 之间的差异，弄错了会
**静默失败** —— 只有一个是从 stdin 收任务书的，另外三个你要是把大段任务书当命令行参数传，
它们会**立刻返回、退出码 0**。这个 Skill 把这些差异抹平。

**一份可以读、而不是只能信的哨兵。** 每次运行都写 `.before`（树快照）、`.log`、`.out`（交付物），
以及 `.exit` —— 它**最后**才写，所以它的存在本身就是完成信号。`.out` 为空就是失败，
不管退出码说什么。

**一条规矩，其余都在为它服务：**

> **改了代码的那一次运行，永远不是给它签字的那一次。**

把**复核方**续跑成修复方是可以的 —— 它的复核在拿到写权限之前就已经写完并落盘了。
但再续跑一次让它给自己的修复背书，就不行。

**怎样不轻信一片绿的测试。** 一个什么都没锁住的锁，绿得和真锁一模一样。所以这个 Skill 会让 agent
去**打破那个不变量并展示它变红**，还要附 `git diff` 证明变异真的落到了文件上。

## 为什么会有它

把后台工作者启动起来是容易的，难的全在启动之后 —— 这里的每一道防线，都是因为它所防的那件事
真的发生过：

- 一棵 `.git` 指针丢失的 worktree 会**向上解析到主仓** —— 存在性检查照样通过，
  而派发进去就直接改了主干。
- 上游鉴权失败写出的是一份**完整**哨兵，所以它报 `DONE` 而不是 `DEAD`，
  唯一的信号是交付物为空。
- `git rebase` **不触发** pre-commit 钩子，所以「rebase 之后门禁是绿的」是一句空话 ——
  而且 rebase 保留 author date，时间戳看起来完全正常。
- 在移动的主干上做 `reset --soft`，暂存区可能悄悄含进**反转别人提交**的改动，而且不会有任何红灯。
- 静态门禁全绿和测试红完全可以共存，只要你是靠 grep import 来取消费面的。

## 里面有什么

```
SKILL.md              给你的 agent 读的操作指南
scripts/
  dispatch.sh/.ps1    派发（preflight + 哨兵）
  relay.sh/.ps1       在原会话里续跑一次已完成的运行
  watch.sh            跨全部 agent，每次运行输出一行状态
  watch-loop.sh       只输出状态变化，供常驻监视器使用
templates/
  brief.md            实现类任务书
  review.md           只读复核任务书
```

两种 shell 一视同仁：每个脚本都有行为一致的 `.sh` 与 `.ps1` 两份。

## 许可

MIT © HikariLan <i@hikarilan.life> —— 见 [LICENSE](LICENSE)。
