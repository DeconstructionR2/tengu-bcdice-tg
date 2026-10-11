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

      register_prefix_from_super_class()
    end
  end
end
