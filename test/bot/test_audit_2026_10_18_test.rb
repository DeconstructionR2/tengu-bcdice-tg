# frozen_string_literal: true

# ============================================================================
# test/bot/test_audit_2026_10_18_test.rb — 2026-10-18 审核轮修复的回归钉
#
# 覆盖：
#   1. DiceLimits：骰数/面数上限（引擎静默给 0 的那一类）
#   2. Chunker：按 UTF-16 码元切段（emoji 不再超 Telegram 上限）
#   3. connection.transaction：嵌套用 SAVEPOINT，内层异常不半提交
#   4. session_logs.append_entry：条目上限（超限停写、库不增长）
#   5. custom_tables：负出目键、换行折叠、Unicode 分隔符表名拒绝
#   6. bank 结算：发送失败时**不**清零
#   7. admin 缓存：阈值触发过期项整体清理
#   8. secrets：构造时清过期行（TTL 不再只在 create 时生效）
#   9. migration.id_of：int64 守卫
# ============================================================================

require "minitest/autorun"
require "logger"
require_relative "test_helper"
require_relative "../../bot/handlers/custom_table"
require_relative "../../bot/handlers/bank"
require_relative "../../bot/handlers/dice"
require_relative "../../db/connection"
require_relative "../../db/custom_tables"
require_relative "../../db/session_logs"
require_relative "../../db/secrets"
require_relative "../../db/bank"
require_relative "../../bot/migration"
require_relative "../../lib/dice_limits"

class TestDiceLimits < Minitest::Test
  def test_count_over_limit
    assert_includes TelegramBot::DiceLimits.violation("300d6"), "骰子数量"
    assert_includes TelegramBot::DiceLimits.violation("201d6"), "骰子数量"
  end

  def test_sides_over_limit
    assert_includes TelegramBot::DiceLimits.violation("1d1000000"), "骰面数"
    assert_includes TelegramBot::DiceLimits.violation("1d10001"), "骰面数"
  end

  def test_valid_expressions_pass
    assert_nil TelegramBot::DiceLimits.violation("2d6")
    assert_nil TelegramBot::DiceLimits.violation("200d6")
    assert_nil TelegramBot::DiceLimits.violation("1d10000")
    assert_nil TelegramBot::DiceLimits.violation("3d6+2")
    assert_nil TelegramBot::DiceLimits.violation("2d")
  end

  def test_handler_turns_over_limit_into_a_readable_message
    handler = TelegramBot::Handlers::DiceHandler.new(
      settings: FakeSettings.new, resolver: ->(_id) { Object },
      logger: Logger.new(IO::NULL)
    )
    out = handler.call(name: "roll", args: "1d1000000", kind: :slash,
                       chat_id: -100, thread_id: nil)
    assert_includes out, "骰面数"
    refute_includes out, "不接受这个命令"
  end

  class FakeSettings
    def resolve(_chat_id, thread_id: nil)
      Struct.new(:game_system).new("NinjaSlayer2Ex")
    end
  end
end

class TestChunkerUtf16 < Minitest::Test
  L = TelegramBot::Chunker::MAX_MESSAGE_LENGTH

  def test_astral_chars_are_counted_as_two_units
    assert_equal 2, TelegramBot::Chunker.utf16_units("\u{1F600}")
    assert_equal 1, TelegramBot::Chunker.utf16_units("あ")
  end

  def test_emoji_text_never_exceeds_utf16_limit
    text = "\u{1F600}" * 5000
    segs = TelegramBot::Chunker.split(text)
    assert_operator segs.size, :>, 1
    segs.each do |seg|
      assert_operator TelegramBot::Chunker.utf16_units(seg), :<=, L,
                      "每段 UTF-16 码元数必须 ≤ #{L}"
    end
    assert_equal text, segs.join, "切段不得丢内容"
  end

  def test_ascii_behaviour_unchanged
    text = "a" * (L + 1)
    segs = TelegramBot::Chunker.split(text)
    assert_equal 2, segs.size
    assert_equal text, segs.join
  end
end

