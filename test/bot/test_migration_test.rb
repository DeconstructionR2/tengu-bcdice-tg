# frozen_string_literal: true

# ============================================================================
# test/bot/test_migration_test.rb — 群升级 re-key（T2.5）
#
# 覆盖计划 §3 决5 / §4.2（迁移 re-key 事务）/ §12 R5 / §0.2.4：
#
#   A. 五表播种 → 迁移 → 逐表断言挂到 new id + chat_id_aliases 落账
#   B. log_entries 不动（无 chat_id 列，靠 log_id 外键跟着父行走）
#   C. 幂等：同一迁移跑两遍，行数/内容不变（第二次 moved? = false）
#   D. 三种时序（§12 R5）：先 to 后 from / 先 from 后 to / 只收一侧
#   E. 空库 re-key 不炸；迁移后原 chat_id 查询归零
#   F. 64 位大数 chat_id（>32 位有效位）
#   G. 事务原子性：中途失败整体回滚，不留半拉子账本
#   H. router 集成：伪造含 migrate_to_chat_id 的 update 走 dispatch，
#      断言调用了注入的 handler 且**不回发任何消息**
#
# 全程零联网、零真实 token；DB 用 :memory: 库（唯一落盘用例自清理）。
# ============================================================================

require "minitest/autorun"
require "stringio"
require "logger"
require_relative "test_helper"
require_relative "../../bot/migration"
require_relative "../../db/connection"

