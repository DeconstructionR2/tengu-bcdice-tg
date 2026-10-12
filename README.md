# tengu-bcdice-tg

BCDice 全量规则系统 + 天狗ダイス忍杀全功能，跑在单一 Ruby 进程里的 Telegram 骰子 bot。

> 非官方移植版：Unofficial Telegram port of [TenguDiceBot](https://github.com/kooreme/TenguDiceBot) (Discord, MIT).

- BCDice 引擎进程内直调（100+ TRPG 规则系统，`bundle update bcdice` 零冲突可升级）
- 天狗ダイス（忍杀）全功能移植：NSRS 發狂表、カルマロンダリング×5 派阀、キャラメイク 6 表、聖戦判定、倍率/记忆符、1版 9 表
- 天狗银行（话题级账本）、自定义表（建/改/删/发布/掷）、暗骰（ephemeral + 公开按钮）、跑团 log 录制与导出（txt+json）
- SQLite 单文件 WAL 持久化；Docker 三阶段镜像（构建期跑全量测试作闸门）
- 测试基线：785 引擎层（722 TOML 数据用例 + 63 守卫测试）+ 863 bot/db 单元测试全绿（`bundle exec rake verify`）

## 命令速查

**主轨（slash，Telegram 菜单可点选）：**

| 命令 | 功能 |
|---|---|
| `/roll <式>` | 通用掷骰（当前作用域的规则系统） |
| `/nd <式>` | 忍杀 2 版直通（无视群设置，固定 NinjaSlayer2Ex） |
| `/system <ID>` | 切换规则系统；话题内打=仅本话题，话题外打=群默认 |
| `/secret <式>` / `/secret last` | 暗骰：ephemeral 仅本人可见 + 「公开」按钮；last 重取最近一次 |
| `/bank …` | 银行：`deposit/withdraw <金额>`、`item add/del <名>`、`balance`、`statement`（结算+清零）、`reset` |
| `/ct …` | 自定义表：`create/rename/dice set/dice del/data set/data del/range/perm/publish/delete/show/list/roll` |
| `/log new\|on\|off\|end\|list` | 跑团 log 录制；end 导出 txt+json 发回本群/话题 |
| `/settings` `/help` `/start` | 群设置（辅助轨开关等）与帮助 |

**辅助轨（裸打骰式，不用斜杠）**

群里直接发 `2d6>=4`、`N4,3`、`SB` 就能掷，不用加 `/`。只有整条消息长得像骰式才响应：中文、裸数字、骰式后面还跟了话（比如 `2d6 roll please`）都不命中，唯一的带空格形态是 repeat（`x3 2d6`）。每群可用 `/settings` 关掉。

两点容易误解：

- 辅助轨的闸门取四个忍杀系系统命令的并集，与当前系统无关。过闸只说明「语法像骰式」，是否真出结果取决于本群当前的规则系统。
- 默认 `NinjaSlayer2Ex` 下 `SBX`/`WSX`/`KRS`、`N5` 这类「难度字母+数字」会真掷表；切到 1 版 `NinjaSlayerEx` 后 `SOUL`/`WS`/`CYBER` 等词表命令也掷表。这些裸词和普通英文短词同形，命中就会应答，介意的话关掉辅助轨；反过来，`N4,3`/`NRS_E4` 这类 2 版命令在 1 版下静默。群切到 CoC 等其它系统后，该系统专属命令请走 `/roll`。这是刻意取舍：宁漏不抢。

日文表名一律不是命令（Telegram slash 只允许拉丁字符，纯 ASCII 定案）。

## 架构

```
Telegram 群/超级群（forum 话题感知）
      │ getUpdates 长轮询（零入境端口）
      ▼
bot/  ── router（slash 主轨 + 裸 ASCII 辅助轨 + callback 分支）
      ── handlers/（一文件一功能）── telegram_api（切段/配速/thread/ephemeral/瞬态退避重试）
      ── migration（群升级 re-key）── session_log_recorder（录制挂钩）
engine 桥接层：BCDice gem（上游零修改）+ game_systems/NinjaSlayer(2)Ex + i18n/
db/  SQLite（WAL 单连接）：settings / bank / custom_tables / secrets / session_logs
```

扩展类直接继承 `NinjaSlayer`/`NinjaSlayer2` 注册新 ID，对上游零改动，`bundle update bcdice` 无冲突升级（`docs/EXTENDING.md` 轴②）。

暗骰走 Bot API 10.3 原生 ephemeral（约 25 分钟消失），secrets 表做持久化兜底，「公开」按钮走常规消息。**前提：bot 须为群管理员**——非管理员只有在触发动作后 15 秒内回指触发消息才能发 ephemeral（已实现自动回指入站命令；官方 Bot API「Reply Targets and Conditions」）。

部署是 Docker multi-stage：builder 阶段跑 `rake verify`，测试不过镜像就不产出；runtime 是非 root 精简镜像（303MB，2026-10-12 实测）。

## 部署（速览）

```bash
# 生产机（本 repo 的运维手册在 docs/OPERATIONS.md，含 409 双轮询红线）：
rsync 源码 → /opt/<project>/src
sudo docker build -t tengu-bcdice-tg:latest .     # 构建闸门=全量测试
sudo docker run -d --name tengu-bcdice-tg --restart unless-stopped \
  --log-opt max-size=10m --log-opt max-file=3 \
  -v /opt/<project>/data:/app/data tengu-bcdice-tg:latest
```

> ⚠️ 部署前提：把 bot **设为群管理员**——否则暗骰（/secret 的 ephemeral 结果）发不出来（非管理员只有 15 秒回指窗口，仅覆盖命令刚发出的瞬间）。详见 docs/OPERATIONS.md §1.5/§4.5。

`.env` 放数据卷（`/opt/<project>/data/.env`），token 用户自填（脚手架 `.env.example`）。备份用 `scripts/backup.sh` 日备（sqlite3 `.backup` 在线一致，保留 7 份），另有 36h 新鲜度监控告警。

## 开发

```bash
bundle install
bundle exec rake verify        # spike + 引擎 toml + bot/db minitest 三段全绿才算过
TEST_TARGET=NinjaSlayer2Ex bundle exec rake test   # 单表筛选
```

扩展四条轴（升级 gem / 新规则系统 / 群内建表 / 新 handler）见 `docs/EXTENDING.md`。

## 文档索引

| 文档 | 内容 |
|---|---|
| `docs/OPERATIONS.md` | 运维手册：部署/升级/恢复/备份/监控/故障排查/409 双轮询红线与 429 瞬态链 |
| `docs/EXTENDING.md` | 扩展开发指南（四条轴 + 可跑示例 + 实证坑录） |
| `docs/REFERENCES.md` | 上游钉版台账（commit hash 登记） |
| `docs/t1.*~t4.*-report.md` | 各任务实施报告（含逐条评审处置记录与实证） |
| `docs/t1.2-review-checklist.md` | 移植逐表人工复核签收单（进行中——「全功能移植」的最终验收以它为准） |
| `docs/spike-t1.1-report.md` | 引擎扩展四机制实证（注册/i18n/键空间/runner） |

## 许可与致谢

- 本项目许可：[MIT](LICENSE)（© 2026 DeconstructionR2）
- 引擎：[BCDice](https://github.com/bcdice/BCDice)（BSD-3-Clause，© Faceless and たいたい竹流），gem 进程内调用，零修改
- 移植数据源：[TenguDiceBot（天狗ダイス）](https://github.com/kooreme/TenguDiceBot)（MIT，© 2022 kooreme），语义逐行对照移植，无代码直抄
- 两家许可文本随仓库（`NOTICE.md`）并随 Docker 运行镜像分发
- 上游钉版快照在 `references/src/`（不入库，台账见 `docs/REFERENCES.md`）
- 忍者杀手 TRPG 规则 © ダイハードテイルズ／サスガタロウ 等原作方；本项目为玩家社群工具
