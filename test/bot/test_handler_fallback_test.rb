# frozen_string_literal: true

# ============================================================================
# test/bot/test_handler_fallback_test.rb — slash handler 的 DB 故障兜底
# （2026-10-12 二审必修，deepseek 复核实证：dice/settings/bank/secret 的
# call 没有兜底 rescue，DB 锁/损坏时异常冒到 router 只 warn 一行、返回 nil
# → 用户视角「打了命令没反应」，违背项目自己的「不装死」原则；
# custom_table/session_log 早有 STORAGE_ERROR 兜底，本文件钉齐四家）
#
# 各家的「故障呈现」口径（刻意的差异，勿「统一」掉）：
#   - slash 命令（显式触发）→ 回 STORAGE_ERROR 文案；
#   - dice 辅助轨（裸打，kind=:aux）→ **保持静默**（闲聊恰逢 DB 故障不该收报错）；
#   - secret（暗骰）→ 只走 ephemeral 告知本人（群里什么都看不见的契约）。
# ============================================================================

require "minitest/autorun"
require "logger"
require_relative "test_helper"
require_relative "../../bot/handlers/dice"
require_relative "../../bot/handlers/settings"
require_relative "../../bot/handlers/bank"
require_relative "../../bot/handlers/secret_dice"
require_relative "../../db/connection"
require_relative "../../db/secrets"

class TestHandlerFallback < Minitest::Test
  # 任何方法调用都炸 DB 故障的假存储（method_missing 全拦）
  class BrokenStore
    def method_missing(*)
      raise SQLite3::BusyException
    end

    def respond_to_missing?(*)
      true
    end
  end

  # send_ephemeral 的探针（secret 兜底路径的用户可见性断言靠它）
  class EphemeralSpy
    attr_reader :sent

    def initialize
      @sent = []
    end

    def send_ephemeral(chat_id, text, user_id:, thread_id: nil, **_extra)
      @sent << { chat_id: chat_id, text: text, user_id: user_id, thread_id: thread_id }
    end
  end

  QUIET = Logger.new(IO::NULL)
  BASE_CTX = { chat_id: -1_000_000_000_123_456_789, thread_id: 88, user_id: 42,
               chat_type: "supergroup" }.freeze

  def ctx(overrides)
    BASE_CTX.merge(overrides)
  end

  # --- slash 四家：用户必须看到错误文案 ------------------------------------

  def test_dice_slash_db_failure_replies_storage_error
    handler = TelegramBot::Handlers::DiceHandler.new(settings: BrokenStore.new, logger: QUIET)
    out = handler.call(ctx(name: "roll", kind: :slash, args: "SB"))
    assert_equal TelegramBot::Handlers::DiceHandler::STORAGE_ERROR, out
  end

  def test_settings_db_failure_replies_storage_error
    handler = TelegramBot::Handlers::SettingsHandler.new(settings: BrokenStore.new, logger: QUIET)
    out = handler.call(ctx(name: "settings", kind: :slash, args: ""))
    assert_equal TelegramBot::Handlers::SettingsHandler::STORAGE_ERROR, out
  end

  def test_bank_db_failure_replies_storage_error
    handler = TelegramBot::Handlers::BankHandler.new(bank: BrokenStore.new, logger: QUIET)
    out = handler.call(ctx(name: "bank", kind: :slash, args: "balance"))
    assert_equal TelegramBot::Handlers::BankHandler::STORAGE_ERROR, out
  end

  # --- 刻意的差异：aux 静默、secret 走 ephemeral -----------------------------

  def test_dice_aux_db_failure_stays_silent
    handler = TelegramBot::Handlers::DiceHandler.new(settings: BrokenStore.new, logger: QUIET)
    out = handler.call(ctx(name: nil, kind: :aux, text: "SB"))
    assert_nil out, "辅助轨（裸打）保持静默契约：DB 故障也不回报错"
  end

  def test_secret_slash_db_failure_notifies_via_ephemeral_only
    spy = EphemeralSpy.new
    handler = TelegramBot::Handlers::SecretDiceHandler.new(secrets: BrokenStore.new, logger: QUIET)
    out = handler.call(ctx(name: "secret", kind: :slash, args: "last", api: spy))

    assert_nil out, "secret 路径恒返回 nil（自走 ephemeral，不经 router 代发）"
    assert_equal 1, spy.sent.size, "DB 故障应尽力 ephemeral 告知本人"
    assert_equal TelegramBot::Handlers::SecretDiceHandler::STORAGE_ERROR, spy.sent.first[:text]
    assert_equal 42, spy.sent.first[:user_id], "只发给掷骰本人（群里不出声）"
  end

  def test_secret_callback_db_failure_answers_alert
    answered = []
    handler = TelegramBot::Handlers::SecretDiceHandler.new(secrets: BrokenStore.new, logger: QUIET)
    data = TenguDB::Secrets.callback_data("abcdef0123456789")
    handler.call(ctx(kind: :callback_query,
                     callback_query: Object.new,
                     data: data,
                     answer_callback_query: ->(text, alert:) { answered << [text, alert] }))

    assert_equal 1, answered.size, "回调故障必须应答（不答用户客户端一直转圈）"
    assert_equal TelegramBot::Handlers::SecretDiceHandler::STORAGE_ERROR, answered.first[0]
    assert answered.first[1], "故障应答用 alert=true（值得用户注意）"
  end
end
