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

    %w[/roll /nd /system /settings /secret /bank /help].each do |cmd|
      assert_includes text, cmd, "帮助文本应覆盖 #{cmd}"
    end
    %w[deposit withdraw balance statement reset].each do |sub|
      assert_includes text, sub, "T3.2：/bank 的主要子命令应在帮助里可见（#{sub}）"
    end
    assert_includes text, "N4,3", "帮助应含裸打示例"
    assert_includes text, "[S]", "帮助应注明 S 判定不可混排的已知差异"
  end

  # T3.3/T3.5 之前，/ct 与 /log 仍是占位。/bank 已由 T3.2 换成真 handler，
  # **不得**再用 PendingHandler（占位文案会让用户以为功能没上）。
  def test_pending_handler_names_feature_and_no_false_promise
    %w[自定义表\ /ct 跑团\ log].each do |feature|
      out = TelegramBot::Handlers::PendingHandler.new(feature: feature).call(nil)

      assert_includes out, feature
      assert_includes out, "后续版本"
    end
  end

  def test_help_text_makes_no_pending_promise_for_bank
    text = TelegramBot::Handlers::HelpHandler.new.call(nil)

    refute_includes text, "天狗银行 /bank 将于后续版本提供",
                    "T3.2 后 /bank 已实装，帮助里不得再有占位承诺"
    assert_includes text, "可透支", "透支是忠实保留的天狗行为，须在帮助里讲明"
  end
end
