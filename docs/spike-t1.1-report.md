# T1.1 spike 实证报告

> 任务：[Bcdice 外部插件类注册 / 外部 i18n 加载 / 继承键空间 / 自研 toml runner 跑通 NinjaSlayer2.toml baseline]
> 实施日：2026-10-11
> 关联计划：<agent-home>/plans/2026-10-11_122428-tengu-bcdice-telegram-dicebot.md §8 T1.1 / §3 决2 / §15.5 V3 V4 V5 V6 V7 E9
> Spike 代码：`game_systems/NinjaSlayer2Ex.rb`、`game_systems/NinjaSlayerEx.rb`、`i18n/NinjaSlayer2Ex/ja_jp.yml`、`test/spike_t1_1.rb`、`test/test_ext_game_system_commands.rb`、`test/randomizer_mock.rb`、`Rakefile`
> 跑法：
>
> ```bash
> bundle exec rake spike           # 三项机制一次性 PASS/FAIL 报告
> bundle exec rake test            # toml 默认全量（4 份：父 + 子 ×2）
> TEST_TARGET=NinjaSlayer2 rake test   # 仅 baseline 上游 33 用例
> bundle exec rake full            # spike + test
> ```

## 0. 总结

| 机制 | 计划预期 | 实证结果 | 判定 |
|---|---|---|---|
| ① 外部插件类注册 | 继承 NinjaSlayer2 + 新 ID，game_system_class 能发现 | `game_system_class("NinjaSlayer2Ex") → BCDice::GameSystem::NinjaSlayer2Ex`；6/6 断言通过 | ✅ PASS |
| ② 外部 i18n 加载 | 注入本仓库 i18n/ 后 translate 到 NinjaSlayer2Ex 键 | dummy 表 6/6 断言通过；上游 NinjaSlayer2 键仍命中，键空间相互隔离 | ✅ PASS |
| ③ 继承键空间行为 | 子类跑父类命令仍命 NinjaSlayer2.* 硬编码键 | SB / SB@6 / WSE 真实掷出，结果文本逐字匹配上游 yml 第 3/6/4 项 | ✅ PASS |
| ④ 自研 toml runner | 跑通上游 NinjaSlayer2.toml 全量 33 用例基线 | baseline 33 tests / 231 assertions / **0 failures**；扩 4 份 toml 总 176 tests 全绿 | ✅ PASS |

四项全绿，无机制性失败、零 workaround 充数。下面对各项展开（命令、真实输出片段、代码位置），并补对 T1.2 风险提示。

---

## 1. ① 外部插件类注册

### 命令与真实输出

```text
$ bundle exec ruby test/spike_t1_1.rb
==============================================================================
① 外部插件类注册
==============================================================================
[PASS] ① BCDice.game_system_class('NinjaSlayer2Ex') 命中
         evidence: got=BCDice::GameSystem::NinjaSlayer2Ex
[PASS] ① BCDice.game_system_class('NinjaSlayerEx') 命中
         evidence: got=BCDice::GameSystem::NinjaSlayerEx
[PASS] ① 父类 NinjaSlayer2 ID 仍为 NinjaSlayer2
         evidence: got=BCDice::GameSystem::NinjaSlayer2/ID=NinjaSlayer2
[PASS] ① 父类 NinjaSlayer ID 仍为 NinjaSlayer
         evidence: got=BCDice::GameSystem::NinjaSlayer/ID=NinjaSlayer
[PASS] ① NinjaSlayer2Ex < NinjaSlayer2（子类关系）
         evidence: ancestors include? true
[PASS] ① prefixes_pattern 含父类所有 prefix（UH/[KENHU]/SB/WS/WSE/NRS）
         evidence: ex.prefixes=["UH", "[KENHU]", "SB", "WS", "WSE", "NRS"] vs ns2.prefixes=["UH", "[KENHU]", "SB", "WS", "WSE", "NRS"]
```

### 代码位置

