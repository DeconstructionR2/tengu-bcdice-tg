# frozen_string_literal: true

# ============================================================================
# test/db/test_session_logs_test.rb — 跑团 log 录制 DB 层（T3.5）
#
# 覆盖计划 §4.1（session_logs/log_entries schema）/ §8 T3.5 / §13 第 6 项：
#
#   - 状态机：start → recording → pause → paused → resume → recording →
#     finish → ended（含 already_* / no_active / 名字校验各分支）
#   - 作用域：话题级 (chat_id, thread_id)；E4 归一（General=1 与群级 0 同一行）；
#     两话题/两群互不相串
#   - 条目：seq 逐条递增（事务内现算）、字段往返、bot 条目 user_id=NULL、
#     多行内容保真、SQL 元字符按值绑定
#   - FK：append 到不存在的 log 必须抛（PRAGMA foreign_keys=ON 生效；§15.5 E10）
#   - list：最新在前 + 条目数 + limit + 作用域隔离
#   - **迁移联动**：session_logs 在 Migration::TABLES 内（反射）；群升级后
#     录制行随新 chat_id 走、条目原样挂着、录制可继续（seq 接着涨）
#
# 全程 :memory: 库，零文件、零联网。
# ============================================================================

require "minitest/autorun"
require "json"
require "logger"
require_relative "../../db/connection"
require_relative "../../db/session_logs"
require_relative "../../bot/migration"