class TestConnectionSavepoint < Minitest::Test
  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
  end

  def teardown
    @conn.close
  end

  def count
    @conn.get_first_value("SELECT count(*) FROM chat_settings").to_i
  end

  def insert(chat_id)
    @conn.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, game_system) VALUES (?, 0, 'X')",
      [chat_id]
    )
  end

  def test_inner_rescued_failure_rolls_back_only_the_inner_layer
    @conn.transaction(:immediate) do
      insert(1)
      begin
        @conn.transaction(:immediate) do
          insert(2)
          raise "inner boom"
        end
      rescue RuntimeError
        nil # 内层失败被吞掉：外层的写入仍应保留，内层必须消失
      end
    end

    assert_equal 1, count
    assert_nil @conn.get_first_hash("SELECT chat_id FROM chat_settings WHERE chat_id = 2")
  end

  def test_inner_success_is_committed_with_the_outer
    @conn.transaction(:immediate) do
      @conn.transaction(:immediate) { insert(3) }
    end

    assert_equal 1, count
  end

  def test_outer_failure_rolls_back_everything
    assert_raises(RuntimeError) do
      @conn.transaction(:immediate) do
        insert(4)
        @conn.transaction(:immediate) { insert(5) }
        raise "outer boom"
      end
    end

    assert_equal 0, count
  end
end

class TestSessionLogEntryCap < Minitest::Test
  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @logs = TenguDB::SessionLogs.new(@conn, logger: Logger.new(IO::NULL))
    @log = @logs.start(chat_id: -100, thread_id: 0, name: "cap").log
  end

  def teardown
    @conn.close
  end

  def test_append_stops_at_the_cap
    cap = TenguDB::SessionLogs::MAX_ENTRIES
    @conn.transaction(:immediate) do
      (1..cap).each do |i|
        @conn.execute(
          "INSERT INTO log_entries (log_id, seq, sender_name, is_bot, msg_kind, content) " \
          "VALUES (?, ?, 'n', 0, 'text', 'x')",
          [@log.id, i]
        )
      end
    end

    assert_nil @logs.append_entry(log_id: @log.id, sender_name: "n", content: "over")
    assert_equal cap, @conn.get_first_value("SELECT count(*) FROM log_entries").to_i
  end

  def test_under_cap_still_appends
    entry = @logs.append_entry(log_id: @log.id, sender_name: "n", content: "ok")
    refute_nil entry
    assert_equal 1, entry.seq
  end
end

