# frozen_string_literal: true

# ============================================================================
# T1.1 实证产物之一：NinjaSlayer（1版）外部扩展类
#
# 用途：同 NinjaSlayer2Ex.rb，证明「继承 + 新 ID」机制也作用于 1版超类。
# T1.1 仅做类注册 + ID 注册验证，命令实际挂在 T1.7 处理。
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
      # 「…TRPG」< 「…TRPGかちょう」，故排在其后；又 < 「…TRPG2」，
      # 在 bot 列表里 1版 → 1版拡張 → 2版 → 2版拡張 连续排列。
      SORT_KEY = "にんしやすれいやあTRPGかちょう"

      register_prefix_from_super_class()
    end
  end
end
