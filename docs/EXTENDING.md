# EXTENDING.md — 扩展开发指南（四条扩展轴）

> 依据：计划 §10「扩展性设计（四条扩展轴）」+ Phase 1~3 各实证报告。
> 每条轴 = 「最小可跑示例 + 验证命令 + 常见坑（指向 docs/t*.md 实证坑录）」。
>
> **共同纪律（三条，全都别绕）**
> 1. **零上游改动**：`vendor/bundle/**` 与 `references/src/**` 只读——一切扩展走
>    「继承 + 外挂」（计划 §3 决2），这是 `bundle update bcdice` 零冲突升级的根基。
> 2. **引擎初始化只走唯一入口** `lib/engine_bootstrap.rb`：`I18n.backend.reload!`
>    → 本仓库 i18n 去重注入 → `require game_systems/*.rb`。自己拼这段序列必踩坑——
>    缺 `reload!` 是**静默**全量 MissingTranslationData（测试照样绿），缺去重则
>    长进程重复注入累积（`docs/spike-t1.1-report.md` §2 坑点 A/B/C）。
> 3. **每次扩展后 `bundle exec rake verify` 全绿才算数**（spike + 引擎层 toml 全量
>    + bot/db 层）。别用 `rake full`——它不含 bot 层，两个测试框架必须分任务跑
>    （Rakefile 头有留档）。

| 轴 | 改哪里 | 要不要碰上游 | 代表作 |
|---|---|---|---|
| ① 升级 BCDice gem | `Gemfile`（+ 测试） | 否 | `docs/REFERENCES.md` 钉版台账 |
| ② 新规则系统 / 继承魔改 | `game_systems/` + `i18n/` + `test/data/` | 否 | `NinjaSlayer2Ex.rb`、`NinjaSlayerEx.rb` |
| ③ 群内 /ct 建自定义表 | 聊天命令（**不写代码**） | 否 | `docs/t3.3-report.md`、`docs/t3.4-report.md` |
| ④ bot 新能力 | `bot/handlers/` + `bot/main.rb` + 菜单同批 | 否 | `handlers/bank.rb` 等全套 |

---

## 1. 轴①：升级 BCDice gem（零冲突升级）

### 1.1 前提（为什么能零冲突——均已实证）

- 上游 loader 枚举 `BCDice::GameSystem.constants` 自动发现规则系统（计划 §0.2.1）——
  我们的扩展类放自己目录、require 进命名空间即注册，**gem 本身零修改**。
- 扩展只调用超类**公开命令层**；仅有三处「复制/覆写上游骨架」的点位被
  `test/engine_structure_test.rb` 结构断言钉住（`Gemfile` 头注释点名：
  `base.rb` 的 `prefixes_pattern` / `dice_command`（secret 捕获语义）、
  `NinjaSlayer2.rb` 的 `proc_dice_2nd`）。
- `Gemfile.lock` 入库；镜像构建 `BUNDLE_FROZEN=true`（漂移 = 构建失败，R9）；
  bundler 钉 `4.0.22`（= lock 的 `BUNDLED WITH`）。

### 1.2 步骤

与 OPERATIONS.md §2 同源（唯一流程，别两处各写一套）：

```bash
# 本机 repo：改 Gemfile 钉版 → bundle update bcdice → verify 全绿 → 提交 Gemfile.lock
bundle update bcdice
bundle exec rake verify
# 生产：留回滚 tag → rsync → docker build（测试红=镜像不产出）→ 换容器
```

### 1.3 验证命令

```bash
bundle exec rake verify                                   # 升级后必跑全量
TEST_TARGET=NinjaSlayer2Ex,NinjaSlayerEx bundle exec rake test   # 只跑两个 Ex 的 toml（快速定位）
```

默认全量（不带 TEST_TARGET）时，runner 会对 `test/data/` 里的子类 toml **复跑父类
全部用例**（孪生对照网，见 runner 头注释）——升完上游，子类化是否仍不破坏父类行为
由它自动回答。

