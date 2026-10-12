# frozen_string_literal: true

# ============================================================================
# test/db/test_secrets_test.rb — 暗骰结果持久化（T3.1）
#
# 覆盖计划 §8 T3.1 与 §15.3 E5 的全部验收点：
#   - CRUD：create / find / latest_for / delete / count_for
#   - **TTL 惰性清理**：写入时顺手删掉超期行；未超期行不动
#   - callback_data 命名空间：编解码往返、非本命名空间 fail-closed、
#     64 字节上限内、形态校验
#   - owned_by?：本人 / 非本人 / nil / 0 / 字符串形态
#   - 值绑定纪律：command/result_text 里的引号分号原样进出（不拼串）
#   - 64 位 chat_id 不损坏
#   - **反射守卫**：secrets 含 chat_id 列，必须在 Migration::TABLES 内
#
# 全程 :memory: 库，零文件、零联网。
# ============================================================================

require "minitest/autorun"
require "logger"
require_relative "../../db/connection"
require_relative "../../db/secrets"
require_relative "../../bot/migration"

class TestSecrets < Minitest::Test
  BIG_CHAT_ID = -1_000_000_000_123_456_789 # 超 32 位（§0.2.4）
  TOPIC = 88
  USER = 42
  OTHER_USER = 43

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @store = TenguDB::Secrets.new(@conn)
  end

  def teardown
    @conn.close
  end

  # 造一条记录（默认都合法）
  def seed(chat_id: BIG_CHAT_ID, thread_id: 0, user_id: USER,
           command: "SB", result_text: "result", id: nil)
    args = { chat_id: chat_id, thread_id: thread_id, user_id: user_id,
             command: command, result_text: result_text }
    args[:id] = id if id
    @store.create(**args)
  end

  # --- CRUD ---------------------------------------------------------------

  def test_create_returns_secret_with_stored_fields
    record, err = seed(command: "SB@6", result_text: "6", thread_id: TOPIC)

    assert_nil err
    refute_nil record
    assert_equal BIG_CHAT_ID, record.chat_id, "64 位 chat_id 不能被截断"
    assert_equal TOPIC, record.thread_id
    assert_equal USER, record.user_id
    assert_equal "SB@6", record.command
    assert_equal "6", record.result_text
    refute_empty record.created_at, "created_at 应由 datetime('now') 落库"
  end

  def test_create_generates_short_lowercase_hex_id
    record, = seed

    assert_match(/\A[0-9a-f]{16}\z/, record.id,
                 "id 应是 16 位小写十六进制（短到能进 callback_data，形态可校验）")
  end

  def test_create_ids_are_unique
    ids = 50.times.map { seed.first.id }

    assert_equal 50, ids.uniq.size, "50 次写入不该撞 id"
  end

  def test_find_returns_the_row
    record, = seed(result_text: "サツバツ")

    found = @store.find(record.id)
    refute_nil found
    assert_equal record.id, found.id
    assert_equal "サツバツ", found.result_text
    assert_equal record.created_at, found.created_at
  end

  def test_find_unknown_or_blank_id_is_nil
    assert_nil @store.find("does-not-exist")
    assert_nil @store.find("")
    assert_nil @store.find(nil)
  end

  def test_delete_reports_whether_a_row_went_away
    record, = seed

    assert @store.delete(record.id), "第一次删应真的删掉一行"
    refute @store.delete(record.id), "再删一次应为 false（changes=0，不是 execute 的返回值）"
    assert_nil @store.find(record.id)
  end

  def test_delete_blank_id_is_false_and_does_not_touch_table
    seed

    refute @store.delete("")
    assert_equal 1, @store.count_for, "空 id 的删除不该变成无条件 DELETE"
  end

  # --- latest_for（/secret last 的数据源，R6 缓解）------------------------

  def test_latest_for_returns_the_newest_of_the_same_user
    @conn.execute(
      "INSERT INTO secrets (id, chat_id, thread_id, user_id, command, result_text, created_at) " \
      "VALUES ('old00000000000001', ?, 0, ?, 'SB', 'old', datetime('now', '-1 hour'))",
      [BIG_CHAT_ID, USER]
    )
    newest, = seed(result_text: "new")

    got = @store.latest_for(chat_id: BIG_CHAT_ID, user_id: USER)
    assert_equal newest.id, got.id, "应取最近一次（同秒并列时按 rowid 取后写的）"
    assert_equal "new", got.result_text
  end

  def test_latest_for_is_scoped_by_user_and_chat
    mine, = seed(result_text: "mine")
    seed(user_id: OTHER_USER, result_text: "theirs")
    seed(chat_id: -100_222_222, result_text: "another-chat")

    got = @store.latest_for(chat_id: BIG_CHAT_ID, user_id: USER)
    assert_equal mine.id, got.id,
                 "别人的行 / 别的群的行都不该出现在我的 last 里"
  end

  def test_latest_for_unknown_user_is_nil
    seed

    assert_nil @store.latest_for(chat_id: BIG_CHAT_ID, user_id: 999)
    assert_nil @store.latest_for(chat_id: BIG_CHAT_ID, user_id: 0)
    assert_nil @store.latest_for(chat_id: BIG_CHAT_ID, user_id: nil)
  end

  # --- TTL 惰性清理（E5 ②）-----------------------------------------------

  # 手工灌一条指定 created_at 的行（datetime('now') 精度到秒，测试要控制它）
  def seed_with_age(id, days_old)
    @conn.execute(
      "INSERT INTO secrets (id, chat_id, thread_id, user_id, command, result_text, created_at) " \
      "VALUES (?, ?, 0, ?, 'SB', 'aged', datetime('now', ?))",
      [id, BIG_CHAT_ID, USER, "-#{days_old} days"]
    )
  end

  def test_purge_expired_removes_only_rows_older_than_ttl
    seed_with_age("fresh0000000001", 1)
    seed_with_age("stale0000000001", 8)
    seed_with_age("ancient000001", 30)

    removed = @store.purge_expired

    assert_equal 2, removed, "两个超期行应被删（读 conn.changes，不是 execute 返回值）"
    refute_nil @store.find("fresh0000000001"), "未超期的行必须留下"
    assert_nil @store.find("stale0000000001")
    assert_nil @store.find("ancient000001")
  end

  def test_ttl_boundary_is_seven_days
    assert_equal 7, TenguDB::Secrets::TTL_DAYS

    seed_with_age("six00000000001", 6)
    seed_with_age("eight000000001", 8)

    @store.purge_expired

    refute_nil @store.find("six00000000001"), "6 天前的行还在 7 天 TTL 内"
    assert_nil @store.find("eight000000001")
  end

  def test_create_purges_expired_rows_lazily
    seed_with_age("stale0000000001", 9)
    seed_with_age("stale0000000002", 10)
    record, = seed(result_text: "brand new")

    refute_nil @store.find(record.id), "新写的行本身不能被自己的清理删掉"
    assert_equal 1, @store.count_for, "写入应顺手清掉两条超期行（惰性 TTL）"
  end

  def test_purge_expired_accepts_custom_ttl_and_rejects_nonsense
    seed_with_age("aged00000000001", 3)

    @store.purge_expired(ttl_days: 1)
    assert_equal 0, @store.count_for, "自定义 TTL=1 天应删掉 3 天前的行"

    seed_with_age("aged00000000002", 3)
    @store.purge_expired(ttl_days: 0)
    refute_nil @store.find("aged00000000002"),
               "ttl<=0 应回落到默认 TTL（而不是「删光」或「删零」）"
  end

  # --- callback_data 命名空间（E5 决策：sec: 前缀）------------------------

  def test_callback_data_round_trip
    record, = seed
    data = TenguDB::Secrets.callback_data(record.id)

    assert data.start_with?("sec:"), "必须有命名空间前缀（callback_data 是共享总线）"
    assert_equal record.id, TenguDB::Secrets.secret_id_from_callback_data(data)
  end

  def test_callback_data_fits_the_64_byte_platform_limit
    data = TenguDB::Secrets.callback_data(TenguDB::Secrets.generate_id)

    assert_operator data.bytesize, :<=, 64,
                    "callback_data 平台上限 64 字节（Telegram InlineKeyboardButton）"
  end

  def test_foreign_or_malformed_callback_data_is_rejected
    [
      nil, "", "sec:", "reveal:abc123", "SEC:abc", " sec:abc",
      "sec:short", "sec:ZZZZZZZZZZZZZZZZ", "sec:#{'a' * 17}",
      "bank:abc123", "sec:abc123; DROP TABLE secrets"
    ].each do |bad|
      assert_nil TenguDB::Secrets.secret_id_from_callback_data(bad),
                 "非本命名空间/畸形 data 必须 fail-closed：#{bad.inspect}"
      refute TenguDB::Secrets.owns_callback_data?(bad)
    end
  end

  def test_owns_callback_data_distinguishes_our_namespace
    id = TenguDB::Secrets.generate_id

    assert TenguDB::Secrets.owns_callback_data?(TenguDB::Secrets.callback_data(id))
    refute TenguDB::Secrets.owns_callback_data?("ct:abc")
  end

  # --- 权限：owned_by?（只有本人，§0.2.4 用真人 user id）------------------

  def test_owned_by_matches_only_the_rolling_user
    record, = seed(user_id: USER)

    assert record.owned_by?(USER)
    assert record.owned_by?(USER.to_s), "字符串形态的 id 应同样通过（入站可能是字符串）"
    refute record.owned_by?(OTHER_USER), "非本人拿不到"
    refute record.owned_by?(nil)
    refute record.owned_by?(0)
    refute record.owned_by?("")
    refute record.owned_by?(9_223_372_036_854_775_808),
           "超 int64 的 candidate 应判非本人（fail-closed，2026-10-12 补齐界守卫）"
    refute record.owned_by?("#{USER}abc"),
           "2026-10-13：宽容 to_i 会把它折成本人——比较侧必须严格解析（fail-closed）"
  end

  def test_create_rejects_ids_beyond_int64
    int64_max = 9_223_372_036_854_775_807

    record, err = @store.create(chat_id: int64_max + 1, user_id: USER,
                                command: "SB", result_text: "r")
    assert_nil record
    assert_equal ArgumentError, err, "超 int64 的 chat_id 应拒（SQLite 会静默存成 REAL）"

    record, err = @store.create(chat_id: BIG_CHAT_ID, user_id: int64_max + 1,
                                command: "SB", result_text: "r")
    assert_nil record
    assert_equal ArgumentError, err, "超 int64 的 user_id 应拒"

    # 界内边界值不误伤（守卫只拦超界；INT64_MIN 是合法 int64，2026-10-12 三审
    # 统一四文件闭区间口径后收录）
    record, err = @store.create(chat_id: -int64_max, user_id: int64_max,
                                command: "SB", result_text: "r")
    assert_nil err
    refute_nil record

    int64_min = -9_223_372_036_854_775_808
    record, err = @store.create(chat_id: int64_min, user_id: USER,
                                command: "SB", result_text: "r")
    assert_nil err
    refute_nil record, "INT64_MIN 作 chat_id 应收（SQLite 存得住）"

    record, err = @store.create(chat_id: int64_min - 1, user_id: USER,
                                command: "SB", result_text: "r")
    assert_nil record
    assert_equal ArgumentError, err, "INT64_MIN-1 超界应拒"
  end

  # --- 值绑定纪律 ---------------------------------------------------------

  def test_sql_metacharacters_are_stored_verbatim
    nasty = %q{SB'; DROP TABLE secrets; -- "x"}
    record, = seed(command: nasty, result_text: nasty)

    assert_equal nasty, @store.find(record.id).command
    assert_equal nasty, @store.find(record.id).result_text
    assert @conn.table_exists?("secrets"), "值必须走绑定，不得拼进 SQL"
  end

  def test_unicode_command_survives
    record, = seed(command: "N4,3[J] サツバツ", result_text: "判定値：6")

    assert_equal "N4,3[J] サツバツ", @store.find(record.id).command
    assert_equal "判定値：6", @store.find(record.id).result_text
  end

  # --- 入参守卫（fail-fast，不把脏行写进库）------------------------------

  def test_create_rejects_invalid_arguments
    [{ result_text: "" }, { result_text: nil }, { user_id: 0 },
     { user_id: nil }, { chat_id: 0 }].each do |override|
      args = { chat_id: BIG_CHAT_ID, user_id: USER,
               command: "SB", result_text: "x" }.merge(override)
      record, err = @store.create(**args)

      assert_nil record, "非法入参不该写库：#{override.inspect}"
      assert_equal ArgumentError, err
    end
    assert_equal 0, @store.count_for
  end

  # --- 反射守卫：secrets 含 chat_id，必须在 Migration::TABLES 里 ----------
  # 「新增含 chat_id 的表但忘了登记迁移名单」= 群升级后暗骰记录静默消失。

  def test_secrets_table_is_covered_by_migration_tables
    assert @conn.table_exists?("secrets"), "sanity：schema.sql 应建出 secrets"
    assert_includes @conn.column_names("secrets"), "chat_id"

    assert_includes TelegramBot::Migration::TABLES, "secrets",
                 "secrets 含 chat_id 列却不在 Migration::TABLES（群升级会丢暗骰记录）"
  end

  # --- 迁移确实带上 secrets 行（与 T2.5 的联动，不只查名单）---------------

  def test_chat_upgrade_moves_secret_rows_to_new_chat_id
    record, = seed(chat_id: -123_456_789, thread_id: TOPIC, result_text: "keep me")

    result = TelegramBot::Migration.new(connection: @conn, logger: Logger.new(IO::NULL))
             .handle(chat_id: -123_456_789, migrate_to: -1_009_876_543_210)

    refute_nil result
    assert_equal 1, result.rows["secrets"]
    moved = @store.find(record.id)
    assert_equal(-1_009_876_543_210, moved.chat_id, "暗骰的公开回发位置必须跟着群走")
    assert_equal TOPIC, moved.thread_id, "话题定位不能被迁移改坏"
  end

  # --- 常量形态守卫 -------------------------------------------------------

  def test_module_constants_are_frozen_and_wellformed
    assert_equal "sec:", TenguDB::Secrets::CALLBACK_PREFIX
    assert_equal 2 * TenguDB::Secrets::ID_BYTES, TenguDB::Secrets::ID_LENGTH
    assert_operator TenguDB::Secrets::TTL_DAYS, :>, 0
    assert_operator TenguDB::Secrets::ID_ATTEMPTS, :>=, 1
  end
end