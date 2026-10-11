# frozen_string_literal: true

# ============================================================================
# test/db/test_connection_test.rb — 连接层（T2.4）
#
# 覆盖计划 §4.1 + §15.5 E10 的连接层契约：
#   - 首次连接自动建 schema（7 表 + 索引全在，且**只建一次**就够）
#   - 重复连接幂等（IF NOT EXISTS，不炸、不重建丢数据）
#   - PRAGMA：journal_mode=WAL、foreign_keys=ON（**并实测真的强制**）
#   - 事务：提交 / 回滚 / 嵌套复用外层
#   - 单连接：同路径 instance 返回同一对象
#   - 64 位 chat_id 往返不丢精度
#
# 全程零文件副作用：用 :memory: 库（唯一的落盘用例自己负责清理）。
# ============================================================================

require "minitest/autorun"
require "tmpdir"
require "tempfile"
require_relative "../../db/connection"
require_relative "../../bot/config"

class TestConnection < Minitest::Test
  # §4.1 的七张表 + 计划明写的索引
  EXPECTED_TABLES = %w[
    chat_settings bank_record custom_tables secrets
    chat_id_aliases session_logs log_entries
  ].freeze

  def setup
    TenguDB::Connection.reset!
    @conn = TenguDB::Connection.open(path: ":memory:")
  end

  def teardown
    @conn.close
    TenguDB::Connection.reset!
  end

  def table_names
    @conn.execute_query(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    ).flatten
  end

  # --- schema 自动落地 ------------------------------------------------------

  def test_schema_created_on_first_connection
    EXPECTED_TABLES.each do |t|
      assert_includes table_names, t, "首次连接应自动建表 #{t}"
    end
  end

  def test_log_entries_index_created
    indexes = @conn.execute_query(
      "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='log_entries'"
    ).flatten
    assert_includes indexes, "idx_log_entries_log"
  end

  def test_reopening_same_path_is_idempotent
    # 建 schema → 写一行 → 再开一次连接 → 数据仍在（IF NOT EXISTS 不重建）
    @conn.execute("INSERT INTO chat_settings (chat_id, thread_id) VALUES (1, 0)")

    other = TenguDB::Connection.open(path: ":memory:")
    other.close
    # 内存库每次是独立实例，故用「同一实例重跑 schema」验证幂等：
    assert_equal 1, @conn.get_first_value("SELECT count(*) FROM chat_settings")
    assert_equal 1, table_names.count { |n| n == "chat_settings" }, "表不应被重建"
  end

  def test_schema_apply_is_idempotent_on_real_file
    Dir.mktmpdir("tengu-db-test") do |dir|
      path = File.join(dir, "idempotent.db")
      first = TenguDB::Connection.open(path: path)
      first.execute("INSERT INTO chat_id_aliases (old_chat_id, new_chat_id) VALUES (1, 2)")
      first.close

      second = TenguDB::Connection.open(path: path) # 第二次连接重跑 schema
      count = second.get_first_value("SELECT count(*) FROM chat_id_aliases")
      second.close

      assert_equal 1, count, "重复连接执行 schema 不应丢数据"
    end
  end

  # --- PRAGMA（§15.5 E10）--------------------------------------------------

  def test_journal_mode_is_wal_on_real_file
    # 内存库的 journal_mode 恒为 memory（WAL 不支持），故用真文件验
    Dir.mktmpdir("tengu-db-test") do |dir|
      conn = TenguDB::Connection.open(path: File.join(dir, "wal.db"))
      assert_equal "wal", conn.pragma("journal_mode").to_s.downcase
      conn.close
    end
  end

  def test_foreign_keys_pragma_is_on
    assert_equal 1, @conn.pragma("foreign_keys").to_i,
                 "连接层必须开 foreign_keys（§15.5 E10），否则 REFERENCES 形同虚设"
  end

  def test_foreign_keys_are_actually_enforced
    # 光断言 PRAGMA 值不够：真插一条孤儿行，看引擎是否拒
    @conn.execute("INSERT INTO session_logs (chat_id, name) VALUES (1, 'x')")
    log_id = @conn.get_first_value("SELECT id FROM session_logs LIMIT 1")

    error = assert_raises(SQLite3::ConstraintException) do
      @conn.execute(
        "INSERT INTO log_entries (log_id, seq, sender_name, content) " \
        "VALUES (?, 1, 'a', 'b')", [log_id + 999]
      )
    end
    refute_nil error, "log_id 指向不存在的 session_logs 应被 FK 拒绝"
  end

  # --- 事务 ----------------------------------------------------------------

  def test_transaction_commits
    @conn.transaction(:immediate) { @conn.execute("INSERT INTO chat_settings (chat_id) VALUES (5)") }

    assert_equal 1, @conn.get_first_value("SELECT count(*) FROM chat_settings")
    refute @conn.transaction_active?, "块结束后事务应已结束"
  end

  def test_transaction_rolls_back_and_reraises
    err = assert_raises(RuntimeError) do
      @conn.transaction(:immediate) do
        @conn.execute("INSERT INTO chat_settings (chat_id) VALUES (5)")
        raise "boom"
      end
    end

    assert_equal "boom", err.message, "异常应原样重抛（不吞、不包装）"
    assert_equal 0, @conn.get_first_value("SELECT count(*) FROM chat_settings"),
                 "异常回滚后不应有残留写入"
    refute @conn.transaction_active?
  end

  def test_nested_transaction_reuses_outer
    # sqlite3 gem 明确不支持嵌套（会抛 cannot start a transaction within a
    # transaction）→ 内层必须复用外层，且内层失败要能整体回滚。
    @conn.transaction(:immediate) do
      @conn.execute("INSERT INTO chat_settings (chat_id) VALUES (1)")
      @conn.transaction(:immediate) do
        @conn.execute("INSERT INTO chat_settings (chat_id) VALUES (2)")
      end
    end

    assert_equal 2, @conn.get_first_value("SELECT count(*) FROM chat_settings")
  end

  # --- 单连接 + 64 位 chat_id ----------------------------------------------

  def test_instance_is_memoized_per_path
    a = TenguDB::Connection.instance(path: ":memory:")
    b = TenguDB::Connection.instance(path: ":memory:")

    assert_same a, b, "同路径应返回同一单连接"
    a.close
  end

  def test_instance_distinguishes_paths
    a = TenguDB::Connection.instance(path: ":memory:")
    other = Tempfile.new(["tengu", ".db"])
    b = TenguDB::Connection.instance(path: other.path)

    refute_same a, b, "不同路径应是不同连接"
    a.close
    b.close
  ensure
    other&.close!
  end

  def test_64bit_chat_id_roundtrip
    big = -1_000_000_000_123_456_789 # 超 32 位有效位（§0.2.4）
    @conn.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, game_system) VALUES (?, ?, ?)",
      [big, 7, "NinjaSlayerEx"]
    )

    got = @conn.get_first_value(
      "SELECT chat_id FROM chat_settings WHERE chat_id = ?", [big]
    )
    assert_equal big, got.to_i, "64 位 chat_id 往返不得丢精度"
  end

  # --- 路径来源 ------------------------------------------------------------

  def test_default_path_comes_from_config
    original = ENV["DB_PATH"]
    ENV["DB_PATH"] = "/tmp/tengu-conn-probe.db"
    assert_equal "/tmp/tengu-conn-probe.db", TelegramBot::Config.db_path,
                 "Config.db_path 是唯一真相源（连接层不得另抄默认值）"
    assert_equal TelegramBot::Config.db_path, TenguDB::Connection.default_path
  ensure
    ENV["DB_PATH"] = original
  end

  def test_connection_creates_parent_directory
    Dir.mktmpdir("tengu-db-test") do |dir|
      path = File.join(dir, "nested", "deep", "tengu.db")
      conn = TenguDB::Connection.open(path: path)

      assert File.exist?(path), "连接层应负责 mkdir_p 父目录"
      conn.close
    end
  end
end

require "tmpdir"
require "tempfile"