### 1.4 常见坑

| 坑 | 说明 | 出处 |
|---|---|---|
| 手痒改 `vendor/bundle` | 改了它，「零冲突升级」的根就没了；gem 升级会覆盖你的改动 | 计划 §0.3 只读红线 |
| 忘了提交 `Gemfile.lock` | 构建 `BUNDLE_FROZEN` 直接失败（fail-closed 而不是静默拉新版） | Dockerfile 头注释 / R9 |
| 升级 `telegram-bot-ruby` | `ClientPollingBackoff`（bot/telegram_api.rb）**复制了** gem 2.8.1 `Client#fetch_updates` 的方法体来接管无退避紧密重试，`RetryPolicy` 依赖 `ResponseError#error_code/data` 形状——升级前对照新版 `client.rb`/`exceptions/response_error.rb` 复核；版本绊线 `test/bot/test_polling_backoff_test.rb` 会当场红 | 2026-10-12 二审修复 |
| 上游正则语义悄悄变 | 扩展命令的 toml 是**逐字断言**，漂移当场红；`engine_structure_test.rb` 是结构守卫 | `docs/t1.4-karmarond-report.md` §3（Preprocessor 三关实测） |
| 把「gem 升级」和「快照重取」混为一谈 | `references/src/` 快照只在要重跑数据 diff/对照时重克隆，须在 `docs/REFERENCES.md` 登记新旧 hash | REFERENCES.md 顶部流程 |

---

## 2. 轴②：`game_systems/` 丢新文件（新规则系统 / 继承魔改）

### 2.1 自动注册机制（时序，别打乱）

```
EngineBootstrap.bootstrap!（默认生产路径，engine_bootstrap.rb:78-95）
  ① I18n.load_path.concat(本仓库 i18n yml - 已有)  # 去重注入
  ② Dir[game_systems/*.rb].sort 逐个 require        # 类定义进 BCDice::GameSystem 命名空间
  ③ I18n.backend.reload!（**仅首调，且在最后**）     # 让下一次 translate 读全两份 yml
       ↓
BCDice.all_game_systems / game_system_class("YourId") 即可发现（spike ① 实证）
       ↓
bot 侧 /system <ID> 走 EngineResolver → BCDice.game_system_class（**ID 大小写敏感**）
```

⚠️ 顺序铁律（kimi T4.3/4.4 评审 E1）：reload **必须在注入之后、且在序列最后**
（bootstrap! 默认 `reload_backend: false`，首调内部在末尾 reload 一次）。
自行脚本化时若在 require 之前 reload：gem 内 yml 已读、本仓库 yml 未注入 →
全量 MissingTranslationData（spike-t1.1-report §2 坑点 A 的原始失败路径）。
另：`bootstrap!(reload_backend: true)` 是测试态的强制重载路径，顺序与上图不同，
别混为一谈。

⚠️ 列举系统名的雷（评审 E2）：不要写 `BCDice.all_game_systems.map(&:ID)`——
上游历史上出现过**没有 ID 常量**的系统，这种写法会整体 NoMethodError。
（口径订正 2026-10-12：本条早先称「实测 FutariSousa_Korean 会 NoMethodError」，
经复核该断言已过时——当前钉版 gem 里它有 ID（`FutariSousa:Korean`），
全量 338 类实测 0 个缺 ID。本条保留为**防御性建议**：未来 gem 升级仍可能
引入无 ID 类。）仓库 dice.rb 的 `EngineResolver.system_ids` 已改为逐项
filter_map + 逐项 rescue：单个类缺 ID 只丢那一项，不再整表清空。要列举先过滤
`const_defined?(:ID)`；只要确认「能不能用」，优先 `game_system_class("YourId")`
单点查询（找不到返回 nil）。

