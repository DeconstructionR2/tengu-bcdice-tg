# frozen_string_literal: true

# ============================================================================
# NinjaSlayer（1版）外部扩展类
#
# 用途 / 履历：
#   - T1.1：仅做类注册 + ID 注册实证（证明「继承 + 新 ID」机制也作用于 1版超类）。
#   - T1.7：**天狗 1版 9 表的命令实现**（本文件的实质内容）。
#
# 移植对象（计划 §5「1版 9 表」清单，全部为天狗独有、BCDice 上游缺失的表）：
#   WS / JITSB / DKKI / KRM / CYBER / BIOCYBER / SOUL / SUMMON / BK
#
# ============================================================================
# 一、骨架选型：**9 表全部「无钳制」（T1.7 拍板，逐条依据见下）
# ============================================================================
#
# 上游 2版扩展里有三套可复用的表骨架：
#   ① 钳制      proc_karmarond（KRS/KRZ/…）—— 需要 datarange，越界取端点
#   ② nil 守卫  proc_nsrs（NSRS）—— 无 datarange，越界当不响应
#   ③ 无钳制    proc_chara_make（NJI/NJS/…）—— 无 datarange，越界当不响应
#
# **② 与 ③ 在行为上同型**（都不钳制、越界不响应），差别只在②保留「多骰型 + 表级
# min_index」的表达位。本批 9 表**不需要**①：
#
#   天狗的钳制分支挂在 `if (diceroll.isTableAdditionValue)` 之下
#   （NJDiscordReply.js:91-97），而 isTableAdditionValue 仅当 dice 字面量含
#   `"+x"` 时才置位（SearchTableDiceroll.js:56-77，`/+x/.test(diceStr)`）。
#   1版 9 表的 dice 字面量实测只有 `1d6` / `1d6+1` / `2d6` / `1d36`
#   —— **无一张含 `+x`** → 恒走 else 分支 `data[diceroll.sumall]`
#   → 与 ledger 逐表登记的 `datarange: null` 完全一致
#   （references/extracted/i18n_key_ledger.yml，9 条 datarange 均为空）。
#
#   故本批**不得**复用钳制骨架，也不设 DATARANGE 常量（凭空造一个可钳边界
#   是假信息；该守卫由 test/ledger_consistency_test.rb 常驻断言）。
#
# 选 **③ 无钳制骨架**的具体理由：
#   - 9 表**均无 `+x` 補正参数**（与 2版 KRS 族的 `@±x` 形态不同，
#     本批命令面只有 `表名` / `表名_X` / `表名@n` 三种，无補正分支）；
#   - 钳制标注 `(raw→clamped)（クランプ）` 在本批**永远不可达**
#     （掷骰可达域恒 ⊆ 表跨度，见下方 EDITION1_REACHABLE），输出现里出现
#     不可达分支即为死代码；
#   - 与 T1.5 CHARAMAKE 同型 → 复用其已验证的「先查表、越界即 nil」写法。
#
# ============================================================================
# 二、索引：**表级 min_index，逐表登记**（**不是**恒为 1！）
# ============================================================================
#
# 天狗恒用绝对索引 `data[出目]`；yml 把 data 摊平成 0 基数组后，
# BCDice 侧恒为 `items[出目 - min_index]`（ledger.index_rule 逐表登记）。
#
# ⚠ **min_index 逐表不同，勿照抄 2版「恒为 1」的经验**：
#     CYBER / SUMMON 是 2d6 表，data 键为 2..12 → min_index = **2**
#     其余 7 表 min_index = 1
#   这也是为什么本表用 `EDITION1_MIN_INDEX` 逐表 Hash 而非单一常量——
#   单一常量会让 CYBER/SUMMON 整体错位一格（取到 1 号表项）。
#
# 注：2D6 表的 min_index(2) 恰好等于 DiceTable 的 `value - @times`(=2)，
#   故 7 张单骰型表用 `DiceTable::Table.from_i18n` 恰好也能算对
#   （ledger.roll_note 记的就是这句）。但本批**仍统一手写索引**，理由：
#     ① JITSB / KRM 含 `1d6+1` 骰型，Table#choice 会错位一格，必须手写；
#     ② 9 表若分两套代码路径，输出格式会分叉：
#        `Table#roll.to_s` → `wasshoiエントリー_1(1D6) ＞ (3) ＞ 正文`（带类型标记）
#        手写 proc     → `wasshoiエントリー_1(3) ＞ 正文`
#     统一手写还与 **1版父类自己的 SB 表输出形态**（`サツバツ表(1) ＞ …`）
#     一致，玩家在同一个游戏系统里看到的是同一种排版。
#
# ============================================================================
# 三、别名收敛（JITSB / KRM）
# ============================================================================
#
# 天狗 1版表的 `dice` 是一个**别名字典**（SearchTableDiceroll 按 `dice[diceKind]`
# 直查），1 版表的别名字典实测（ledger.dice 逐条）：
#   JITSB：10 个键 → 2 个唯一骰型
#         1d6    ← a / d / d6 / 1d / 1d6            （5 个）
#         1d6+1  ← b / d+1 / 1d+1 / d6+1 / 1d6+1    （5 个）
#   KRM：  13 个键 → 3 个唯一骰型
#         1d6    ← a / d / d6 / 1d / 1d6            （5 个）
#         1d6+1  ← b / d+1 / 1d+1 / d6+1 / 1d6+1    （5 个）
#         2d6    ← c / 2d / 2d6                     （3 个）
#
# ASCII 化规则（任务书拍板，参照 2版 KRS 族的 `_A` 后缀先例）：
#   **按骰型去重**，每个唯一骰型收敛成一个 `_A` / `_B` / `_C` 后缀：
#     JITSB → A=1d6, B=1d6+1
#     KRM   → A=1d6, B=1d6+1, C=2d6
#   裸命令 = A（天狗 tablehelp.js：「ショートカット英字が省略された場合はAを
#   指定したものとみなします」）。
#
# ⚠ 别名里的 `d`（`d`/`d6`/`d+1`/`2d`/`2d6`）是**同型别名不是额外骰型**：
#   例如 KRM 的 `_D`（天狗 `,D`）实为 `1d6`，与 `_A` **完全同骰**。
#   故本批**不提供** `_D`：提供它等于凭空多一个与 A 无差别的可选项。
#   同理 JITSB **不提供** `_C` / `_D`（其 dice 字典里根本没有对应键）。
#   越界后缀（`WS_C` / `DKKI_C` / `KRM_D` / `JITSB_C`）一律**不响应**。
#
# ============================================================================
# 四、1版 prefixes_pattern 覆写（T1.7）
# ============================================================================
#
# 2版有阻塞级 bug：base.rb:47 把前缀数组原样拼进 `/^(S)?(...)/i`，其中
#   ① 可选 `(S)?` 是暗骰标记；② `register_prefix("[KENHU]")` 里的 `[KENHU]`
#   被当作**字符类**。命令 `SEISEN9` 回溯时先让 `(S)?` 吃掉 S，剩 `EISEN9`
#   交给 `[KENHU]` 字符类，其 `E` 匹配首字母 → 命令变成 `EISEN9` → 不响应。
#
# **1版的实证结论（与 2版不同，故本文件用另一种形态）：**
#   ① 1版父类 NinjaSlayer 只注册 `NJ EV AT EL SB` 五个前缀，
#      **没有 `[KENHU]` 字符类**，也没有 `WS/WSE/NRS`；
#   ② 本批新增的 9 个前缀两两**无遮蔽**（无一是另一的前缀）；
#   → 故「`(S)?` 吃掉 S 后剩余串恰好匹配另一个前缀」这条 2版 的失败路径
#      在 1版**走不通**：`SOUL` 里 `(S)?` 吃掉 S 后剩 `OUL`（无前缀匹配）
#      → 正则回溯让 `(S)?` 匹配空 → `SOUL` 正常命中。
#   → 穷举探针（14 前缀 + 各暗骰形态 + 畸形样本，共 63 条候选）实测：
#      **未加覆写的引擎原生 pattern 与下述覆写形态逐条行为一致（0 差异）**。
#
# 本覆写的价值是**预防性**而非修补：把前缀交替顺序固定为「长度降序」，
# 于是日后若有人注册 `BK` / `BKX` 这类互为前缀的新命令，最长前缀先试、
# 不会复现「`SB` 先命中吃掉 `SBX`」的遮蔽；同时**刻意保留 `(S)?` 分组**，
# 使全部暗骰形态（`SBK` / `SBIOCYBER` / `SSOUL` …）与引擎原生行为逐字节一致。
#
# ⚠ **为何不照抄 2版的「只保护 S 前缀」形态**（探针实证，会回归）：
#     2版形态 = `\A(?:<S 开头前缀降序>|^(S)?(<全部前缀>))`。
#     把它套到 1版前缀上，保护分支排在 `(S)?` **之前**，而 1版 恰好有
#     `SB` / `SOUL` / `SUMMON` 三个 S 开头前缀：
#       · `SBK`       → 以 `SB` 开头 → 剩 `K`       → **合法暗骰静默失效**
#       · `SBIOCYBER` → 以 `SB` 开头 → 剩 `IOCYBER` → **合法暗骰静默失效**
#     风险集 = { 非 S 前缀 q | "S"+q 以某 S 前缀开头 }，1版 实测 = [BK, BIOCYBER]，
#     各自 × 6 种后缀形态 = **12 条命令全部回归**（穷举实测，守卫见
#     test/engine_structure_test.rb 的 test_edition1_two_version_form_would_regress_secret_commands）。
#     注意 `SNJ4` **不在**其中：`SNJ4` 不以任何 S 前缀开头 → 保护分支不命中，
#     回溯到 `(S)?` 分支 → 行为与引擎原生一致。
#     本文件因此采用「全部前缀长度降序 + 保留 `(S)?`」形态。
# ============================================================================
#
# 参考：
#   - 上游 lib/bcdice/base.rb:22-29    register_prefix / register_prefix_from_super_class
#   - 上游 lib/bcdice/base.rb:35-47    prefixes_pattern 冻结行为
#   - 上游 lib/bcdice/preprocessor.rb  三关前处理（空白/括号/implicit-D）
#   - 上游 lib/bcdice/dice_table/table.rb  Table#choice 用 `value - @times`（相对索引）
#   - references/src/TenguDiceBot/.../tengu_dice/nd_datatable.js:303-473  1版 9 表源
#   - references/src/TenguDiceBot/.../tengu_dice/NJDiscordReply.js:91-97,115  钳制/定値原文
#   - references/src/TenguDiceBot/.../classes/SearchTableDiceroll.js  diceKind / +x 判定
#   - references/extracted/i18n_key_ledger.yml  9 表逐条登记（datarange / min_index / dice）
#   - docs/spike-t1.1-report.md §5.7  时序铁律
#   - 计划 §5 移植矩阵 / §8 T1.7
# ============================================================================

