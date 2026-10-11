# frozen_string_literal: true

# ============================================================================
# T1.1 spike ① + ③ 实证产物：NinjaSlayer2 外部扩展类（#1版动作见姊妹文件 NinjaSlayerEx.rb）
#
# 目的：
#   1. 验证「在 BCDice::GameSystem 命名空间下声明一个继承自 NinjaSlayer2 的子类
#      即会被 BCDice.game_system_class(id) 自动发现」，无需修改 gem。
#   2. 验证「register_prefix_from_super_class」官方扩展机制可用：先继承超类前缀，
#      再叠加本扩展独有的命令前缀（NSRS）。注意：prefixes_pattern 一旦生成即冻结，
#      因此所有注册必须在类定义期内完成（见上游 lib/bcdice/base.rb:35）。
#   3. 验证「子类实例使用超类命令时仍能命中 gem 内 NinjaSlayer2.* i18n 键」（V3 旁证：
#      超类用硬编码字符串键，不依赖类名推导）。
#
# 参考：
#   - 上游 lib/bcdice/base.rb:22-29    register_prefix / register_prefix_from_super_class
#   - 上游 lib/bcdice/base.rb:35-47    prefixes_pattern 冻结行为
#   - 上游 lib/bcdice/loader.rb:10-21  game_system_class / all_game_systems
#   - 计划 §3 决2 / §15.5 V5
# ============================================================================

require "bcdice"
require "bcdice/game_system"
require "bcdice/game_system/NinjaSlayer2"

module BCDice
  module GameSystem
    # T1.1①：继承 NinjaSlayer2，注入新 ID 让 game_system_class 能发现。
    class NinjaSlayer2Ex < NinjaSlayer2
      ID = "NinjaSlayer2Ex"

      # T1.1② / ②：把本仓库的 i18n/ 目录加到全局 load_path，让 translate 能命中
      # NinjaSlayer2Ex.* 键空间的 dummy 表。本步骤在测试脚本里显式调用，避免污染
      # gem 自身的 base.rb 加载逻辑（零上游改动原则）。
      # 见 plan §15.5 V4：translate = I18n.translate(key, locale: @locale, raise: true)。

      # 默认行为：完全不重定义 eval。父类足以证明：
      #   - prefixes_pattern 包含 UH/[KENHU]/SB/WS/WSE/NRS（继承 + 本类无新增）
      #     与父类完全一致；
      #   - 父类的 SB / WSE / NRS 内部仍 translate("NinjaSlayer2.table.XXX")，
      #     命中 gem 内 yml（计划 §15.5 V3）。
      #
      # T1.1③ 实证脚本里会：game_system.eval("SB") 检查 Result.text
      # 是否为"SATSUBATSU 超类的内容"，从而断言键空间仍走 NinjaSlayer2.*。

      # T1.1① 提示：将 register_prefix_from_super_class 放在类体内是上游官方写法
      # （参见上游 lib/bcdice/game_system/MorkBorg_Korean.rb:46）。
      # 本 spike 不增 prefix —— 这是后续 T1.3 的事，T1.1 仅证明框架可用。
      register_prefix_from_super_class()
    end
  end
end
