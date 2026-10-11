# frozen_string_literal: true

# ============================================================================
# NinjaSlayer2 外部扩展类：NSRS 発狂表 + 天狗呈现版 SBX/WSX（T1.3）、
#                          カルマロンダリング ×5 派阀（T1.4）
# （#1版动作见姊妹文件 NinjaSlayerEx.rb）
#
# 目的：
#   1. 移植天狗ダイス忍杀的 NSRS 発狂表（BCDice 缺失项）—— 4 骰型命令族。
#      **语义=忠实天狗纯表查询**：天狗 `/nd NSRS発狂[,{A|B|C|D}]` 只掷骰查表，
#      **没有** 前置的 NRS 克服判定（父类 `NRS` 命令才有 `nB6>=难度` 那一步）。
#      用户 2026-10-11 拍板：不镜像父类的前置判定。
#   2. 移植天狗呈现版的 サツバツ / wasshoiエントリー 两张表为 SBX / WSX
#      （拍板 D1-A1=B：父类 SB / WSE 的纯文本版与天狗版并存，父类行为零改动）。
#   3. 覆写 NAME / SORT_KEY / HELP_MESSAGE（kimi-code T1.1 评审 P5）：
#      Ex 类不能裸继承父类的 NAME（bot 侧列举游戏系统时会与父类撞名）。
#   4. T1.4：移植天狗 カルマロンダリング ×5 派阀（KRS/KRZ/KRA/KRO/KRY）——
#      5 表 × 4 骰型（a~d）+ `@±x` 補正 + datarange 钳制。
#      **钳制先于索引**（天狗 NJDiscordReply.js:93-95 原文语义），
#      越界不是「不响应」而是取 datarange 端点项——与 NSRS 的 nil 守卫相反。
#
# 参考：
#   - 上游 lib/bcdice/base.rb:22-29    register_prefix / register_prefix_from_super_class
#   - 上游 lib/bcdice/base.rb:35-47    prefixes_pattern 冻结行为
#   - 上游 lib/bcdice/preprocessor.rb  三关前处理（空白/括号/implicit-D）
#   - 上游 lib/bcdice/dice_table/table.rb  Table#choice 的 index 语义
#   - 上游 lib/bcdice/game_system/NinjaSlayer2.rb  父类 NRS / SB / WSE 的输出形态
#   - references/src/TenguDiceBot/TenguDiceBot/tengu_dice/NJDiscordReply.js:93-95
#       钳制原文（超 max 取 data[max]、低于 min 取 data[min]）
#   - references/src/TenguDiceBot/TenguDiceBot/classes/SearchTableDiceroll.js
#       +x 解析原文（Number() + Math.floor，负数走 else 分支替换）
#   - references/src/TenguDiceBot/TenguDiceBot/classes/dice.js
#       d3+3+x 的真实掷法（split(/\+/)：无補正时 ["d3","3"]，有補正时 ["d3","3","x"]）
#   - docs/spike-t1.1-report.md         四机制实证与坑点
#   - docs/t1.2-coverage-audit.md §5.1  天狗绝对索引 vs BCDice 相对索引
#   - references/extracted/i18n_key_ledger.yml  NSRS/SBX/WSX/KR* 逐表登记
#   - docs/t1.4-karmarond-report.md    本任务实绩报告（含 Preprocessor 三关实测）
#   - 计划 §5 移植矩阵 / §8 T1.3·T1.4 / §12 R3
# ============================================================================

require "bcdice"
require "bcdice/game_system"
require "bcdice/game_system/NinjaSlayer2"