require "bcdice"
require "bcdice/game_system"
require "bcdice/game_system/NinjaSlayer"

module BCDice
  module GameSystem
    class NinjaSlayerEx < NinjaSlayer
      ID = "NinjaSlayerEx"

      # ゲームシステム名（kimi-code T1.1 评审 P5：Ex 类不得裸继承父类 NAME，
      # 否则 bot 侧列举游戏系统时与父类同名——bcdice-api 按 NAME/SORT_KEY
      # 输出列表，撞名会显示成两个一样的条目）。1版沿用 2版 Ex 的「拡張」后缀惯例。
      NAME = "ニンジャスレイヤーTRPG 拡張"

      # ゲームシステム名の読みがな
      # 排序实证（2026-10-11）：「…TRPG」<「…TRPG1かちょう」<「…TRPG2」<「…TRPG2かちょう」
      # （'1'<'2'<'か'），故 1版拡張 用「TRPG1かちょう」——bot 列表呈
      # 1版 → 1版拡張 → 2版 → 2版拡張 连续排列（kimi T1.3 评审 P1：
      # 初版「TRPGかちょう」实测落到 2版拡張 之后，注释与事实相反）。
      SORT_KEY = "にんしやすれいやあTRPG1かちょう"

      # ダイスボットの使い方
      #
      # ⚠ **必须含父类的 HELP_MESSAGE 全文**（不是只写扩展部分）：
      #   HELP_MESSAGE 是**常量覆写**——Ex 类一旦自己定义，
      #   父类那段（NJ / EV / AT / EL / SB の说明）就**整个消失**，
      #   bot 侧 /help 只会显示扩展命令，1版玩家最常用的 NJ 判定反而没说明。
      #   2版 NinjaSlayer2Ex 初版也踩过同一形态的坑（HELP 里只见天狗表、
      #   看不见 K6/NRS 的用法），此处直接从 superclass 拼进来，
      #   父类日后增补说明也会自动跟着走（不复制第二份 = 不会漂移）。
      #
      # 先取父类全文（常量在类体内已定义，直接引用即可）。
      parent_help = NinjaSlayer::HELP_MESSAGE

      # 注意父类 HELP 末行的「※上記コマンド群は『コア・ルールブック』に対応していません」
      # 会一并保留——那是父类对 1版 的准确声明，本扩展不改变它的事实基础。
      HELP_MESSAGE = begin
        extension_help = <<~TEXT
        --- 天狗ダイス版 追加コマンド ---
        本システム（ニンジャスレイヤーTRPG 1版 拡張）は、天狗ダイス忍杀の独自表を
        移植しているため、親类的コマンドに加えて以下のコマンドが使用できます。

        --- 天狗独自表 9 種（T1.7）---
        記法（全表共通）：
        - 素の `表名` は `_A` と同じ（ショートカット省略時はAとみなします）。
        - `_A` / `_B` / `_C` でダイス型を選びます（**表ごとに使える文字が異なります**）。
        - `@出目` で**定値表示**します（dice を振らず、その出目の項目だけを表示）。

        - WS          Wasshoi!エントリー      A…1D6
        - JITSB       ジツ拡張サイバネ暴走    A…1D6  B…1D6+1
        - DKKI        暗黒カラテ衝動          A…1D6
        - KRM         カルマロンダリング      A…1D6  B…1D6+1  C…2D6
        - CYBER       サイバネ狂気判定        A…2D6
        - BIOCYBER    バイオサイバネ狂気判定  A…1D6
        - SOUL        ソウル鑑定              A…1D6
        - SUMMON      ソーマトリコール        A…2D6
        - BK          生い立ち                A…1D36

        例：
        - KRM_C       → 2D6 を振ってカルマロンダリング表を引く
        - JITSB       → 1D6 を振ってジツ拡張サイバネ暴走表を引く
        - CYBER       → 2D6 を振ってサイバネ狂気判定表を引く
        - BK@12       → 振らずに生い立ち表の 12 番を表示
        - WS@3        → 振らずに Wasshoi!エントリー の 3 番を表示

        ※ **使える `_X` は表ごとに決まっています**（上記のとおり）。
          例えば `WS_C` / `DKKI_C` / `JITSB_C` / `KRM_D` は応答しません。
        ※ `@出目` は**表の収録範囲内**だけ応答します
          （1D6 表＝1〜6、2D6 表＝2〜12、1D36 表＝1〜36）。
          範囲外（例：WS@0 / WS@7 / CYBER@1 / BK@37）は応答しません。
          先頭の 0 も範囲外です（例：WS@03 は応答しません）。
        ※ 本 9 表に**補正値**（`@+3` 等の掷骰補正）は**ありません**。
          天狗 1版この 9 表に可変値（+x）が無いため、補正も钳制も発生しません。
          出目が表の範囲外に出た場合はdice を振り直してください。
        ※ 親類的命令（NJ / EV / AT / EL / SB）は**一切変更していません**。
        ※ 上の親類ヘルプの例（NJ4 / EV5/3 / AT6[H] / EL6[H]）もそのまま使えます。
        TEXT

        parent_help + extension_help
      end

      # T1.1①：先继承超类全部前缀（NJ/EV/AT/EL/SB）。
      # T1.7：再用 register_prefix 追加本扩展的 9 个表前缀。
      #
      # ⚠ 时序铁律（spike-t1.1-report.md §5.7 / 上游 base.rb:35-47）：
      # prefixes 在首次 eval / command_pattern / prefixes_pattern 调用时冻结，
      # 此后任何 register_prefix 都会 FrozenError。**全部注册必须在类体内完成**。
      register_prefix_from_super_class()
      register_prefix(
        # T1.7 的 9 张天狗 1版表。**前缀注册顺序无功能含义**（前缀组是
        # 无锚点的 `prefix` 匹配，唯一顺序敏感处是 engine_structure_test 里
        # 钉死的 prefixes_pattern 长度降序覆写，见文件头 §4）。
        #
        # 两两无遮蔽（无一是另一的前缀），故无论注册顺序如何，
        # 引擎原生 alternation 与本类的降序覆写结果一致（实测 0 差异）。
        "WS",
        "JITSB",
        "DKKI",
        "KRM",
        "CYBER",
        "BIOCYBER",
        "SOUL",
        "SUMMON",
        "BK"
      )

      # ======================================================================
      # T1.7：1版 9 表 —— 骰型 / 索引 / 骨架的逐表登记
      # ======================================================================

      # 9 张表的键（T1.7 清单，顺序 = i18n yml 顺序 = ledger 顺序）。
      EDITION1_TABLES = %w[WS JITSB DKKI KRM CYBER BIOCYBER SOUL SUMMON BK].freeze

      # 每张表 → 各 `_X` 后缀的骰型规格。
      #
      # expr  = 输出里展示的骰型标记（含常量项，如 "1D6+1"）
      # times/sides = 实际掷的骰
      # bonus = 骰型常量（先计入绝对出目，再按表级 min_index 索引）
      #
      # 单骰型表的键只有 "A"——**不存在** `_B`/`_C`（给了也不响应）。
      # 数据源同源：nd_datatable.js 各表的 `dice: {...}` + ledger.dice_ranges。
      EDITION1_DICE_TYPES = {
        # wasshoiエントリー_1（1d6）。出目顺序与 2版 wasshoiエントリー**不同**
        # （1版 3=天井破壊 / 5=KRAAAAASH 窓 / 2版 3=冷蔵庫 → 见 ledger.note），
        # 属天狗 1版原文，**忠实照搬不做对齐**。
        "WS" => { "A" => { expr: "1D6", times: 1, sides: 6, bonus: 0 } }.freeze,
        # ジツ拡張サイバネ暴走_1（data 1..7）：源码 10 个别名字典去重成 2 个骰型。
        "JITSB" => {
          "A" => { expr: "1D6", times: 1, sides: 6, bonus: 0 },
          "B" => { expr: "1D6+1", times: 1, sides: 6, bonus: 1 }
        }.freeze,
        "DKKI" => { "A" => { expr: "1D6", times: 1, sides: 6, bonus: 0 } }.freeze,
        # カルマロンダリング_1（data 1..12）：源码 13 个别名字典去重成 3 个骰型。
        # ⚠ 与 2版 KRS 族**不是同一张表**：1版 KRM 的 c 是 2D6（2版 KRS 的 c 是 1D6+1）。
        "KRM" => {
          "A" => { expr: "1D6", times: 1, sides: 6, bonus: 0 },
          "B" => { expr: "1D6+1", times: 1, sides: 6, bonus: 1 },
          "C" => { expr: "2D6", times: 2, sides: 6, bonus: 0 }
        }.freeze,
        "CYBER" => { "A" => { expr: "2D6", times: 2, sides: 6, bonus: 0 } }.freeze,
        "BIOCYBER" => { "A" => { expr: "1D6", times: 1, sides: 6, bonus: 0 } }.freeze,
        "SOUL" => { "A" => { expr: "1D6", times: 1, sides: 6, bonus: 0 } }.freeze,
        "SUMMON" => { "A" => { expr: "2D6", times: 2, sides: 6, bonus: 0 } }.freeze,
        # 生い立ち_1（d36 = **单颗 36 面**，T1.5 已实证，非 D66 组合表）。
        "BK" => { "A" => { expr: "1D36", times: 1, sides: 36, bonus: 0 } }.freeze
      }.freeze

      # 每张表的索引下限（表级 min_index）。
      #
      # ⚠ **不是恒为 1**：CYBER / SUMMON 是 2d6 表，data 键 2..12 → min_index = 2。
      #   写成单一常量 1 会让这 2 张表整体错位一格（出目 2 取到第 2 号表项）。
      #   该值与 ledger.min_index 逐表一致，由 test/ledger_consistency_test.rb
      #   与 scripts/gen_table_toml.rb 的三方交叉校验共同钉死。
      EDITION1_MIN_INDEX = {
        "WS" => 1, "JITSB" => 1, "DKKI" => 1, "KRM" => 1, "CYBER" => 2,
        "BIOCYBER" => 1, "SOUL" => 1, "SUMMON" => 2, "BK" => 1
      }.freeze

      # 每张表的骨架选型（T1.7 拍板：9 表**全部**无钳制）。
      #
      # 把「选型」本身也登记成数据而非散落在注释里，好让常驻测试能断言
      # 「骨架选型与 ledger 的 datarange 登记一致」——有人给某张表加上
      # datarange（或反过来偷偷加钳制常量）时当场红，而不是等到某天
      # 玩家掷出个越界出目才发现行为变了。
      #
      # 取值：
      #   :no_clamp  无钳制（天狗 else 分支：data[出目]，越界 → 不响应）
      #   :clamp     钳制到 datarange 端点（天狗 isTableAdditionValue 分支）
      EDITION1_SKELETONS = EDITION1_TABLES.to_h { |k| [k, :no_clamp] }.freeze

      # 1版 9 表的命令正则。
      #
      # 三个**互斥**的捕获组：
      #   1 = 表名      2 = `_X` 骰型后缀（nil = 裸命令 = A）
      #   3 = `@出目` 定値表示（nil = 掷骰查表）
      #
      # 两条约束逐条对应天狗原文：
      #   ① `([1-9]\d*)` 而非 `(\d+)`：天狗 /fnd 是**字符串键**直查
      #      （NJDiscordReply.js:115 `data[stringArray[1]] != null`），
      #      data 的键是 "1".."36"，故 "03" 查不到 → 不响应。
      #      上界不在正则里写死，由 proc 按 items 长度守卫，
      #      这样 yml 条目数与命令上界**恒等**（同 T1.5 CHARAMAKE 的处理）。
      #   ② 表名 alternation 按**长度降序**书写（BIOCYBER 先于 CYBER）。
      #      本组**不设** `\A`/`\z` 之外的锚点自由，元组正则整体锚定，
      #      且无前缀遮蔽，故顺序在此不影响结果——写成降序只是为了
      #      「最长先试」这一意图在源码里一眼可读，与 prefixes_pattern 覆写同构。
      RE_EDITION1 = /\A(BIOCYBER|SUMMON|JITSB|CYBER|DKKI|SOUL|KRM|BK|WS)(?:_([ABC]))?(?:@([1-9]\d*))?\z/i.freeze

      # ======================================================================
      # prefixes_pattern 覆写（T1.7）—— 前缀交替顺序固定为长度降序
      # ======================================================================
      #
      # 形态：`\A(S)?(<全部前缀，长度降序>)`
      #
      # 与 2版 NinjaSlayer2Ex 的差异（**刻意不同**，见文件头 §4 的实测结论）：
      #   2版：`\A(?:<S 开头前缀降序>|^(S)?(<全部前缀>))`
      #   1版：`\A(S)?(<全部前缀降序>)`
      #
      # 理由：1版父类无 `[KENHU]` 字符类、14 个前缀两两无遮蔽，
      # 「`(S)?` 吃掉 S 后剩余串误命中另一前缀」这条 2版 的失败路径不存在；
      # 而套用 2版形态会让保护分支抢在 `(S)?` 之前命中 `SB`，
      # **回归掉合法暗骰 `SBK` / `SBIOCYBER`**（实测 3 条）。
      # 本形态保留 `(S)?` 分组 → 全部暗骰形态与引擎原生逐条一致，
      # 同时把「最长前缀先试」固定下来，杜绝未来的前缀遮蔽。
      #
      # 实测（本文件 §4 的穷举探针）：对 14 前缀 + 各暗骰形态 + 畸形样本
      # 共 63 条候选，本覆写与**未覆写的引擎原生 pattern 行为零差异**
      # —— 即当前它是**行为中性的预防性覆写**，价值在于「日后新注册前缀时
      # 不依赖 alternation 顺序恰好正确」。
      #
      # 实现注意：父类 @prefixes_pattern 是**实例变量**而非类变量字典，
      # 但 Ruby 的类实例变量沿继承链各自独立，故这里直接重设本类的
      # @prefixes_pattern 即可（父类的缓存不受影响）。
      #
      # R1 升级守卫：test/engine_structure_test.rb 断言本覆写的结构形态
      #   （通式而非硬编码前缀名），上游改 prefixes_pattern 签名/语义时当场红。
      def self.prefixes_desc
        # 首次调用即冻结（与上游 prefixes_pattern 同一时序铁律）。
        # 排序键 = [-长度, 原序] —— 长度相同时保持注册顺序（稳定），
        # 使 pattern.source 逐字节可复现（幂等断言需要）。
        @prefixes_desc ||= prefixes.sort_by.with_index { |p, i| [-p.length, i] }.freeze
      end

      def self.prefixes_pattern
        @prefixes_pattern ||= Regexp.new(
          "\\A(S)?(?:#{prefixes_desc.join('|')})",
          Regexp::IGNORECASE
        ).freeze
      end

      # 父类实现的入口覆写（T1.1 / 计划 §15.5 V4 同形写法）。
      #
      # 先匹配本类新命令；未命中一律交给 `super`——父类实现内建
      # rescue→nil（语法错误即不响应），**不要复制父类方法体**。
      #
      # @param command [String]
      # @return [Result, String, nil]
      def eval_game_system_specific_command(command)
        result = proc_ex_command(command)
        return result unless result.nil?

        return super
      end

      private

      # 本扩展命令的分发。未命中返回 nil（交由 super 处理）。
      #
      # 本方法自身不抛异常：出目越界时 proc_edition1_table 返回 nil
      # （= 不响应），任何分支都不允许 nil 文本漏进输出。
      #
      # @param command [String]
      # @return [String, nil]
      def proc_ex_command(command)
        case command
        when RE_EDITION1
          return proc_edition1_table(
            Regexp.last_match[1].upcase,
            Regexp.last_match[2] || "A", # nil → 裸命令 = A（天狗 tablehelp.js）
            Regexp.last_match[3]        # nil = 掷骰查表；非 nil = @出目 定値表示
          )
        end

        return nil
      end

      # 1版 9 表を振る（掷骰查表 / `@出目` 定値表示 两条互斥路径）
      #
      # 忠实移植天狗「纯表查询」语义链：
      #   掷骰  : roll(times, sides) + bonus → sum → items[sum - min_index]
      #   定値  : items[fixed - min_index]（不掷骰，天狗 /fnd 等价）
      #
      # ⚠ **绝不钳制**（见文件头 §1）：本批 9 表 datarange 恒为 nil
      #   （天狗 dice 字面量无 "+x" → isTableAdditionValue 不置位 → 走
      #   else 分支 `data[出目]`），故越界一律**不响应**，与 T1.5 CHARAMAKE 同型。
      #
      # 输出骨架（与 1版父类自己的 SB 表 `サツバツ表(1) ＞ …` 同形）：
      #   `<日文表名>(<出目>) ＞ <正文>`
      #   表名取 yml `name` 按第一个 '(' 截断（yml 的 `(1D6)` 是**默认骰型 a**
      #   的标记，而 JITSB_B / KRM_C 实际掷的是 1D6+1 / 2D6，直接用 name
      #   会标错 = 假信息）。日文表名逐字来自 yml，不在代码里手写。
      #
      # @param key [String] EDITION1_TABLES 的键
      # @param dice_type_s [String] "A" / "B" / "C"（该表不支持的字母 → nil）
      # @param fixed_s [String, nil] `@出目` 的原始串（nil = 掷骰）
      # @return [String, nil]
      def proc_edition1_table(key, dice_type_s, fixed_s)
        spec = EDITION1_DICE_TYPES[key]&.[](dice_type_s)
        return nil if spec.nil? # 未知表 / 该表不支持的骰型后缀（如 WS_C）

        min_index = EDITION1_MIN_INDEX.fetch(key)
        items = translate("NinjaSlayerEx.table.#{key}.items")
        label = edition1_table_label(key)

        if fixed_s.nil?
          # 掷骰路径：骰型常量先计入绝对出目，再按表级 min_index 索引。
          sum = @randomizer.roll_sum(spec[:times], spec[:sides]) + spec[:bonus]
          body = items[sum - min_index]
          # 掷骰可达域恒 ⊆ 表跨度（EDITION1_REACHABLE 的不变量，
          # 由 ledger_consistency_test.rb 常驻断言），故此处理论不可达；
          # 仍保留守卫：yml 若被手工改短，守卫会让它安静地不响应，
          # 而不是产出 nil 文本或 IndexError 冒泡（父类 eval 有 rescue，
          # 会吞成「语法错误」、掩盖真因）。
          return nil if body.nil?

          return "#{label}(#{sum}) ＞ #{body}"
        end

        # 定値表示路径。天狗用字符串键直查（NJDiscordReply.js:115），
        # 此处已由正则挡掉前导零（铁律①），再补上界守卫：
        # `@7`（1D6 表）/ `@1`（2D6 表，min_index=2）/ `@37`（1D36 表）
        # 越界 → 不响应。
        #
        # ⚠ 下界侧**不能**靠「索引算出负数 → 数组取到 nil」来兜底：
        #   Ruby 负下标会绕回数组末尾、返回**最后一项**而非 nil
        #   （T1.5 实测踩中，见 ledger_consistency_test 的同名注释）。
        #   故先显式判 `fixed < min_index` 再算索引。
        fixed = fixed_s.to_i
        return nil if fixed < min_index

        body = items[fixed - min_index]
        return nil if body.nil?

        "#{label}(#{fixed}) ＞ #{body}"
      end

      # 1版 9 表的标签（不带骰型标记）。
      #
      # yml 的 name 形如 `カルマロンダリング_1(1D6) ＞ `，其中 `(1D6)` 是
      # **默认骰型 a** 的标记（ledger.roll_note），而 B/C 实际掷的是
      # 1D6+1 / 2D6 —— 直接用 name 会把 `KRM_C` 的输出标成 1D6（假信息）。
      # 与 2版 nsrs_table_label / karmarond_table_label 同解：
      # 按第一个 '(' 截断，日文表名本身逐字来自 yml。
      #
      # @param key [String]
      # @return [String]
      def edition1_table_label(key)
        translate("NinjaSlayerEx.table.#{key}.name")[/\A[^(]*/]
      end
    end
  end
end