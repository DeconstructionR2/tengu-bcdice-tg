# frozen_string_literal: true

# ============================================================================
# NinjaSlayer2 外部扩展类：NSRS 発狂表 + 天狗呈现版 SBX/WSX（T1.3 实证产物）
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
#
# 参考：
#   - 上游 lib/bcdice/base.rb:22-29    register_prefix / register_prefix_from_super_class
#   - 上游 lib/bcdice/base.rb:35-47    prefixes_pattern 冻结行为
#   - 上游 lib/bcdice/dice_table/table.rb  Table#choice 的 index 语义
#   - 上游 lib/bcdice/game_system/NinjaSlayer2.rb  父类 NRS / SB / WSE 的输出形态
#   - docs/spike-t1.1-report.md         四机制实证与坑点
#   - docs/t1.2-coverage-audit.md §5.1  天狗绝对索引 vs BCDice 相对索引
#   - references/extracted/i18n_key_ledger.yml  NSRS / SBX / WSX 逐表登记
#   - 计划 §5 移植矩阵 / §8 T1.3 / §12 R3
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
        親类的行为は一切変更していません。
      TEXT

      # T1.1①：先继承超类全部前缀（UH/[KENHU]/SB/WS/WSE/NRS）。
      # T1.3：再用 register_prefix 追加本扩展的三个新前缀。
      #
      # ⚠ 时序铁律（spike-t1.1-report.md §5.7 / 上游 base.rb:35-47）：
      # prefixes 在首次 eval / command_pattern / prefixes_pattern 调用时冻结，
      # 此后任何 register_prefix 都会 FrozenError。**全部注册必须在类体内完成**。
      register_prefix_from_super_class()
      register_prefix(
        "NSRS",
        "SBX",
        "WSX"
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
      # 本方法自身不抛异常：所有出目在查表前都已用 items 边界校验兜底，
      # 越界只当不响应。
      # @param command [String]
      # @return [String, nil]
      def proc_ex_command(command)
        case command
        when RE_EX_NSRS
          return proc_nsrs(Regexp.last_match[1] || "A")
        when RE_EX_SIMPLE_TABLE
          return proc_ex_simple_table(EX_SIMPLE_TABLES.fetch(Regexp.last_match[1].upcase))
        end

        return nil
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