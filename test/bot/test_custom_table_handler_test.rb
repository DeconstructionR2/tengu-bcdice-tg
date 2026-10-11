# frozen_string_literal: true

# ============================================================================
# test/bot/test_custom_table_handler_test.rb — 天狗自定义表 /ct 命令层（T3.4）
#
# 覆盖计划 §8 T3.4 / §5（改表权限=建表者或群管理员）/ t3.3-report §6.1 待办清单：
#   - 子命令映射：create/rename/dice set|del/data set|del/range/perm add|del/
#     publish/delete/show/list/roll/help（母本 ct_command 15 文件的命令层判定）
#   - 命令层判定逐条：表名合法性、骰式正则（updateDice.js:55 逐字）、
#     diceName/diceString 小写归一、dataIndex ^\d+$、flag 解析（t/T/f/F）
#   - 权限：母本逐操作判据（全体 permission / 前三位 admin 位 / deleteTable 的
#     public 分支只认 permission[0]）+ Telegram 化群管理员旁路（Admin，fail-closed）
#   - 「不许删前三位」（deletePermission.js:17-20 管理範囲チェック）
#   - 内置表撞名两路（create + publish；真桥另见 test_custom_table_builtin_test.rb）
#   - 范围钳自动维护（updateDice/deleteDice/updateData/deleteData 四处命令层逻辑）
#   - dataVerification（publishTable.js:45-91）
#
# 层 2 为**真身 handler + 真 Router** 端到端接线（T2.6 教训：只测单元会漏接线 bug）。
# 掷骰语义（查找顺序/钳制/補正）在 test_custom_table_roll_test.rb。
# 全程 mock，零联网、零真 token、零 bot 进程；DB 用 :memory:。
# ============================================================================

require "minitest/autorun"
require "logger"
require_relative "test_helper"
require_relative "../../bot/router"
require_relative "../../bot/handlers/dice"
require_relative "../../bot/handlers/custom_table"
require_relative "../../db/connection"
require_relative "../randomizer_mock"
require_relative "../../lib/engine_bootstrap"

# /roll 与 /ct 共存的接线用例需要引擎（i18n + game_systems）；幂等，只在本进程跑一次。
EngineBootstrap.bootstrap!

# 假 admin（形状与 bot/admin.rb 的 admin? 一致；记录调用，供「私聊豁免零网络」断言）
# private_exempt 默认 true：与真 Admin 的「私聊恒 true」契约保持同步（bot/admin.rb 纪律 2）
class CtFakeAdmin
  attr_reader :asked

  def initialize(admins: [], default: false, raise_on: false, private_exempt: true)
    @admins = Array(admins).map(&:to_i)
    @default = default
    @raise_on = raise_on
    @private_exempt = private_exempt
    @asked = []
  end

  def admin?(_chat_id, user_id, chat_type: nil)
    @asked << [user_id.to_i, chat_type]
    raise "getChatMember exploded" if @raise_on
    return true if @private_exempt && chat_type.to_s == "private"

    @default || @admins.include?(user_id.to_i)
  end
end