所以「加系统」= **加文件**（+ 可选 yml + toml 测试）+ **扩 i18n 守卫白名单**
（`test/i18n_guard_test.rb` 的 `ALLOWED_TOP`——你的新命名空间不加进白名单，
`rake verify` 当场红；评审 E3：这条不是可选项，与「加文件」并列必做）。
不需要改上游、不需要改引擎注册表。

### 2.2 最小可跑示例（骨架）

⚠️ `DiceBot` 自带默认 ID/NAME/SORT_KEY/HELP_MESSAGE 四常量——**忘覆盖会沿用
'DiceBot' 这一名字**（评审 E6）。四常量必须全部重写（骨架里已逐个标出）。
仓库实战均走「继承既有系统」（`NinjaSlayer2Ex < NinjaSlayer2`），优先参考它。

```ruby
# game_systems/MyDiceBot.rb —— 骨架（与 NinjaSlayer2Ex.rb 同构的精简版）
require "bcdice"
require "bcdice/game_system"

module BCDice
  module GameSystem
    class MyDiceBot < DiceBot        # 继承 DiceBot，或继承既有系统做魔改（如 NinjaSlayer2Ex < NinjaSlayer2）
      ID = "MyDiceBot"
      NAME = "我的规则系统"           # 继承路线必改：与父类撞名＝列表出现两个同名条目
      SORT_KEY = "まいだいすほつと"   # 继承路线建议排到父类正下方（NinjaSlayer2Ex 的 SORT_KEY 写法）
      HELP_MESSAGE = "MYS ：あいさつを返す"  # 继承路线：parent_help + extension_help 拼接（见下）

      # 全部前缀注册**在类体内一次性完成**（prefixes 首次 eval/command_pattern 调用即冻结，
      # 过后注册 = FrozenError；上游 base.rb:35-47，spike-t1.1 §5 第 7 项）：
      #   继承路线先：register_prefix_from_super_class()
      #   然后追加新前缀（可多个）：
      register_prefix("MYS")

      RE_MYS = /^MYS$/i.freeze       # 首尾锚定——裸 ASCII 辅助轨闸门靠反射锚定正则自动进网

      # 未命中本类命令一律交回 super（父类实现自带语法错误→nil，**不要复制父类方法体**）
      def eval_game_system_specific_command(command)
        return nil unless RE_MYS.match?(command)

        "MYS ＞ Hello! (#{@randomizer.roll_once(6)})"
      end
    end
  end
end
```

配 `i18n/MyDiceBot/ja_jp.yml`（表文本）时：顶层命名空间 = 你的系统名；结构照
`i18n/NinjaSlayer2Ex/ja_jp.yml` 的 `ja_jp: <Namespace>: table: <KEY>: {name, type, items}`。
表文本**用 psych `YAML.dump` 机器生成**——手写块标量的空白差异会批量打爆红
（T1.2 数据管线纪律，见 `i18n/NinjaSlayer2Ex/ja_jp.yml` 头注释与
`scripts/json_to_i18n.rb`）。

配 toml 用例 `test/data/MyDiceBot.toml`（格式 = 上游测试框架，real 样例见
`test/data/NinjaSlayer2Ex.toml` 的 SBX 用例区段（注释头 L484 起，首条 input="SBX" 在 L599））：

```toml
[[ test ]]
game_system = "MyDiceBot"
input = "MYS"
output = "MYS ＞ Hello! (4)"   # 逐字断言；第一次先跑一次、把实际输出原样填回（或让生成器跑）
rands = [
  { sides = 6, value = 4 },
]
```

### 2.3 验证命令

```bash
bundle exec rake spike                            # ①类注册 ②i18n 加载 ③继承键空间
TEST_TARGET=MyDiceBot bundle exec rake test       # 只跑新系统的 toml
bundle exec rake verify                           # 全量回归（必跑）
```

真机：把 bot 拉进的测试群里 `/system MyDiceBot` 切过去，打一条新命令看应答
（测试场地用 示例群 的 test/test2 话题，别碰其他话题）。

### 2.4 常见坑（每条都有实证出处）

