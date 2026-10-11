# frozen_string_literal: true

# ============================================================================
# test/db/test_settings_test.rb — chat_settings 三级查找（T2.4）
#
# 覆盖计划 §3 决6 / §13 第 5 项 / §15.3 E4：
#   - 三级查找顺序逐层：话题 → 群 → 全局默认 NinjaSlayer2Ex
#   - E4：thread_id ∈ {0, 1} 都归群级作用域（forum General 话题恒为 1，
#     故「话题外打 = 群默认」在 forum 里必须映射到 General）
#   - 话题覆盖群默认；群默认覆盖全局；两者都不覆盖回全局默认
#   - 写读往返（UPSERT 不产生第二行；updated_at 刷新）
#   - 64 位 chat_id
#   - 删除回落
#
# 全程 :memory: 库，零文件副作用。
# ============================================================================

require "minitest/autorun"
require_relative "../../db/settings"

class TestSettings < Minitest::Test
  CHAT_ID = -1_000_000_000_123_456_789 # 超 32 位（§0.2.4）
  OTHER_CHAT = -1_000_000_000_999_999_999
  TOPIC = 88
  ANOTHER_TOPIC = 99

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @settings = TenguDB::Settings.new(@conn)
  end

  def teardown
    @conn.close
  end

  # --- 作用域归一（E4）-----------------------------------------------------

  def test_normalize_thread_id_treats_zero_one_and_nil_as_group
    assert_equal 0, TenguDB::Settings.normalize_thread_id(nil)
    assert_equal 0, TenguDB::Settings.normalize_thread_id(0)
    assert_equal 0, TenguDB::Settings.normalize_thread_id(1),
                 "forum General 话题(thread_id=1)应归群级（E4）"
    assert_equal 0, TenguDB::Settings.normalize_thread_id(-3),
                 "非法负值也应归群级而非落库"
  end

  def test_normalize_thread_id_keeps_real_topics
    assert_equal 88, TenguDB::Settings.normalize_thread_id(88)
    assert_equal 2, TenguDB::Settings.normalize_thread_id(2)
  end

  def test_topic_scope_predicate
    refute TenguDB::Settings.topic_scope?(nil)
    refute TenguDB::Settings.topic_scope?(0)
    refute TenguDB::Settings.topic_scope?(1), "General 不是话题级"
    assert TenguDB::Settings.topic_scope?(2)
    assert TenguDB::Settings.topic_scope?(TOPIC)
  end

  # --- 三级查找 ------------------------------------------------------------

  def test_resolve_falls_back_to_global_default
    r = @settings.resolve(CHAT_ID)

    assert_equal TenguDB::Settings::DEFAULT_GAME_SYSTEM, r.game_system
    assert_equal TenguDB::Scope::DEFAULT, r.scope
    assert_equal "默认", r.scope_label
    assert_equal "NinjaSlayer2Ex", r.game_system, "全局默认即 §4.1 的列默认值"
  end

  def test_group_setting_overrides_global_default
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: "NinjaSlayerEx")

    r = @settings.resolve(CHAT_ID)
    assert_equal "NinjaSlayerEx", r.game_system
    assert_equal TenguDB::Scope::GROUP, r.scope
    assert_equal "本群", r.scope_label
  end

  def test_topic_setting_overrides_group_default
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: "NinjaSlayerEx")
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "NinjaSlayer2Ex")

    in_topic = @settings.resolve(CHAT_ID, thread_id: TOPIC)
    assert_equal "NinjaSlayer2Ex", in_topic.game_system
    assert_equal TenguDB::Scope::THREAD, in_topic.scope
    assert_equal "本话题", in_topic.scope_label
    assert_equal TOPIC, in_topic.thread_id

    outside = @settings.resolve(CHAT_ID)
    assert_equal "NinjaSlayerEx", outside.game_system, "群级不该被话题设置污染"
    assert_equal TenguDB::Scope::GROUP, outside.scope
  end

  def test_topic_without_group_setting_falls_back_to_global_default
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "NinjaSlayerEx")

    r = @settings.resolve(CHAT_ID, thread_id: TOPIC)
    assert_equal TenguDB::Scope::THREAD, r.scope

    other = @settings.resolve(CHAT_ID) # 群级没设置
    assert_equal TenguDB::Scope::DEFAULT, other.scope
    assert_equal "NinjaSlayer2Ex", other.game_system
  end

  def test_one_topic_does_not_leak_into_another_topic
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "NinjaSlayerEx")

    r = @settings.resolve(CHAT_ID, thread_id: ANOTHER_TOPIC)
    assert_equal TenguDB::Scope::DEFAULT, r.scope, "别的未被设置的话题不得命中别的设置"
    assert_equal "NinjaSlayer2Ex", r.game_system
  end

  # --- E4：General 话题读写对称 -------------------------------------------

  def test_general_topic_reads_group_setting
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: "NinjaSlayerEx")

    r = @settings.resolve(CHAT_ID, thread_id: 1) # forum General
    assert_equal "NinjaSlayerEx", r.game_system
    assert_equal TenguDB::Scope::GROUP, r.scope, "General 话题解析出的应是群级"
    assert_equal "本群", r.scope_label
  end

  def test_writing_in_general_topic_writes_group_row
    stored = @settings.set_game_system(CHAT_ID, thread_id: 1, game_system: "ShinobiGami")

    assert_equal 0, stored, "General 话题的写入应落到群级行（E4）"
    row = @settings.fetch_row(CHAT_ID, 1)
    refute_nil row, "归一后应能按 thread_id=1 读回同一行"
    assert_equal "ShinobiGami", row["game_system"]

    rows = @settings.entries_for_chat(CHAT_ID)
    assert_equal 1, rows.size, "不该为 General 话题多写一行"
  end

  def test_general_topic_write_visible_outside
    @settings.set_game_system(CHAT_ID, thread_id: 1, game_system: "ShinobiGami")

    assert_equal "ShinobiGami", @settings.game_system(CHAT_ID, thread_id: nil),
                 "General 里改的群默认，群外也该看得到"
    assert_equal "ShinobiGami", @settings.game_system(CHAT_ID, thread_id: 0)
  end

  def test_other_topic_write_not_visible_in_general
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "NinjaSlayerEx")

    assert_equal "NinjaSlayer2Ex", @settings.game_system(CHAT_ID, thread_id: 1),
                 "话题级设置不得外溢到 General/群级"
  end

  # --- 写路径与 UPSERT -----------------------------------------------------

  def test_set_returns_stored_thread_id
    assert_equal 0, @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: "ShinobiGami")
    assert_equal 0, @settings.set_game_system(CHAT_ID, thread_id: nil, game_system: "ShinobiGami")
    assert_equal 0, @settings.set_game_system(CHAT_ID, thread_id: 1, game_system: "ShinobiGami")
    assert_equal TOPIC, @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "ShinobiGami")
  end

  def test_upsert_does_not_duplicate_rows
    3.times { @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "ShinobiGami") }
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "NinjaSlayerEx")

    rows = @settings.entries_for_chat(CHAT_ID)
    assert_equal 1, rows.size, "UPSERT 后应只有一行"
    assert_equal "NinjaSlayerEx", rows.first["game_system"], "后写覆盖先写"
  end

  def test_roundtrip_with_64bit_chat_id
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "NinjaSlayerEx")

    row = @settings.fetch_row(CHAT_ID, TOPIC)
    assert_equal CHAT_ID, row["chat_id"].to_i, "64 位 chat_id 往返不丢精度"
    assert_equal TOPIC, row["thread_id"].to_i
    assert_equal "NinjaSlayerEx", row["game_system"]
    refute_nil row["updated_at"]
  end

  def test_settings_are_isolated_per_chat
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: "NinjaSlayerEx")

    assert_equal "NinjaSlayer2Ex", @settings.game_system(OTHER_CHAT, thread_id: 0),
                 "A 群的设置不得泄漏到 B 群"
    assert_empty @settings.entries_for_chat(OTHER_CHAT), "B 群不应有任何设置行"
  end

  def test_fetch_row_returns_nil_when_absent
    assert_nil @settings.fetch_row(CHAT_ID, TOPIC)
  end

  # --- 删除 ----------------------------------------------------------------

  def test_delete_removes_row_and_falls_back
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "NinjaSlayerEx")

    assert @settings.delete(CHAT_ID, thread_id: TOPIC)
    assert_nil @settings.fetch_row(CHAT_ID, TOPIC)
    assert_equal TenguDB::Scope::DEFAULT, @settings.resolve(CHAT_ID, thread_id: TOPIC).scope
    refute @settings.delete(CHAT_ID, thread_id: TOPIC), "删不存在的行应报 false"
  end

  # --- 注入面 / 事务 --------------------------------------------------------

  def test_settings_uses_injected_connection
    other = TenguDB::Settings.new(@conn)
    other.set_game_system(CHAT_ID, thread_id: 0, game_system: "ShinobiGami")

    assert_equal "ShinobiGami", @settings.game_system(CHAT_ID),
                 "两个 Settings 实例共用同一注入连接时数据一致"
  end

  def test_write_inside_transaction_rolls_back
    @conn.transaction(:immediate) do
      @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "NinjaSlayerEx")
      raise "boom"
    end
    nil
  rescue RuntimeError
    assert_nil @settings.fetch_row(CHAT_ID, TOPIC), "事务回滚后设置不应残留"
  end
end