# ============================================================================
# 层 1：handler 直调（注入内存 DB + 假内置源 + 假 admin）
# ============================================================================
class TestCustomTableHandler < Minitest::Test
  CHAT_ID = -1_000_000_000_123_456_789
  AUTHOR = 42       # 建表者（permission[0]）
  ADMIN_USER = 7    # 群管理员（不在任何表权限里）
  STRANGER = 99     # 路人
  TRUSTED = 314     # perm add 进来的普通权限用户（第 4 位起）
  BIT_1 = 271       # 仅用于占住 permission 第 2/3 位（admin 位）
  BIT_2 = 272

  # 假内置表源（形状同 BuiltinTables 的读取面：dice_string / data_entry / datarange）
  FakeBuiltinTable = Struct.new(:dice, :data) do
    def dice_string(k) = dice[k.to_s]
    def data_entry(i) = data[i.to_s]
    def datarange = TenguDB::DataRange.unbounded
  end

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @ct = TenguDB::CustomTables.new(@conn)
    @admin = CtFakeAdmin.new(admins: [ADMIN_USER])
    @builtin = {
      "sbx" => FakeBuiltinTable.new({ "a" => "1d6" }, { "1" => "内置一", "2" => "内置二" }),
      "krs" => FakeBuiltinTable.new({ "a" => "1d3" }, { "1" => "ソウカイヤ1" })
    }
    @handler = build_handler
  end

  def teardown
    @conn.close
  end

  def build_handler(admin: :default, randomizer: nil, builtin: :default, custom_tables: nil)
    TelegramBot::Handlers::CustomTableHandler.new(
      custom_tables: custom_tables || @ct,
      admin: admin == :default ? @admin : admin,
      builtin: builtin == :default ? @builtin : builtin,
      randomizer: randomizer,
      logger: Logger.new(IO::NULL)
    )
  end

  # handler 直调（形状与 router run_handler 的 context 一致）
  def ct_call(args, chat_id: CHAT_ID, user_id: AUTHOR, chat_type: "supergroup", kind: :slash)
    @handler.call(name: "ct", args: args, chat_id: chat_id,
                  user_id: user_id, chat_type: chat_type, kind: kind)
  end

  def table(name, chat_id: CHAT_ID)
    @ct.fetch(chat_id: chat_id, name: name)
  end

  def seed_table(name = "测试表", user_id: AUTHOR, chat_id: CHAT_ID)
    out = ct_call("create #{name}", user_id: user_id, chat_id: chat_id)
    assert_includes out, "已在本群建表", "seed 失败：#{out}"
    name
  end

  # 把表权限布置成「管理位占满前三位 + TRUSTED 在第 4 位」
  def occupy_admin_bits(name)
    @ct.set_permissions(chat_id: CHAT_ID, name: name,
                        permissions: [AUTHOR, BIT_1, BIT_2, TRUSTED])
  end

  # --- 入口与用法 -----------------------------------------------------------

  def test_no_args_shows_usage
    out = ct_call("")

    %w[create rename dice data range perm publish delete show list roll].each do |verb|
      assert_includes out, "/ct #{verb}", "用法表应含 #{verb}"
    end
  end

  def test_help_subcommand_and_topics
    assert_equal ct_call(""), ct_call("help")
    assert_includes ct_call("help roll"), "查找顺序"
    assert_includes ct_call("help roll"), "范围钳"
    unknown = ct_call("help nosuch")
    assert_includes unknown, "天狗自定义表", "未知主题回落总用法"
    assert_includes unknown, "没有「nosuch」这个子命令"
  end

  def test_unknown_subcommand_gets_a_reply_not_silence
    assert_includes ct_call("frobnicate x"), "未知子命令"
  end

  def test_group_subcommands_without_action_show_their_usage
    assert_includes ct_call("dice"), "/ct dice set"
    assert_includes ct_call("data nope"), "/ct data set"
    assert_includes ct_call("perm nope"), "/ct perm add"
  end

  def test_handler_is_silent_without_chat_id_or_for_other_commands
    assert_nil ct_call("list", chat_id: 0)
    assert_nil ct_call("list", chat_id: nil)
    assert_nil @handler.call(name: "bank", args: "list", chat_id: CHAT_ID, user_id: AUTHOR)
    assert_nil @handler.call(name: nil, args: "list", chat_id: CHAT_ID, user_id: AUTHOR)
  end

  def test_handler_dispatches_by_kind_and_ignores_other_tracks
    # T3.1 教训：单键 handler 也要判 kind——回调/辅助轨绝不该走 CT 路径
    assert_nil @handler.call(name: "ct", args: "list", chat_id: CHAT_ID,
                             user_id: AUTHOR, kind: :callback_query)
    assert_nil @handler.call(name: "ct", args: "list", chat_id: CHAT_ID,
                             user_id: AUTHOR, kind: :aux)
    # 直调（kind 缺省）视为 slash，照常应答
    assert_includes @handler.call(name: "ct", args: "list", chat_id: CHAT_ID, user_id: AUTHOR),
                    "一览"
  end

  # --- create ---------------------------------------------------------------

  def test_create_makes_the_tengu_initial_table
    out = ct_call("create 暗殺表")

    assert_includes out, "已在本群建表「暗殺表」"
    t = table("暗殺表")
    refute_nil t
    assert_equal({ "a" => "1d6" }, t.dice, "天狗初始物：dice {a: 1d6}")
    assert_empty t.data
    assert_equal [AUTHOR], t.permissions
    assert_equal AUTHOR, t.author_id
    refute t.datarange.is_use
  end

  def test_create_rejects_duplicate_in_the_same_chat
    seed_table("同名表")
    out = ct_call("create 同名表", user_id: STRANGER)

    assert_includes out, "本群已有同名表「同名表」"
    assert_equal AUTHOR, table("同名表").author_id, "撞名不得覆盖原表"
  end

  def test_create_rejects_builtin_names_case_insensitively
    # 验收钉：内置表同名阴影——建了会「等于没建」（掷表查找内置优先）
    ["SBX", "sbx", "Sbx", "KRS"].each do |name|
      out = ct_call("create #{name}")

      assert_includes out, "不能用与内置表相同的名称", "#{name} 必须被内置撞名拦截"
      assert_nil table(name), "被拦的名字不许落库"
    end
  end

  def test_create_validates_name_and_arity
    assert_includes ct_call("create"), "参数个数不对"
    assert_includes ct_call("create a b"), "参数个数不对"
    assert_includes ct_call("create #{'x' * 33}"), "表名无效"
    assert_nil table("x" * 33)
  end

  def test_create_needs_a_caller
    assert_includes ct_call("create 无发起人表", user_id: nil), "识别不了发起人"
    assert_nil table("无发起人表")
  end

  # --- rename ---------------------------------------------------------------

  def test_rename_moves_the_table_with_payload_intact
    seed_table("旧名表")
    ct_call("dice set 旧名表 b 2d6")
    ct_call("data set 旧名表 3 命中")
    out = ct_call("rename 旧名表 新名表")

    assert_includes out, "表名已更新：「旧名表」→「新名表」"
    assert_nil table("旧名表"), "旧名必须消失（不是复制一份）"
    renamed = table("新名表")
    assert_equal({ "a" => "1d6", "b" => "2d6" }, renamed.dice)
    assert_equal({ "3" => "命中" }, renamed.data)
  end

  def test_rename_rejects_conflicts_same_name_and_bad_input
    seed_table("表甲")
    seed_table("表乙")

    assert_includes ct_call("rename 表甲 表乙"), "新表名「表乙」已被占用"
    assert_includes ct_call("rename 表甲 表甲"), "旧表名与新表名相同"
    assert_includes ct_call("rename 表甲"), "参数个数不对"
    assert_includes ct_call("rename 没有这张 新名"), "找不到表"
    assert_equal "表甲", table("表甲").name
  end

  def test_rename_permission_is_admin_bits_or_group_admin
    seed_table("权限表")
    occupy_admin_bits("权限表")

    # 普通权限用户（第 4 位）不能改名（母本 updateTableName.js:15 只认前三位）
    assert_includes ct_call("rename 权限表 新名", user_id: TRUSTED), "前三位"
    # 群管理员（不在权限名单）可以（Telegram 化旁路）
    assert_includes ct_call("rename 权限表 新名", user_id: ADMIN_USER), "表名已更新"
    # 路人不行
    assert_includes ct_call("rename 新名 别的", user_id: STRANGER), "前三位"
  end

  def test_rename_flag_t_targets_the_public_row
    seed_table("公共表源")
    (1..6).each { |i| ct_call("data set 公共表源 #{i} 值#{i}") }
    ct_call("publish 公共表源")

    out = ct_call("rename 公共表源 公共改名 t")

    assert_includes out, "表名已更新"
    assert_nil @ct.fetch(chat_id: 0, name: "公共表源", scope: :public)
    refute_nil @ct.fetch(chat_id: 0, name: "公共改名", scope: :public)
    # 不带 t 时动的是本群行 → 找不到公共表
    assert_includes ct_call("rename 公共改名 别的"), "找不到表"
  end

  def test_rename_flag_forms_and_bad_flag
    seed_table("旗表")

    assert_includes ct_call("rename 旗表 旗表2 F"), "表名已更新" # f/F = 本群
    assert_includes ct_call("rename 旗表2 旗表3 x"), "末尾标记只能是 t"
    assert_equal "旗表2", table("旗表2").name, "坏 flag → 不改名"
    assert_nil table("旗表3")
  end

  def test_rename_can_produce_a_shadowed_name_like_the_tengu
    # 母本 updateTableName.js 无 datatable 引用 → 改名**不查内置表**（忠实保留；
    # 登记为已知面：改出的内置同名会被查找顺序里的内置级遮住）
    seed_table("普通表")

    out = ct_call("rename 普通表 SBX")

    assert_includes out, "表名已更新", "母本语义：改名不拦内置名"
    refute_nil table("SBX")
  end

  # --- dice set / dice del --------------------------------------------------

  def test_dice_set_updates_and_normalizes_lowercase
    seed_table("骰表")
    out = ct_call("dice set 骰表 A 2D6+3")

    assert_includes out, "a : 2d6+3", "快捷名 A→a、骰式 2D6+3→2d6+3（母本 adjust 小写化）"
    assert_equal({ "a" => "2d6+3" }, table("骰表").dice)
  end

  def test_dice_set_validates_dice_expression_like_tengu_regex
    seed_table("骰表")
    ["2d6*2", "1d6+", "d6", "hello", "1d6++2", "1D6+X", "+x"].each do |bad|
      out = ct_call("dice set 骰表 b #{bad}")

      assert_includes out, "骰式格式错误", "#{bad.inspect} 必须被拒（母本 updateDice.js:55 正则）"
    end
    # 合法形态放行（母本正则白名单）
    ["1d6", "6", "2d6+3", "1d6-3", "3d6+x", "4d6+3d10-5d6+32"].each do |good|
      out = ct_call("dice set 骰表 b #{good}")

      assert_includes out, "骰型已更新", "#{good.inspect} 应放行：#{out}"
    end
    assert_equal "4d6+3d10-5d6+32", table("骰表").dice["b"]
  end

  def test_dice_set_validates_shortcut_name_chars
    seed_table("骰表")

    assert_includes ct_call("dice set 骰表 a,b 1d6"), "快捷名不能含"
    assert_includes ct_call("dice set 骰表 名.字 1d6"), "快捷名不能含"
    assert_includes ct_call("dice set 骰表 名#字 1d6"), "快捷名不能含"
  end

  def test_dice_set_permission_is_the_full_permission_list
    seed_table("骰表")
    occupy_admin_bits("骰表")

    # 母本 updateDice.js:13-15：看**全体** permission（第 4 位也算）
    assert_includes ct_call("dice set 骰表 b 1d6", user_id: TRUSTED), "骰型已更新"
    assert_includes ct_call("dice set 骰表 c 1d6", user_id: STRANGER), "你没有操作表"
    assert_includes ct_call("dice set 骰表 d 1d6", user_id: ADMIN_USER), "骰型已更新"
  end

  def test_dice_set_on_missing_private_and_public_rows
    assert_includes ct_call("dice set 没有表 b 1d6"), "找不到表"
    assert_includes ct_call("dice set 没有表 b 1d6 t"), "找不到公共表"
  end

  def test_dice_del_protects_the_default_shortcut
    seed_table("骰表")

    %w[a A].each do |name|
      out = ct_call("dice del 骰表 #{name}")

      assert_includes out, "默认骰型", "#{name} 不可删（母本 deleteDice.js:42）"
    end
    refute_nil table("骰表").dice["a"]
  end

  def test_dice_del_removes_only_that_shortcut_and_is_idempotent
    seed_table("骰表")
    ct_call("dice set 骰表 b 2d6")
    ct_call("dice set 骰表 c 3d6")

    out = ct_call("dice del 骰表 b")

    assert_includes out, "「b」已删除"
    assert_equal %w[a c], table("骰表").dice.keys
    out = ct_call("dice del 骰表 b")
    assert_includes out, "本来就没有快捷名「b」", "删不存在的 ≠ 报错，但要明说未改动"
  end

  def test_dice_ops_flag_t_edits_the_public_row
    seed_table("公共骰")
    (1..6).each { |i| ct_call("data set 公共骰 #{i} 值#{i}") }
    ct_call("publish 公共骰")

    out = ct_call("dice set 公共骰 b 2d6 t")

    assert_includes out, "骰型已更新"
    assert_equal "2d6", @ct.fetch(chat_id: 0, name: "公共骰", scope: :public).dice["b"]
  end

  # --- 范围钳自动维护（母本 updateDice/deleteDice/updateData/deleteData）------

  def test_dice_set_plus_x_turns_range_on_from_data_keys
    seed_table("钳表")
    ct_call("data set 钳表 2 二")
    ct_call("data set 钳表 10 十")

    out = ct_call("dice set 钳表 b 2d6+x")

    assert_includes out, "骰型已更新"
    range = table("钳表").datarange
    assert range.is_use, "含 +x 且未开钳 → 自动开（母本 updateDice.js:29-34）"
    assert_equal 2, range.min
    assert_equal 10, range.max
  end

  def test_dice_set_plus_x_with_empty_data_opens_an_unbounded_range
    seed_table("空钳表")
    ct_call("dice set 空钳表 b 1d3+x")

    range = table("空钳表").datarange
    assert range.is_use, "母本对空 data 会开钳（MAX/MIN 哨兵）"
    assert_nil range.min
    assert_nil range.max, "本项目的「哨兵」是 null（=不设限）"
  end

  def test_dice_set_plus_x_leaves_an_existing_range_alone
    seed_table("钳表")
    ct_call("range 钳表 1 6")
    ct_call("dice set 钳表 b 1d6+x")

    assert_equal({ "isUse" => true, "max" => 6, "min" => 1 }, table("钳表").datarange.to_h,
                 "已开钳时母本不动（updateDice.js:29 的 !isUse 条件）")
  end

  def test_dice_set_without_plus_x_turns_range_off_when_no_addition_dice_remains
    seed_table("钳表")
    ct_call("dice set 钳表 b 1d6+x")
    ct_call("dice set 钳表 b 2d6") # 唯一 +x 骰型被改掉

    range = table("钳表").datarange
    refute range.is_use, "其余骰型无 +x → 关钳（updateDice.js:38-44）"
    assert range.unbounded?
  end

  def test_dice_set_without_plus_x_keeps_range_when_another_addition_dice_exists
    seed_table("钳表")
    (1..3).each { |i| ct_call("data set 钳表 #{i} 值#{i}") }
    ct_call("dice set 钳表 b 1d6+x") # 钳 1..3
    ct_call("dice set 钳表 c 2d6+x")

    ct_call("dice set 钳表 b 2d6") # 还有 c 带 +x

    range = table("钳表").datarange
    assert range.is_use, "还有 +x 骰型 → 钳制不动（isExistOtherAdditionDice）"
    assert_equal 1, range.min
    assert_equal 3, range.max
  end

  def test_dice_del_turns_range_off_when_the_last_addition_dice_goes
    seed_table("钳表")
    ct_call("data set 钳表 1 一")
    ct_call("dice set 钳表 b 1d6+x")
    assert table("钳表").datarange.is_use

    out = ct_call("dice del 钳表 b")

    assert_includes out, "已删除"
    refute table("钳表").datarange.is_use, "最后一个 +x 骰型删掉 → 关钳（deleteDice.js:21-26）"
  end

  def test_data_set_expands_the_range_when_it_is_on
    seed_table("钳表")
    ct_call("data set 钳表 1 一")
    ct_call("dice set 钳表 b 1d6+x") # 钳 1..1

    ct_call("data set 钳表 6 六")

    range = table("钳表").datarange
    assert_equal 1, range.min
    assert_equal 6, range.max, "开钳时新出目纳入（updateData.js:22-34）"
  end

  def test_data_del_recomputes_the_range_when_the_boundary_goes
    seed_table("钳表")
    (1..3).each { |i| ct_call("data set 钳表 #{i} 值#{i}") }
    ct_call("dice set 钳表 b 1d3+x")

    ct_call("data del 钳表 3")

    range = table("钳表").datarange
    assert_equal 2, range.max, "删端点 → 按剩余 data 重算（deleteData.js:24-32）"
    assert_equal 1, range.min
    assert range.is_use, "isUse 原样保留"
  end

  def test_data_del_of_an_interior_entry_leaves_the_range_alone
    seed_table("钳表")
    (1..5).each { |i| ct_call("data set 钳表 #{i} 值#{i}") }
    ct_call("dice set 钳表 b 1d6+x")

    ct_call("data del 钳表 3")

    assert_equal 5, table("钳表").datarange.max, "非端点删除不动钳制"
  end

  # --- data set / data del --------------------------------------------------

  def test_data_set_records_text_with_spaces_verbatim
    seed_table("数据表")
    out = ct_call("data set 数据表 3 前半 后半")

    assert_includes out, "出目 3 结果已录入"
    assert_equal "前半 后半", table("数据表").data["3"], "出目号之后是自由文本（空格保留）"
  end

  def test_data_set_validates_index_and_text
    seed_table("数据表")

    ["3a", "-1", "1.5", "０３"].each do |bad|
      assert_includes ct_call("data set 数据表 #{bad} 文本"), "出目号必须是半角数字",
                      "#{bad.inspect} 应被拒（母本 ^\\d+$）"
    end
    assert_includes ct_call("data set 数据表 3"), "参数个数不对"
    assert_includes ct_call("data set 数据表 3 t"), "结果文本为空", "flag 之后必须有文本"
    assert_empty table("数据表").data
  end

  def test_data_set_flag_before_text_targets_the_public_row
    seed_table("公共数据")
    (1..6).each { |i| ct_call("data set 公共数据 #{i} 值#{i}") }
    ct_call("publish 公共数据")

    out = ct_call("data set 公共数据 2 t 公共二")

    assert_includes out, "出目 2 结果已录入"
    assert_equal "公共二", @ct.fetch(chat_id: 0, name: "公共数据", scope: :public).data["2"]
    # 文本以 t 开头但不是一个 flag token → 按文本收（位置解析，不做内容猜测）
    seed_table("本群数据")
    assert_includes ct_call("data set 本群数据 1 t2"), "已录入"
    assert_equal "t2", table("本群数据").data["1"]
  end

  def test_data_del_missing_entry_is_a_success_state_with_dedicated_line
    seed_table("数据表")
    ct_call("data set 数据表 1 一")

    out = ct_call("data del 数据表 9")

    assert_includes out, "本来就没有出目 9 的数据", "天狗 deleteData.js:17-18 = 成功语义"
    assert_equal 1, table("数据表").data.size
  end

  def test_data_del_removes_only_that_entry
    seed_table("数据表")
    ct_call("data set 数据表 1 一")
    ct_call("data set 数据表 2 二")

    out = ct_call("data del 数据表 1")

    assert_includes out, "出目 1 数据已删除"
    assert_equal({ "2" => "二" }, table("数据表").data)
  end

  def test_data_ops_permission_is_the_full_permission_list
    seed_table("数据表")
    ct_call("data set 数据表 1 一")
    occupy_admin_bits("数据表")

    assert_includes ct_call("data set 数据表 2 二", user_id: TRUSTED), "结果已录入"
    assert_includes ct_call("data del 数据表 1", user_id: STRANGER), "你没有操作表"
    assert_includes ct_call("data set 数据表 3 三", user_id: ADMIN_USER), "结果已录入"
  end

  # --- range ----------------------------------------------------------------

  def test_range_sets_and_clears_the_clamp
    seed_table("钳表")

    out = ct_call("range 钳表 1 12")
    assert_includes out, "范围钳已开启：1..12"
    assert_equal({ "isUse" => true, "max" => 12, "min" => 1 }, table("钳表").datarange.to_h)

    out = ct_call("range 钳表 off")
    assert_includes out, "范围钳已关闭（不设限）"
    refute table("钳表").datarange.is_use
    assert table("钳表").datarange.unbounded?
  end

  def test_range_accepts_signed_and_zero_bounds
    seed_table("钳表")

    assert_includes ct_call("range 钳表 -5 5"), "-5..5"
    assert_equal(-5, table("钳表").datarange.min)
    assert_includes ct_call("range 钳表 0 6"), "0..6"
    assert_equal 0, table("钳表").datarange.min
  end

  def test_range_rejects_inverted_and_bad_arguments
    seed_table("钳表")

    assert_includes ct_call("range 钳表 9 2"), "最小不能大于最大"
    assert_includes ct_call("range 钳表 1 x"), "范围钳参数无效"
    assert_includes ct_call("range 钳表 1"), "范围钳参数无效"
    assert_includes ct_call("range 钳表 1 2 x"), "末尾标记只能是 t"
    refute table("钳表").datarange.is_use, "非法输入不许改库"
  end

  def test_range_flag_is_positional_and_works_with_off
    seed_table("本群钳")
    ct_call("range 本群钳 1 6")
    ct_call("publish 本群钳") # 已开钳 → 发布跳过数据校验

    out = ct_call("range 本群钳 off t")

    assert_includes out, "范围钳已关闭"
    refute @ct.fetch(chat_id: 0, name: "本群钳", scope: :public).datarange.is_use
  end

  def test_range_permission_is_the_full_permission_list
    seed_table("钳权限表")
    occupy_admin_bits("钳权限表")

    assert_includes ct_call("range 钳权限表 1 6", user_id: STRANGER), "你没有操作表"
    assert_includes ct_call("range 钳权限表 1 6", user_id: TRUSTED), "范围钳已开启"
  end

  # --- perm add / perm del --------------------------------------------------

  def test_perm_add_appends_and_rejects_duplicates
    seed_table("权限表")
    out = ct_call("perm add 权限表 #{TRUSTED}")

    assert_includes out, "添加权限：#{TRUSTED}"
    assert_equal [AUTHOR, TRUSTED], table("权限表").permissions
    assert_includes ct_call("perm add 权限表 #{TRUSTED}"), "已在权限名单里"
    assert_includes ct_call("perm add 权限表 abc"), "用户 ID 必须是半角数字"
  end

  def test_perm_add_requires_admin_bits
    seed_table("权限表")
    occupy_admin_bits("权限表")

    # 普通权限用户（第 4 位）不能再授权（母本 addPermission.js:11-15 只认前三位）
    assert_includes ct_call("perm add 权限表 555", user_id: TRUSTED), "前三位"
    assert_includes ct_call("perm add 权限表 555", user_id: ADMIN_USER), "添加权限"
    assert_includes ct_call("perm add 权限表 666", user_id: STRANGER), "前三位"
    assert_equal [AUTHOR, BIT_1, BIT_2, TRUSTED, 555], table("权限表").permissions
  end

  def test_perm_del_forbids_removing_the_admin_slots
    seed_table("权限表")
    ct_call("perm add 权限表 #{TRUSTED}")

    out = ct_call("perm del 权限表 #{AUTHOR}")

    assert_includes out, "不能删除权限前三位", "管理範囲チェック（deletePermission.js:17-20）"
    assert_equal [AUTHOR, TRUSTED], table("权限表").permissions
  end

  def test_perm_del_rejects_users_outside_the_deletable_range
    seed_table("权限表")

    assert_includes ct_call("perm del 权限表 #{TRUSTED}"), "不在可删除的权限位"
  end

  def test_perm_del_removes_a_limited_user_and_keeps_order
    seed_table("权限表")
    @ct.set_permissions(chat_id: CHAT_ID, name: "权限表",
                        permissions: [AUTHOR, BIT_1, BIT_2]) # 先占满管理位
    ct_call("perm add 权限表 #{TRUSTED}")
    ct_call("perm add 权限表 555")

    assert_includes ct_call("perm del 权限表 #{TRUSTED}"), "删除权限：#{TRUSTED}"
    assert_equal [AUTHOR, BIT_1, BIT_2, 555], table("权限表").permissions
  end

  # --- publish --------------------------------------------------------------

  def test_publish_moves_a_complete_table_to_public
    seed_table("发布表")
    (1..6).each { |i| ct_call("data set 发布表 #{i} 值#{i}") }

    out = ct_call("publish 发布表")

    assert_includes out, "已发布为公共表"
    assert_nil table("发布表"), "发布是「移」：私有行消失（publishTable.js:22-27）"
    published = @ct.fetch(chat_id: 0, name: "发布表", scope: :public)
    refute_nil published
    assert_equal AUTHOR, published.author_id
  end

  def test_publish_requires_the_data_to_be_complete
    seed_table("缺口表")
    ct_call("data set 缺口表 2 二")
    ct_call("data set 缺口表 3 三")

    out = ct_call("publish 缺口表")

    assert_includes out, "出目 1,4,5,6 没有登记数据", "publishTable.js:76-81 缺哪报哪"
    refute_nil table("缺口表"), "校验失败不许动表"
    assert_nil @ct.fetch(chat_id: 0, name: "缺口表", scope: :public)
  end

  def test_publish_rejects_extra_data_beyond_the_dice_range
    seed_table("多余表")
    (1..8).each { |i| ct_call("data set 多余表 #{i} 值#{i}") }

    out = ct_call("publish 多余表")

    assert_includes out, "数据数与可能出目不一致", "publishTable.js:82-87"
    assert_includes out, "登记数据数:8，出目范围:1~6"
  end

  def test_publish_skips_verification_when_the_range_is_on
    seed_table("钳表")
    ct_call("data set 钳表 1 一")
    ct_call("dice set 钳表 b 1d6+x")
    assert table("钳表").datarange.is_use

    assert_includes ct_call("publish 钳表"), "已发布为公共表",
                    "isUse 时跳过校验（publishTable.js:18）"
  end

  def test_publish_skips_verification_when_a_dice_has_plus_x
    seed_table("加表")
    ct_call("data set 加表 1 一")
    ct_call("dice set 加表 b 1d6+x")
    ct_call("range 加表 off") # 强制 isUse=false，仍应因 +x 跳过

    assert_includes ct_call("publish 加表"), "已发布为公共表",
                    "骰式含 +x 时跳过校验（publishTable.js 的 help 原文：判定できない）"
  end

  def test_publish_rejects_builtin_collision
    # create 已拦内置名 → 这里用 db 直灌模拟历史数据/手工库
    @ct.create_table(chat_id: CHAT_ID, name: "SBX", author_id: AUTHOR)
    (1..6).each do |i|
      @ct.update_data(chat_id: CHAT_ID, name: "SBX", data_index: i, data_string: "值#{i}")
    end

    out = ct_call("publish SBX")

    assert_includes out, "不能用与内置表相同的名称", "publishTable.js:13-14 内置撞名"
    refute_nil table("SBX"), "被拦时私有表原样不动"
  end

  def test_publish_rejects_public_collision
    # 别的群发布过同名公共表
    @ct.create_table(chat_id: -999, name: "公共占用", author_id: 1)
    (1..6).each do |i|
      @ct.update_data(chat_id: -999, name: "公共占用", data_index: i, data_string: "值#{i}")
    end
    @ct.publish_table(chat_id: -999, name: "公共占用")
    # 本群同名表
    seed_table("公共占用")
    (1..6).each { |i| ct_call("data set 公共占用 #{i} 值#{i}") }

    out = ct_call("publish 公共占用")

    assert_includes out, "公共表里已有同名表", "publishTable.js:15-16"
    refute_nil table("公共占用"), "被拦时本群表原样不动"
  end

  def test_publish_permission_is_admin_bits_or_group_admin
    seed_table("发布权限")
    (1..6).each { |i| ct_call("data set 发布权限 #{i} 值#{i}") }
    occupy_admin_bits("发布权限")

    # 普通权限用户不能发布（母本代码无检查、help 承诺三档 —— 本项目落到前三位）
    assert_includes ct_call("publish 发布权限", user_id: TRUSTED), "前三位"
    refute_nil table("发布权限")
    assert_includes ct_call("publish 发布权限", user_id: ADMIN_USER), "已发布为公共表"
  end

  def test_publish_missing_table
    assert_includes ct_call("publish 不存在"), "找不到表"
  end

  # --- delete ---------------------------------------------------------------

  def test_delete_removes_the_private_table
    seed_table("删表")
    out = ct_call("delete 删表")

    assert_includes out, "已删除"
    assert_nil table("删表")
    assert_includes ct_call("delete 删表"), "找不到表"
  end

  def test_delete_private_permission_is_admin_bits
    seed_table("删表权限")
    occupy_admin_bits("删表权限")

    assert_includes ct_call("delete 删表权限", user_id: TRUSTED), "前三位"
    assert_includes ct_call("delete 删表权限", user_id: ADMIN_USER), "已删除"
    assert_nil table("删表权限")
  end

  def test_delete_public_row_only_accepts_the_first_permission_slot
    # 母本 deleteTable.js:13-16：public 分支**只认 permission[0]**（私有才认前三位）
    @ct.create_table(chat_id: CHAT_ID, name: "公共删除", author_id: AUTHOR,
                     permissions: [AUTHOR, BIT_1, BIT_2, TRUSTED])
    (1..6).each do |i|
      @ct.update_data(chat_id: CHAT_ID, name: "公共删除", data_index: i, data_string: "值#{i}")
    end
    @ct.publish_table(chat_id: CHAT_ID, name: "公共删除")

    # 第二/三位（admin 位）与群管理员都不行
    assert_includes ct_call("delete 公共删除 t", user_id: BIT_1), "第一位权限用户"
    assert_includes ct_call("delete 公共删除 t", user_id: ADMIN_USER), "第一位权限用户"
    refute_nil @ct.fetch(chat_id: 0, name: "公共删除", scope: :public)
    # 第一位可以
    assert_includes ct_call("delete 公共删除 t", user_id: AUTHOR), "已删除"
    assert_nil @ct.fetch(chat_id: 0, name: "公共删除", scope: :public)
    # 不带 t 找不到（本群行不存在）
    assert_includes ct_call("delete 公共删除"), "找不到表"
  end

  # --- show / list ----------------------------------------------------------

  def test_show_renders_the_table_detail
    seed_table("详表")
    ct_call("dice set 详表 b 2d6")
    ct_call("data set 详表 3 文本三")
    ct_call("range 详表 1 12")

    out = ct_call("show 详表", user_id: STRANGER)

    assert_includes out, "表「详表」（本群表）"
    assert_includes out, "建表者：#{AUTHOR}"
    assert_includes out, "快捷骰：a : 1d6 , b : 2d6"
    assert_includes out, "范围钳：开启 1..12"
    assert_includes out, "权限（前三位=管理位）：#{AUTHOR}"
    assert_includes out, "3：文本三"
  end

  def test_show_hints_when_the_name_is_a_builtin
    out = ct_call("show SBX")

    assert_includes out, "是内置表"
    assert_includes ct_call("show 不存在的"), "找不到表"
    assert_includes ct_call("show 不存在的 t"), "找不到公共表"
  end

  def test_list_shows_private_and_public_sections
    seed_table("甲表")
    @ct.create_table(chat_id: -999, name: "乙表", author_id: AUTHOR)
    @ct.create_table(chat_id: -999, name: "公共甲", author_id: AUTHOR)
    (1..6).each do |i|
      @ct.update_data(chat_id: -999, name: "公共甲", data_index: i, data_string: "值#{i}")
    end
    @ct.publish_table(chat_id: -999, name: "公共甲")

    out = ct_call("list", user_id: STRANGER)

    assert_includes out, "◆自定义表一览◆"
    assert_includes out, "【本群表】"
    assert_includes out, "甲表 — a : 1d6"
    refute_includes out, "乙表", "别的群的表不该出现"
    assert_includes out, "【公共表】"
    assert_includes out, "公共甲"
    assert_includes ct_call("list extra"), "参数个数不对"
  end

  # --- 权限模型横切面 --------------------------------------------------------

  def test_group_admin_bypass_applies_to_private_rows_via_the_admin_helper
    seed_table("旁路表")
    spy = CtFakeAdmin.new(admins: [ADMIN_USER])
    handler = build_handler(admin: spy)

    out = handler.call(name: "ct", args: "dice set 旁路表 b 1d6",
                       chat_id: CHAT_ID, user_id: ADMIN_USER, chat_type: "supergroup")

    assert_includes out, "骰型已更新"
    assert_equal [[ADMIN_USER, "supergroup"]], spy.asked, "必须把 chat_type 传给 admin?"
  end

  def test_public_rows_do_not_consult_the_group_admin
    seed_table("公共旁路")
    (1..6).each { |i| ct_call("data set 公共旁路 #{i} 值#{i}") }
    ct_call("publish 公共旁路")
    spy = CtFakeAdmin.new(admins: [ADMIN_USER])
    handler = build_handler(admin: spy)

    out = handler.call(name: "ct", args: "dice set 公共旁路 b 1d6 t",
                       chat_id: CHAT_ID, user_id: ADMIN_USER, chat_type: "supergroup")

    assert_includes out, "你没有操作表", "公共行没有「本群」→ 群管理员旁路不适用"
    assert_empty spy.asked, "公共行连 getChatMember 都不该查"
  end

  def test_private_chat_exemption_is_delegated_to_the_admin_helper
    # 私聊里建表（作者=AUTHOR），再由**非作者**的本人（私聊 chat_id=99）改表：
    # 母本判据不命中 → 落到 admin?；真 Admin 对 private 恒 true（bot/admin.rb 纪律 2）
    ct_call("create 私聊表", chat_id: STRANGER, user_id: AUTHOR, chat_type: "private")
    refute table("私聊表", chat_id: STRANGER).permitted?(STRANGER)

    spy = CtFakeAdmin.new(admins: [], default: false) # 私聊 → true（同真 Admin 契约）
    handler = build_handler(admin: spy)
    out = handler.call(name: "ct", args: "dice set 私聊表 b 1d6",
                       chat_id: STRANGER, user_id: STRANGER, chat_type: "private")

    assert_includes out, "骰型已更新", "私聊豁免：由 Admin 决定（handler 不得自行拦）"
    assert_equal [[STRANGER, "private"]], spy.asked, "chat_type 必须原样传给 admin?"
  end

  def test_private_chat_is_not_a_backdoor_when_admin_denies
    # 私聊豁免是 **Admin 的契约**，不是 handler 的特判：admin? 说 no 就要拦住
    ct_call("create 私聊险表", chat_id: STRANGER, user_id: AUTHOR, chat_type: "private")
    handler = build_handler(admin: CtFakeAdmin.new(admins: [], private_exempt: false))

    out = handler.call(name: "ct", args: "dice set 私聊险表 b 1d6",
                       chat_id: STRANGER, user_id: STRANGER, chat_type: "private")

    assert_includes out, "你没有操作表"
  end

  def test_missing_admin_or_raising_admin_denies_group_writes
    seed_table("缺依赖表")
    # 未注入 admin（nil）→ 群内一律拒（fail-closed）
    bare = build_handler(admin: nil)
    out = bare.call(name: "ct", args: "dice set 缺依赖表 b 1d6",
                    chat_id: CHAT_ID, user_id: ADMIN_USER, chat_type: "supergroup")

    assert_includes out, "你没有操作表"
    # admin? 抛异常 → 也按拒
    raising = build_handler(admin: CtFakeAdmin.new(raise_on: true))
    out2 = raising.call(name: "ct", args: "dice set 缺依赖表 b 1d6",
                        chat_id: CHAT_ID, user_id: ADMIN_USER, chat_type: "supergroup")
    assert_includes out2, "你没有操作表"
    # chat_type 缺失（nil）≠ 私聊豁免：只影响权限判定的 type 透传；
    # 作者本人先命中母本判据（permitted?），不受影响
    nil_type = build_handler(admin: CtFakeAdmin.new(admins: []))
    out3 = nil_type.call(name: "ct", args: "dice set 缺依赖表 b 1d6",
                         chat_id: CHAT_ID, user_id: AUTHOR, chat_type: nil)
    assert_includes out3, "骰型已更新"
  end

  # --- 失败路径 --------------------------------------------------------------

  # 注入一个「写成功但 set_datarange 恒失败」的假 DB：验 RANGE_SYNC_FAILED 分支
  class RangeFailCT
    def initialize(real)
      @real = real
    end

    def set_datarange(**)
      TenguDB::MutationResult.error(SQLite3::BusyException)
    end

    def method_missing(name, *args, **kw, &blk)
      @real.send(name, *args, **kw, &blk)
    end

    def respond_to_missing?(name, include_private = false)
      @real.respond_to?(name, include_private)
    end
  end

  def test_range_sync_failure_is_surfaced
    seed_table("同步失败")
    handler = build_handler(custom_tables: RangeFailCT.new(@ct))

    out = handler.call(name: "ct", args: "dice set 同步失败 b 1d6+x",
                       chat_id: CHAT_ID, user_id: AUTHOR, chat_type: "supergroup")

    assert_includes out, "范围钳同步失败"
  end

  # 注入一个恒抛异常的表存储：handler 必须回可读文案而不是静默
  class ExplodingCT
    def method_missing(_name, *_args, **_kw, &_blk)
      raise SQLite3::BusyException, "database is locked"
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  def test_storage_explosion_degrades_to_a_readable_reply
    handler = build_handler(custom_tables: ExplodingCT.new)
    out = handler.call(name: "ct", args: "show 任意表",
                       chat_id: CHAT_ID, user_id: AUTHOR, chat_type: "supergroup")

    assert_includes out, "存储层出错"
  end

  def test_registry_exposes_the_ct_key
    handler = build_handler

    assert_equal({ ct: handler }, TelegramBot::Handlers::CustomTableHandler.registry(handler))
  end