- `game_systems/NinjaSlayer2Ex.rb`：8 行 `class NinjaSlayer2Ex < NinjaSlayer2` + `ID = "NinjaSlayer2Ex"` + `register_prefix_from_super_class()`。
- `game_systems/NinjaSlayerEx.rb`：同理继承 NinjaSlayer。
- 关键点：扩展类**只** require `bcdice/game_system/NinjaSlayer2`，**无需**碰 `BCDice.game_system_loader` 任何 hook。BCDice loader 在被 `BCDice.all_game_systems` 调用时遍历 `BCDice::GameSystem.constants`，子类自然出现（`lib/bcdice/loader.rb:18-21`）。

### 偏差点 / 意外发现

- **零改动 gem 实现注册**——第三方假设得到证实：`require_relative "../game_systems/NinjaSlayer2Ex.rb"` 后即被识别。意味着未来 T1.3~T1.7 每个新命令只用写一个 rb 文件，零打补丁 gem。
- `register_prefix_from_super_class` 直接复用上游父类 prefixes，不会因 `prefixes_pattern` 冻结机制丢掉父命令（V5 旁证成立）。

---

## 2. ② 外部 i18n 加载

### 命令与真实输出

```text
==============================================================================
② 外部 i18n 加载
==============================================================================
[PASS] ② I18n.t('NinjaSlayer2Ex.table.SPIKE_DUMMY.name') 命中
         evidence: got="T1.1 spike dummy 表(D6) ＞ "
[PASS] ② I18n.t('NinjaSlayer2Ex.table.SPIKE_DUMMY.items')[0] 命中第 1 项
         evidence: got="SPIKE_DUMMY 1"
[PASS] ② I18n.t('NinjaSlayer2.table.SATSUBATSU.name') 仍命中上游
         evidence: got="サツバツ!!(D6) ＞ "
[PASS] ② 键空间隔离：NinjaSlayer2.table.SPIKE_DUMMY.name 不存在
         evidence: raise I18n::MissingTranslationData as expected（NinjaSlayer2 不继承到 SPIKE_DUMMY）
[PASS] ② 键空间隔离反向：NinjaSlayerEx.table.SPIKE_DUMMY.name 应 raise
         evidence: raise I18n::MissingTranslationData as expected（1版扩展未声明 dummy 表）
[PASS] ② I18n.t('NinjaSlayer2Ex.table.SPIKE_DUMMY.items') 是数组且首项= SPIKE_DUMMY 1
         evidence: class=Array, first="SPIKE_DUMMY 1"
```

### 代码位置

- `i18n/NinjaSlayer2Ex/ja_jp.yml`：参照上游 `references/src/BCDice/i18n/NinjaSlayer2/ja_jp.yml` 的 `name/type/items` 结构写一个 dummy 表 `SPIKE_DUMMY`（占位文本，非真实文本 —— 见 §0 风险提示）。
- `test/spike_t1_1.rb#check_i18n_load_path`：两步注入
  1. `I18n.backend.reload!` 强制重新加载（避免 `init_translations` 已跑过的副作用）；
  2. `I18n.load_path.concat(Dir["i18n/**/*.yml"])`。
- Spike 顺序：`require "bcdice"` → reload! → concat yml → 任何 translate。前两步骤不被任何 BCDice 命令的提前 eval 抢走（baseline 跑通证实）。

### 偏差点 / 意外发现

**坑点 A**：i18n 1.x backend (`I18n::Backend::Simple`) 内的 `init_translations` 一旦跑过就 `mark @initialized=true`，**不会**自动重读后续追加的 load_path。直接 `I18n.load_path << yml` 后续 translate 仍是 missing。**必须**先 `I18n.backend.reload!`，否则注入失效。我因一份 PoC 失败后实测 I18n source 才发现这一点。

