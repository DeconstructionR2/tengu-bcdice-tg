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

# ============================================================================
# aux_enabled（T2.6）：辅助轨开关，按群一份，不分话题
#
# 计划 §6 口径「每群 /settings 可关辅助轨」—— 与 game_system 的三级查找
# **刻意不同**：规则系统可以话题级，开关只走群级行（db/settings.rb 头部
# 「aux_enabled 只走群级行」一节有完整理由）。
# ============================================================================
class TestSettingsAuxEnabled < Minitest::Test
  CHAT_ID = -1_000_000_000_123_456_789
  OTHER_CHAT = -1_000_000_000_999_999_999
  TOPIC = 88
  ANOTHER_TOPIC = 99
  NS1EX = "NinjaSlayerEx"

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @settings = TenguDB::Settings.new(@conn)
  end

  def teardown
    @conn.close
  end

  # --- 默认值 -------------------------------------------------------------

  def test_default_is_enabled_when_no_row_exists
    assert TenguDB::Settings::DEFAULT_AUX_ENABLED
    assert @settings.aux_enabled(CHAT_ID),
           "没有任何行时默认开（辅助轨默认开着，少一个动作就少一次抢话风险）"
  end

  def test_default_matches_schema_column_default
    # 常量与列默认值必须同，否则「库里有行 vs 没有行」两种群默认行为不一致
    row = @conn.get_first_hash(
      "SELECT dflt_value FROM pragma_table_info('chat_settings') WHERE name = 'aux_enabled'"
    )
    assert_equal "1", row["dflt_value"].to_s
    assert_equal true, TenguDB::Settings::DEFAULT_AUX_ENABLED
  end

  # --- 读写往返 -----------------------------------------------------------

  def test_write_and_read_round_trip
    # 未设置过的群默认**开**（DEFAULT_AUX_ENABLED），所以从「开」翻到「关」，
    # 再翻回「开」——两条边界都覆盖到。
    assert @settings.aux_enabled(CHAT_ID), "起点应是默认开"

    assert_equal false, @settings.set_aux_enabled(CHAT_ID, enabled: false)
    refute @settings.aux_enabled(CHAT_ID)

    assert_equal true, @settings.set_aux_enabled(CHAT_ID, enabled: true)
    assert @settings.aux_enabled(CHAT_ID)
  end

  def test_set_accepts_several_truthy_falsy_shapes
    [true, 1, "1"].each do |v|
      @settings.set_aux_enabled(CHAT_ID, enabled: v)
      assert @settings.aux_enabled(CHAT_ID), "入参 #{v.inspect} 应判为开"
    end

    [false, 0, "0"].each do |v|
      @settings.set_aux_enabled(CHAT_ID, enabled: v)
      refute @settings.aux_enabled(CHAT_ID), "入参 #{v.inspect} 应判为关"
    end
  end

  def test_returns_boolean_not_integer
    # 存储是整数 0/1，但对外必须是布尔——handler 的分支与 router 的
    # `? true : false` 都依赖这个契约
    assert_equal false, @settings.set_aux_enabled(CHAT_ID, enabled: 0)
    assert_equal true, @settings.set_aux_enabled(CHAT_ID, enabled: 1)
  end

  # --- 只走群级（不分话题）------------------------------------------------

  def test_written_in_topic_lands_on_group_row
    @settings.set_aux_enabled(CHAT_ID, enabled: false, thread_id: TOPIC)

    rows = @settings.entries_for_chat(CHAT_ID)
    assert_equal 1, rows.size, "只该写一行（群级）"
    assert_equal 0, rows.first["thread_id"].to_i
    refute @settings.aux_enabled(CHAT_ID, thread_id: TOPIC),
           "话题内也要读到群级的那份（每群一份）"
  end

  def test_topic_rows_do_not_override_group_value
    # 手工往话题行灌一个 0（模拟历史数据/手改 DB）：**不应**影响生效值
    @settings.set_aux_enabled(CHAT_ID, enabled: true)
    @conn.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, aux_enabled) VALUES (?, ?, 0)",
      [CHAT_ID, TOPIC]
    )

    assert @settings.aux_enabled(CHAT_ID, thread_id: TOPIC),
           "话题行的值一律不读（每群一份，话题级开关是刻意不做的）"
  end

  def test_general_topic_reads_group_value
    # E4：forum General 话题（thread_id=1）
    @settings.set_aux_enabled(CHAT_ID, enabled: false)

    refute @settings.aux_enabled(CHAT_ID, thread_id: 1),
           "General 话题应看到群级开关"
  end

  # --- 与 game_system 共存（互不覆盖）--------------------------------------

  def test_aux_write_does_not_clobber_game_system
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)
    @settings.set_aux_enabled(CHAT_ID, enabled: false)

    assert_equal NS1EX, @settings.game_system(CHAT_ID),
                 "改辅助轨不该把规则系统带回列默认值"
    row = @settings.fetch_row(CHAT_ID, 0)
    assert_equal NS1EX, row["game_system"]
    assert_equal 0, row["aux_enabled"].to_i
  end

  def test_game_system_write_does_not_reopen_aux
    @settings.set_aux_enabled(CHAT_ID, enabled: false)
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    refute @settings.aux_enabled(CHAT_ID),
           "改规则系统不该顺手把辅助轨打开（两个开关各自 DO UPDATE 自己那列）"
  end

  def test_both_writes_coexist_on_one_row
    @settings.set_aux_enabled(CHAT_ID, enabled: false)
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    rows = @settings.entries_for_chat(CHAT_ID)
    assert_equal 1, rows.size, "两个开关应共用群级那一行（UPSERT，不新增行）"
    assert_equal NS1EX, rows.first["game_system"]
    assert_equal 0, rows.first["aux_enabled"].to_i
  end

  # --- 隔离与删除 ---------------------------------------------------------

  def test_switch_is_isolated_per_chat
    @settings.set_aux_enabled(CHAT_ID, enabled: false)

    assert @settings.aux_enabled(OTHER_CHAT), "A 群关掉不该影响 B 群"
  end

  def test_deleting_group_row_restores_default
    @settings.set_aux_enabled(CHAT_ID, enabled: false)
    assert @settings.delete(CHAT_ID, thread_id: 0)

    assert @settings.aux_enabled(CHAT_ID),
           "行被删后应回默认（开）——删行是 /settings 复位的语义"
  end

  def test_roundtrip_with_64bit_chat_id
    @settings.set_aux_enabled(CHAT_ID, enabled: false)

    row = @settings.fetch_row(CHAT_ID, 0)
    assert_equal CHAT_ID, row["chat_id"].to_i, "64 位 chat_id 往返不丢精度"
    assert_equal 0, row["aux_enabled"].to_i
  end

  def test_entries_expose_aux_column
    @settings.set_aux_enabled(CHAT_ID, enabled: false)

    entry = @settings.entries_for_chat(CHAT_ID).first
    assert entry.key?("aux_enabled"), "entries_for_chat 供 /settings 展示，应含该列"
    assert_equal 0, entry["aux_enabled"].to_i
  end

  def test_write_rolls_back_inside_transaction
    @conn.transaction(:immediate) do
      @settings.set_aux_enabled(CHAT_ID, enabled: false)
      raise "boom"
    end
    nil
  rescue RuntimeError
    assert @settings.aux_enabled(CHAT_ID), "事务回滚后开关不该残留"
    assert_empty @settings.entries_for_chat(CHAT_ID)
  end
end