# REFERENCES.md — 上游钉版登记

> 钉版纪律（计划 §0.3）：转换与复核以本表 commit hash 对应的快照为准。
> 快照实体在 `references/src/`（浅克隆，本目录被 .gitignore 排除，可随时按下表重取）。
> 升级快照流程：重克隆 → 本表登记新旧 hash → 重跑数据 diff 报告。

登记时间：2026-10-11（T0.5 首次钉版）

## 上游仓库快照

| 仓库 | commit hash | 快照日期 | License | 用途 |
|---|---|---|---|---|
| [bcdice/BCDice](https://github.com/bcdice/BCDice) | `8eced50f6868bdecee69717a958f525788a49d28` | 2026-08-05 | BSD-3-Clause | 引擎本体+超类（**版本 3.17.0，与 Gemfile 钉版一致**） |
| [kooreme/TenguDiceBot](https://github.com/kooreme/TenguDiceBot) | `ca3d85a6d383ff5e14fb72fe01db65ca3e6fd168` | 2025-08-29 | MIT | 移植数据源（**repo 版本 4.2.1**；说明书 v5.2.0 仅作交叉参考，语义以本快照代码为准 —— §15.2 E1） |
| [bcdice/bcdice-api](https://github.com/bcdice/bcdice-api) | `19fabf97535c90526fcb4e19ee226a4646a1a402` | 2025-05-23 | — | 插件机制旁证（§15.3 E8：其 plugins/ 仅 .keep，旁证价值弱，注册机制依据以 BCDice loader.rb 为准） |
| [Shunshun94/discord-bcdicebot](https://github.com/Shunshun94/discord-bcdicebot) | `0005d04fb8e2089d1040d1e3c4b21369ecf4d59c` | 2026-02-05 | — | bot 层模式参照（频道级切系统的 Discord 等价物） |
| [sealdice/story-painter](https://github.com/sealdice/story-painter) | `fad63caf6ce3690d7e629cc747e4044210f04acc` | 2026-01-25 | — | log 染色器参照（导出格式适配 backlog 依据） |

## 关键参考文件在位核查（2026-10-11 全过）

- BCDice：`lib/bcdice/loader.rb`（注册机制）、`lib/bcdice/game_system/NinjaSlayer.rb`、`NinjaSlayer2.rb`（超类）、`i18n/NinjaSlayer2/ja_jp.yml`（表文本范本）、`test/data/NinjaSlayer2.toml`（toml 范本）、`test/test_game_system_commands.rb` + `test/randomizer_mock.rb`（自研 runner 母本，T1.1④）
- TenguDiceBot：`tengu_dice/nd_datatable.js`（519 行）、`nd_datatext.js`（882 行）——合计 1,401 行，与计划 §11 量化账吻合；`wasshoi.js`（聖戦）、`NJShortcutTranslator.js`、`tengu_bank/record.js`、`tb_db_wrapper.js`、`DB/db.js`、`DB/db_wrapper.js`、`discord_command/snd.js`

## Telegram 官方文档（2026-10-11 核对，Bot API 10.3）

- [core.telegram.org/bots/api](https://core.telegram.org/bots/api) — EphemeralMessageParameters / is_ephemeral / migrate_chat / message_thread_id / callback_data 64B / getChatMember / sendDice
- [core.telegram.org/bots/features](https://core.telegram.org/bots/features) — Privacy Mode / Ephemeral Messages / 命令命名规则
- [core.telegram.org/bots/faq](https://core.telegram.org/bots/faq) — 限流 / getUpdates vs webhook

## 第三方语义基准

- [天狗ダイス v5.2.0 使用说明书](https://note.com/kooreme/n/ncec59ad4ca8d) — 交叉参考（版本高于钉版快照，命令 diff 走 T1.2④）
- [BCDice 忍杀2版骰子 bot 作者设计说明](https://note.com/taka_2501/n/nb2ef60d84277) — 上游政策排除项存档（本地 fork 不受约束，但需知晓哪些属「上游不收」）