| 坑 | 说明 | 出处 |
|---|---|---|
| 注册时序 | 全部 `register_prefix` / `register_prefix_from_super_class` 必须在类体内完成；任何先行 eval 会冻结 prefixes（`prefixes_pattern` 首调冻结）→ 运行期补注册 `FrozenError` | `docs/spike-t1.1-report.md` §5 第 7 项 / 上游 base.rb:35-47 |
| `HELP_MESSAGE` 是**常量覆写** | 继承路线若只写扩展段，父类那段说明**整个消失**（2 版玩家最常用的 `K6` 说明没了）。正确写法 = `parent_help + extension_help` 拼接（不抄第二份惰性漂移） | `NinjaSlayer2Ex.rb` L61-78 注释（T1.1 遗留教训） |
| i18n 键空间 | 只能在**自己的**命名空间新增表；往父类命名空间写键会**静默遮蔽**上游表。`test/i18n_guard_test.rb` 三层断言（白名单/上游全量逐字比对/yml 可解析）当场红——**新增命名空间时同步扩 `ALLOWED_TOP` 白名单**（当前只许 `NinjaSlayerEx` / `NinjaSlayer2Ex`） | `test/i18n_guard_test.rb`、`docs/spike-t1.1-report.md` 机制③ |
| toml `output` 键必存 | 空串代 nil；缺键 runner NoMethodError（与上游同形）；`output` 是 `result.text` 逐字比对，**不归一化**——表文本手工抄录必红 | runner 源码、`docs/t1.4-karmarond-report.md` §5（生成器） |
| S 前缀 / 暗骰标记冲突 | 上游 `prefixes_pattern = /^(S)?(...)/i`——以 S 开头的新前缀（如 `SEISEN`）会被暗骰标记吃掉首字母而失配。T1.6 已泛化保护（S 开头前缀按长度降序并入保护分支），**新加 S 开头的命令要跑回归确认** | `docs/t1.5-report.md` §3、`docs/t1.6-report.md` §4 |
| 索引语义 | 天狗式「绝对索引 `data[出目]`」与 `Table.from_i18n` 的「相对索引」错位一格；带 `+x`/多骰型的表要手写 roll + 显式 min_index（照 `NinjaSlayer2Ex.rb` 的 `NSRS_DICE_TYPES` 骨架） | `docs/t1.2-coverage-audit.md` §5.1、`NinjaSlayer2Ex.rb` 注释 |
| 辅助轨（裸 ASCII）不进网 | 闸门反射的规则类取自 `AuxMatcher::DEFAULT_SYSTEM_IDS`（`bot/router.rb`）——新系统要支持裸打字，把 ID 加进那个列表；新命令正则必须是**首尾锚定**（`\A…\z` 或 `^…$`）才会被自动收割 | `bot/router.rb` AuxMatcher 注释、`docs/t2.3-report.md` §2 |
| 生成器交叉校验 | 用 `scripts/gen_table_toml.rb` 生成哨兵块（幂等 + ledger↔代码↔yml 三方校验不过即 abort）；手工用例放哨兵外不受影响 | `docs/t1.4-karmarond-report.md` §5 |

---

## 3. 轴③：群内 `/ct` 建自定义表（用户侧扩展，不写代码）

### 3.1 用法全表（命令层文案是唯一权威，原文见 `bot/handlers/custom_table.rb` USAGE）

```
/ct create <表名>                                建表（初始骰型 a : 1d6）
/ct rename <旧名> <新名> [t]                     改名
/ct dice set <表> <快捷名> <骰式> [t]            设骰型（骰式形如 1d6、2d6+3、3d6+x）
/ct dice del <表> <快捷名> [t]                   删骰型（快捷名 a 不可删）
/ct data set <表> <出目> [t] <结果文本>          录入出目结果（文本可含空格）
/ct data del <表> <出目> [t]                     删出目结果
/ct range <表> <最小> <最大> [t]                开范围钳；/ct range <表> off [t] 关
/ct perm add|del <表> <用户ID> [t]               权限增删（前三位是管理位，删前三位会被拒）
/ct publish <表>                                 发布为公共表（原表移走，全部群可用）
/ct delete <表> [t]                              删表
/ct show <表> [t]                                查看表内容；/ct list 本群表+公共表一览
/ct roll <表> [快捷名] [補正]                    掷表（查找顺序 内置 → 本群 → 公共）
/ct help [子命令]                                总用法 / 分题帮助
```