**坑点 B**：BCDice base.rb 末尾的 `I18n.load_path << Dir[File.join(__dir__, "../../i18n/**/*.yml")]` 这种 `<< Dir[...]` 单元素 push 会塞一个数组元素进去；`I18n::Backend::Base#load_translations` 用 `filenames.flatten.each` 兜底—— 我们模仿 BCDice 方式时也要用 `concat(Dir[...])` 平展，否则会出现"load_path 含一个数组项"的奇怪状态。

**坑点 C**：i18n 默认翻译缺失时 `translate` 行为是返回 `"translation missing: <locale>.<key>"` 字符串（不 raise），所以**测试断言**必须显式 `raise: true`，否则永远"成功"返回占位字符串被误判通过。

### T1.2 风险提示

- T1.2（数据转换管线）将生成 100+ 张表，**全部**靠 `I18n.load_path.concat(Dir["i18n/**/*.yml"])` 一次性注入；只要 yml 命名归源正确（NinjaSlayer2Ex / NinjaSlayerEx 各一份顶层 namespace），本机制即自动生效。
- **建议 T1.2 之前在 `test/test_ext_game_system_commands.rb` 顶部加**：
  ```ruby
  I18n.backend.reload! if I18n.backend.respond_to?(:reload!)
  I18n.load_path.concat(Dir[File.expand_path("../i18n/**/*.yml", __dir__)])
  ```
  防止 runner 早于 i18n 注入而被 `init_translations` 跳过——已在本 spike 的 runner 中实现，T1.2 不会被坑。

---

## 3. ③ 继承键空间行为

### 命令与真实输出

```text
==============================================================================
③ 继承键空间行为
==============================================================================
[PASS] ③ 子类 SB 输出命中父表 SATSUBATSU 第 3 项（V3 硬编码键旁证）
         evidence: text="サツバツ!!(D6) ＞ (3) ＞ 「苦しみ抜いて死ぬがいい！」急所や内臓を情け容赦なく破壊！  \n『痛打+1』。敵の【体力】を減らした場合、付属効果として『ニ"
[PASS] ③ 子类 SB@6 输出命中父表 SATSUBATSU 第 6 项
         evidence: text="サツバツ!!(6) ＞ 「さらばだ！ イイイヤアアアアーーーーッ！」ヤリめいたチョップが敵の胸を貫通！ さらに心臓を掴み取り、握りつぶした！ ゴウランガ！  \n『"
[PASS] ③ 子类 WSE 输出命中父表 WASSHOI
         evidence: text="ニンジャスレイヤー=サンのエントリー!!(D6) ＞ (4) ＞ 天井破壊や床破砕、または垂直リフト射出により出現！  \n標的ニンジャから2マス離れた任意の場所に"
[PASS] ③ 子类 instance.class 链确认经子类
         evidence: is instance_of? true
```

### 代码位置

- `test/spike_t1_1.rb#check_inherited_keyspace`：
  - `FixedSidesRandomizer` mock 一个永远回返特定值的 `Randomizer`，规避真实骰序；
  - `klass = BCDice.game_system_class("NinjaSlayer2Ex")`；
  - `inst = klass.new("SB")` → `eval.text`；
- 输出文本**逐字取自** `references/src/BCDice/i18n/NinjaSlayer2/ja_jp.yml` 的 `table.SATSUBATSU.items[2]`（第 3 项）。任何字符差异会立刻暴露。

### 偏差点 / 意外发现

**确认 V3**：父类用硬编码字符串 `translate('NinjaSlayer2.table.SATSUBATSU.items')`（`references/src/BCDice/lib/bcdice/game_system/NinjaSlayer2.rb:285`），不依赖类名推导。子类继承父类方法体，硬编码键不变 → 仍命中 `NinjaSlayer2.*`，**未**跑向 `NinjaSlayer2Ex.*`。这意味着：