end

# ============================================================================
# 层 2：真身 handler + 真 Router 端到端接线（T2.6 教训）
# ============================================================================
class TestCustomTableRouting < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789
  TOPIC = 88
  AUTHOR = 42

  ROUTING_BUILTIN = {
    "sbx" => Struct.new(:dice, :data) {
      def dice_string(k) = dice[k.to_s]
      def data_entry(i) = data[i.to_s]
      def datarange = TenguDB::DataRange.unbounded
    }.new({ "a" => "1d6" }, { "1" => "内置" })
  }.freeze

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @ct = TenguDB::CustomTables.new(@conn)
    @handler = TelegramBot::Handlers::CustomTableHandler.new(
      custom_tables: @ct, admin: CtFakeAdmin.new(admins: []),
      builtin: ROUTING_BUILTIN, logger: Logger.new(IO::NULL)
    )
    @api, @fake, = build_api
    @router = TelegramBot::Router.new(
      api: @api,
      handlers: TelegramBot::Handlers::CustomTableHandler.registry(@handler),
      bot_username: "example_dice_bot",
      logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    @conn.close
  end

  def update(text:, thread_id: nil, chat_id: CHAT_ID)
    attrs = { message_id: 1, date: 1_700_000_000,
              chat: { id: chat_id, type: "supergroup" },
              from: { id: AUTHOR, is_bot: false, first_name: "Tester" }, text: text }
    attrs[:message_thread_id] = thread_id if thread_id
    Telegram::Bot::Types::Message.new(**attrs)
  end

  # 名字避开 Object#send / Minitest#run（同 bank 测试的教训注释）
  def ct_send(text:, thread_id: nil)
    @router.dispatch(update(text: text, thread_id: thread_id))
    @fake.sent_messages.pop
  end

  def test_ct_slash_reaches_the_handler_with_thread_passthrough
    message = ct_send(text: "/ct create 接线表", thread_id: TOPIC)

    refute_nil message, "/ct 已有真 handler（菜单上架命令不许静默）"
    assert_includes message[:text], "已在本群建表"
    assert_equal TOPIC, message[:message_thread_id], "thread 必须透传（forum 不掉话题）"
    refute_nil @ct.fetch(chat_id: CHAT_ID, name: "接线表")
  end

  def test_full_journey_through_the_real_router
    ct_send(text: "/ct create 旅程表", thread_id: TOPIC)
    ct_send(text: "/ct dice set 旅程表 b 1d6", thread_id: TOPIC)
    ct_send(text: "/ct data set 旅程表 4 旅程结果", thread_id: TOPIC)
    @fake.sent_messages.clear

    show = ct_send(text: "/ct show 旅程表", thread_id: TOPIC)
    assert_includes show[:text], "快捷骰：a : 1d6 , b : 1d6"

    list = ct_send(text: "/ct list", thread_id: TOPIC)
    assert_includes list[:text], "旅程表"
    assert_equal TOPIC, list[:message_thread_id]
  end

  def test_roll_journey_with_fixed_dice_through_the_router
    rnd = RandomizerMock.new([[4, 6]])
    handler = TelegramBot::Handlers::CustomTableHandler.new(
      custom_tables: @ct, admin: CtFakeAdmin.new(admins: []),
      builtin: ROUTING_BUILTIN, randomizer: rnd, logger: Logger.new(IO::NULL)
    )
    router = TelegramBot::Router.new(
      api: @api, handlers: TelegramBot::Handlers::CustomTableHandler.registry(handler),
      bot_username: "example_dice_bot", logger: Logger.new(IO::NULL)
    )

    router.dispatch(update(text: "/ct create 掷表", thread_id: TOPIC))
    @ct.update_data(chat_id: CHAT_ID, name: "掷表", data_index: 4, data_string: "四点")
    @fake.sent_messages.clear

    router.dispatch(update(text: "/ct roll 掷表", thread_id: TOPIC))
    message = @fake.sent_messages.pop

    assert_includes message[:text], "本群表「掷表」(a)：1d6 ＞ 4"
    assert_includes message[:text], "四点"
    assert_equal TOPIC, message[:message_thread_id]
  end

  def test_commands_not_owned_by_ct_stay_silent
    @router.dispatch(update(text: "/bank deposit 100", thread_id: TOPIC))

    assert_empty @fake.sent_messages.map { |m| m[:text] },
                 "CT handler 不得越权处理别的命令"
  end

  def test_ct_merges_alongside_other_handlers_without_clobbering
    dice = TelegramBot::Handlers::DiceHandler.new(
      settings: TenguDB::Settings.new(@conn), logger: Logger.new(IO::NULL)
    )
    router = TelegramBot::Router.new(
      api: @api,
      handlers: TelegramBot::Handlers::DiceHandler.registry(dice)
                      .merge(TelegramBot::Handlers::CustomTableHandler.registry(@handler)),
      bot_username: "example_dice_bot", logger: Logger.new(IO::NULL)
    )

    router.dispatch(update(text: "/ct create 共存表", thread_id: TOPIC))
    router.dispatch(update(text: "/roll SB", thread_id: TOPIC))

    texts = @fake.sent_messages.map { |m| m[:text] }
    assert(texts.any? { |t| t.include?("已在本群建表") }, "CT 命令应被处理：#{texts.inspect}")
    assert(texts.any? { |t| t.include?("サツバツ") }, "掷骰命令应照常工作：#{texts.inspect}")
  end
end