- `[t]` = flag：**t/T = 公共表**、不写或 **f/F = 本群表**（独立 token，不做内容猜测）。
- 权限：改表 = 权限名单**或本群管理员**（getChatMember，fail-closed）；公共行只认
  表自身的权限数组（群管理员旁路只管本群私有表）。匿名管理员 fail-closed。
- 掷表带 `+x` 骰型可用補正；出目超范围钳时取端点数据**并明示**（天狗是静默的）。
- 数据存储：`custom_tables` 表，**群级一表一行（话题共享）**。

### 3.2 最小可跑示例（群里实操一条龙）

```
/ct create 暗殺表
/ct data set 暗殺表 1 被目击者看到
/ct data set 暗殺表 2 暗杀成功且无人发现
/ct dice set 暗殺表 a 1d3
/ct roll 暗殺表
/ct range 暗殺表 1 2
/ct publish 暗殺表          → 去另一个群 /ct roll 暗殺表 验证公共可见
```

### 3.3 验证要点

- `/ct show 暗殺表` 回显骰型/范围钳/全部数据；`/ct list` 看本群表与公共表；
- 另一个群 `/ct roll 暗殺表` 能掷到 = publish 生效（public scope）；原群表已「移走」。

### 3.4 常见坑

| 坑 | 说明 | 出处 |
|---|---|---|
| 与内置表撞名会**拒绝**建表/发布 | 掷表查找内置优先，不拦等于「建了永远掷不到」；两路都拦 | `docs/t3.4-report.md`（母本 createTable.js:10-11 对照） |
| 改名**不查**内置表 | 改名可改出「被内置阴影」的名字（母本同款，已知面） | 同上 |
| 自动维护会**覆盖手动 range** | `dice set`/`data set`/`data del` 会按数据键域重算范围钳（母本语义：范围由 data 推导） | `docs/t3.4-report.md` §4 决策 3 |
| `publish` 前的 dataVerification | 出目数据不齐会拒；骰式含 `+x` 或已开范围钳时**跳过**校验（母本语义） | `custom_table.rb` 头注释 ⑥ |
| flag 位置 | 定长命令 flag = 最后一个 token；`data set` 的 flag 必须**紧邻出目号**（其后是自由文本） | `custom_table.rb`「flag 解析」 |
| 匿名管理员 | 权限判定对匿名管理员 **fail-closed**（平台共享 id，不能当所有者） | `docs/t3.4-report.md`（kimi 必修） |

db 层 12 操作语义与「public 时 chat_id 取 0 占位」等内部纪律见
`docs/t3.3-report.md`（扩展 db/custom_tables.rb 前必读）。

---

## 4. 轴④：`bot/handlers/` 一文件一功能（bot 侧新能力）

### 4.1 接线三步（缺一即「看着接了实则从不执行」）

1. **写文件** `bot/handlers/<name>.rb`：class + `call(context)` + `self.registry`；
2. **接线** `bot/main.rb`：`require_relative` + 构造 + 在 `Router.new(handlers: …)`
   里 `.merge(YourHandler.registry(your_handler))`；
3. **菜单同批落地**：加进 `TelegramApi::MainMenu::ENTRIES`（slash ≤32 拉丁字符）
   **同时**把 handler 与 `/help` 文案一并上——菜单上架但没 handler = 用户视角
   「bot 死了」（真机验收实测教训；未实现的功能先挂 `PendingHandler` 占位应答，
   范式在 `bot/handlers/help.rb`。菜单**外**的未知 slash 才允许静默）。

