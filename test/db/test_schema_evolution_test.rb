# frozen_string_literal: true

# ============================================================================
# test/db/test_schema_evolution_test.rb — schema 演进范式（T2.6 首个实例）
#
# 为什么单开一个文件：这是一个**跨 schema.sql 与 db/connection.rb 的纪律**，
# 放在 test_connection_test.rb 里会被当成连接层的边角。它的失败症状
# （旧库 no such column）是**部署后才现形**的，故必须由测试当场拦下。
#
# 覆盖：
#   - 旧库（手工建**无** aux_enabled 的 chat_settings）首连 → 列出现
#   - 补列后**既有数据一行不动**（值取列默认值 1）
#   - 二次连接幂等（不重复加列、不炸）
#   - 新库直建（schema.sql 已含该列，补列 no-op）
#   - ensure_column 本身的语义：表不存在 / 列已存在 / 真加列
#   - COLUMN_ADDITIONS 与 schema.sql **不得漂移**（反射守卫：新库建出的列
#     必须与登记的列定义一致，否则新库与旧库行为不同）
#   - 通则守卫：凡登记进 COLUMN_ADDITIONS 的 (表,列) 必须真的存在于
#     schema.sql 建出的表里——漏改 schema.sql 的那条腿当场红
#
# 全程真文件库（:memory: 不经历「首连」的语义），用 tmpdir 自清理。
# ============================================================================

require "minitest/autorun"
require "tmpdir"
require "sqlite3"
require_relative "../../db/connection"

