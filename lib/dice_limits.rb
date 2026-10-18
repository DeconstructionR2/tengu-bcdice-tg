# frozen_string_literal: true

# ============================================================================
# lib/dice_limits.rb — BCDice 骰数/面数上限的显式守卫（2026-10-18 审核轮）
#
# 背景：BCDice 的 Randomizer 对超限骰组**不报错**，而是返回空集：
#   `1d1000000`（面数 > 10000）、`300d6`（骰数 > 200）→ 求和为 0，
#   结果文本看起来像一次正常掷骰（`(300D6) ＞ 0`），玩家会被误导；
#   而 `20001d6` 走另一条路径抛 `BCDice::TooManyRandsError`，被 handler
#   兜底成「当前规则系统不接受这个命令」——把内部限制说成规则系统问题。
# 故在进入引擎**之前**按引擎自身的上限显式判一次，给出可读回执。
#
# 上限来源（BCDice 3.17.0）：
#   - Randomizer#roll_sum / roll_barabara：times > 200 或 sides > 10000 → []
#   - Randomizer#roll_once：sides > 10000 → 0
#   本模块只覆盖「显式 NdM / NB M 形态」（含 `2d` 这种省略面数的写法，
#   引擎把 `2d` 补成 `2d6`）。其它形态（repeat、choice 等）由引擎自己兜底。
# ============================================================================

module TelegramBot
  # 骰组上限（与 BCDice Randomizer 保持一致）
  module DiceLimits
    MAX_DICE = 200
    MAX_SIDES = 10_000

    # 隐式面数（`2d` → `2d6`，见引擎 replace_implicit_d）
    IMPLICIT_SIDES = 6

    # NdM / NBM（B = バラバラ、大小写不敏感；骰数与面数都可省略）：
    #   - **骰数省略**（`d1000000`）：引擎按 1 颗处理 → 必须能匹配，
    #     否则面数上限形同虚设（2026-10-18 复审实测：`d1000000` 直接
    #     绕过旧正则，引擎照样给 `＞ 0`）。
    #   - 面数省略（`2d` → 2d6）。
    DICE_TOKEN = /(\d*)\s*[dDbB](\d*)/

    BAD_DICE_COUNT = "骰子数量超出上限：一次最多 %<max>d 颗（你写了 %<got>d 颗）。"
    BAD_DICE_SIDES = "骰面数超出上限：单颗最多 %<max>d 面（你写了 %<got>d 面）。"

    module_function

    # @param expr [String] 原始骰式
    # @return [String, nil] nil = 通过；String = 可直接回给用户的错误文案
    def violation(expr)
      expr.to_s.scan(DICE_TOKEN) do |times, sides|
        count = times.empty? ? 1 : times.to_i
        faces = sides.empty? ? IMPLICIT_SIDES : sides.to_i

        if count > MAX_DICE
          return format(BAD_DICE_COUNT, max: MAX_DICE, got: count)
        end
        if faces > MAX_SIDES
          return format(BAD_DICE_SIDES, max: MAX_SIDES, got: faces)
        end
      end

      nil
    end
  end
end