- T1.3 / T1.7 在子类加新命令（NSRS 等）会**独立**用 `translate('NinjaSlayer2Ex.table.NSRS.items')`，与父类 `NinjaSlayer2.*` 完全隔离；
- 父类别的表（NSRS、SATSUBATSU、WASSHOI 在 2版内）**永远**走父类 yml——我们不能"借刀"扩展这些表，只能新增表。

### T1.2 风险提示

- `NinjaSlayer2.table.SATSUBATSU.items` 是 6 个表项的数组，里面**含有换行符**和**半角全角混合字符**。T1.2 JS→Ruby 转换管线用 `JSON.parse` dump 而非正则拆分，可保证这些字符安全落地。我们后续对表文本做断言时，**必须**用 `\n`/`\r` 显式比较（YAML literal block 会有差异）。
- 第 6 项最后一段"ゴウランガ！"是父类表里关键的语义标志，意味着"SB@6 表完成 = 即死判定"，T1.3 加 NSRS 新表时也要按同等格式收尾。

---

## 4. ④ 自研 toml runner 跑通 NinjaSlayer2 baseline

### 命令与真实输出

```text
$ TEST_TARGET=NinjaSlayer2 bundle exec rake test
-------------------------------------------------------------------------------
33 tests, 231 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications
100% passed
-------------------------------------------------------------------------------
```

**验收硬标准达成**：上游 `references/src/BCDice/test/data/NinjaSlayer2.toml` 全量 33 用例在自研 runner 下 0 失败。

整体默认全量（runner 跑 `test/data/*.toml` 共 4 份：原 NinjaSlayer、NinjaSlayer2 + 副本 NinjaSlayerEx、NinjaSlayer2Ex）：

```text
$ bundle exec rake test
176 tests, 1232 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications
100% passed
```

明细：
| toml | 用例数 | 断言数 | 结果 |
|---|---|---|---|
| NinjaSlayer2.toml (上游 baseline) | 33 | 231 | 全绿 |
| NinjaSlayer2Ex.toml (同输入换 game_system) | 33 | 231 | 全绿 |
| NinjaSlayer.toml | 55 | 385 | 全绿 |
| NinjaSlayerEx.toml | 55 | 385 | 全绿 |

子类双跑的目的：让**任何子类无意中破坏父类行为**的事故在 toml 层就被抓到——只要父类 33 全绿，子类 33 也必须全绿才能继续，回归网很厚。

### 代码位置

- 母本：`references/src/BCDice/test/test_game_system_commands.rb` + `randomizer_mock.rb`（§15.5 V6 已旁证）。
- 落点：
  - `test/test_ext_game_system_commands.rb`：自研 runner，结构对齐上游，去掉 simplecov，顶部 `I18n.backend.reload!` + `I18n.load_path.concat(...)` 维持 spike 顺序；
  - `test/randomizer_mock.rb`：直接拷贝上游副本（BSD-3 见 §0.1 兼容）；
  - `test/data/NinjaSlayer{2,}{,Ex}.toml`：上游 toml 的副本，**全部 33 + 55 + 55 + 55 用例输入都是从上游快照逐行 cp 而来**，NinjaSlayer2Ex.toml 仅作 `sed s/NinjaSlayer2/NinjaSlayer2Ex/g` 转换；
  - `Rakefile`：`rake test` 默认跑 toml runner，`rake spike` 跑 spike，`rake full` 两个一起。

### 偏差点 / 意外发现

- Ruby 3.2 + Bundler 13.4 + test-unit 3.7 组合下，`rake test` 输出格式与上游一致。
- 早期映射逻辑加了"父 .toml 自动孪生子 .toml"，但用户验收要求是「**全量**用例作基线，**报告**用例总数」——这暗示指定目标文件时要可重现跑出 33 而不是 66。因此把 mapping 改为**仅** `Dir["test/data/*.toml"]` 默认走全部，显式 `TEST_TARGET=X` 时只跑 X 一份。
- `:test:` namespace 内部 rake 任务与 Gemfile 中 rake 13.4 自带的 `Rake::TestTask` 命名需注意：定义 `:default` 即承担 `rake test` 的入口，再加 `task test: :default` 作短路。`rake full: %i[spike default]` 用于一键回归。

