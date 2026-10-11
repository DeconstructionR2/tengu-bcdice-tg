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

    %w[/roll /nd /system /settings /help].each do |cmd|
      assert_includes text, cmd, "帮助文本应覆盖 #{cmd}"
    end
    assert_includes text, "N4,3", "帮助应含裸打示例"
    assert_includes text, "[S]", "帮助应注明 S 判定不可混排的已知差异"
  end

  def test_pending_handler_names_feature_and_no_false_promise
    out = TelegramBot::Handlers::PendingHandler.new(feature: "暗骰 /secret").call(nil)

    assert_includes out, "暗骰 /secret"
    assert_includes out, "后续版本"
  end
end
