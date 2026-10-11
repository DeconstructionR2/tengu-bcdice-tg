# frozen_string_literal: true

# ============================================================================
# test/bot/test_help_test.rb — /help 与 T3.x 占位应答（热修回归钉）
#
# 出处（2026-10-12 Phase 2 真机验收）：菜单里的 /help 没有 handler，按静默
# 策略不回复，用户视角=「bot 死了」。教训：**菜单已上架的命令必须有应答**。
# ============================================================================

require "minitest/autorun"
require_relative "test_helper"
require_relative "../../bot/handlers/help"

class TestHelpHandler < Minitest::Test
  def test_help_text_covers_live_commands
    text = TelegramBot::Handlers::HelpHandler.new.call(nil)

    %w[/roll /nd /system /settings /secret /bank /ct /log /help].each do |cmd|
      assert_includes text, cmd, "帮助文本应覆盖 #{cmd}"
    end
    %w[deposit withdraw balance statement reset].each do |sub|
      assert_includes text, sub, "T3.2：/bank 的主要子命令应在帮助里可见（#{sub}）"
    end
    %w[new off on end list].each do |sub|
      assert_includes text, "/log #{sub}", "T3.5：/log 的子命令应在帮助里可见（#{sub}）"
    end
    assert_includes text, "N4,3", "帮助应含裸打示例"
    assert_includes text, "[S]", "帮助应注明 S 判定不可混排的已知差异"
  end

  # PendingHandler 自 T3.5 起**无生产使用者**（菜单十条命令全有真 handler），
  # 保留为将来「先上菜单、后补实现」命令的候车位——本用例钉住它的通用契约
  # （占位文案必须点名功能、不假装已实现）。
  def test_pending_handler_names_feature_and_no_false_promise
    out = TelegramBot::Handlers::PendingHandler.new(feature: "未来的某命令 /future").call(nil)

    assert_includes out, "未来的某命令 /future"
    assert_includes out, "后续版本"
  end

  def test_help_text_makes_no_pending_promise_for_bank_or_ct
    text = TelegramBot::Handlers::HelpHandler.new.call(nil)

    refute_includes text, "天狗银行 /bank 将于后续版本提供",
                    "T3.2 后 /bank 已实装，帮助里不得再有占位承诺"
    refute_includes text, "自定义表 /ct 将于后续版本提供",
                    "T3.4 后 /ct 已实装，帮助里不得再有占位承诺"
    refute_includes text, "将于后续版本提供",
                    "T3.5 后菜单全部实装，帮助里不应再有任何占位承诺"
    assert_includes text, "可透支", "透支是忠实保留的天狗行为，须在帮助里讲明"
    assert_includes text, "/ct create", "T3.4：/ct 的入口应在帮助里可见"
  end
end