module BCDice
  module GameSystem
    class NinjaSlayer2Ex < NinjaSlayer2
      ID = "NinjaSlayer2Ex"

      # ゲームシステム名（kimi-code T1.1 评审 P5：加「拡張」后缀避免与父类撞名）
      NAME = "ニンジャスレイヤーTRPG 2版 拡張"

      # ゲームシステム名の読みがな
      # 上游惯例（bcdice-api dicebots.rb 按 SORT_KEY 升序列出系统）：
      # 变体类在父类 SORT_KEY 之后追加读音即可排到父类正下方；
      # 「…TRPG2」< 「…TRPG2かちょう」，且 1版「…TRPG」自然排在其前。
      SORT_KEY = "にんしやすれいやあTRPG2かちょう"

      HELP_MESSAGE = <<~TEXT
        --- 天狗ダイス版 追加コマンド ---
        本システム（ニンジャスレイヤーTRPG 2版 拡張）は、天狗ダイス忍杀の独自表を
        移植しているため、親类的コマンドに加えて以下のコマンドが使用できます。
        （HELP の全面整備は別タスクで拡張予定）

        --- 天狗独自表：NSRS発狂 ---
        - NSRS or NSRS_A
        1D3を振り、NSRS（ニンジャ・リアリティ・ショック）発症時の反応を決定します。

        - NSRS_B
        1D6を振り、NSRS_A と同じ表を参照します。

        - NSRS_C
        1D6+1を振り、NSRS_A と同じ表を参照します。

        - NSRS_D
        1D3+1を振り、NSRS_A と同じ表を参照します。

        ※ NSRS 発狂表は「発症後の反応決定」だけの表で、前段の NRS 判定
        （`{dice}B6>={難易度}`）は行いません。NRS 判定には親类的 NRS コマンドを併用してください。
        ※ 未知の枝（例：NSRS_X）は応答しません。

        --- 天狗呈现版 定型表 ---
        - SBX
        1D6を振り、サツバツ表（天狗呈现版・効果サマリー付き）を返します。

        - WSX
        1D6を振り、Wasshoi!エントリー決定表（天狗呈现版）を返します。

        ※ 親类的 SB / WSE は純テキスト版（SATSUBATSU / WASSHOI 表による出力）のままで、
        親类的行為は一切変更していません。

        --- カルマロンダリング（5 派閥）---
        5 派閥とも同じ形です。`@補正値` を付ける場合は `_A`〜`_D` の
        ショートカットを省略できません（天狗の仕様どおり）。

        - KRS        （ソウカイヤ派）
        - KRZ        （ザイバツ派）
        - KRA        （アマクダリ派）
        - KRO        （オムラ派）
        - KRY        （ヨロシサン派）

        記法：
        - 素の `KRS` は `KRS_A` と同じ（ショートカット省略時は A とみなします）。
        - `_A` / `_B` / `_C` / `_D` でダイス型を選びます。
        - `@+n` / `@-n` で補正値を選びます（負の値も指定できます）。
          小数は向下取整（`@1.9` → +1。天狗の `Number()+Math.floor` と同じ语义）。

        ダイス型：
        - KRS（ソウカイヤ）：A…1D3、B…1D6、C…1D6+1、D…2D6
        - KRZ / KRA / KRO / KRY：
          A…1D3、B…1D3+1、C…2D3、D…1D3+3

        例：
        - KRS_C         → 1D6+1 を振ってソウカイヤの表を引く
        - KRS_C@2       → 補正 +2
        - KRZ_D@-1      → 補正 -1（負の補正値）
        - KRO_D         → 1D3+3（補正なし）

        ※ 補正値を足した出目が表の収録範囲をこえた場合、
        範囲のうち最も近い値の項目を参照します
        （ソウカイヤ＝1〜12、その他 4 派閥＝1〜6。天狗と同じクランプ）。
        ※ 未知の派閥（例：KRB）や未知のダイス型（例：KRS_E）は応答しません。
      TEXT

      # T1.1①：先继承超类全部前缀（UH/[KENHU]/SB/WS/WSE/NRS）。
      # T1.3：再用 register_prefix 追加本扩展的三个新前缀。
      # T1.4：追加カルマロンダリング 5 派阀前缀（KRS/KRZ/KRA/KRO/KRY）。
      #
      # ⚠ 时序铁律（spike-t1.1-report.md §5.7 / 上游 base.rb:35-47）：
      # prefixes 在首次 eval / command_pattern / prefixes_pattern 调用时冻结，
      # 此后任何 register_prefix 都会 FrozenError。**全部注册必须在类体内完成**。
      register_prefix_from_super_class()
      register_prefix(
        "NSRS",
        "SBX",
        "WSX",
        "KRS",
        "KRZ",
        "KRA",
        "KRO",
        "KRY"
      )

      # 本扩展表命令的正则。
      #
      # NSRS 发狂表：裸 NSRS == NSRS_A（天狗省略快捷键时按 a 处理，
      # 见 tengu_dice/tablehelp.js「ショートカット英字が省略された場合はAを指定したものとみなします」）。
      RE_EX_NSRS = /^NSRS(?:_([ABCD]))?$/i.freeze

      # NSRS 発狂表的 4 个骰型。
      # 数据源：tengu_dice/nd_datatable.js:275-291 的 `dice: {a,b,c,d}`
      # （i18n_key_ledger.yml 的 NSRS 条目同源登记）。
      #
      # ⚠ yml 里的 `type: 1D3` **只表达默认骰型 a**（ledger roll_note），
      #   因此 DiceTable::Table.from_i18n 对本表不适用：
      #     - Table#choice 用 `value - @times` 算 index，是相对索引；
      #     - 天狗是绝对索引 `data[sum]`，含 +1 骰型时两者错位一格
      #       （coverage-audit §5.1）。
      #   故本表手写 roll + 显式 min_index 索引。
      NSRS_DICE_TYPES = {
        "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
        "B" => { expr: "1D6", times: 1, sides: 6, bonus: 0 },
        "C" => { expr: "1D6+1", times: 1, sides: 6, bonus: 1 },
        "D" => { expr: "1D3+1", times: 1, sides: 3, bonus: 1 }
      }.freeze

      # NSRS 発狂表的索引下限：天狗 data[1..7]，yml 已摊平为 0 基数组 → items[sum - 1]。
      NSRS_TABLE_MIN_INDEX = 1

      # 本扩展的两张 1d6 单骰型表（ledger: 单骰型表 type 与 data_index 全域一致，
      # 可直接用 DiceTable::Table）。
      EX_SIMPLE_TABLES = {
        "SBX" => "NinjaSlayer2Ex.table.SBX",
        "WSX" => "NinjaSlayer2Ex.table.WSX"
      }.freeze

      RE_EX_SIMPLE_TABLE = /^(SBX|WSX)$/i.freeze

      # ======================================================================
      # T1.4：カルマロンダリング ×5 派阀
      # ======================================================================
      #
      # 语义铁律（源码实测值，逐条对应 kimi-code T1.3 评审预警）：
      #
      # ① 钳制先于索引（tengu_dice/NJDiscordReply.js:93-95 原文）：
      #      if (datarange.max < sumall) table = data[datarange.max];
      #      else if (datarange.min > sumall) table = data[datarange.min];
      #      else table = data[sumall];
      #    → 越界**不是**「不响应」，而是取 datarange 端点项。
      #    → T1.3 NSRS 的 `return nil if body.nil?` 守卫**在此不适用**，
      #      复用其骨架时必须改掉（见下方 proc_karmarond）。
      #
      # ② +x 解析（classes/SearchTableDiceroll.js:checkTable 原文）：
      #      Math.floor(Number(additionValue))；负数走 else 分支替换
      #      （diceStr.replace("+x", Math.floor(...)) → "1d3-2"）。
      #    → floor 语义、负数合法；省略/非数字 → 天狗替换为 "" 即 0。
      #    → 天狗 tablehelp.js：「補正値を指定するときにはショートカットを
      #      省略できません」→ ASCII 形态 KRS@-1 **不响应**，
      #      必须显式 KRS_A@-1（见 RE_KARMAROND）。
      #
      # ③ 索引恒为 items[clamp(sum) - min_index]，五表 min_index 均 = 1。
      #
      # ④ `d3+3+x`（4 派阀的 D 骰型）不是 1 颗 3 面 + 3，而是
      #      1 颗 3 面 **再加常量 3**（dice.js: 字符串按 '+' 拆分，
      #      纯数字段走 NUMBER_ONLY 分支计入 sum；末位空串不掷也不计）。
      #    → 语义等价于 ledger 登记的 `d3+3+x`，本次改写为 times=1/sides=3/bonus=3。
      #
      # ⑤ BCDice Preprocessor 三关与本语法的交互（**实测**，见
      #      docs/t1.4-karmarond-report.md §3）：
      #      - trim_after_whitespace：`KRS_C@2 foo` → `KRS_C@2`（正常，取空白前）
      #      - replace_parentheses：本语法规避 '(' ')'，永不改写
      #      - replace_implicit_d / `(\d+)D([^\w]|$)`：本类命令**不含 nD**
      #        （`@` 補正是纯数字，不触发），无副作用
      #    → 结论：ASCII `@±x` 形态与三关无冲突，无需 change_text 覆写。

      # 5 派阀 → 4 骰型规格。
      # 数据源同源：tengu_dice/nd_datatable.js:112-217 的 `dice: {a,b,c,d}`
      # + references/extracted/i18n_key_ledger.yml 的 dice_ranges 逐条登记。
      #
      # expr = 展示用骰型标记（含常量项，如 "1D6+1" / "1D3+3"）；
      # times/sides 是实际掷的骰；bonus 是常量（先计入 sum，再钳制、再索引）。
      KARMAROND_DICE_TYPES = {
        # ソウカイヤ派：1d3+x / 1d6+x / 1d6+1+x / 2d6+x（datarange 1..12）
        "KRS" => {
          "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
          "B" => { expr: "1D6", times: 1, sides: 6, bonus: 0 },
          "C" => { expr: "1D6+1", times: 1, sides: 6, bonus: 1 },
          "D" => { expr: "2D6", times: 2, sides: 6, bonus: 0 }
        }.freeze,
        # ザイバツ派：1d3+x / 1d3+1+x / 2d3+x / d3+3+x（datarange 1..6）
        "KRZ" => {
          "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
          "B" => { expr: "1D3+1", times: 1, sides: 3, bonus: 1 },
          "C" => { expr: "2D3", times: 2, sides: 3, bonus: 0 },
          "D" => { expr: "1D3+3", times: 1, sides: 3, bonus: 3 }
        }.freeze,
        # アマクダリ派：同上（1d3+x / 1d3+1+x / 2d3+x / d3+3+x）
        "KRA" => {
          "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
          "B" => { expr: "1D3+1", times: 1, sides: 3, bonus: 1 },
          "C" => { expr: "2D3", times: 2, sides: 3, bonus: 0 },
          "D" => { expr: "1D3+3", times: 1, sides: 3, bonus: 3 }
        }.freeze,
        # オムラ派：同上
        "KRO" => {
          "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
          "B" => { expr: "1D3+1", times: 1, sides: 3, bonus: 1 },
          "C" => { expr: "2D3", times: 2, sides: 3, bonus: 0 },
          "D" => { expr: "1D3+3", times: 1, sides: 3, bonus: 3 }
        }.freeze,
        # ヨロシサン派：同上
        "KRY" => {
          "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
          "B" => { expr: "1D3+1", times: 1, sides: 3, bonus: 1 },
          "C" => { expr: "2D3", times: 2, sides: 3, bonus: 0 },
          "D" => { expr: "1D3+3", times: 1, sides: 3, bonus: 3 }
        }.freeze
      }.freeze

      # 各表的 datarange（钳制边界）。来源：nd_datatable.js 各表的
      # `datarange: {max, min}`，ledger 同源登记（datarange 字段）。
      # 与 ledger dice_ranges 独立编码（此处刻意重复登记，gen_table_toml.rb
      # 会做 ledger ↔ 代码 的一致性交叉校验，见该脚本 §4）。
      KARMAROND_DATARANGE = {
        "KRS" => { min: 1, max: 12 }.freeze,
        "KRZ" => { min: 1, max: 6 }.freeze,
        "KRA" => { min: 1, max: 6 }.freeze,
        "KRO" => { min: 1, max: 6 }.freeze,
        "KRY" => { min: 1, max: 6 }.freeze
      }.freeze

      # 五表的索引下限恒为 1（ledger min_index 逐表登记 = 1）。
      KARMAROND_TABLE_MIN_INDEX = 1

      # カルマロンダリング命令的正则。
      #
      # 天狗原文法 `,C,-1`（表名,ショートカット,補正値）ASCII 化为
      # `{派阀}_{骰型}@{±補正}`。要点：
      #   - 裸 `{派阀}` == `{派阀}_A`（天狗「ショートカット英字が省略された
      #     場合はAを指定したものとみなします」，tablehelp.js:2 節）。
      #   - **带 @ 補正时必须显式 `_X`**（天狗「補正値を指定するときには
      #     ショートカットを省略できません」）→ `KRS@-1` 不匹配 → 不响应。
      #     故正则写成两个互斥分支而不是 `(...)?(?:@...)?` 的可省略嵌套：
      #     后者会让「省略 _X 仍带 @」意外通过（2026-10-11 实测踩中）。
      #   - `@` 后天狗是 Number(x) + Math.floor → 接受小数取下整
      #     （`KRS_A@1.9` → +1，`KRS_A@-1.5` → -2）。ASCII 侧保留 floor 语义。
      #   - 正负号皆可（`@+2` / `@-2`）；计划 §6 写的是 `@±x`。
      #     天狗原文法 `,C,2` 无符号，但 `Number("+2") === 2`，
      #     ASCII 侧显式允许正号属无损放宽（不改变任何既有语义）。
      #     负数合法（tablehelp 例 `/nd ソウカイヤカルマロンダリング,C,-1`）。
      #
      # 分组：1=派阀 / 2=骰型(带@时) / 3=補正值(带@时) / 4=骰型(不带@时)
      RE_KARMAROND = /^(KRS|KRZ|KRA|KRO|KRY)(?:_([ABCD])@([+-]?\d+(?:\.\d+)?)|(?:_([ABCD]))?)$/i.freeze

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
      # 本方法自身不抛异常：出目越界的处理**逐命令不同**——
      # NSRS/SBX 越界当不响应（NSRS 无 datarange，理论上不可达）；
      # カルマロンダリング越界**钳制到 datarange 端点**（天狗语义，见
      # proc_karmarond 与铁律①）。任何一条都不允许 nil 文本漏进输出。
      # @param command [String]
      # @return [String, nil]
      def proc_ex_command(command)
        case command
        when RE_EX_NSRS
          return proc_nsrs(Regexp.last_match[1] || "A")
        when RE_EX_SIMPLE_TABLE
          return proc_ex_simple_table(EX_SIMPLE_TABLES.fetch(Regexp.last_match[1].upcase))
        when RE_KARMAROND
          # 两个互斥分支：带 @ 的用分组 2/3，不带 @ 的用分组 4（nil → "A"）
          return proc_karmarond(
            Regexp.last_match[1].upcase,
            (Regexp.last_match[2] || Regexp.last_match[4] || "A"),
            Regexp.last_match[3]
          )
        end

        return nil
      end

      # カルマロンダリングを振る（5 派阀 × 4 骰型 + `@±x` 補正 + datarange 钳制）
      #
      # 忠实天狗 `,C,-1` → ASCII `_C@-1` 的语义链（SearchTableDiceroll.js
      # checkTable → diceroll.js → NJDiscordReply.js addTableOutput）：
      #   1. 掷骰（times/sides），加上骰型常量 bonus，再加用户補正；
      #   2. 钳制到 datarange（**先钳制**）；
      #   3. 按绝对出目索引 items[出目 - min_index]（min_index = 1）。
      #
      # ⚠ 与 proc_nsrs 的三处**故意**不同（kimi-code T1.3 评审预警逐条对应）：
      #   - 越界不返回 nil，而是取端点项（铁律①）；
      #   - 補正可以是负数（铁律②）；
      #   - 不需要「body.nil? 守卫」：钳制后索引必然落在 items 内。
      #
      # @param school [String] "KRS"/"KRZ"/"KRA"/"KRO"/"KRY"
      # @param dice_type_s [String] "A"/"B"/"C"/"D"
      # @param addition_s [String, nil] 補正值原始串（nil = 未指定 = 0）
      # @return [String, nil]
      def proc_karmarond(school, dice_type_s, addition_s)
        spec = KARMAROND_DICE_TYPES[school][dice_type_s]
        return nil if spec.nil?

        # 天狗 Math.floor(Number(x))：floor 语义、负数合法。
        # 未指定（nil）→ 0。天狗对非数字同样当 0，但我们的正则已限定
        # `@` 后必须是数字串，非数字形态直接不匹配 → 不响应（比天狗严格，
        # 避免把 `KRS_A@abc` 当成裸 KRS_A 静默掷骰）。
        # kimi P1-1：超长数字串 to_f → ±Infinity——**先**做有限性守卫再 floor
        # （Infinity.floor 本身抛 FloatDomainError，守卫放 floor 后则来不及）。
        # 非有限值按符号饱和到 ±10**6（语义等价于直接钳到 datarange 端点）。
        addition = 0
        if addition_s
          f = addition_s.to_f
          addition = f.finite? ? f.floor : (f.negative? ? -(10**6) : 10**6)
        end

        # 骰型常量 + 用户補正 一并计入绝对出目（天狗 diceStr 字符串拼接的等价物）
        sum = @randomizer.roll_sum(spec[:times], spec[:sides]) + spec[:bonus] + addition

        range = KARMAROND_DATARANGE[school]
        clamped = sum.clamp(range[:min], range[:max])
        # 钳制发生时明示：出目旁标注「(raw→clamped)（クランプ）」。
        # 天狗的钳制是**静默**的（NJDiscordReply.js 只取端点项、不提示）；
        # 本任务要求钳制可见，故加标注——语义不变，只是多告诉玩家一眼。
        # 同时把钳制后的实际索引值一并显示，便于对照 yml 逐条核验。
        face_mark = clamped == sum ? "(#{sum})" : "(#{sum}→#{clamped})（クランプ）"

        items = translate("NinjaSlayer2Ex.table.#{school}.items")
        body = items[clamped - KARMAROND_TABLE_MIN_INDEX]
        # 理论上钳制后不会越界（items 长度 == datarange 跨度），
        # 但 yml 若被手工改动长度会失配——兜底**按钳制方向取端点**而非 nil
        # （kimi P2-1：固定 items.first 在上溢时取错端点且掩盖失配；
        # 失配由 test/ledger_consistency_test.rb 常驻断言兜底）。
        if body.nil?
          body = clamped >= range[:max] ? items.last : items.first
        end

        "#{karmarond_table_label(school)}(#{spec[:expr]}) ＞ #{face_mark} ＞ #{body}"
      end

      # カルマロンダリング的标签（不带骰型标记）。
      #
      # yml 的 name 形如 `ソウカイヤカルマロンダリング(1D3) ＞ `，其中 `(1D3)`
      # 只是**默认骰型 a** 的标记（ledger roll_note），而 B/C/D 实际掷的是
      # 1D6 / 1D6+1 / 2D6，直接用 name 会标错（假信息）。
      # 与 nsrs_table_label 同解：按第一个 '(' 截断，日文表名逐字来自 yml。
      #
      # @param school [String]
      # @return [String]
      def karmarond_table_label(school)
        translate("NinjaSlayer2Ex.table.#{school}.name")[/\A[^(]*/]
      end

      # NSRS 発狂表を振る（忠实天狗纯表查询，无前置 NRS 判定）
      #
      # @param dice_type_s [String] "A" / "B" / "C" / "D"
      # @return [String, nil]
      def proc_nsrs(dice_type_s)
        spec = NSRS_DICE_TYPES[dice_type_s]
        return nil if spec.nil?

        # 補正込みの絶対出目。天狗は data[出目]（絶対）→ items[出目 - min_index]。
        # +1 骰型（C/D）不做任何额外偏移：sum 已含補正，直接按 min_index 索引。
        sum = @randomizer.roll_sum(spec[:times], spec[:sides]) + spec[:bonus]

        items = translate("NinjaSlayer2Ex.table.NSRS.items")
        body = items[sum - NSRS_TABLE_MIN_INDEX]
        # 越界（不应发生）当作不响应，避免 nil 文本进到输出里
        return nil if body.nil?

        "#{nsrs_table_label}(#{spec[:expr]}) ＞ (#{sum}) ＞ #{body}"
      end

      # NSRS 発狂表的标签（不带骰型标记）。
      #
      # yml 的 name 形如 `nsrs発狂(1D3) ＞ `，其中 `(1D3)` 只是**默认骰型 a**的标记
      # （ledger roll_note），而 +1 骰型实际掷的是 1D6+1 / 1D3+1，
      # 直接用 name 会把 C/D 的输出标成 1D3（假信息）。
      # 故按第一个 '(' 截断取标签，日文表名本身逐字来自 yml，不在代码里手写。
      # @return [String]
      def nsrs_table_label
        translate("NinjaSlayer2Ex.table.NSRS.name")[/\A[^(]*/]
      end

      # 天狗呈现版的 1d6 单骰型表を振る（SBX / WSX）。
      # 与父类 SB / WSE 的无指定出目分支同形：`DiceTable::Table.from_i18n(...).roll`。
      #
      # @param i18n_key [String]
      # @return [String]
      def proc_ex_simple_table(i18n_key)
        DiceTable::Table.from_i18n(i18n_key, @locale).roll(@randomizer).to_s
      end
    end
  end
end