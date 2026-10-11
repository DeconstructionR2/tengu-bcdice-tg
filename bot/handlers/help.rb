# frozen_string_literal: true

# ============================================================================
# bot/handlers/help.rb — /help 与「菜单已上架但未实现」命令的占位应答（热修）
#
# 背景（2026-10-12 Phase 2 真机验收）：菜单里的 /help 没有 handler，按静默
# 策略不回复——用户视角是「bot 死了」。菜单已上架的命令**必须**有应答：
#   - /help        → 静态帮助文本（ASCII，§13 第 2 项纯 ASCII 定案）
#   - /ct /log     → PendingHandler 一句话占位（T3.3/T3.5 提供）
# 未在菜单里的未知 slash 仍按静默策略不回复（不变）。
# /bank 已由 T3.2 换成真 handler，故不再在占位名单里（文案陈旧会让用户
# 以为 /bank 不能用——与 T3.1 对 /secret 做过的同一处订正）。
# ============================================================================

module TelegramBot
  module Handlers
    # /help：静态命令一览。文案只列已实现能力，不预告细节。
    class HelpHandler
      TEXT = <<~HELP.chomp
        天狗骰子 · 命令一览
        /roll <式> — 按本群/话题的规则系统掷骰（例：/roll 2d6>=4）
        /nd <式> — 忍杀2版直通，无视群设置（例：/nd SB、/nd NSRS）
        /system — 查看/切换规则系统（话题内打只改本话题）
        /settings — 群设置总览（辅助轨开关等）
        /secret <式> — 暗骰：结果只有你自己看得到（约 25 分钟后消失）
        /secret last — 重看本聊天你最近一次暗骰结果
        /bank deposit <金额> — 存钱（/bank withdraw 取钱，可透支）
        /bank item add|del <道具名> — 存取道具
        /bank balance — 查账；/bank statement — 出结算并清零；/bank reset — 清零
        /help — 本帮助

        裸打也能掷骰（整条消息都是骰式才触发，闲聊不响应）：
        N4,3　SB　SB@6　NRS_E4　2d6>=4　K6[J]　x3 2d6

        注意：S 前缀的暗骰结果不公开显示（请改用 /secret）；
        暗骰消息里的「公开」按钮会把它发到群里，只有点它才会公开；
        [S]/[S5] 不能与其他追加判定混排（K6[S][J] 无效），追加判定用 [J]/[L]/[=4]。
      HELP

      def call(_context)
        TEXT
      end
    end

    # 菜单已上架、T3.x 才实现的命令：一句话占位（**不含**「静默」误导）。
    class PendingHandler
      def initialize(feature:)
        @feature = feature
      end

      def call(_context)
        "#{@feature} 将于后续版本提供（开发中）。"
      end
    end
  end
end
