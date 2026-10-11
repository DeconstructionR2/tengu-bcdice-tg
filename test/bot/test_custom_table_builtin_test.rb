# frozen_string_literal: true

# ============================================================================
# test/bot/test_custom_table_builtin_test.rb — 内置表桥 BuiltinTables（T3.4）
#
# 验「读引擎侧 i18n 的天狗内置表 → resolve_table 可注入内置源」这座桥：
#   - 表名集合（23 张 = ledger 已映射计数；SPIKE_DUMMY 是 spike 占位，已排除）
#   - 每张表的读取面：骰型（yml type = 默认骰型 a）、data 键偏移
#     （1d6→1、2d6→2）、items 逐字
#   - 与 handler 的集成：创建/发布时的内置撞名拦截、/ct roll 的内置级命中
#     （**真桥 + 真 i18n**，非注入假身）
#
# 本文件需要引擎 bootstrap（i18n load_path 注入）；它不联网、不读 .env。
# ============================================================================

require "minitest/autorun"
require "logger"
require_relative "test_helper"
require_relative "../../bot/handlers/custom_table"
require_relative "../../db/connection"
require_relative "../randomizer_mock"
require_relative "../../lib/engine_bootstrap"

EngineBootstrap.bootstrap!

class TestCustomTableBuiltin < Minitest::Test
  CHAT_ID = -1_000_000_000_123_456_789
  AUTHOR = 42
  Bridge = TelegramBot::Handlers::BuiltinTables

  # ledger 的 23 张已映射表（i18n_key_ledger.yml counts.已映射: 23）
  EXPECTED_KEYS = %w[
    nsrs krs krz kra kro kry nji njs njn njk njc njb sbx wsx
    ws jitsb dkki krm cyber biocyber soul summon bk
  ].freeze

  def setup
    Bridge.reset!
    @conn = TenguDB::Connection.open(path: ":memory:")
    @ct = TenguDB::CustomTables.new(@conn)
    @handler = TelegramBot::Handlers::CustomTableHandler.new(
      custom_tables: @ct, admin: nil, logger: Logger.new(IO::NULL)
    ) # builtin 缺省 = 真桥
  end

  def teardown
    @conn.close
    Bridge.reset!
  end

  def call(args, user_id: AUTHOR)
    @handler.call(name: "ct", args: args, chat_id: CHAT_ID,
                  user_id: user_id, chat_type: "supergroup", kind: :slash)
  end

  # --- 桥本体 ---------------------------------------------------------------

  def test_map_covers_the_expected_engine_tables
    map = Bridge.map

    assert_equal 23, map.size, "= ledger 的已映射计数（SPIKE_DUMMY 已排除）"
    assert_equal EXPECTED_KEYS.sort, map.keys.sort
    refute map.key?("spike_dummy"), "spike 占位表不是内置表"
  end

  def test_entries_expose_dice_and_items_like_the_engine
    sbx = Bridge.map["sbx"]

    assert_equal({ "a" => "1d6" }, sbx.dice, "yml type 即默认骰型 a（小写化）")
    assert_equal 6, sbx.data.size
    assert_equal "1d6", sbx.dice_string("a")
    assert_includes sbx.name, "サツバツ"
    # items 逐字（与 i18n 同源；这里只验非空与前缀，逐字保真由引擎层测试守）
    refute_empty sbx.data_entry(1).to_s

    nsrs = Bridge.map["nsrs"]
    assert_equal "1d3", nsrs.dice_string("a")
    assert_equal 7, nsrs.data.size, "NSRS data[1..7]（ledger min/max_index 1..7）"
  end

  def test_data_key_offset_follows_the_default_dice_minimum
    # 1d6 → 键从 1 起
    assert_equal %w[1 2 3 4 5 6], Bridge.map["sbx"].data.keys
    # 1d36 → 键 1..36
    assert_equal 36, Bridge.map["njk"].data.size
    assert Bridge.map["njk"].data.key?("36")
    # 2d6 → 键从 **2** 起（CYBER/SUMMON 是 11 条 2..12，母本 data[合計値]）
    cyber = Bridge.map["cyber"]
    assert_equal %w[2 3 4 5 6 7 8 9 10 11 12], cyber.data.keys
    assert_equal 11, cyber.data.size
    assert Bridge.map["summon"].data.key?("12")
    refute Bridge.map["summon"].data.key?("1"), "2d6 的最小出目是 2，不存在 data[1]"
  end

  def test_table_datarange_is_unbounded_in_this_bridge
    # 内置表在 /ct roll 路径不携带钳制（多骰型/`+x` 走引擎命令）
    assert Bridge.map["krs"].datarange.unbounded?
    refute Bridge.map["krs"].datarange.is_use
  end

  def test_source_is_a_callable_over_the_same_map
    source = Bridge.source

    assert_same Bridge.map["sbx"], source.call("sbx")
    assert_same Bridge.map["krz"], source.call("KRZ"), "source 也要兜底 downcase"
    assert_nil source.call("no_such_table")
  end

  def test_source_drives_resolve_table_lookup_order
    resolution = @ct.resolve_table(name: "SBX", chat_id: CHAT_ID, builtin: Bridge.source)

    assert resolution.builtin?, "查找顺序第一级命中内置（SearchTableDiceroll.js:13-24）"
    assert_nil resolution.table
    # 大小写折叠（母本 tableName.toLowerCase()）
    assert @ct.resolve_table(name: "sbx", chat_id: CHAT_ID, builtin: Bridge.source).builtin?
  end

  # --- 与 handler 的集成（真桥）---------------------------------------------

  def test_create_rejects_real_builtin_names
    ["SBX", "sbx", "NSRS", "KRS", "Cyber"].each do |name|
      out = call("create #{name}")

      assert_includes out, "不能用与内置表相同的名称", "#{name} 必须被真桥拦下"
      assert_nil @ct.fetch(chat_id: CHAT_ID, name: name)
    end
  end

  def test_publish_rejects_real_builtin_names
    # 直灌模拟历史数据（create 会拦）
    @ct.create_table(chat_id: CHAT_ID, name: "KRS", author_id: AUTHOR)
    (1..12).each do |i|
      @ct.update_data(chat_id: CHAT_ID, name: "KRS", data_index: i, data_string: "值#{i}")
    end

    out = call("publish KRS")

    assert_includes out, "不能用与内置表相同的名称"
    refute_nil @ct.fetch(chat_id: CHAT_ID, name: "KRS"), "被拦时原表不动"
  end

  def test_roll_hits_the_real_builtin_table
    # SBX 是 1d6 表；固定骰序取 [3,6] → 出目 3
    handler = TelegramBot::Handlers::CustomTableHandler.new(
      custom_tables: @ct, admin: nil,
      randomizer: RandomizerMock.new([[3, 6]]), logger: Logger.new(IO::NULL)
    )
    out = handler.call(name: "ct", args: "roll sbx", chat_id: CHAT_ID,
                       user_id: AUTHOR, chat_type: "supergroup", kind: :slash)

    assert_includes out, "内置表「sbx」(a)：1d6 ＞ 3"
    assert_includes out, Bridge.map["sbx"].data_entry(3),
                    "结果的文本必须与 i18n items[2] 一致"
  end

  def test_show_hints_for_builtin_names_through_the_real_bridge
    out = call("show NSRS")

    assert_includes out, "是内置表"
  end

  def test_non_builtin_names_fall_through_to_the_private_level
    call("create 普通表")
    (1..6).each { |i| @ct.update_data(chat_id: CHAT_ID, name: "普通表", data_index: i, data_string: "结果#{i}") }
    handler = TelegramBot::Handlers::CustomTableHandler.new(
      custom_tables: @ct, admin: nil,
      randomizer: RandomizerMock.new([[1, 6]]), logger: Logger.new(IO::NULL)
    )

    out = handler.call(name: "ct", args: "roll 普通表", chat_id: CHAT_ID,
                       user_id: AUTHOR, chat_type: "supergroup", kind: :slash)

    assert_includes out, "本群表「普通表」(a)：1d6 ＞ 1", "非内置名沿查找顺序落到 DB 级"
    assert_includes out, "结果1"
  end
end