class TestCustomTableAuditFixes < Minitest::Test
  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @ct = TenguDB::CustomTables.new(@conn)
    @handler = TelegramBot::Handlers::CustomTableHandler.new(
      custom_tables: @ct, admin: AlwaysAdmin.new,
      randomizer: -> { FixedRandom.new },
      logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    @conn.close
  end

  class AlwaysAdmin
    def admin?(_chat_id, _user_id, chat_type: nil) = true
  end

  class FixedRandom
    def roll_sum(_times, _sides) = 1
  end

  def ct(args)
    @handler.call(name: "ct", args: args, chat_id: -100, thread_id: nil,
                  user_id: 42, chat_type: "supergroup", kind: :slash)
  end

  def test_negative_outcome_round_trip
    ct("create neg")
    ct("dice set neg a 1d6-10")
    assert_includes ct("data set neg -4 neg-four"), "已录入"

    table = @ct.fetch(chat_id: -100, name: "neg", scope: :private)
    assert_equal "neg-four", table.data_entry(-4)
  end

  def test_negative_outcome_delete
    ct("create negdel")
    ct("dice set negdel a 1d6-10")
    ct("data set negdel -5 five")
    ct("data del negdel -5")
    table = @ct.fetch(chat_id: -100, name: "negdel", scope: :private)
    assert_nil table.data_entry(-5)
  end

  def test_multiline_table_text_is_flattened_in_roll_output
    ct("create flat")
    ct("data set flat 1 line1\nsecond line")
    out = ct("roll flat a")

    lines = out.split("\n")
    assert_equal 2, lines.size, "掷表输出固定两行（头 + 正文）"
    assert_includes out, "⏎"
    refute_includes out, "second line\n"
  end

  def test_show_flattens_multiline_and_caps_rows
    ct("create showtbl")
    ct("data set showtbl 1 a\nb")
    out = ct("show showtbl")
    assert_includes out, "⏎"
  end

  def test_unicode_line_separator_is_rejected_in_table_names
    out = ct("create A\u2028B")
    assert_includes out, "表名无效"
  end

  def test_overlong_dice_shortcut_name_is_rejected
    ct("create longname")
    out = ct("dice set longname #{'b' * 40} 1d6")
    assert_includes out, "快捷名过长"
  end

  def test_dice_expression_over_engine_limit_is_rejected_at_set_time
    ct("create bigdice")
    out = ct("dice set bigdice a 300d6")
    assert_includes out, "骰子数量"
    table = @ct.fetch(chat_id: -100, name: "bigdice", scope: :private)
    refute_equal "300d6", table.dice["a"]
  end
end

class TestBankStatementOrdering < Minitest::Test
  CHAT = -100

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @bank = TenguDB::Bank.new(@conn)
    @bank.save_money(chat_id: CHAT, thread_id: nil, amount: 100)
  end

  def teardown
    @conn.close
  end

  class ExplodingApi
    def send_text(*_args, **_kwargs) = raise(TelegramBot::SendError, "boom")
  end

  class RecordingApi
    attr_reader :sent
    def initialize = @sent = []
    def send_text(chat_id, text, thread_id: nil, **_extra)
      @sent << { chat_id: chat_id, text: text, thread_id: thread_id }
      [:ok]
    end
  end

  def handler
    TelegramBot::Handlers::BankHandler.new(bank: @bank, logger: Logger.new(IO::NULL))
  end

  def test_send_failure_keeps_the_ledger
    out = handler.call(name: "bank", args: "statement", chat_id: CHAT, thread_id: nil,
                       user_id: 1, api: ExplodingApi.new)

    assert_includes out, "发送失败"
    refute_nil @bank.fetch(chat_id: CHAT, thread_id: nil), "发送失败时不得清零"
  end

  def test_successful_send_then_clears
    api = RecordingApi.new
    out = handler.call(name: "bank", args: "statement", chat_id: CHAT, thread_id: nil,
                       user_id: 1, api: api)

    assert_nil out, "发送成功后 handler 不再返回文本（避免 router 二次发送）"
    assert_equal 1, api.sent.size
    assert_includes api.sent.first[:text], "结果"
    assert_nil @bank.fetch(chat_id: CHAT, thread_id: nil), "发送成功后清零"
  end

  def test_statement_output_is_recorded_to_session_log
    recorded = []
    recorder = Object.new
    recorder.define_singleton_method(:record_bot_output) do |chat_id:, thread_id:, text:|
      recorded << { chat_id: chat_id, thread_id: thread_id, text: text }
    end

    handler = TelegramBot::Handlers::BankHandler.new(
      bank: @bank, session_log: recorder, logger: Logger.new(IO::NULL)
    )
    handler.call(name: "bank", args: "statement", chat_id: CHAT, thread_id: nil,
                 user_id: 1, api: RecordingApi.new)

    assert_equal 1, recorded.size, "handler 自发的报表必须补录进 log（绕过 router 挂钩②）"
    assert_includes recorded.first[:text], "结果"
  end
end

class TestAdminCacheSweep < Minitest::Test
  def test_expired_entries_are_swept_when_the_cache_grows
    clock = 0.0
    api = FakeAdminApi.new
    admin = TelegramBot::Admin.new(api: api, clock: -> { clock }, ttl: 300.0,
                                   logger: Logger.new(IO::NULL))

    (1..600).each { |uid| admin.admin?(-100, uid) }
    assert_operator admin.cached_admin_count, :>, 512

    clock = 10_000.0
    admin.admin?(-100, 9999)

    assert_operator admin.cached_admin_count, :<=, 2,
                    "超过阈值时整体清理过期项（只剩刚写入的那条）"
  end

  class FakeAdminApi
    def api_client = self
    def api = self
    def get_chat_member(chat_id:, user_id:) = Struct.new(:status).new("administrator")
  end
end

class TestSecretsPurgeOnInit < Minitest::Test
  def test_old_rows_are_purged_by_constructor
    conn = TenguDB::Connection.open(path: ":memory:")
    conn.execute(
      "INSERT INTO secrets (id, chat_id, thread_id, user_id, command, result_text, created_at) " \
      "VALUES ('old', -100, 0, 1, '2d6', 'x', datetime('now', '-30 days'))"
    )
    assert_equal 1, conn.get_first_value("SELECT count(*) FROM secrets").to_i

    TenguDB::Secrets.new(conn)

    assert_equal 0, conn.get_first_value("SELECT count(*) FROM secrets").to_i
  ensure
    conn&.close
  end
end

class TestMigrationIdGuard < Minitest::Test
  def test_out_of_range_id_is_rejected
    conn = TenguDB::Connection.open(path: ":memory:")
    migration = TelegramBot::Migration.new(connection: conn)
    huge = "9" * 40

    assert_nil migration.send(:id_of, huge)
    assert_nil migration.send(:id_of, 0)
    assert_equal 123, migration.send(:id_of, "123")
  ensure
    conn&.close
  end
end