### 4.2 handler 契约（router 的注册表接口）

- `handler.call(context)`；context 键（`bot/router.rb` `run_handler` 摊平）：
  `router / api / kind / command / name / args / text / chat_id / thread_id /
  user_id / chat_type / message / callback_query / data / answer_callback_query`。
- 返回 **String → router 代发**（自动带 thread 透传 + 4096 切段 + 1 条/秒配速）；
  返回 **nil → 静默**；也可以自己用 `context[:api].send_text(...)` 发（按钮/多消息场景）。
- 发送封装一律 `**extra` 透传（`reply_markup`、`parse_mode`…）——不加会被
  ArgumentError 吞掉再被 rescue 静默，按钮根本发不出去。
- 自己发消息时 **thread_id 先归一**：从 DB 读出的值过 `positive? ? 值 : nil`
  （Ruby 0 是真值，`message_thread_id: 0` 会拍上 wire，forum 群 400 风险）。
- **wire 参数名只许出现在 `bot/telegram_api.rb` 一层**（路由/handler 只传语义参数，
  如 `alert:`；转换归封装内部）——越俎代庖拼 `show_alert:` 撞关键字形参再被吞。
- 可注入 logger 的类默认值必须是 `::Logger.new($stderr)`，**不许** `$stderr` 裸值
  （IO 没有 `#warn`，生产 warn 全哑、事故零日志；全仓已统一）。

### 4.3 最小可跑示例（骨架）

```ruby
# bot/handlers/ping.rb
require "logger"

module TelegramBot
  module Handlers
    class PingHandler
      def initialize(logger: ::Logger.new($stderr))
        @logger = logger
      end

      # 本功能占用的 router 键全列在这里（slash 命令名 => handler 对象）
      def self.registry(handler = new)
        { ping: handler }
      end

      def call(context)
        return nil unless context[:name].to_s == "ping"   # 按 name/kind 分发，别忽略

        "pong"
      end
    end
  end
end
```

接线（`bot/main.rb`，照既有 `.merge(registry)` 写法）：

```ruby
require_relative "handlers/ping"
# … Router.new(handlers: { start: …, help: …, log: … }
#     .merge(TelegramBot::Handlers::PingHandler.registry(ping_handler)), …)
```

菜单同批（`bot/telegram_api.rb`）：

```ruby
{ command: "ping", description: "连通性自检", ephemeral: false },
```

端到端测试（**真身 + 真 Router**——只测单元会漏掉「接线静默失效」类 bug；
夹具照 `test/bot/test_router_test.rb` 的 `update()` 构造，用 gem 真类型）：

```ruby
# test/bot/test_ping_handler_test.rb
require_relative "test_helper"
require_relative "../../bot/router"

class TestPingHandler < Minitest::Test
  include BotTestHelper

  def test_wired_via_real_router
    @api, @fake, = build_api
    router = TelegramBot::Router.new(
      api: @api, logger: Logger.new(IO::NULL),
      handlers: TelegramBot::Handlers::PingHandler.registry
    )
    router.dispatch(update(text: "/ping"))          # update() = test_router_test.rb 同款消息夹具
    assert_includes @fake.sent_messages.map { |m| m[:text] }, "pong"
  end
end
```

按钮回调类 handler（如要加按钮）：挂 `:callback_query` 键 + **先 `answer_callback_query`
再干活**（不答客户端永远转圈；router 有 ensure 兜底双保险）+ `callback_data` 用
自己的**前缀命名空间**（参照 `sec:`）+ 按 `context[:kind]` 分发。参照实现与双缺口
教训见 `bot/handlers/secret_dice.rb` 与 `docs/t3.1-report.md` §3。

### 4.4 验证命令