class TestSessionLogs < Minitest::Test
  BIG_CHAT_ID = -1_000_000_000_123_456_789 # 超 32 位有效位（§0.2.4）
  OTHER_CHAT_ID = -1_000_000_000_987_654_321
  TOPIC = 88
  OTHER_TOPIC = 99
  GENERAL_TOPIC = 1 # forum 的 General 话题（E4：归群级）

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @store = TenguDB::SessionLogs.new(@conn, logger: Logger.new(IO::NULL))
  end

  def teardown
    @conn.close
  end

  def s_start(chat_id: BIG_CHAT_ID, thread_id: nil, name: "第一团")
    @store.start(chat_id: chat_id, thread_id: thread_id, name: name)
  end

  def append(log, content: "hello", name: "Tester", user_id: 42, is_bot: 0, kind: "text")
    @store.append_entry(log_id: log.id, sender_name: name, user_id: user_id,
                        is_bot: is_bot, msg_kind: kind, content: content)
  end

  # =========================================================================
  # A. 状态机
  # =========================================================================

  def test_start_creates_a_recording_log
    result = s_start

    assert result.ok?, "全新作用域应能开录"
    log = result.log
    assert log.recording?
    assert_equal BIG_CHAT_ID, log.chat_id, "64 位 chat_id 不能被截断"
    assert_equal 0, log.thread_id, "未传 thread 时落群级行"
    assert_equal "第一团", log.name
    refute_empty log.created_at
    assert_nil log.ended_at, "刚开录没有结束时间"
    assert log.active?
  end

  def test_start_normalizes_thread_like_the_rest_of_the_schema
    # E4：nil / 0 / 1（General）都归群级；>1 才是话题级
    [nil, 0, GENERAL_TOPIC, -3].each_with_index do |raw, i|
      result = @store.start(chat_id: BIG_CHAT_ID + i + 10, thread_id: raw, name: "t")
      assert result.ok?, "thread=#{raw.inspect} 开录应成功"
      assert_equal 0, result.log.thread_id, "thread=#{raw.inspect} 应归一为群级 0"
    end

    topic = s_start(thread_id: TOPIC)
    assert_equal TOPIC, topic.log.thread_id

    general = s_start(thread_id: GENERAL_TOPIC, name: "general")
    assert_equal 0, general.log.thread_id, "General 话题=1 与群级 0 同一行"
  end

  def test_start_refuses_while_one_is_active
    first = s_start(name: "开场团").log
    second = s_start(name: "第二个")

    assert_equal TenguDB::LogResult::ALREADY_ACTIVE, second.status
    assert_equal first.id, second.log.id, "拒收时应带出那条进行中的"
    assert_equal 1, @conn.get_first_value("SELECT count(*) FROM session_logs WHERE chat_id = ?",
                                          [BIG_CHAT_ID]).to_i, "拒收不许再落一行"
  end

  def test_paused_log_still_blocks_new_start
    started = s_start.log
    @store.pause(chat_id: BIG_CHAT_ID)

    again = s_start(name: "插队")
    assert_equal TenguDB::LogResult::ALREADY_ACTIVE, again.status
    assert_equal started.id, again.log.id
  end

  def test_start_after_finish_opens_a_fresh_log
    first = s_start(name: "旧团").log
    @store.finish(chat_id: BIG_CHAT_ID)

    second = s_start(name: "新团")
    assert second.ok?
    assert_operator second.log.id, :>, first.id
    assert second.log.recording?
    assert @store.find(first.id).ended?, "旧的那条保持 ended 不动"
  end

  def test_start_rejects_bad_names
    ["", "   ", nil].each do |bad|
      result = s_start(name: bad)
      assert_equal TenguDB::LogResult::INVALID_NAME, result.status, "#{bad.inspect} 应拒"
    end

    too_long = "あ" * (TenguDB::SessionLogs::MAX_NAME_LENGTH + 1)
    assert_equal TenguDB::LogResult::INVALID_NAME, s_start(name: too_long).status

    with_control = "第一团\n第二行"
    assert_equal TenguDB::LogResult::INVALID_NAME, s_start(name: with_control).status

    ok_name = "あ" * TenguDB::SessionLogs::MAX_NAME_LENGTH
    ok_result = s_start(name: "  #{ok_name}  ")
    assert ok_result.ok?, "恰好上限、且两端空白被 strip 后应通过"
    assert_equal ok_name, ok_result.log.name, "名字应被 strip"
    assert_equal 1, @conn.get_first_value("SELECT count(*) FROM session_logs WHERE chat_id = ?",
                                          [BIG_CHAT_ID]).to_i, "被拒的名字一律不落库（只留通过的这条）"
  end

  def test_start_rejects_bad_chat_ids
    [nil, 0, "", "   "].each do |bad|
      result = @store.start(chat_id: bad, name: "x")
      assert_equal TenguDB::LogResult::INVALID_ARGUMENT, result.status, "#{bad.inspect} 应拒"
    end
  end

  def test_full_state_machine
    log = s_start.log

    paused = @store.pause(chat_id: BIG_CHAT_ID)
    assert paused.ok?
    assert paused.log.paused?
    assert_equal TenguDB::LogResult::ALREADY_PAUSED,
                 @store.pause(chat_id: BIG_CHAT_ID).status
    assert_equal TenguDB::LogResult::ALREADY_PAUSED,
                 @store.pause(chat_id: BIG_CHAT_ID, thread_id: GENERAL_TOPIC).status,
                 "General=1 归一到同一行——群级暂停对 General 视角也可见"

    resumed = @store.resume(chat_id: BIG_CHAT_ID)
    assert resumed.ok?
    assert resumed.log.recording?
    assert_equal TenguDB::LogResult::ALREADY_RECORDING,
                 @store.resume(chat_id: BIG_CHAT_ID).status

    finished = @store.finish(chat_id: BIG_CHAT_ID)
    assert finished.ok?
    assert finished.log.ended?
    refute_nil finished.log.ended_at, "finish 必须写 ended_at"
    refute finished.log.active?

    assert_equal TenguDB::LogResult::NO_ACTIVE, @store.finish(chat_id: BIG_CHAT_ID).status
    assert_equal TenguDB::LogResult::NO_ACTIVE, @store.pause(chat_id: BIG_CHAT_ID).status
    assert_equal TenguDB::LogResult::NO_ACTIVE, @store.resume(chat_id: BIG_CHAT_ID).status
    assert_equal log.id, finished.log.id
  end

  def test_finish_works_directly_from_paused
    s_start
    @store.pause(chat_id: BIG_CHAT_ID)

    result = @store.finish(chat_id: BIG_CHAT_ID)
    assert result.ok?, "暂停中也能直接收工（不要求先 on 再 end）"
    assert result.log.ended?
  end

  def test_transitions_outside_any_log_report_no_active
    [%i[pause], %i[resume], %i[finish]].each do |(op)|
      result = @store.public_send(op, chat_id: BIG_CHAT_ID)
      assert_equal TenguDB::LogResult::NO_ACTIVE, result.status, "#{op} 空作用域应 no_active"
      assert_nil result.log
    end
  end

  def test_scope_isolation_between_topics_and_chats
    group_log = s_start(name: "群级").log
    topic_log = s_start(thread_id: TOPIC, name: "话题").log
    other_topic = s_start(thread_id: OTHER_TOPIC, name: "另一话题").log
    other_chat = s_start(chat_id: OTHER_CHAT_ID, name: "别的群").log

    assert_equal topic_log.id, @store.active(chat_id: BIG_CHAT_ID, thread_id: TOPIC).id
    assert_equal other_topic.id, @store.active(chat_id: BIG_CHAT_ID, thread_id: OTHER_TOPIC).id
    assert_equal group_log.id, @store.active(chat_id: BIG_CHAT_ID).id
    assert_equal other_chat.id, @store.active(chat_id: OTHER_CHAT_ID).id

    @store.finish(chat_id: BIG_CHAT_ID, thread_id: TOPIC)
    assert_nil @store.active(chat_id: BIG_CHAT_ID, thread_id: TOPIC)
    assert @store.active(chat_id: BIG_CHAT_ID).recording?, "收话题的工不影响群级那条"
  end

  def test_recording_for_only_returns_recording_state
    log = s_start.log
    assert_equal log.id, @store.recording_for(chat_id: BIG_CHAT_ID).id

    @store.pause(chat_id: BIG_CHAT_ID)
    assert_nil @store.recording_for(chat_id: BIG_CHAT_ID), "paused 不算「正在录」"
    refute_nil @store.active(chat_id: BIG_CHAT_ID), "但仍是进行中（active）"

    @store.resume(chat_id: BIG_CHAT_ID)
    assert_equal log.id, @store.recording_for(chat_id: BIG_CHAT_ID).id
  end

  # =========================================================================
  # B. 条目
  # =========================================================================

  def test_append_assigns_sequential_seq_within_a_log
    log = s_start.log
    a = append(log, content: "one")
    b = append(log, content: "two")
    c = append(log, content: "three", is_bot: 1, user_id: nil, name: "骰子bot")

    assert_equal [1, 2, 3], [a.seq, b.seq, c.seq]
    assert_equal %w[one two three], @store.entries(log.id).map(&:content)
    assert_equal 3, @store.count_entries(log.id)
  end

  def test_seq_is_per_log_not_global
    first = s_start(name: "甲").log
    second = s_start(thread_id: TOPIC, name: "乙").log

    append(first, content: "a1")
    append(second, content: "b1")
    append(first, content: "a2")

    assert_equal [1, 2], @store.entries(first.id).map(&:seq)
    assert_equal [1], @store.entries(second.id).map(&:seq)
  end

  def test_entry_fields_round_trip
    log = s_start.log
    entry = append(log, content: "サツバツ！", name: "山田", user_id: 42, is_bot: 0)

    refute_nil entry.id
    assert_equal log.id, entry.log_id
    assert_equal "山田", entry.sender_name
    assert_equal 42, entry.user_id
    refute entry.bot?
    assert_equal "text", entry.msg_kind
    refute_empty entry.created_at

    bot_entry = append(log, content: "结果：6", name: "骰子bot", user_id: nil,
                            is_bot: 1, kind: "text")
    assert bot_entry.bot?, "is_bot=1 → bot?"
    assert_nil bot_entry.user_id, "bot 条目 user_id 为 NULL（schema 注释）"

    placeholder = append(log, content: "（照片）", kind: "photo")
    assert_equal "photo", placeholder.msg_kind, "非文本的 msg_kind 记种类"
  end

  def test_entry_content_is_bound_not_interpolated
    log = s_start.log
    nasty = %q{'; DROP TABLE log_entries; --}
    entry = append(log, content: nasty)

    assert_equal nasty, entry.content
    assert @conn.table_exists?("log_entries"), "值必须绑定，不得拼进 SQL"
  end

  def test_multiline_content_survives
    log = s_start.log
    text = "第一行\n第二行\n\n第四行"
    append(log, content: text)

    assert_equal text, @store.entries(log.id).first.content
  end

  def test_append_to_unknown_log_raises_via_foreign_key
    # PRAGMA foreign_keys=ON 的实证（§15.5 E10）：孤儿行不该能进
    ghost = TenguDB::SessionLog.new(id: 999_999, chat_id: BIG_CHAT_ID,
                                    thread_id: 0, name: "ghost", status: "recording")
    assert_raises(SQLite3::ConstraintException) { append(ghost, content: "orphan") }
    assert_equal 0, @conn.get_first_value("SELECT count(*) FROM log_entries").to_i
  end

  def test_entries_empty_log
    log = s_start.log
    assert_equal [], @store.entries(log.id)
    assert_equal 0, @store.count_entries(log.id)
  end

  # =========================================================================
  # C. list
  # =========================================================================

  def test_list_newest_first_with_entry_counts
    first = s_start(name: "一").log
    append(first)
    append(first, content: "x")
    @store.finish(chat_id: BIG_CHAT_ID)

    second = s_start(name: "二").log
    @store.finish(chat_id: BIG_CHAT_ID)

    third = s_start(name: "三").log
    append(third)

    rows = @store.list(chat_id: BIG_CHAT_ID)

    assert_equal [third.id, second.id, first.id], rows.map(&:id), "最新在前"
    assert_equal [1, 0, 2], rows.map(&:entry_count), "每条的条目数"
    assert rows.first.recording?
    assert rows.last.ended?
  end

  def test_list_is_scope_scoped_and_supports_limit
    s_start(name: "群级")
    s_start(thread_id: TOPIC, name: "话题甲")
    s_start(thread_id: OTHER_TOPIC, name: "话题乙")

    assert_equal ["群级"], @store.list(chat_id: BIG_CHAT_ID).map(&:name)
    assert_equal ["话题甲"], @store.list(chat_id: BIG_CHAT_ID, thread_id: TOPIC).map(&:name)
    assert_equal ["话题乙"], @store.list(chat_id: BIG_CHAT_ID, thread_id: OTHER_TOPIC).map(&:name)
    assert_empty @store.list(chat_id: OTHER_CHAT_ID)

    # limit：只取最新 N 条
    @store.finish(chat_id: BIG_CHAT_ID)
    s_start(name: "第二个")
    @store.finish(chat_id: BIG_CHAT_ID)
    s_start(name: "第三个")
    assert_equal 2, @store.list(chat_id: BIG_CHAT_ID, limit: 2).size
    assert_equal ["第三个", "第二个"], @store.list(chat_id: BIG_CHAT_ID, limit: 2).map(&:name)
  end

  def test_find_returns_nil_for_unknown_id
    assert_nil @store.find(12_345)
  end

  # =========================================================================
  # D. 群升级 re-key 联动
  # =========================================================================

  def test_session_logs_is_registered_in_migration_tables
    assert_includes TelegramBot::Migration::TABLES, "session_logs",
                    "含 chat_id 的表必须在 Migration::TABLES 内（群升级不丢录制）"
  end

  def test_rekey_moves_the_recording_and_entries_stay_attached
    old_chat = -1_234_567_890
    new_chat = -1_009_876_543_210
    log = @store.start(chat_id: old_chat, thread_id: TOPIC, name: "升级前").log
    append(log, content: "升级前的发言")

    migration = TelegramBot::Migration.new(connection: @conn, logger: Logger.new(IO::NULL))
    migration.handle(chat_id: old_chat, migrate_to: new_chat)

    assert_nil @store.active(chat_id: old_chat, thread_id: TOPIC), "旧 id 下不再有录制"
    moved = @store.active(chat_id: new_chat, thread_id: TOPIC)
    refute_nil moved, "录制行应改挂新 chat_id"
    assert_equal log.id, moved.id
    assert_equal new_chat, moved.chat_id
    assert moved.recording?, "进行中的状态原样保留"

    entries = @store.entries(log.id)
    assert_equal ["升级前的发言"], entries.map(&:content), "条目靠 log_id 挂着，不受 re-key 影响"

    # 录制可以继续，seq 接着涨
    append(moved, content: "升级后的发言")
    assert_equal [1, 2], @store.entries(log.id).map(&:seq)
  end
end