### T1.2 风险提示

- **本 runner 是永久骨架**——T1.3 起 NSRS、T1.4 圣战判定、T1.5 カルマロンダリング、T1.6 キャラメイク、T1.7 1版扩展**每条命令的 toml 用例走同一 runner**。把每条 toml 测试附在新建表同 PR 内的 commit 中，可保持 upstream signal 干净。
- 跑 docker multi-stage 构建时（计划 §9），这一步即构建期"测试通过才打包"的关卡。**rake test 必须 non-zero on failure**，目前已合规。

---

## 5. 与计划预期的偏差 / 风险汇总（T1.2 视角）

1. **i18n 注入需 `reload!`**：T1.2 脚本若直接 `I18n.load_path << yml` 而未 `reload!`，会全 silent fail。已在 runner 与 spike 顶部固化此顺序，外部文档已记。
2. **i18n 缺翻译默认返回占位字符串、不 raise**：自动化断言必须用 `raise: true` 显式参数，否则误判 PASS。T1.2 写脚本时务必如此。
3. **父类键硬编码**：子类不可"覆盖"父类表，只能新增表。T1.2 处理 NSRS / WASSHOI 等**新增**表时，落盘 key 用 `NinjaSlayer2Ex.*`；处理 SATSUBATSU / 既存 NRS 时，落盘 key 仍 `NinjaSlayer2.*`（**就地续写**到 `i18n/NinjaSlayer2/ja_jp.yml`，**勿**写到 NinjaSlayer2Ex 的表空间）。
4. **dummy 表的占位文本不可代替真实保真度**：本 spike 的 `SPIKE_DUMMY` 是占位；T1.2 的 `extract_tengu_data.mjs` 必须用 Node 直接 require 钉版快照 JS 文件（计划 §8 T1.2①），靠 JS 引擎自己解析模板字符串，禁止正则切。
5. **子类的双跑回归网**：所有 toml 默认都被双跑（父 + 子），这是**有意为之**——子类化扩展机制的回归盾，任何父类行为被破坏的事故会被 176 用例一起抓到。但代价是 rake test 默认耗时 ~0.4s × 4 toml，可以接受。
6. **NinjaSlayer（1版）当前 55 个用例**也内置在我们的 toml 目录下（test/data/NinjaSlayer*.toml）——T1.7 加 1版扩展时会复用这些用例做 baseline（类似 T1.1 验证）。
7. **PREFIX 冻结约束（V5）**：未来 T1.3 注册 NSRS 时必须用 `register_prefix("NSRS", ...)`，在 `register_prefix_from_super_class()` 之后追加，且整个过程必须在类体内（top-level）完成，不能延迟到 `def initialize`。本 spike 的 `NinjaSlayer2Ex.rb` 已是正确范式，直接 clone 添加 prefix 即可。

---

## 6. 提交清单（git -c user.name='DeconstructionR2' ...）

- 新增：
  - `Rakefile`
  - `game_systems/NinjaSlayer2Ex.rb`
  - `game_systems/NinjaSlayerEx.rb`
  - `i18n/NinjaSlayer2Ex/ja_jp.yml`
  - `test/randomizer_mock.rb`（从上游钉版快照 BSD-3 复制，原始版权与许可注记未来保持）
  - `test/test_ext_game_system_commands.rb`
  - `test/spike_t1_1.rb`
  - `test/data/NinjaSlayer.toml`
  - `test/data/NinjaSlayer2.toml`
  - `test/data/NinjaSlayerEx.toml`
  - `test/data/NinjaSlayer2Ex.toml`
  - `docs/spike-t1.1-report.md`（本文件）
- 修改：无
- 未修改（确认只读）：
  - `vendor/bundle/**`（零上游改动）
  - `references/src/**`（钉版快照）