```bash
bundle exec ruby -Ilib -Itest test/bot/test_ping_handler_test.rb   # 单文件
bundle exec rake bot                                              # bot/db 层全量
bundle exec rake verify                                           # 全量回归（必跑）
# 接线闭环（真 main.rb 子进程）：test/bot/test_main_startup_test.rb 的范式
```

真机：测试群（示例群 的 test/test2 话题）打 `/ping`——顺带确认菜单点选也通。

### 4.5 常见坑（全是实施期实证，逐条有报告）

| 坑 | 说明 | 出处 |
|---|---|---|
| 菜单命令无 handler | 用户点了没反应 = 装死；未实装先挂 PendingHandler 占位应答 | `bot/handlers/help.rb`（范式）、计划 §8（3a13c07 热修）、`docs/t3.5-report.md`（占位替换实录） |
| 发送封装缺 `**extra` | `reply_markup` 被 ArgumentError 吞、rescue 静默，按钮没发出去测试也看不出 | `docs/t3.1-report.md` §3 缺口 1 |
| `run_handler` 没摊平 `data` | 回调 handler 读 `context[:data]` 拿 nil，整条路径走「未知命令」分支 | `docs/t3.1-report.md` §3 缺口 2（含泛化教训：「同一个 handler 挂两个键必须验两个键都被调用」） |
| 「调到」≠「送达」 | 边界测试必须断言假身实际收到的 wire 参数（`FakeApi` 的 `answered` 里真有 `show_alert: true`） | `docs/t3.1-report.md` kimi 评审 #1 |
| listen 接缝形状 | `Client#listen` yield 的是 `handle_update` 返回值（Message 而非 Update；callback 是 CallbackQuery 本体）——测试假身的产出形状必须对着 vendor 源码写 | 计划 §8 Phase 2 验收记录（b8ebb68）、`test/bot/test_listen_seam_test.rb` |
| 匿名管理员 | 把 `user_id` 当所有者/权限位前必须对匿名管理员 fail-closed（平台共享 id） | `docs/t3.4-report.md`、`callback_query.from` 才是真人 |
| DB 纪律 | sqlite3 gem 三坑（results_as_hash 全局、execute 不返回行数、REFERENCES 需 PRAGMA）、事务嵌套/块内 return、INTEGER 动态类型显式校验 | `docs/t2.4-report.md` D5/D6、`docs/t3.2-report.md` |
| 录制挂钩边界 | 新 handler 若"自走发送"（不经 router 代发），进不进 `/log` 要显式设计（挂钩②不可达）；`/secret` 类私密内容绝不落盘 | `docs/t3.5-report.md` §2/§4 |

---

## 附录：验证命令速查

```bash
bundle exec rake verify        # 完整回归：spike + 引擎 toml + bot/db（提交/构建前的唯一标准）
bundle exec rake spike         # 只跑 T1.1 四机制
bundle exec rake default       # 只跑引擎层 toml（默认全量）
bundle exec rake bot           # 只跑 bot/db 层
TEST_TARGET=NinjaSlayer2Ex bundle exec rake test          # 单 toml（可逗号多值）
TEST_TARGET=NinjaSlayer2Ex,NinjaSlayerEx bundle exec rake test
bundle exec ruby -Ilib -Itest test/bot/test_router_test.rb  # 单个 minitest 文件
```

文档索引：`docs/spike-t1.1-report.md`（四机制与坑点）、`docs/t1.4-karmarond-report.md`
（Preprocessor 三关 / 生成器）、`docs/t1.5-report.md`（SEISEN S 前缀冲突）、
`docs/t1.6-report.md`（S 前缀泛化 / 倍率）、`docs/t2.3-report.md`（辅助轨闸门）、
`docs/t3.1-report.md`（按钮接线两缺口）、`docs/t3.3-report.md`+`docs/t3.4-report.md`（CT）、
`docs/t3.5-report.md`（log 录制挂钩）、`docs/OPERATIONS.md`（部署/升级/恢复）、
`docs/REFERENCES.md`（钉版台账）。