class TestMigration < Minitest::Test
  include BotTestHelper

  # 真实参照：测试群「示例迁移群」真发生过升级（旧普通群 → 新超级群）
  OLD_CHAT_ID = -1_234_567_890
  NEW_CHAT_ID = -1_009_876_543_210

  # 超 32 位有效位的 id（§0.2.4：chat_id 可远超 32 位）
  BIG_OLD = -1_000_000_000_123_456_789
  BIG_NEW = -1_000_000_000_987_654_321

  def setup
    TenguDB::Connection.reset!
    @conn = TenguDB::Connection.open(path: ":memory:")
    @io = StringIO.new
    @logger = Logger.new(@io)
    @migration = TelegramBot::Migration.new(connection: @conn, logger: @logger)
    seed_all_tables(OLD_CHAT_ID)
  end

  def teardown
    @conn.close
    TenguDB::Connection.reset!
  end

  # --- 夹具 -----------------------------------------------------------------

  # 在**五张含 chat_id 的表**各播种一行 + 一条 log_entries（经 log_id 关联）
  #
  # @param chat_id [Integer] 挂到哪个 id 下
  # @param suffix [String] 同库播种第二组时的区分后缀（PK/UNIQUE 约束
  #   （chat_settings PK、secrets.id、custom_tables.name）不允许同 id 播两次）
  def seed_all_tables(chat_id, suffix: "a")
    # 两级 thread_id 都带后缀：chat_settings / bank_record 的 PK 是
    # (chat_id, thread_id)，同一 chat_id 播第二组时必须整组换键。
    # 首组保留真实形态：群级 0（E4 归一后）+ 话题 88。
    group_thread, topic = suffix == "a" ? [0, 88] : [900 + suffix.ord, 800 + suffix.ord]

    @conn.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, game_system) VALUES (?, ?, 'NinjaSlayerEx')",
      [chat_id, group_thread]
    )
    @conn.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, game_system) VALUES (?, ?, 'NinjaSlayer2Ex')",
      [chat_id, topic]
    )
    @conn.execute(
      "INSERT INTO bank_record (chat_id, thread_id, sum_money, money_record) " \
      "VALUES (?, ?, -4200, '[{\"amount\":100}]')", [chat_id, topic]
    )
    @conn.execute(
      "INSERT INTO custom_tables (scope, chat_id, name, spec, author_id) " \
      "VALUES ('private', ?, ?, '{\"dice\":{\"a\":1}}', 7)", [chat_id, "table-#{suffix}"]
    )
    @conn.execute(
      "INSERT INTO secrets (id, chat_id, user_id, command, result_text) " \
      "VALUES (?, ?, 42, 'S2d6', 'result')", ["sec-#{suffix}", chat_id]
    )
    log_id = insert_log_and_fetch(chat_id, suffix)
    @conn.execute(
      "INSERT INTO log_entries (log_id, seq, sender_name, user_id, content) " \
      "VALUES (?, 1, 'Tester', 42, 'hello')", [log_id]
    )
    log_id
  end

  # RETURNING 不作依赖（sqlite3 版本差异）；显式插入后取 last_insert_rowid
  def insert_log_and_fetch(chat_id, suffix = "a")
    @conn.execute(
      "INSERT INTO session_logs (chat_id, name) VALUES (?, ?)", [chat_id, "第#{suffix}团"]
    )
    @conn.get_first_value("SELECT last_insert_rowid()")
  end

  def count(table, chat_id)
    @conn.get_first_value("SELECT count(*) FROM #{table} WHERE chat_id = ?", [chat_id]).to_i
  end

  def alias_row(old_id)
    @conn.get_first_hash(
      "SELECT old_chat_id, new_chat_id, migrated_at FROM chat_id_aliases WHERE old_chat_id = ?",
      [old_id]
    )
  end

  # 五张表逐表断言：旧 id 归零、新 id 拿到行
  def assert_all_moved(from:, to:)
    %w[chat_settings bank_record custom_tables secrets session_logs].each do |t|
      assert_equal 0, count(t, from), "#{t}: 迁移后旧 chat_id #{from} 下必须为 0 行"
      assert_operator count(t, to), :>, 0, "#{t}: 行应改挂到新 chat_id #{to}"
    end
  end

  def warnings
    @io.string
  end

  # =========================================================================
  # A. 基础：五表迁移 + alias 落账
  # =========================================================================

  def test_all_five_tables_move_to_new_chat_id
    result = @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)

    assert_all_moved(from: OLD_CHAT_ID, to: NEW_CHAT_ID)
    assert_equal :to, result.direction
    assert_equal OLD_CHAT_ID, result.old_chat_id
    assert_equal NEW_CHAT_ID, result.new_chat_id
    assert result.moved?, "首次迁移应真的改动了行"

    # 逐表命中行数：chat_settings 有 2 行（群级 + 话题），其余各 1
    assert_equal 2, result.rows["chat_settings"]
    assert_equal 1, result.rows["bank_record"]
    assert_equal 1, result.rows["custom_tables"]
    assert_equal 1, result.rows["secrets"]
    assert_equal 1, result.rows["session_logs"]
    assert_equal 6, result.moved_total
  end

  def test_business_data_is_preserved_not_just_moved
    @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)

    # 内容不能被 UPDATE 碰坏（只改 chat_id 一列）
    bank = @conn.get_first_hash(
      "SELECT chat_id, thread_id, sum_money, money_record FROM bank_record WHERE chat_id = ?",
      [NEW_CHAT_ID]
    )
    assert_equal NEW_CHAT_ID, bank["chat_id"]
    assert_equal 88, bank["thread_id"]
    assert_equal(-4200, bank["sum_money"])
    assert_equal '[{"amount":100}]', bank["money_record"]

    ct = @conn.get_first_hash(
      "SELECT chat_id, name, spec, author_id FROM custom_tables WHERE chat_id = ?",
      [NEW_CHAT_ID]
    )
    assert_equal "table-a", ct["name"]
    assert_equal '{"dice":{"a":1}}', ct["spec"]
    assert_equal 7, ct["author_id"]
  end

  def test_alias_row_is_recorded_with_timestamp
    assert_nil alias_row(OLD_CHAT_ID), "迁移前不应有 alias 行"

    @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)

    row = alias_row(OLD_CHAT_ID)
    refute_nil row, "chat_id_aliases 必须落账（审计 + 幂等）"
    assert_equal OLD_CHAT_ID, row["old_chat_id"]
    assert_equal NEW_CHAT_ID, row["new_chat_id"]
    assert_match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/, row["migrated_at"].to_s,
                 "migrated_at 应是 SQLite datetime('now') 形态")
  end

  def test_log_entries_follow_parent_via_foreign_key
      log_id = seed_all_tables(OLD_CHAT_ID, suffix: "b") # 第二组（CT/secrets 唯一键不撞）
      @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)

      # log_entries **没有 chat_id 列**——验证它靠 log_id 关联仍归属于新群
      entry = @conn.get_first_hash(
        "SELECT e.content, s.chat_id AS parent_chat FROM log_entries e " \
        "JOIN session_logs s ON s.id = e.log_id WHERE e.log_id = ?", [log_id]
      )
      refute_nil entry, "log_entries 行不应因迁移而消失"
      assert_equal "hello", entry["content"]
      assert_equal NEW_CHAT_ID, entry["parent_chat"],
                   "log_entries 靠 log_id 外键跟着 session_logs 走，无需 UPDATE"

      # 结构性断言：log_entries 表确实没有 chat_id 列（§4.2：不动它）
      columns = @conn.execute_query("PRAGMA table_info(log_entries)").map(&:first)
      refute_includes columns, "chat_id",
                      "log_entries 无 chat_id 列（经 log_id 关联），re-key 不该 UPDATE 它"
      # 反证：迁移前后的条目集合完全一致（没有丢条目）
      assert_equal 2, @conn.get_first_value("SELECT count(*) FROM log_entries"),
                   "两组的 log_entries 都应在（各 1 条）"
    end

  # =========================================================================
  # C. 幂等：同一迁移跑两遍
  # =========================================================================

  def test_second_identical_migration_moves_nothing
    first = @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)
    assert first.moved?

    snapshot = snapshot_all
    second = @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)

    refute second.moved?, "重复迁移必须 0 行变更（幂等硬要求）"
    assert_equal 0, second.moved_total
    assert_equal snapshot, snapshot_all, "重复迁移不得改变任何行内容或行数"
    assert_equal 1, @conn.get_first_value("SELECT count(*) FROM chat_id_aliases"),
                 "重复迁移不得产生第二条 alias 行（INSERT OR IGNORE）"
  end

  def test_both_directions_together_are_idempotent
    @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)
    snapshot = snapshot_all

    # 两侧消息都到（任意顺序）
    other = @migration.handle(chat_id: NEW_CHAT_ID, migrate_from: OLD_CHAT_ID)
    again = @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)

    refute other.moved?
    refute again.moved?
    assert_equal snapshot, snapshot_all
    assert_equal 1, @conn.get_first_value("SELECT count(*) FROM chat_id_aliases")
  end

  # =========================================================================
  # D. §12 R5 三种时序
  # =========================================================================

  def test_timing_to_then_from
    @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)
    @migration.handle(chat_id: NEW_CHAT_ID, migrate_from: OLD_CHAT_ID)
    assert_timing_terminal_state
  end

  def test_timing_from_then_to
    @migration.handle(chat_id: NEW_CHAT_ID, migrate_from: OLD_CHAT_ID)
    @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)
    assert_timing_terminal_state
  end

  def test_timing_only_one_side
    # 只见到一侧（只收旧群侧 migrate_to）
    @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)
    assert_timing_terminal_state
  end

  def test_timing_only_new_group_side
    # 只见到另一侧（只收新群侧 migrate_from）
    @migration.handle(chat_id: NEW_CHAT_ID, migrate_from: OLD_CHAT_ID)
    assert_timing_terminal_state
  end

  def test_same_message_three_times_in_a_row
    3.times { @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID) }
    assert_timing_terminal_state
  end

  # 三种时序的共同终态断言（每条时序用例调它 → 天然等价性检查）
  def assert_timing_terminal_state
    assert_all_moved(from: OLD_CHAT_ID, to: NEW_CHAT_ID)
    row = alias_row(OLD_CHAT_ID)
    refute_nil row, "任一时序都必须留下 alias 审计行"
    assert_equal NEW_CHAT_ID, row["new_chat_id"]
    assert_equal 1, @conn.get_first_value("SELECT count(*) FROM chat_id_aliases")
  end

  # =========================================================================
  # E. 空库 / 不存在的行
  # =========================================================================

  def test_rekey_on_empty_database_does_not_raise
    # log_entries 有 FK → 必须先删子表（这本身就是 E10「foreign_keys=ON 真在
    # 生效」的连带证明：关掉 FK 时这个 DELETE 不会报错，但也正因如此
    # 清理顺序必须写对）
    @conn.execute("DELETE FROM log_entries")
    @conn.execute("DELETE FROM session_logs")
    @conn.execute("DELETE FROM chat_settings")
    @conn.execute("DELETE FROM bank_record")
    @conn.execute("DELETE FROM custom_tables")
    @conn.execute("DELETE FROM secrets")

    assert_equal 0, @conn.get_first_value("SELECT count(*) FROM chat_settings")

    result = nil
    assert_silent do
      result = @migration.handle(chat_id: -111_222_333, migrate_to: -100_111_222_333)
    end

    refute result.moved?, "空库 re-key 不应有任何变更"
    refute_nil alias_row(-111_222_333), "即使无数据行也要留下 alias 审计（幂等键）"
    assert_equal 1, @conn.get_first_value("SELECT count(*) FROM chat_id_aliases")
    refute @conn.transaction_active?
  end

  def test_rekey_for_unknown_chat_is_a_noop
    result = @migration.handle(chat_id: -777_000_111, migrate_to: -100_777_000_111)

    refute result.moved?
    assert_equal 0, result.moved_total
    # 原有播种完全不受影响（UNKNOWN 迁移不应误伤别的群）
    assert_equal 2, count("chat_settings", OLD_CHAT_ID)
    assert_equal 1, count("secrets", OLD_CHAT_ID)
    assert_equal 1, @conn.get_first_value("SELECT count(*) FROM chat_id_aliases"),
                 "未知 id 的迁移不产生悬空 alias"
    assert_equal -100_777_000_111, alias_row(-777_000_111)["new_chat_id"],
                 "审计仍要记录（诊断用），只是没有行可搬"
  end

  def test_no_migration_fields_returns_nil
    assert_nil @migration.handle(chat_id: OLD_CHAT_ID)
    assert_nil @migration.handle(chat_id: nil, migrate_to: nil, migrate_from: nil)
  end

  def test_same_id_on_both_sides_is_noop
    result = @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: OLD_CHAT_ID,
                               migrate_from: OLD_CHAT_ID)

    refute result.moved?, "old == new 时不得自我 UPDATE（否则误报为有变更）"
    assert_equal 2, count("chat_settings", OLD_CHAT_ID), "原有行必须原地不动"
    assert_equal 1, count("bank_record", OLD_CHAT_ID)
    assert_nil alias_row(OLD_CHAT_ID), "old == new 时不写 alias（无迁移发生）"
  end

  # =========================================================================
  # F. 64 位 chat_id
  # =========================================================================

  def test_64bit_chat_ids_move_without_precision_loss
    seed_all_tables(BIG_OLD, suffix: "b") # 第二组：secrets.id / PK 不与首组撞

    @migration.handle(chat_id: BIG_OLD, migrate_to: BIG_NEW)

    assert_all_moved(from: BIG_OLD, to: BIG_NEW)
    row = alias_row(BIG_OLD)
    assert_equal BIG_NEW, row["new_chat_id"], "64 位 id 往返不得丢精度"
    assert_equal 0, count("secrets", BIG_OLD)
    assert_equal 1, count("secrets", BIG_NEW)
  end

  def test_string_chat_ids_are_coerced
    # 入站若是字符串（如从 JSON 直读），不得因字符串比较而漏迁移
    @migration.handle(chat_id: OLD_CHAT_ID.to_s, migrate_to: NEW_CHAT_ID.to_s)

    assert_equal 0, count("chat_settings", OLD_CHAT_ID)
    assert_equal 2, count("chat_settings", NEW_CHAT_ID)
  end

  # =========================================================================
  # G. 事务原子性
  # =========================================================================

  def test_conflicting_target_row_rolls_everything_back
    # 目标 id 侧已存在同键行（chat_settings PK (chat_id, thread_id)）→ UNIQUE 冲突
    @conn.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, game_system) VALUES (?, 0, 'NinjaSlayerEx')",
      [NEW_CHAT_ID]
    )

    assert_raises(SQLite3::ConstraintException) do
      @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)
    end

    # 整笔回滚：连先执行的 bank_record 也不能留在新 id 下
    assert_equal 2, count("chat_settings", OLD_CHAT_ID), "冲突时旧 id 下应保持原样"
    assert_equal 0, count("bank_record", NEW_CHAT_ID), "事务回滚：先执行的表也不能改"
    assert_equal 0, count("secrets", NEW_CHAT_ID)
    assert_nil alias_row(OLD_CHAT_ID), "事务回滚：alias 也不该留下半条记录"
    refute @conn.transaction_active?, "回滚后不应残留活动事务"
  end

  def test_rollback_leaves_ledger_readable_for_retry
    # 回滚后应能原样重试（未卡在活动事务/锁上）
    @conn.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, game_system) VALUES (?, 0, 'X')",
      [NEW_CHAT_ID]
    )
    assert_raises(SQLite3::ConstraintException) do
      @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)
    end

    # 清掉冲突行 → 重试成功
    @conn.execute("DELETE FROM chat_settings WHERE chat_id = ? AND game_system = 'X'", [NEW_CHAT_ID])
    result = @migration.handle(chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID)
    assert result.moved?, "冲突解除后应能正常迁移（连接未卡死）"
    assert_all_moved(from: OLD_CHAT_ID, to: NEW_CHAT_ID)
  end

  # =========================================================================
  # H. router 集成
  # =========================================================================

  # 假 migration handler：记录调用（测试注入依赖，router 自己不碰 DB）
  class FakeMigration
    attr_reader :calls

    def initialize(raise_with: nil)
      @calls = []
      @raise_with = raise_with
    end

    def call(chat_id:, migrate_to: nil, migrate_from: nil)
      @calls << { chat_id: chat_id, migrate_to: migrate_to, migrate_from: migrate_from }
      raise @raise_with if @raise_with

      :ok
    end
  end

  def router_with(migration)
    require_relative "../../bot/router"
    api, fake, = build_api
    [TelegramBot::Router.new(api: api, migration: migration,
                              bot_username: "example_dice_bot",
                              logger: Logger.new(@io)), fake]
  end

  # 构造一条迁移 update（用 gem 的真类型，避免自造假对象掩盖真实语义）
  def migration_update(direction, chat_id:, other_id:, text: "群已升级为超级群")
    attrs = { message_id: 500, date: 1_700_000_000,
              chat: { id: chat_id, type: direction == :to ? "group" : "supergroup" },
              from: { id: 42, is_bot: false, first_name: "Tester" },
              text: text }
    attrs[:migrate_to_chat_id] = other_id if direction == :to
    attrs[:migrate_from_chat_id] = other_id if direction == :from

    Telegram::Bot::Types::Update.new(update_id: 500,
                                      message: Telegram::Bot::Types::Message.new(**attrs))
  end

  def test_router_calls_injected_migration_handler_for_migrate_to
    fake_migration = FakeMigration.new
    router, fake_api = router_with(fake_migration)

    router.dispatch(migration_update(:to, chat_id: OLD_CHAT_ID, other_id: NEW_CHAT_ID))

    assert_equal 1, fake_migration.calls.size, "旧群侧消息应触发 migration handler"
    assert_equal({ chat_id: OLD_CHAT_ID, migrate_to: NEW_CHAT_ID, migrate_from: nil },
                 fake_migration.calls.first)
    assert_empty fake_api.sent_messages, "迁移服务消息不得回发任何内容"
  end

  def test_router_calls_injected_migration_handler_for_migrate_from
    fake_migration = FakeMigration.new
    router, fake_api = router_with(fake_migration)

    router.dispatch(migration_update(:from, chat_id: NEW_CHAT_ID, other_id: OLD_CHAT_ID))

    assert_equal 1, fake_migration.calls.size
    assert_equal({ chat_id: NEW_CHAT_ID, migrate_to: nil, migrate_from: OLD_CHAT_ID },
                 fake_migration.calls.first)
    assert_empty fake_api.sent_messages
  end

  def test_router_migration_message_never_routed_as_normal_message
    fake_migration = FakeMigration.new
    router, fake_api = router_with(fake_migration)
    routed = []
    router.register(:aux) { |ctx| routed << ctx[:text]; "掷骰" }
    router.register(:start) { "hi" }

    # 迁移服务消息的正文恰好是合法骰式——也**不得**进 aux 轨（否则群里会
    # 因为「群升级」回一句掷骰结果）
    router.dispatch(migration_update(:to, chat_id: OLD_CHAT_ID, other_id: NEW_CHAT_ID,
                                     text: "2d6>=4"))

    assert_empty routed, "迁移服务消息不得走普通消息轨"
    assert_empty fake_api.sent_messages
  end

  def test_router_survives_migration_handler_exception
    fake_migration = FakeMigration.new(raise_with: RuntimeError.new("db locked"))
    router, fake_api = router_with(fake_migration)
    # 第二个 supergroup 的 id（与 OLD/NEW 都不同），与 64 位无关，用来证明
    # 「迁移失败后下一条普通消息」是被真路由了、不是又被误判成迁移消息
    other_group = -1_000_555_666_777
    router.register(:start) { "hi" }

    result = router.dispatch(migration_update(:to, chat_id: OLD_CHAT_ID, other_id: NEW_CHAT_ID))
    assert_nil result, "handler 异常应被兜住（不杀循环）"

    # 循环没死：后续普通消息照常处理
    ok = Telegram::Bot::Types::Update.new(
      update_id: 501,
      message: Telegram::Bot::Types::Message.new(
        message_id: 501, date: 1_700_000_000, text: "/start",
        chat: { id: other_group, type: "supergroup" },
        from: { id: 42, is_bot: false, first_name: "Tester" }
      )
    )
    router.dispatch(ok)
    assert_equal ["hi"], fake_api.sent_messages.map { |m| m[:text] },
                 "迁移失败后长轮询循环必须继续工作"
  end

  def test_router_warning_does_not_leak_message_text
    fake_migration = FakeMigration.new(raise_with: RuntimeError.new("secret user text"))
    router, = router_with(fake_migration)
    router.dispatch(migration_update(:to, chat_id: OLD_CHAT_ID, other_id: NEW_CHAT_ID,
                                     text: "群里某人的私密内容"))

    log = warnings
    refute_empty log, "异常必须留 warn 痕迹"
    refute_includes log, "secret user text", "日志不得含异常消息正文"
    refute_includes log, "私密内容", "日志不得含入站消息正文"
    assert_includes log, "RuntimeError", "日志应记异常类名（可诊断）"
  end

  def test_router_without_migration_dependency_stays_silent
    api, fake_api, = build_api
    router = TelegramBot::Router.new(api: api, logger: Logger.new(@io))

    result = router.dispatch(migration_update(:to, chat_id: OLD_CHAT_ID, other_id: NEW_CHAT_ID))

    assert_nil result
    assert_empty fake_api.sent_messages, "未注入 handler 时也不得回发"
    assert_includes warnings, "migration", "缺依赖要有 warn（别静默丢迁移）"
  end

  def test_router_non_migration_messages_never_touch_migration_handler
    fake_migration = FakeMigration.new
    router, = router_with(fake_migration)

    plain = Telegram::Bot::Types::Update.new(
      update_id: 502,
      message: Telegram::Bot::Types::Message.new(
        message_id: 502, date: 1_700_000_000, text: "SB",
        chat: { id: NEW_CHAT_ID, type: "supergroup" },
        from: { id: 42, is_bot: false, first_name: "Tester" }
      )
    )
    router.dispatch(plain)

    assert_empty fake_migration.calls, "普通消息不得误触 migration"
  end

  # =========================================================================
  # 端到端：真 Migration + 真 Router 串起来（单连接纪律的连带验证）
  # =========================================================================

  def test_end_to_end_router_drives_real_migration
    require_relative "../../bot/router"
    api, fake_api, = build_api
    router = TelegramBot::Router.new(
      api: api,
      migration: TelegramBot::Migration.new(connection: @conn, logger: Logger.new(@io)),
      bot_username: "example_dice_bot",
      logger: Logger.new(@io)
    )

    router.dispatch(migration_update(:to, chat_id: OLD_CHAT_ID, other_id: NEW_CHAT_ID))
    # Telegram 升级时会向**两侧**各发一条；重复到达也应幂等
    router.dispatch(migration_update(:from, chat_id: NEW_CHAT_ID, other_id: OLD_CHAT_ID))
    router.dispatch(migration_update(:to, chat_id: OLD_CHAT_ID, other_id: NEW_CHAT_ID))

    assert_all_moved(from: OLD_CHAT_ID, to: NEW_CHAT_ID)
    assert_equal NEW_CHAT_ID, alias_row(OLD_CHAT_ID)["new_chat_id"]
    assert_empty fake_api.sent_messages, "整条链路上不得有任何回发"
    assert_equal 1, @conn.get_first_value("SELECT count(*) FROM chat_id_aliases")
  end

  # --- 工具 -----------------------------------------------------------------

  # 五表 + log_entries 的完整快照（幂等断言用：行数与内容都要一字不差）
  def snapshot_all
    TelegramBot::Migration::TABLES.sort.each_with_object({}) do |table, acc|
      acc[table] = @conn.execute_query("SELECT * FROM #{table} ORDER BY rowid")
    end.merge(
      "log_entries" => @conn.execute_query("SELECT * FROM log_entries ORDER BY rowid"),
      "chat_id_aliases" => @conn.execute_query("SELECT * FROM chat_id_aliases ORDER BY rowid")
    )
  end
end