# frozen_string_literal: true

# ============================================================================
# test/bot/test_custom_table_roll_test.rb — /ct roll 掷自定义表（T3.4）
#
# 覆盖母本两段（命令层判定归 T3.4）：
#   classes/SearchTableDiceroll.js:13-24  查找顺序 default→private→public
#   classes/SearchTableDiceroll.js:55-77  `+x` 可変数解析（floor/负数/非数字忽略）
#   tengu_dice/NJDiscordReply.js:91-95    datarange 钳制（取端点）
#
# 钳制的语义与验收词「超钳报错」的落点：天狗是**静默**取端点，本项目按 T1.4
# 「钳制发生时明示」约定输出标注（绝不静默）——见 docs/t3.4-report.md §4 决策 3。
#
# 随机源注入固定骰序（test/randomizer_mock.rb），零真实随机、零联网。
# ============================================================================

require "minitest/autorun"
require "logger"
require_relative "test_helper"
require_relative "../../bot/handlers/custom_table"
require_relative "../../db/connection"
require_relative "../randomizer_mock"

class TestCustomTableRoll < Minitest::Test
  CHAT_ID = -1_000_000_000_123_456_789
  AUTHOR = 42
  STRANGER = 99

  FakeBuiltinTable = Struct.new(:dice, :data) do
    def dice_string(k) = dice[k.to_s]
    def data_entry(i) = data[i.to_s]
    def datarange = TenguDB::DataRange.unbounded
  end

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @ct = TenguDB::CustomTables.new(@conn)
    @builtin = { "sbx" => FakeBuiltinTable.new({ "a" => "1d6" }, { "1" => "内置一" }) }
  end

  def teardown
    @conn.close
  end

  # 固定骰序实例：rands 形如 [[骰面, 期望面数], ...]（RandomizerMock 语义）
  def handler(rands: [], builtin: :default)
    TelegramBot::Handlers::CustomTableHandler.new(
      custom_tables: @ct,
      admin: nil,
      builtin: builtin == :default ? @builtin : builtin,
      randomizer: rands.empty? ? nil : RandomizerMock.new(rands),
      logger: Logger.new(IO::NULL)
    )
  end

  def roll(args, rands: [], builtin: :default, user_id: STRANGER)
    handler(rands: rands, builtin: builtin).call(
      name: "ct", args: "roll #{args}", chat_id: CHAT_ID,
      user_id: user_id, chat_type: "supergroup", kind: :slash
    )
  end

  def test_randomizer_factory_produces_a_fresh_instance_per_roll
    # kimi T3.4 评审提案 #5：callable randomizer 是**工厂**——每次掷骰取新实例
    # （BCDice::Randomizer 会累积 rand_results，长驻进程共享一个会撞上限）
    made = []
    factory = -> { r = RandomizerMock.new([[3, 6]]); made << r; r }
    h = TelegramBot::Handlers::CustomTableHandler.new(
      custom_tables: @ct, admin: nil, builtin: @builtin,
      randomizer: factory, logger: Logger.new(IO::NULL)
    )

    2.times do
      h.call(name: "ct", args: "roll sbx", chat_id: CHAT_ID,
             user_id: STRANGER, chat_type: "supergroup", kind: :slash)
    end

    assert_equal 2, made.size, "每次掷骰都必须向工厂取新实例"
  end

  # 建一张 1d6 表并填 1..6
  def seed_six(name = "六表", dice_name: "a", expr: "1d6")
    @ct.create_table(chat_id: CHAT_ID, name: name, author_id: AUTHOR)
    @ct.update_dice(chat_id: CHAT_ID, name: name, dice_name: dice_name, dice_string: expr) if expr != "1d6"
    (1..6).each { |i| @ct.update_data(chat_id: CHAT_ID, name: name, data_index: i, data_string: "结果#{i}") }
    name
  end

  # --- 基本掷表 -------------------------------------------------------------

  def test_roll_defaults_to_shortcut_a
    seed_six
    out = roll("六表", rands: [[3, 6]])

    assert_equal "本群表「六表」(a)：1d6 ＞ 3\n结果3", out
  end

  def test_roll_with_explicit_shortcut_is_downcased
    @ct.create_table(chat_id: CHAT_ID, name: "多骰表", author_id: AUTHOR)
    @ct.update_dice(chat_id: CHAT_ID, name: "多骰表", dice_name: "b", dice_string: "2d6")
    @ct.update_data(chat_id: CHAT_ID, name: "多骰表", data_index: 7, data_string: "七")

    out = roll("多骰表 B", rands: [[3, 6], [4, 6]])

    assert_includes out, "本群表「多骰表」(b)：2d6 ＞ 7", "快捷名 B→b，2d6 求和 3+4"
    assert_includes out, "七"
  end

  def test_roll_multi_term_expression_evaluates
    @ct.create_table(chat_id: CHAT_ID, name: "算式表", author_id: AUTHOR)
    @ct.update_dice(chat_id: CHAT_ID, name: "算式表", dice_name: "b", dice_string: "2d6+3")
    @ct.update_data(chat_id: CHAT_ID, name: "算式表", data_index: 10, data_string: "十")

    out = roll("算式表 b", rands: [[2, 6], [5, 6]])

    assert_includes out, "2d6+3 ＞ 10", "2+5+3 = 10"
  end

  def test_roll_unknown_table_or_shortcut_is_reported
    out = roll("不存在的表", rands: [])
    assert_includes out, "找不到表「不存在的表」"

    seed_six
    out = roll("六表 z", rands: [])
    assert_includes out, "表「六表」没有快捷名「z」的骰型"
  end

  def test_roll_without_permission_is_allowed
    seed_six
    out = roll("六表", rands: [[1, 6]], user_id: STRANGER)

    assert_includes out, "结果1", "掷表是读操作（母本无权限检查）"
  end

  def test_roll_arity
    assert_includes roll("", rands: []), "参数个数不对"
    assert_includes roll("a b c d", rands: []), "参数个数不对"
  end

  # --- `+x` 可変数（SearchTableDiceroll.js:57-77）----------------------------

  def test_adjustment_is_substituted_with_floor_semantics
    @ct.create_table(chat_id: CHAT_ID, name: "加表", author_id: AUTHOR)
    @ct.update_dice(chat_id: CHAT_ID, name: "加表", dice_name: "b", dice_string: "1d6+x")
    (1..8).each { |i| @ct.update_data(chat_id: CHAT_ID, name: "加表", data_index: i, data_string: "值#{i}") }

    out = roll("加表 b 1.9", rands: [[4, 6]])

    assert_includes out, "1d6+1 ＞ 5", "Math.floor(1.9)=1（天狗 Number+floor）"
    assert_includes out, "值5"
  end

  def test_negative_adjustment_becomes_subtraction
    @ct.create_table(chat_id: CHAT_ID, name: "加表", author_id: AUTHOR)
    @ct.update_dice(chat_id: CHAT_ID, name: "加表", dice_name: "b", dice_string: "1d6+x")
    (1..6).each { |i| @ct.update_data(chat_id: CHAT_ID, name: "加表", data_index: i, data_string: "值#{i}") }
    @ct.set_datarange(chat_id: CHAT_ID, name: "加表", is_use: true, max: 6, min: 1)

    out = roll("加表 b -1.5", rands: [[5, 6]])

    assert_includes out, "1d6-2", "Math.floor(-1.5) = -2（负数走 replace 替换）"
    assert_includes out, "值3"
  end

  def test_non_numeric_adjustment_is_ignored_like_tengu
    @ct.create_table(chat_id: CHAT_ID, name: "加表", author_id: AUTHOR)
    @ct.update_dice(chat_id: CHAT_ID, name: "加表", dice_name: "b", dice_string: "1d6+x")
    (1..6).each { |i| @ct.update_data(chat_id: CHAT_ID, name: "加表", data_index: i, data_string: "值#{i}") }
    @ct.set_datarange(chat_id: CHAT_ID, name: "加表", is_use: true, max: 6, min: 1)

    out = roll("加表 b abc", rands: [[4, 6]])

    assert_includes out, "1d6 ＞ 4", "数字ではない値は無視（替换为空串）"
  end

  def test_adjustment_on_a_table_without_plus_x_is_ignored
    seed_six
    out = roll("六表 a 5", rands: [[3, 6]])

    assert_includes out, "1d6 ＞ 3", "骰式无 +x → 補正值不参与（同天狗）"
  end

  # --- datarange 钳制（NJDiscordReply.js:91-95）-----------------------------

  def test_roll_within_bounds_is_not_clamped
    seed_six
    @ct.update_dice(chat_id: CHAT_ID, name: "六表", dice_name: "b", dice_string: "1d6+x")
    @ct.set_datarange(chat_id: CHAT_ID, name: "六表", is_use: true, max: 6, min: 1)

    out = roll("六表 b 2", rands: [[3, 6]])

    assert_includes out, "1d6+2 ＞ 5"
    refute_includes out, "钳制", "界内不钳"
    assert_includes out, "结果5"
  end

  def test_roll_exactly_on_the_boundary_is_not_clamped
    seed_six
    @ct.update_dice(chat_id: CHAT_ID, name: "六表", dice_name: "b", dice_string: "1d6+x")
    @ct.set_datarange(chat_id: CHAT_ID, name: "六表", is_use: true, max: 6, min: 1)

    out = roll("六表 b 2", rands: [[4, 6]])

    assert_includes out, "1d6+2 ＞ 6"
    refute_includes out, "钳制", "== max 不算超界（T1.4 边界矩阵同款）"
  end

  def test_roll_above_the_clamp_reports_and_takes_the_upper_endpoint
    seed_six
    @ct.update_dice(chat_id: CHAT_ID, name: "六表", dice_name: "b", dice_string: "1d6+x")
    @ct.set_datarange(chat_id: CHAT_ID, name: "六表", is_use: true, max: 6, min: 1)

    out = roll("六表 b 10", rands: [[4, 6]])

    assert_includes out, "1d6+10 ＞ 14",
                    "原始出目照实显示（玩家看得出掷了多少+补了多少）"
    assert_includes out, "（出目 14 超出钳制范围 1..6，按钳制取 6）",
                    "超钳必须明示（验收词「超钳报错」的落点）"
    assert_includes out, "结果6", "取端点数据（天狗语义）"
  end

  def test_roll_below_the_clamp_reports_and_takes_the_lower_endpoint
    seed_six
    @ct.update_dice(chat_id: CHAT_ID, name: "六表", dice_name: "b", dice_string: "1d6+x")
    @ct.set_datarange(chat_id: CHAT_ID, name: "六表", is_use: true, max: 6, min: 1)

    out = roll("六表 b -10", rands: [[3, 6]])

    assert_includes out, "（出目 -7 超出钳制范围 1..6，按钳制取 1）"
    assert_includes out, "结果1"
  end

  def test_roll_without_a_range_never_clamps
    seed_six
    @ct.update_dice(chat_id: CHAT_ID, name: "六表", dice_name: "b", dice_string: "1d6+x")

    out = roll("六表 b 100", rands: [[2, 6]])

    assert_includes out, "1d6+100 ＞ 102"
    refute_includes out, "钳制", "不设限不拦（钳制仅在开钳时生效）"
    assert_includes out, "（出目 102 没有登记数据）", "界外且无数据 → 明说缺数据"
  end

  def test_roll_without_plus_x_never_clamps_even_when_range_is_on
    seed_six
    @ct.set_datarange(chat_id: CHAT_ID, name: "六表", is_use: true, max: 3, min: 1)

    out = roll("六表 a", rands: [[5, 6]])

    assert_includes out, "1d6 ＞ 5"
    refute_includes out, "钳制", "无 +x → isTableAdditionValue=false（天狗同款）"
  end

  def test_clamped_endpoint_without_data_is_reported
    @ct.create_table(chat_id: CHAT_ID, name: "洞表", author_id: AUTHOR)
    @ct.update_dice(chat_id: CHAT_ID, name: "洞表", dice_name: "b", dice_string: "1d6+x")
    @ct.update_data(chat_id: CHAT_ID, name: "洞表", data_index: 3, data_string: "三")
    @ct.set_datarange(chat_id: CHAT_ID, name: "洞表", is_use: true, max: 4, min: 1)

    out = roll("洞表 b 10", rands: [[4, 6]])

    assert_includes out, "按钳制取 4"
    assert_includes out, "（出目 4 没有登记数据）"
  end

  def test_missing_data_inside_the_range_is_reported_after_the_dice_line
    @ct.create_table(chat_id: CHAT_ID, name: "缺表", author_id: AUTHOR)
    @ct.update_data(chat_id: CHAT_ID, name: "缺表", data_index: 3, data_string: "三")

    out = roll("缺表", rands: [[2, 6]])

    assert_equal "本群表「缺表」(a)：1d6 ＞ 2\n（出目 2 没有登记数据）", out
  end

  # --- 查找顺序 default→private→public（SearchTableDiceroll.js:13-24）-------

  def test_lookup_order_three_states
    # default（内置）
    out = roll("SBX", rands: [[1, 6]])
    assert_includes out, "内置表「SBX」(a)：1d6 ＞ 1"
    assert_includes out, "内置一"

    # private
    seed_six("本群表")
    out = roll("本群表", rands: [[3, 6]])
    assert_includes out, "本群表「本群表」(a)"

    # public（别的群发布的）
    @ct.create_table(chat_id: -999, name: "公共表", author_id: 1)
    @ct.update_data(chat_id: -999, name: "公共表", data_index: 5, data_string: "公共五")
    @ct.publish_table(chat_id: -999, name: "公共表")

    out = roll("公共表", rands: [[5, 6]])
    assert_includes out, "公共表「公共表」(a)：1d6 ＞ 5"
    assert_includes out, "公共五"
  end

  def test_builtin_shadows_private_and_public
    # 内置 > 私有：db 直灌一个与内置同名的私有表（create 会拦，模拟历史数据）
    @ct.create_table(chat_id: CHAT_ID, name: "SBX", author_id: AUTHOR)
    @ct.update_data(chat_id: CHAT_ID, name: "SBX", data_index: 1, data_string: "私有一")

    out = roll("SBX", rands: [[1, 6]])

    assert_includes out, "内置表「SBX」", "查找顺序第一级（default）先命中"
    assert_includes out, "内置一"
  end

  def test_private_shadows_public
    @ct.create_table(chat_id: -999, name: "同名表", author_id: 1)
    @ct.update_data(chat_id: -999, name: "同名表", data_index: 1, data_string: "公共一")
    @ct.publish_table(chat_id: -999, name: "同名表")
    seed_six("同名表")
    @ct.update_data(chat_id: CHAT_ID, name: "同名表", data_index: 1, data_string: "私有一")

    out = roll("同名表", rands: [[1, 6]])

    assert_includes out, "本群表「同名表」", "private 先于 public"
    assert_includes out, "私有一"
  end

  def test_builtin_lookup_is_case_folded_while_db_is_exact
    # 内置：tableName.toLowerCase()（SearchTableDiceroll.js:15）
    assert_includes roll("sbx", rands: [[2, 6]]), "内置表"
    # DB：精确匹配（Firestore field 名同款）——表名是 "六表"，小写化无关；改用 ASCII 名验证
    @ct.create_table(chat_id: CHAT_ID, name: "CaseTable", author_id: AUTHOR)
    @ct.update_data(chat_id: CHAT_ID, name: "CaseTable", data_index: 1, data_string: "一")

    assert_includes roll("CaseTable", rands: [[1, 6]]), "本群表「CaseTable」"
    assert_includes roll("casetable", rands: []), "找不到表「casetable」",
                    "DB 侧按原样精确匹配（不折叠大小写）"
  end

  # --- 脏数据与防御 ---------------------------------------------------------

  def test_hand_mangled_dice_expression_is_reported_not_crashed
    @ct.create_table(chat_id: CHAT_ID, name: "坏表", author_id: AUTHOR)
    @conn.execute(
      "UPDATE custom_tables SET spec = ? WHERE name = '坏表'",
      [JSON.generate({ "dice" => { "a" => "1d6", "b" => "make_it_rain" }, "data" => {} })]
    )

    out = roll("坏表 b", rands: [])

    assert_includes out, "无法解析（可能被手工改动）", "坏骰式给可读错误，不许静默或半解析"
    assert_includes roll("坏表", rands: [[1, 6]]), "1d6 ＞ 1", "同一张表的正常骰型不受影响"
  end
end