class TestSchemaEvolution < Minitest::Test
  # T2.4 的原始 chat_settings（**故意没有** aux_enabled）——部署前的老库长这样
  LEGACY_CHAT_SETTINGS = <<~SQL
    CREATE TABLE chat_settings (
      chat_id      INTEGER NOT NULL,
      thread_id    INTEGER NOT NULL DEFAULT 0,
      game_system  TEXT NOT NULL DEFAULT 'NinjaSlayer2Ex',
      updated_at   TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (chat_id, thread_id)
    );
  SQL

  BIG_CHAT_ID = -1_000_000_000_123_456_789

  def setup
    TenguDB::Connection.reset!
  end

  def teardown
    TenguDB::Connection.reset!
  end

  # 造一个「T2.4 时代」的旧库：只有 chat_settings + 两条既有数据
  def build_legacy_db(path)
    db = SQLite3::Database.new(path)
    db.execute_batch(LEGACY_CHAT_SETTINGS)
    db.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, game_system) VALUES (?, 0, ?)",
      [BIG_CHAT_ID, "NinjaSlayerEx"]
    )
    db.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, game_system) VALUES (?, 88, ?)",
      [BIG_CHAT_ID, "NinjaSlayer2Ex"]
    )
    db.close
  end

  # --- 旧库首连自动补列 ---------------------------------------------------

  def test_legacy_db_gains_column_on_first_connection
    Dir.mktmpdir("tengu-t2.6-schema") do |dir|
      path = File.join(dir, "legacy.db")
      build_legacy_db(path)

      # 补列前：确认旧库真的没有这一列（否则本用例是自证的假绿）
      raw = SQLite3::Database.new(path)
      refute_includes raw.get_first_value(
        "SELECT group_concat(name) FROM pragma_table_info('chat_settings')"
      ).to_s.split(","), "aux_enabled", "sanity：旧库本就不该有 aux_enabled"
      raw.close

      conn = TenguDB::Connection.open(path: path)

      assert conn.column?("chat_settings", "aux_enabled"),
             "首连后旧库应自动补上 aux_enabled（schema 演进的职责）"
      conn.close
    end
  end

  def test_legacy_db_data_survives_the_migration
    Dir.mktmpdir("tengu-t2.6-schema") do |dir|
      path = File.join(dir, "legacy.db")
      build_legacy_db(path)

      conn = TenguDB::Connection.open(path: path)
      rows = conn.execute_query(
        "SELECT chat_id, thread_id, game_system, aux_enabled FROM chat_settings ORDER BY thread_id"
      )
      conn.close

      assert_equal 2, rows.size, "既有行数不该变"
      assert_equal BIG_CHAT_ID, rows[0][0].to_i, "64 位 chat_id 不该在补列中损坏"
      assert_equal "NinjaSlayerEx", rows[0][2], "既有 game_system 值不动"
      assert_equal 1, rows[0][3].to_i, "新列取 DEFAULT 1（辅助轨默认开）"
      assert_equal 88, rows[1][1].to_i, "话题行也不动"
      assert_equal 1, rows[1][3].to_i
    end
  end

  def test_legacy_db_keeps_working_through_the_settings_layer
    # 补列不是「列出现了」就完事——上层读写的路径也得通
    Dir.mktmpdir("tengu-t2.6-schema") do |dir|
      path = File.join(dir, "legacy.db")
      build_legacy_db(path)

      require_relative "../../db/settings"
      conn = TenguDB::Connection.open(path: path)
      settings = TenguDB::Settings.new(conn)

      assert settings.aux_enabled(BIG_CHAT_ID),
             "旧库升级后辅助轨应读得出（默认开）"
      settings.set_aux_enabled(BIG_CHAT_ID, enabled: false)
      refute settings.aux_enabled(BIG_CHAT_ID), "旧库升级后也能写"
      assert_equal "NinjaSlayerEx", settings.game_system(BIG_CHAT_ID),
                   "补列过程不得影响既有的规则系统设置"
      conn.close
    end
  end

  def test_reopening_legacy_db_is_idempotent
    Dir.mktmpdir("tengu-t2.6-schema") do |dir|
      path = File.join(dir, "legacy.db")
      build_legacy_db(path)

      first = TenguDB::Connection.open(path: path)
      first.close
      second = TenguDB::Connection.open(path: path)
      names = second.column_names("chat_settings")
      second.close
      third = TenguDB::Connection.open(path: path)
      third.close

      assert_equal 1, names.count("aux_enabled"),
                   "反复连接不该重复加列（第二次就该是 no-op）"
    end
  end

  # --- 新库直建 -----------------------------------------------------------

  def test_fresh_db_has_column_from_schema_sql
    Dir.mktmpdir("tengu-t2.6-schema") do |dir|
      conn = TenguDB::Connection.open(path: File.join(dir, "fresh.db"))

      assert conn.column?("chat_settings", "aux_enabled"),
             "新库应由 schema.sql 直接建出该列（不用靠 ALTER）"
      conn.close
    end
  end

  def test_column_additions_are_noop_on_fresh_db
    Dir.mktmpdir("tengu-t2.6-schema") do |dir|
      conn = TenguDB::Connection.open(path: File.join(dir, "fresh.db"))

      TenguDB::Connection::COLUMN_ADDITIONS.each do |table, column, definition|
        refute conn.ensure_column(table, column, definition),
               "新库上 #{table}.#{column} 已存在，补列必须是 no-op"
      end
      conn.close
    end
  end

  # --- ensure_column 本身的语义 -------------------------------------------

  def test_ensure_column_returns_true_when_it_actually_adds
    conn = TenguDB::Connection.open(path: ":memory:")
    conn.execute("CREATE TABLE t (a INTEGER)")
    conn.execute("INSERT INTO t (a) VALUES (1)")

    assert conn.ensure_column("t", "b", "INTEGER NOT NULL DEFAULT 7"),
           "缺列时应真的执行 ALTER 并返回 true"
    assert_equal 7, conn.get_first_value("SELECT b FROM t"),
                 "NOT NULL + DEFAULT 要让既有行拿到默认值（否则 ALTER 会失败）"
    conn.close
  end

  def test_ensure_column_returns_false_when_column_exists
    conn = TenguDB::Connection.open(path: ":memory:")

    refute conn.ensure_column("chat_settings", "aux_enabled", "INTEGER NOT NULL DEFAULT 1"),
           "列已存在时应是 no-op"
    conn.close
  end

  def test_ensure_column_returns_false_when_table_absent
    conn = TenguDB::Connection.open(path: ":memory:")

    refute conn.ensure_column("no_such_table", "x", "INTEGER"),
           "表不存在时应返回 false 而不是炸（掩盖真实问题）"
    conn.close
  end

  def test_column_names_of_missing_table_is_empty
    conn = TenguDB::Connection.open(path: ":memory:")

    assert_empty conn.column_names("no_such_table")
    refute conn.column?("no_such_table", "x")
    assert conn.table_exists?("chat_settings"), "sanity：schema 的表应存在"
    refute conn.table_exists?("no_such_table")
    conn.close
  end

  # --- 通则守卫（把「两条腿」的纪律钉成测试）------------------------------

  # 守卫①：凡登记进 COLUMN_ADDITIONS 的列，必须**真的是 schema.sql 建出来的**
  #        那一列。漏改 schema.sql 的话：新库一建就没有这列，而 ensure_column
  #        会替它补上——两条腿都在，但**语义**已经漂移（新库靠 ALTER 补列、
  #        列定义与登记处不同源），属于「碰巧能用」的脆弱状态。
  def test_every_registered_column_exists_in_fresh_schema
    conn = TenguDB::Connection.open(path: ":memory:")

    TenguDB::Connection::COLUMN_ADDITIONS.each do |table, column, _definition|
      assert conn.table_exists?(table), "登记的表 #{table} 必须存在于 schema.sql"
      assert conn.column?(table, column),
             "登记的列 #{table}.#{column} 必须由 schema.sql 直接建出" \
             "（新库与旧库必须同源；只靠 ensure_column 补出来的是两条腿各写一份）"
    end
    conn.close
  end

  # 守卫②：登记的列定义必须与 schema.sql 建出的列**默认值一致**。
  #        两处漂移 → 同一个新群在「新库」上默认开、在「旧库」上默认关。
  def test_registered_definition_matches_schema_default
    conn = TenguDB::Connection.open(path: ":memory:")
    defaults = conn.execute_query("PRAGMA table_info(chat_settings)")
                  .to_h { |_cid, name, _type, _notnull, default, _pk| [name, default] }

    TenguDB::Connection::COLUMN_ADDITIONS.each do |table, column, definition|
      next unless table == "chat_settings"

      expected = definition[/DEFAULT\s+(\S+)/, 1]
      actual = defaults[column].to_s
      assert_equal expected, actual,
                   "#{table}.#{column} 的列默认值在 schema.sql 与 COLUMN_ADDITIONS " \
                   "之间漂移了（新旧库默认行为会不同）"
    end
    conn.close
  end

  def test_column_additions_shape_is_frozen_and_wellformed
    assert TenguDB::Connection::COLUMN_ADDITIONS.frozen?,
           "登记处应 frozen（避免运行期被改）"
    TenguDB::Connection::COLUMN_ADDITIONS.each do |entry|
      assert_equal 3, entry.size, "每条应是 [表, 列, 定义子句] 三元组：#{entry.inspect}"
      table, column, definition = entry
      refute_empty table.to_s
      refute_empty column.to_s
      # 插值进 SQL 的部分必须是常量且不含引号/分号（防注入与语句截断）
      refute_match(/[;'"\\]/, definition,
                   "列定义会被插值进 ALTER TABLE，不得含引号/分号：#{definition.inspect}")
      refute_match(/[;'"\\]/, table.to_s)
      refute_match(/[;'"\\]/, column.to_s)
    end
  end

  def test_not_null_columns_must_carry_a_default
    # ADD COLUMN ... NOT NULL 在有数据的表上，没有 DEFAULT 会直接失败
    TenguDB::Connection::COLUMN_ADDITIONS.each do |table, column, definition|
      next unless definition.match?(/NOT\s+NULL/i)

      assert_match(/DEFAULT\s+\S/i, definition,
                   "#{table}.#{column} 声明了 NOT NULL 却没给 DEFAULT —— " \
                   "在有数据的旧库上 ALTER 会直接失败")
    end
  end

  # --- 反向守卫（kimi T2.6 评审）----------------------------------------------
  # 正向守卫已钉「登记的列必须在新库建出」；本条钉反向——**只在 schema.sql
  # 加列、忘了登记 COLUMN_ADDITIONS**：旧库部署后该列不存在，查询当场炸。
  # 做法：schema.sql 里每张表的列集 − 该表 T2.4 基线列 = 必须全部登记在
  # COLUMN_ADDITIONS 里。

  # T2.4 七表原始列（计划 §4.1 定案）。演进只能通过 COLUMN_ADDITIONS 加列；
  # 直接改这张基线表 = 明确宣告「我在破坏旧库兼容」（审慎动作，故放行）。
  SCHEMA_BASELINE_COLUMNS = {
    "chat_settings"   => %w[chat_id thread_id game_system updated_at],
    "bank_record"     => %w[chat_id thread_id sum_money money_record item_record updated_at],
    "custom_tables"   => %w[id scope chat_id name spec permissions datarange author_id created_at updated_at],
    "secrets"         => %w[id chat_id thread_id user_id command result_text created_at],
    "chat_id_aliases" => %w[old_chat_id new_chat_id migrated_at],
    "session_logs"    => %w[id chat_id thread_id name status created_at ended_at],
    "log_entries"     => %w[id log_id seq sender_name user_id is_bot msg_kind content created_at],
  }.freeze

  def test_schema_sql_columns_beyond_baseline_are_registered
    sql = File.read(File.expand_path("../../db/schema.sql", __dir__))
    ddl_blocks = sql.scan(/CREATE TABLE IF NOT EXISTS (\w+)\s*\((.*?)\);/m)
    refute_empty ddl_blocks, "应从 schema.sql 解析出建表块（解析失败=守卫失效）"

    ddl_blocks.each do |table, body|
      columns = body.lines.map(&:strip).filter_map do |line|
        next if line.empty? || line.start_with?("--")

        first = line.split.first.to_s.downcase
        next if first.match?(/\A(?:unique|primary|foreign|check|constraint)\b/)

        first
      end

      baseline = SCHEMA_BASELINE_COLUMNS[table] || []
      extra = columns - baseline
      registered = TenguDB::Connection::COLUMN_ADDITIONS
                   .select { |t, _, _| t == table }.map { |_, c, _| c }
      unregistered = extra - registered

      assert_empty unregistered,
                   "#{table} 的列 #{unregistered.inspect} 超出 T2.4 基线却未登记 " \
                   "COLUMN_ADDITIONS——旧库升级后会缺列（登记的列才会被 ensure_column 补上）"
    end
  end
end