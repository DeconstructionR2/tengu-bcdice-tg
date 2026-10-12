# frozen_string_literal: true

# ============================================================================
# test/db/test_custom_tables_test.rb — 天狗 CT（自定义表）DB 层（T3.3）
#
# 覆盖计划 §0.2.3 / §4.2 验收单的 CT 12 操作（建表/改名/改骰型/改条目/改范围钳/
# 改权限/发布到公共/删骰型/删条目/删表/按频道查全部/查单表）与查找顺序，
# 以及 §4.1 的 schema 语义：
#
#   - **12 操作逐条** 正常系 + 异常系（表不存在/撞名/入参非法/存储层失败）
#   - **查找顺序** default内置 → 频道私有 → 公共，三态断言（SearchTableDiceroll.js:14）
#   - **发布到公共**：复制+删私有（是「移」）、含公共同名冲突（整笔回滚）
#   - **UNIQUE(scope,chat_id,name)**：公共重名拦截 / 跨群私有同名放行 /
#     同一群同名拦截 / 私有与公共可同名共存
#   - **datarange 钳制语义**：isUse / max / min / **null = 不设限** / 倒挂拒绝
#   - **permissions 数组**读写 + admin 位（前三）位置语义
#   - **群升级 re-key** 私有表跟着走（Migration 联动，参照 T3.1/T3.2 同款）
#   - **事务纪律**：改名/发布/读改写都走 :immediate；块内不 return
#   - JSON 列损坏容错（warn + 降级，不当致命）
#   - 值一律绑定（SQL 元字符表名/条目文本不得拼进 SQL）
#
# 全程 :memory: 库，零文件、零联网、不读 .env、不起 bot 进程。
# ============================================================================

require "minitest/autorun"
require "json"
require "logger"
require "delegate"
require_relative "../../db/connection"
require_relative "../../db/custom_tables"
require_relative "../../bot/migration"

class TestCustomTables < Minitest::Test
  CHAT = -1_000_000_000_123_456_789 # 超 32 位有效位（§0.2.4）
  OTHER_CHAT = -1_000_000_000_987_654_321
  AUTHOR = 42
  GUILD_OWNER = 7
  COUSER = 11

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @ct = TenguDB::CustomTables.new(@conn, logger: Logger.new(IO::NULL))
  end

  def teardown
    @conn.close
  end

  # 造一张私有表（默认骰型 {a:'1d6'}、空 data、权限只有建表者、不设限）
  def seed_private(name: "测试表", chat_id: CHAT, author_id: AUTHOR, **kwargs)
    @ct.create_table(chat_id: chat_id, name: name, author_id: author_id, **kwargs)
  end

  # 造一张公共表（走发布路径——公共行只能由 publish 产生）
  def seed_public(name: "公共表", chat_id: CHAT, author_id: AUTHOR)
    seed_private(name: name, chat_id: chat_id, author_id: author_id)
    @ct.publish_table(chat_id: chat_id, name: name)
  end

  # 原始列值（验「落库形态」而不只是对象视图）
  def raw(column, name:, scope: "private", chat_id: CHAT)
    chat = scope == "public" ? 0 : chat_id
    @conn.get_first_value(
      "SELECT #{column} FROM custom_tables WHERE scope = ? AND chat_id = ? AND name = ?",
      [scope, chat, name]
    )
  end

  # =========================================================================
  # A. 操作 1：建表（天狗 createTable，db_wrapper.js:43）
  # =========================================================================

  def test_create_table_writes_the_tengu_initial_shape
    result = seed_private

    assert result.ok?, "建表应成功（sanity）"
    table = result.table
    assert_equal "测试表", table.name
    assert_equal "private", table.scope
    assert_equal CHAT, table.chat_id, "64 位 chat_id 不能被截断"
    assert_equal({ "a" => "1d6" }, table.dice,
                 "初始骰型 = 天狗 {a:'1d6'}（db_wrapper.js:45-47）")
    assert_empty table.data, "初始 data 为空对象"
    assert_equal [AUTHOR], table.permissions, "默认权限只放建表者"
    assert_equal AUTHOR, table.author_id
    refute table.datarange.is_use, "初始 isUse=false"
    assert table.datarange.unbounded?, "初始 max/min 为 null（不设限）"
  end

  def test_create_table_stores_spec_permissions_datarange_as_json_columns
    seed_private(permissions: [AUTHOR, GUILD_OWNER])

    spec = JSON.parse(raw("spec", name: "测试表"))
    assert_equal({ "dice" => { "a" => "1d6" }, "data" => {} }, spec,
                 "spec 必须是 JSON：{dice:{}, data:{}}（§4.1）")
    assert_equal [AUTHOR, GUILD_OWNER], JSON.parse(raw("permissions", name: "测试表"))
    assert_equal({ "isUse" => false, "max" => nil, "min" => nil },
                 JSON.parse(raw("datarange", name: "测试表")),
                 "不设限用 JSON null，不写天狗那两个哨兵值（§4.2 定案）")
  end

  def test_create_table_accepts_explicit_permission_array_and_keeps_order
    # 天狗 permission 的**位置即层级**：前三位是 admin 位
    result = seed_private(permissions: [AUTHOR, GUILD_OWNER, COUSER, 99])

    assert result.ok?
    assert_equal [AUTHOR, GUILD_OWNER, COUSER, 99], result.table.permissions,
                 "顺序必须原样保留（admin 位靠位置判定）"
    assert_equal [AUTHOR, GUILD_OWNER, COUSER], result.table.admins,
                 "前三位是 admin 位（天狗 permission[0..2]）"
  end

  def test_create_table_rejects_a_duplicate_name_in_the_same_chat
    seed_private

    second = seed_private
    assert second.already_exists?, "同群同名必须拦（UNIQUE(scope,chat_id,name)）"
    assert_equal 1, @ct.count_for(chat_id: CHAT)
  end

  def test_create_table_rejects_public_scope_directly
    # 天狗只有 publishTable 会写 public_db（db_wrapper.js:65-70 的唯一 null 调用方）
    result = @ct.create_table(chat_id: CHAT, name: "偷偷建公共", author_id: AUTHOR,
                              scope: :public)

    assert result.invalid_argument?, "公共行只能由发布产生"
    assert_equal 0, @ct.count_for(chat_id: CHAT, scope: "public")
  end

  def test_create_table_rejects_bad_arguments
    [
      { chat_id: 0 }, { chat_id: nil }, { chat_id: "" }, { chat_id: "  " },
      { name: "" }, { name: nil }, { author_id: 0 }, { author_id: "abc" },
      { permissions: [] }, { permissions: [0, 0] }
    ].each do |bad|
      args = { chat_id: CHAT, name: "参数表", author_id: AUTHOR }.merge(bad)
      result = @ct.create_table(**args)
      assert result.invalid_argument?, "#{bad.inspect} 必须被拒（不该建出半截行）"
    end
    assert_equal 0, @ct.count_for(chat_id: CHAT), "被拒的入参不得留下任何行"
  end

  # 2026-10-12 验收轮修复 [3]：非法 scope 字符串此前漏判 sc.nil? ——
  # normalize_scope 对不认识的 scope 返回 nil，nil 直接进 INSERT 撞 scope 列的
  # NOT NULL 约束，被 rescue SQLite3::ConstraintException 误报成 already_exists
  # （同群同名的假象）。兄弟方法（rename/publish/edit/delete/list/count）都有
  # sc.nil? 守卫，这里补齐同口径。
  def test_create_table_rejects_an_unknown_scope_string
    result = @ct.create_table(chat_id: CHAT, name: "错scope表", author_id: AUTHOR,
                              scope: "bogus")

    assert result.invalid_argument?, "非法 scope 必须 invalid_argument（不是 already_exists）"
    assert_equal 0, @ct.count_for(chat_id: CHAT), "被拒的入参不得留下任何行"
  end

  def test_create_table_rejects_inverted_datarange_bounds
    result = @ct.create_table(chat_id: CHAT, name: "倒挂表", author_id: AUTHOR,
                              datarange: TenguDB::DataRange.new(
                                is_use: true, max: 2, min: 9
                              ))

    assert result.invalid_argument?, "max < min 的倒挂钳制必须拒（钳完必空且无提示）"
    assert_nil @ct.fetch(chat_id: CHAT, name: "倒挂表")
  end

  def test_create_table_values_are_bound_not_interpolated
    nasty = "表'; DROP TABLE custom_tables; --"
    result = seed_private(name: nasty)

    assert result.ok?, "表名含 SQL 元字符也必须走绑定"
    assert_equal nasty, result.table.name
    assert @conn.table_exists?("custom_tables"), "表不得被拼进 SQL 而删掉"
  end

  # =========================================================================
  # B. 操作 2：改名（天狗 updateTableName，db_wrapper.js:39）
  # =========================================================================

  def test_rename_moves_the_row_and_keeps_all_payload
    seed_private(permissions: [AUTHOR, GUILD_OWNER])
    @ct.update_dice(chat_id: CHAT, name: "测试表", dice_name: "b", dice_string: "2d6+3")
    @ct.update_data(chat_id: CHAT, name: "测试表", data_index: 3, data_string: "当たり")

    result = @ct.rename_table(chat_id: CHAT, old_name: "测试表", new_name: "改名表")

    assert result.ok?
    assert_equal "改名表", result.table.name
    assert_equal({ "a" => "1d6", "b" => "2d6+3" }, result.table.dice)
    assert_equal({ "3" => "当たり" }, result.table.data)
    assert_equal [AUTHOR, GUILD_OWNER], result.table.permissions, "权限随行带走"
    assert_nil @ct.fetch(chat_id: CHAT, name: "测试表"), "旧名必须消失（不是复制一份）"
    assert_equal 1, @ct.count_for(chat_id: CHAT), "改名后仍只有一行"
  end

  def test_rename_to_an_existing_name_is_refused_and_changes_nothing
    seed_private(name: "表甲")
    seed_private(name: "表乙")

    result = @ct.rename_table(chat_id: CHAT, old_name: "表甲", new_name: "表乙")

    assert result.already_exists?, "撞名按天狗回 already_exists"
    refute_nil @ct.fetch(chat_id: CHAT, name: "表甲"), "撞名时旧表必须原样不动"
    assert_empty @ct.fetch(chat_id: CHAT, name: "表乙").data
    assert_equal 2, @ct.count_for(chat_id: CHAT)
  end

  def test_rename_missing_table_is_not_found
    result = @ct.rename_table(chat_id: CHAT, old_name: "没有这张", new_name: "新名")

    assert result.not_found?, "源表不存在 = 天狗「テーブルがありません。」"
    refute result.success?
  end

  def test_rename_rejects_same_name_and_bad_arguments
    seed_private

    assert @ct.rename_table(chat_id: CHAT, old_name: "测试表",
                            new_name: "测试表").invalid_argument?
    assert @ct.rename_table(chat_id: 0, old_name: "测试表",
                            new_name: "别的").invalid_argument?
    assert @ct.rename_table(chat_id: CHAT, old_name: "测试表",
                            new_name: "  ").invalid_argument?
    assert_equal "测试表", @ct.fetch(chat_id: CHAT, name: "测试表").name,
                 "被拒的改名不得动数据"
  end

  def test_rename_runs_inside_a_transaction
    seed_private
    calls = []
    probe = Class.new(SimpleDelegator) do
      define_method(:transaction) do |*args, &blk|
        calls << args.first
        super(*args, &blk)
      end
    end.new(@conn)
    ct = TenguDB::CustomTables.new(probe, logger: Logger.new(IO::NULL))

    ct.rename_table(chat_id: CHAT, old_name: "测试表", new_name: "改名表")

    assert_equal [:immediate], calls,
                 "改名 = 改名+删旧两步，必须走 :immediate 事务（天狗无事务会留两张表）"
  end

  def test_rename_can_target_a_public_table
    # 天狗 updateTableName 支持 flag t（data.flag ? null : ids.channelId）：
    # 公共表也可改名（T3.3 审计修复：原稿公共 scope 拿私有 chat_id 查行 → 永远 not_found）
    seed_public(name: "公共旧名")

    result = @ct.rename_table(chat_id: OTHER_CHAT, old_name: "公共旧名",
                              new_name: "公共新名", scope: :public)

    assert result.ok?, "公共表改名必须可达（母本 flag t 分支）"
    assert_equal "public", result.table.scope
    assert_equal 0, result.table.chat_id, "公共行 chat_id 恒为 0 占位"
    assert_nil @ct.fetch(chat_id: 0, name: "公共旧名", scope: :public)
    refute_nil @ct.fetch(chat_id: 0, name: "公共新名", scope: :public)
    assert_equal 1, @ct.count_for(chat_id: 0, scope: "public"), "旧行消失、无多余行"
  end

  def test_rename_of_a_public_table_ignores_the_calling_chat_id
    seed_public(name: "公共甲")
    seed_public(name: "公共乙")

    # 撞名按 already_exists，且旧行原样不动
    dup = @ct.rename_table(chat_id: 0, old_name: "公共乙", new_name: "公共甲",
                           scope: :public)
    assert dup.already_exists?
    refute_nil @ct.fetch(chat_id: 0, name: "公共乙", scope: :public)

    # 换一个群的 id 调用仍能改到公共行（公共是全局的）
    ok = @ct.rename_table(chat_id: OTHER_CHAT, old_name: "公共乙",
                          new_name: "公共丙", scope: :public)
    assert ok.ok?
    assert_equal 2, @ct.count_for(chat_id: 0, scope: "public")
  end

  def test_edit_family_public_scope_reachable_with_zero_or_nil_chat_id
    # kimi T3.3 评审提案 #1（必修）的回归钉：公共行 chat_id 恒 0 占位、不来自
    # 入参——scope 覆盖必须在 chat_id nil 判**之前**，否则 edit 系 6 操作在
    # public + chat_id 0/nil 下恒 invalid_argument（天狗 flag t 传 null channelID）
    seed_public(name: "公共表")

    ok = @ct.update_dice(chat_id: 0, name: "公共表", dice_name: "d66",
                         dice_string: "1d6", scope: :public)
    assert ok.ok?, "public + chat_id=0 的 update_dice 必须可达（#{ok.status}）"

    del = @ct.delete_data(chat_id: nil, name: "公共表", data_index: "1",
                          scope: :public)
    refute del.invalid_argument?,
           "public + chat_id=nil 的 delete_data 不得误判入参非法"
  end

  # =========================================================================
  # C. 操作 3：改骰型（天狗 updateDice，db_wrapper.js:73）
  # =========================================================================

  def test_update_dice_merges_one_shortcut_and_keeps_the_others
    seed_private

    result = @ct.update_dice(chat_id: CHAT, name: "测试表",
                             dice_name: "b", dice_string: "2D6+3")

    assert result.ok?
    assert_equal({ "a" => "1d6", "b" => "2D6+3" }, result.table.dice,
                 "天狗深合并：只动那一个键，默认骰型 a 不能被抹掉")
  end

  def test_update_dice_overwrites_the_same_shortcut_idempotently
    seed_private
    @ct.update_dice(chat_id: CHAT, name: "测试表", dice_name: "b", dice_string: "2d6")
    @ct.update_dice(chat_id: CHAT, name: "测试表", dice_name: "b", dice_string: "3d6")

    assert_equal({ "a" => "1d6", "b" => "3d6" },
                 @ct.fetch(chat_id: CHAT, name: "测试表").dice)
  end

  def test_update_dice_supports_the_tengu_variable_marker
    # 天狗 updateDice 的 `/\+x/.test(diceString)` 分支（可変数の表）
    seed_private

    assert @ct.update_dice(chat_id: CHAT, name: "测试表",
                           dice_name: "c", dice_string: "1d6+x").ok?
    assert_equal "1d6+x", @ct.fetch(chat_id: CHAT, name: "测试表").dice_string("c")
  end

  def test_update_dice_missing_table_and_bad_arguments
    assert @ct.update_dice(chat_id: CHAT, name: "没有这张",
                           dice_name: "b", dice_string: "2d6").not_found?
    seed_private
    assert @ct.update_dice(chat_id: CHAT, name: "测试表",
                           dice_name: "", dice_string: "2d6").invalid_argument?
    assert @ct.update_dice(chat_id: CHAT, name: "测试表",
                           dice_name: "b", dice_string: "").invalid_argument?
    assert_equal({ "a" => "1d6" },
                 @ct.fetch(chat_id: CHAT, name: "测试表").dice,
                 "异常分支不得留下半截写入")
  end

  # =========================================================================
  # D. 操作 4：改条目（天狗 updateData，db_wrapper.js:77）
  # =========================================================================

  def test_update_data_stores_the_result_under_the_roll_index
    seed_private

    result = @ct.update_data(chat_id: CHAT, name: "测试表",
                             data_index: 3, data_string: "大成功")

    assert result.ok?
    assert_equal({ "3" => "大成功" }, result.table.data,
                 "出目键是字符串数字（天狗 String(array[2])）")
    assert_equal "大成功", result.table.data_entry(3), "整数索引应能取到"
    assert_equal({ "3" => "大成功" }, JSON.parse(raw("spec", name: "测试表"))["data"])
  end

  def test_update_data_treats_integer_and_string_index_identically
    seed_private

    @ct.update_data(chat_id: CHAT, name: "测试表", data_index: 4, data_string: "甲")
    result = @ct.update_data(chat_id: CHAT, name: "测试表",
                             data_index: "4", data_string: "乙")

    assert_equal({ "4" => "乙" }, result.table.data, "同键覆盖，不该出现两个键")
  end

  def test_update_data_with_sql_metacharacters_is_bound
    nasty = "結果'; DELETE FROM custom_tables; --"
    seed_private

    result = @ct.update_data(chat_id: CHAT, name: "测试表",
                             data_index: 2, data_string: nasty)

    assert result.ok?
    assert_equal nasty, result.table.data_entry(2)
    assert @conn.table_exists?("custom_tables")
  end

  def test_update_data_missing_table_and_bad_arguments
    assert @ct.update_data(chat_id: CHAT, name: "没有这张",
                           data_index: 1, data_string: "x").not_found?
    seed_private
    assert @ct.update_data(chat_id: CHAT, name: "测试表",
                           data_index: nil, data_string: "x").invalid_argument?
    # 空结果文本放行：空串拦截是**命令层**的事（天狗 ct_command 的
    # `if (!array[3])` 在 JS 假值语义下空串也拦），db 存层不做文本内容校验
    # （与「set_permissions 不内置 deletePermission 前三位限制」同一纪律；
    # 天狗存层本身也无校验——updateData 的 `array[3].replace(/\\/g,'')`
    # 输入 `\` 就能存出空串）。命令层规则归 T3.4。
    assert @ct.update_data(chat_id: CHAT, name: "测试表",
                           data_index: 1, data_string: "").ok?
  end

  # =========================================================================
  # E. 操作 5：改范围钳（天狗 updateAddition，db_wrapper.js:81）
  # =========================================================================

  def test_set_datarange_writes_is_use_max_min
    seed_private

    result = @ct.set_datarange(chat_id: CHAT, name: "测试表",
                               is_use: true, max: 15, min: 2)

    assert result.ok?
    range = result.table.datarange
    assert range.is_use, "isUse 应为 true"
    assert_equal 15, range.max
    assert_equal 2, range.min
    refute range.unbounded?, "给了上下限就不再是「不设限」"
    assert_equal({ "isUse" => true, "max" => 15, "min" => 2 },
                 JSON.parse(raw("datarange", name: "测试表")))
  end

  def test_datarange_null_means_unbounded_not_the_tengu_sentinel_values
    # §4.2 定案：天狗的 MAX/MIN_SAFE_INTEGER → JSON null（本表键是小整数出目，
    # 用 ±2^53 当哨兵毫无意义）
    seed_private
    @ct.set_datarange(chat_id: CHAT, name: "测试表", is_use: true, max: 15, min: 2)

    # 天狗 updateAddition 的默认参数 = 回到「不设限」
    result = @ct.set_datarange(chat_id: CHAT, name: "测试表", is_use: false)

    assert result.ok?
    assert result.table.datarange.unbounded?, "不给 max/min = 回到不设限（天狗同款）"
    refute result.table.datarange.is_use
    stored = JSON.parse(raw("datarange", name: "测试表"))
    assert_nil stored["max"], "落库必须是 null，绝不是 9007199254740991"
    assert_nil stored["min"]
  end

  def test_datarange_is_use_can_be_turned_on_with_null_bounds
    seed_private

    result = @ct.set_datarange(chat_id: CHAT, name: "测试表", is_use: true)

    assert result.table.datarange.is_use
    assert result.table.datarange.unbounded?, "开了钳但没给界 = 不设限"
    assert_equal %w[isUse max min].sort,
                 JSON.parse(raw("datarange", name: "测试表")).keys.sort,
                 "三个键都应存在（isUse 恒在，max/min 为 null）"
  end

  def test_datarange_rejects_inverted_bounds_and_keeps_the_old_value
    seed_private
    @ct.set_datarange(chat_id: CHAT, name: "测试表", is_use: true, max: 15, min: 2)

    result = @ct.set_datarange(chat_id: CHAT, name: "测试表",
                               is_use: true, max: 2, min: 9)

    assert result.invalid_argument?, "max < min 必须拒"
    assert_equal 15, @ct.fetch(chat_id: CHAT, name: "测试表").datarange.max,
                 "被拒的写入不得改动既有钳制"
  end

  def test_datarange_accepts_zero_and_negative_bounds
    seed_private

    result = @ct.set_datarange(chat_id: CHAT, name: "测试表",
                               is_use: true, max: 0, min: -5)

    assert result.ok?, "0 与负数是合法出目（天狗允许负 min）"
    assert_equal(-5, result.table.datarange.min)
  end

  def test_datarange_missing_table_is_not_found
    assert @ct.set_datarange(chat_id: CHAT, name: "没有这张",
                             is_use: true, max: 6, min: 1).not_found?
  end

  def test_data_range_value_object_helpers
    assert TenguDB::DataRange.unbounded.unbounded?
    refute TenguDB::DataRange.new(is_use: true, max: 6, min: 6).invalid_bounds?
    assert TenguDB::DataRange.new(is_use: true, max: 5, min: 6).invalid_bounds?
    assert_equal "isUse=false max=nil min=nil", TenguDB::DataRange.unbounded.to_s
    # 脏值降级：空串/垃圾 → 不设限（不当致命）
    assert TenguDB::DataRange.new(max: "", min: "abc").unbounded?
    assert_equal 12, TenguDB::DataRange.new(max: "12", min: "3").max,
                 "字符串数字应能转成整数（手工灌库的库）"
  end

  # =========================================================================
  # F. 操作 6：改权限（天狗 updatePermission，db_wrapper.js:105）
  # =========================================================================

  def test_set_permissions_replaces_the_whole_array_in_order
    seed_private

    result = @ct.set_permissions(chat_id: CHAT, name: "测试表",
                                 permissions: [AUTHOR, GUILD_OWNER, 5, 6])

    assert result.ok?
    assert_equal [AUTHOR, GUILD_OWNER, 5, 6], result.table.permissions
    assert_equal [AUTHOR, GUILD_OWNER, 5], result.table.admins, "admin 位 = 前三位"
    assert_equal [AUTHOR, GUILD_OWNER, 5, 6], JSON.parse(raw("permissions", name: "测试表"))
  end

  def test_permission_membership_and_admin_position_semantics
    # 天狗两套判据：updateDice/deleteDice 看**全体** permission；
    # updateTableName/deleteTable/addPermission 只看**前三位** admin 位
    result = seed_private(permissions: [AUTHOR, GUILD_OWNER, COUSER, 99])
    table = result.table

    assert table.permitted?(99), "第四位起是限定用户，可改骰型/条目"
    refute table.admin?(99), "但他不是 admin 位（不能改名/删表/改权限）"
    assert table.admin?(GUILD_OWNER)
    assert table.permitted?(GUILD_OWNER)
    refute table.permitted?(12345), "不在名单里的人一律不行"
    refute table.permitted?(0), "0 不是合法 user id（fail-closed）"
    refute table.permitted?(nil)
    refute table.permitted?("")
  end

  def test_permission_strings_from_hand_written_rows_still_match
    # 手工灌库写成字符串也应命中（比较侧一律 to_i 归一）
    seed_private(permissions: [AUTHOR])
    @conn.execute("UPDATE custom_tables SET permissions = ? WHERE name = ?",
                  [JSON.generate(["42", 7]), "测试表"])

    table = @ct.fetch(chat_id: CHAT, name: "测试表")
    assert_equal [42, 7], table.permissions, "字符串 id 归一为整数"
    assert table.admin?(7)
  end

  def test_set_permissions_rejects_empty_and_bad_lists
    seed_private

    assert @ct.set_permissions(chat_id: CHAT, name: "测试表",
                               permissions: []).invalid_argument?
    assert @ct.set_permissions(chat_id: CHAT, name: "测试表",
                               permissions: [0, nil]).invalid_argument?
    assert @ct.set_permissions(chat_id: CHAT, name: "测试表",
                               permissions: nil).invalid_argument?
    assert_equal [AUTHOR], @ct.fetch(chat_id: CHAT, name: "测试表").permissions,
                 "被拒的写入不得清空名单"
  end

  def test_set_permissions_missing_table_is_not_found
    assert @ct.set_permissions(chat_id: CHAT, name: "没有这张",
                               permissions: [1]).not_found?
  end

  # =========================================================================
  # G. 操作 7：发布到公共（天狗 publishTable，db_wrapper.js:65）
  # =========================================================================

  def test_publish_moves_the_private_row_to_the_public_scope
    seed_private(permissions: [AUTHOR, GUILD_OWNER])
    @ct.update_dice(chat_id: CHAT, name: "测试表", dice_name: "b", dice_string: "2d6+3")
    @ct.update_data(chat_id: CHAT, name: "测试表", data_index: 3, data_string: "当たり")
    @ct.set_datarange(chat_id: CHAT, name: "测试表", is_use: true, max: 15, min: 2)

    result = @ct.publish_table(chat_id: CHAT, name: "测试表")

    assert result.ok?
    published = result.table
    assert_equal "public", published.scope
    assert_equal 0, published.chat_id, "公共行的 chat_id 是 0 占位（§4.1）"
    assert_equal({ "a" => "1d6", "b" => "2d6+3" }, published.dice, "整行复制")
    assert_equal({ "3" => "当たり" }, published.data)
    assert_equal [AUTHOR, GUILD_OWNER], published.permissions
    assert_equal 15, published.datarange.max, "范围钳随行带过去"
    assert_nil @ct.fetch(chat_id: CHAT, name: "测试表"),
               "发布是「移」不是「复制一份留着」（ct_command/publishTable.js 删私有那步）"
    refute_nil @ct.fetch(chat_id: 0, name: "测试表", scope: "public")
    assert_equal 0, @ct.count_for(chat_id: CHAT)
    assert_equal 1, @ct.count_for(chat_id: 0, scope: "public")
  end

  def test_published_table_is_visible_from_other_chats
    seed_public(name: "広める表")

    resolved = @ct.resolve_table(name: "広める表", chat_id: OTHER_CHAT)
    assert resolved.public?
    assert_equal "1d6", resolved.table.dice_string("a"), "别的群也能查到公共表"
  end

  def test_publish_is_refused_when_a_public_table_of_the_same_name_exists
    seed_private(name: "衝突表", chat_id: CHAT)
    # 别的群先发布了一个同名公共表
    seed_private(name: "衝突表", chat_id: OTHER_CHAT)
    assert @ct.publish_table(chat_id: OTHER_CHAT, name: "衝突表").ok?

    result = @ct.publish_table(chat_id: CHAT, name: "衝突表")

    assert result.already_exists?,
           "公共同名必须拦（天狗「同名のテーブルがpublicに公開されています。」）"
    refute_nil @ct.fetch(chat_id: CHAT, name: "衝突表"),
               "冲突时私有表必须原样不动（整笔回滚）"
    assert_equal 1, @ct.count_for(chat_id: CHAT)
    assert_equal 1, @ct.count_for(chat_id: 0, scope: "public")
  end

  def test_publish_unique_fallback_returns_already_exists_and_keeps_both_sides
    # kimi T3.3 评审提案 #9：预查路径之外的 UNIQUE 兜底分支（并发/异常路径：
    # 预查公共为 nil、INSERT 却撞 UNIQUE）。用单例覆写让公共预查说谎，逼出
    # 事务内的 ConstraintException 分支
    seed_public(name: "衝突表", chat_id: OTHER_CHAT) # 公共侧预置同名
    seed_private(name: "衝突表")                      # 本群私有同名

    @ct.define_singleton_method(:fetch_row) do |scope_name, chat, key|
      scope_name == "public" ? nil : super(scope_name, chat, key)
    end

    result = @ct.publish_table(chat_id: CHAT, name: "衝突表")

    assert result.already_exists?, "UNIQUE 兜底必须回 already_exists"
    refute_nil @ct.fetch(chat_id: CHAT, name: "衝突表"), "私有表必须原样存活"
    assert_equal 1, @ct.count_for(chat_id: 0, scope: "public"), "公共侧仍是预置那条"
  end

  def test_publish_missing_table_is_not_found
    result = @ct.publish_table(chat_id: CHAT, name: "没有这张")

    assert result.not_found?, "天狗「テーブルがありません。」"
    assert_equal 0, @ct.count_for(chat_id: 0, scope: "public")
  end

  def test_publish_rejects_bad_arguments
    assert @ct.publish_table(chat_id: 0, name: "x").invalid_argument?
    assert @ct.publish_table(chat_id: CHAT, name: " ").invalid_argument?
    assert @ct.publish_table(chat_id: CHAT, name: nil).invalid_argument?
  end

  def test_publish_runs_inside_a_transaction
    seed_private
    calls = []
    probe = Class.new(SimpleDelegator) do
      define_method(:transaction) do |*args, &blk|
        calls << args.first
        super(*args, &blk)
      end
    end.new(@conn)
    ct = TenguDB::CustomTables.new(probe, logger: Logger.new(IO::NULL))

    ct.publish_table(chat_id: CHAT, name: "测试表")

    assert_equal [:immediate], calls,
                 "发布 = 读 + 写公共 + 删私有，必须走 :immediate 事务"
  end

  # =========================================================================
  # G2. flag t：公共行的读改写路径（母本所有 ct_command 的 data.flag 分支）
  # =========================================================================

  def test_public_rows_support_the_flag_t_style_edits
    # 天狗每个 ct_command 都带 flag t（`data.flag ? null : ids.channelId`）——
    # 改骰型/改条目/改权限/改钳制对**公共表**同样可用（T3.3 审计补齐覆盖）
    seed_public(name: "公共可改表")

    assert @ct.update_dice(chat_id: CHAT, name: "公共可改表", dice_name: "b",
                           dice_string: "2d6", scope: :public).ok?
    assert @ct.update_data(chat_id: CHAT, name: "公共可改表", data_index: 3,
                           data_string: "当たり", scope: :public).ok?
    assert @ct.set_permissions(chat_id: OTHER_CHAT, name: "公共可改表",
                               permissions: [AUTHOR, 5], scope: :public).ok?,
           "公共行的写路径与调用方在哪个群无关"
    assert @ct.set_datarange(chat_id: CHAT, name: "公共可改表", is_use: true,
                             max: 6, min: 1, scope: :public).ok?

    row = @ct.fetch(chat_id: 0, name: "公共可改表", scope: :public)
    assert_equal({ "a" => "1d6", "b" => "2d6" }, row.dice)
    assert_equal({ "3" => "当たり" }, row.data)
    assert_equal [AUTHOR, 5], row.permissions
    assert_equal 6, row.datarange.max
    assert_equal 1, @ct.count_for(chat_id: 0, scope: "public"), "没改出行分裂"
  end

  def test_flag_t_delete_paths_target_public_rows
    seed_public(name: "公共删改")
    @ct.update_dice(chat_id: CHAT, name: "公共删改", dice_name: "b",
                    dice_string: "2d6", scope: :public)

    assert @ct.delete_dice(chat_id: OTHER_CHAT, name: "公共删改",
                           dice_name: "b", scope: :public).ok?
    assert @ct.update_data(chat_id: CHAT, name: "公共删改", data_index: 5,
                           data_string: "x", scope: :public).ok?
    assert @ct.delete_data(chat_id: CHAT, name: "公共删改", data_index: 5,
                           scope: :public).ok?

    row = @ct.fetch(chat_id: 0, name: "公共删改", scope: :public)
    assert_equal({ "a" => "1d6" }, row.dice)
    assert_empty row.data
  end

  # =========================================================================
  # H. UNIQUE(scope, chat_id, name) 行为
  # =========================================================================

  def test_same_name_is_allowed_across_different_chats
    assert seed_private(name: "同名牌", chat_id: CHAT).ok?
    assert seed_private(name: "同名牌", chat_id: OTHER_CHAT).ok?,
           "跨群私有同名必须放行（UNIQUE 含 chat_id）"
    assert_equal 1, @ct.count_for(chat_id: CHAT)
    assert_equal 1, @ct.count_for(chat_id: OTHER_CHAT)
    refute_equal @ct.fetch(chat_id: CHAT, name: "同名牌").id,
                 @ct.fetch(chat_id: OTHER_CHAT, name: "同名牌").id,
                 "两个群各一行，互不相干"
  end

  def test_private_and_public_rows_may_share_a_name
    seed_private(name: "同名両scope", chat_id: CHAT)
    seed_private(name: "同名両scope", chat_id: OTHER_CHAT)
    assert @ct.publish_table(chat_id: OTHER_CHAT, name: "同名両scope").ok?

    assert_equal 1, @ct.count_for(chat_id: CHAT)
    assert_equal 1, @ct.count_for(chat_id: 0, scope: "public"),
                 "private 与 public 可同名共存（UNIQUE 首列是 scope）"
    # 两个 scope 下的同名行互不干扰（各查各的）
    refute_nil @ct.fetch(chat_id: CHAT, name: "同名両scope")
    refute_nil @ct.fetch(chat_id: 0, name: "同名両scope", scope: :public)
  end

  def test_public_scope_rejects_a_duplicate_name_directly
    seed_public(name: "公共重名")

    assert_raises(SQLite3::ConstraintException) do
      @conn.execute(
        "INSERT INTO custom_tables (scope, chat_id, name, spec, permissions, " \
        "datarange, author_id) VALUES ('public', 0, ?, '{}', '[]', '{}', 1)", ["公共重名"]
      )
    end
    assert_equal 1, @ct.count_for(chat_id: 0, scope: "public"),
                 "UNIQUE 必须真的兜住公共同名（不能指望应用层不写错）"
  end

  def test_chat_id_zero_is_refused_for_private_rows
    # 0 是公共行的占位：私有表写 chat_id=0 会与公共行抢 UNIQUE 槽位
    result = seed_private(name: "黑洞表", chat_id: 0)

    assert result.invalid_argument?, "私有表不得用 chat_id=0（那是公共占位）"
    assert_equal 0, @ct.count_for(chat_id: 0, scope: "public")
  end

  # =========================================================================
  # I. 操作 8：删骰型（天狗 deleteDice，db_wrapper.js:114）
  # =========================================================================

  def test_delete_dice_removes_only_that_shortcut
    seed_private
    @ct.update_dice(chat_id: CHAT, name: "测试表", dice_name: "b", dice_string: "2d6")
    @ct.update_dice(chat_id: CHAT, name: "测试表", dice_name: "c", dice_string: "1d8")

    result = @ct.delete_dice(chat_id: CHAT, name: "测试表", dice_name: "b")

    assert result.ok?
    assert result.changed?
    assert_equal({ "a" => "1d6", "c" => "1d8" }, result.table.dice)
  end

  def test_delete_dice_of_an_absent_shortcut_succeeds_without_change
    # 天狗 FieldValue.delete 哨兵删不存在的键不报错 → 幂等成功
    seed_private

    result = @ct.delete_dice(chat_id: CHAT, name: "测试表", dice_name: "zz")

    assert result.ok?, "删不存在的快捷名不算错误（Firestore 哨兵同款）"
    refute result.changed?, "但要能区分「真删掉了」与「本来就没有」"
    assert_equal({ "a" => "1d6" }, result.table.dice)
  end

  def test_delete_dice_missing_table_and_bad_arguments
    assert @ct.delete_dice(chat_id: CHAT, name: "没有这张", dice_name: "b").not_found?
    seed_private
    assert @ct.delete_dice(chat_id: CHAT, name: "测试表", dice_name: "").invalid_argument?
    assert_equal({ "a" => "1d6" }, @ct.fetch(chat_id: CHAT, name: "测试表").dice)
  end

  # =========================================================================
  # J. 操作 9：删条目（天狗 deleteData，db_wrapper.js:117）
  # =========================================================================

  def test_delete_data_removes_the_index_entry
    seed_private
    @ct.update_data(chat_id: CHAT, name: "测试表", data_index: 3, data_string: "甲")
    @ct.update_data(chat_id: CHAT, name: "测试表", data_index: 4, data_string: "乙")

    result = @ct.delete_data(chat_id: CHAT, name: "测试表", data_index: 3)

    assert result.ok?
    assert result.changed?
    assert_equal({ "4" => "乙" }, result.table.data)
  end

  def test_delete_data_of_an_absent_index_is_success_with_its_own_status
    # 天狗 ct_command/deleteData.js:12-13：
    #   if (!userTable.data[dataIndex]) return {result: true,
    #       message: 「入力した番号のデータは存在しません。」} ← **成功**
    seed_private

    result = @ct.delete_data(chat_id: CHAT, name: "测试表", data_index: 99)

    assert result.data_missing?, "「本来就没有」要有自己的状态，handler 据此选文案"
    assert result.success?, "但它必须算**成功**（天狗 result:true）"
    assert_equal({}, result.table.data)
  end

  def test_delete_data_missing_table_and_bad_arguments
    assert @ct.delete_data(chat_id: CHAT, name: "没有这张", data_index: 1).not_found?
    seed_private
    assert @ct.delete_data(chat_id: CHAT, name: "测试表", data_index: nil).invalid_argument?
  end

  # =========================================================================
  # K. 操作 10：删表（天狗 deleteTable，db_wrapper.js:132）
  # =========================================================================

  def test_delete_table_removes_the_private_row
    seed_private

    result = @ct.delete_table(chat_id: CHAT, name: "测试表")

    assert result.ok?
    assert result.changed?
    assert_nil @ct.fetch(chat_id: CHAT, name: "测试表")
    assert_equal 0, @ct.count_for(chat_id: CHAT)
  end

  def test_delete_table_of_an_absent_row_succeeds_without_change
    # Firestore 删不存在的 field 也回 true
    seed_private

    result = @ct.delete_table(chat_id: CHAT, name: "没有这张")

    assert result.ok?, "删不存在的表不算错误"
    refute result.changed?
    assert_equal 1, @ct.count_for(chat_id: CHAT), "别的表不许被误伤"
  end

  def test_delete_table_can_target_the_public_scope
    seed_public(name: "公共表")

    result = @ct.delete_table(chat_id: CHAT, name: "公共表", scope: :public)

    assert result.ok?
    assert result.changed?
    assert_equal 0, @ct.count_for(chat_id: 0, scope: "public")
  end

  def test_delete_table_ignores_chat_id_for_the_public_scope
    # 公共行的 chat_id 恒为 0；传不传 chat_id 都得删到同一行
    seed_public(name: "公共表")

    result = @ct.delete_table(chat_id: OTHER_CHAT, name: "公共表", scope: :public)

    assert result.ok?
    assert result.changed?, "公共表是全局的，与调用方在哪个群无关"
  end

  def test_delete_table_rejects_bad_arguments
    assert @ct.delete_table(chat_id: CHAT, name: "").invalid_argument?
    assert @ct.delete_table(chat_id: 0, name: "x").invalid_argument?, "私有表禁 chat_id=0"
    assert @ct.delete_table(chat_id: CHAT, name: "x", scope: :bogus).invalid_argument?
  end

  # =========================================================================
  # L. 操作 11：按频道查全部（天狗 getAllTable，db_wrapper.js:21）
  # =========================================================================

  def test_all_for_chat_returns_public_and_private_separately
    seed_private(name: "本群甲", chat_id: CHAT)
    seed_private(name: "本群乙", chat_id: CHAT)
    seed_private(name: "他群表", chat_id: OTHER_CHAT)
    seed_public(name: "公共甲")

    result = @ct.all_for_chat(chat_id: CHAT)

    assert_equal %w[本群乙 本群甲], result["private"].map(&:name),
                 "私有侧只含本群的表，且按名升序（ORDER BY 真实生效——不再 .sort 中和断言，评审提案 #10）"
    assert_equal %w[公共甲], result["public"].map(&:name),
                 "公共侧是全局的，与 chat_id 无关"
    refute_includes result["private"].map(&:name), "他群表",
                    "别的群的私有表不该混进来"
    assert_equal %w[private public], result.keys.sort
  end

  def test_all_for_chat_returns_empty_sections_when_nothing_exists
    result = @ct.all_for_chat(chat_id: CHAT)

    assert_empty result["public"]
    assert_empty result["private"]
  end

  def test_all_for_chat_refuses_a_zero_chat_id_instead_of_leaking_public
    assert_equal({ "public" => [], "private" => [] }, @ct.all_for_chat(chat_id: 0))
  end

  def test_list_filters_by_scope_and_orders_by_name
    seed_private(name: "zeta", chat_id: CHAT)
    seed_private(name: "alpha", chat_id: CHAT)

    assert_equal %w[alpha zeta], @ct.list(chat_id: CHAT).map(&:name)
    assert_equal %w[alpha zeta], @ct.list(chat_id: CHAT, scope: :private).map(&:name)
    assert_empty @ct.list(chat_id: CHAT, scope: :public)
  end

  # =========================================================================
  # M. 操作 12：查单表 + **查找顺序**（SearchTableDiceroll.js:13-24）
  # =========================================================================

  def test_lookup_order_constant_is_default_private_public
    # SearchTableDiceroll.js:14 原文注释：//default -> private -> publicで検索。
    assert_equal %i[builtin private public], TenguDB::CustomTables::LOOKUP_ORDER,
                 "查找顺序必须逐字保留：default(内置) → private → public"
    assert_equal %i[builtin private public], TenguDB::Resolution::SOURCES
  end

  def test_builtin_wins_when_the_same_name_exists_in_all_three_places
    seed_private(name: "三処表", chat_id: CHAT)
    seed_private(name: "三処表", chat_id: OTHER_CHAT)
    assert @ct.publish_table(chat_id: OTHER_CHAT, name: "三処表").ok?
    builtin = { "三処表" => { "dice" => { "a" => "9d9" } } }

    resolved = @ct.resolve_table(name: "三処表", chat_id: CHAT, builtin: builtin)

    assert resolved.builtin?, "三处同名时必须命中**内置**（第一顺位）"
    refute resolved.private?
    refute resolved.public?
    assert_equal({ "a" => "9d9" }, resolved.builtin["dice"])
    assert_equal "内置", resolved.source_label
  end

  def test_private_wins_over_public_when_there_is_no_builtin
    seed_private(name: "両処表", chat_id: CHAT)
    seed_private(name: "両処表", chat_id: OTHER_CHAT)
    assert @ct.publish_table(chat_id: OTHER_CHAT, name: "両処表").ok?
    @ct.update_dice(chat_id: CHAT, name: "両処表", dice_name: "a", dice_string: "4d4")

    resolved = @ct.resolve_table(name: "両処表", chat_id: CHAT)

    assert resolved.private?, "无内置时私有先于公共（第二顺位）"
    assert_equal "4d4", resolved.table.dice_string("a"), "命中的是**本群**那张"
    assert_equal "本群", resolved.source_label
  end

  def test_public_is_the_last_resort
    seed_public(name: "公共優先表")

    resolved = @ct.resolve_table(name: "公共優先表", chat_id: CHAT)

    assert resolved.public?, "前两级都没有才落到公共（第三顺位）"
    assert_equal "1d6", resolved.table.dice_string("a")
    assert_equal "公共", resolved.source_label
  end

  def test_resolve_reports_not_found_without_blowing_up
    resolved = @ct.resolve_table(name: "哪也没有", chat_id: CHAT, builtin: {})

    refute resolved.found?
    assert_equal :public, resolved.source, "没命中时来源恒为最末一级"
    assert_nil resolved.table
    assert_nil resolved.builtin
  end

  def test_resolve_falls_back_to_public_from_a_different_chat
    seed_public(name: "跨群公共")

    resolved = @ct.resolve_table(name: "跨群公共", chat_id: OTHER_CHAT)

    assert resolved.public?
    assert_equal 0, resolved.table.chat_id, "命中的是公共行（chat_id=0 占位）"
  end

  def test_resolve_without_chat_id_skips_the_private_level
    # 天狗 getUserTable(null, name) 的语义：只查公共
    seed_private(name: "私有表")

    resolved = @ct.resolve_table(name: "私有表", chat_id: nil)

    refute resolved.found?, "不传 chat_id = 不查私有级（天狗同款）"
    refute resolved.private?
  end

  def test_builtin_lookup_folds_case_like_tengu_does
    # 天狗内层：`this.datatable.dataTable[tableName.toLowerCase()]`
    seed_private(name: "Latin表", chat_id: CHAT)
    builtin = { "latin表" => { "dice" => {} } }

    hit = @ct.resolve_table(name: "LATIN表", chat_id: CHAT, builtin: builtin)
    assert hit.builtin?, "内置源按 downcase 键取（天狗同款）"

    # DB 侧是精确匹配（Firestore field 名精确匹配）：表名存的是 "Latin表"，
    # 查 "LATIN表" 查不到 → 内置没命中时也不能靠大小写糊弄过去
    miss = @ct.resolve_table(name: "LATIN表", chat_id: CHAT, builtin: {})
    refute miss.found?, "DB 侧不做大小写折叠（天狗 Firestore 字段名精确匹配）"
    assert_equal "Latin表", @ct.fetch(chat_id: CHAT, name: "Latin表").name
  end

  def test_builtin_source_may_be_a_callable
    seen = []
    source = lambda do |key|
      seen << key
      { "dice" => {} } if key == "呼出表"
    end

    resolved = @ct.resolve_table(name: "呼出表", chat_id: CHAT, builtin: source)

    assert resolved.builtin?, "内置源也可传 callable（引擎侧现取）"
    assert_equal ["呼出表"], seen, "传进去的必须是 downcase 后的表名"
  end

  def test_fetch_is_a_single_scope_lookup_without_the_lookup_order
    seed_private(name: "直查表", chat_id: CHAT)

    refute_nil @ct.fetch(chat_id: CHAT, name: "直查表"), "本群私有行直查得到"
    assert_nil @ct.fetch(chat_id: CHAT, name: "直查表", scope: :public),
               "直查不带级联（不会因为同名公共行而回私有那张）"
    assert_nil @ct.fetch(chat_id: OTHER_CHAT, name: "直查表"), "别的群直查不到"
  end

  # =========================================================================
  # N. 事务纪律
  # =========================================================================

  def test_every_spec_read_modify_write_runs_inside_an_immediate_transaction
    seed_private
    calls = []
    probe = Class.new(SimpleDelegator) do
      define_method(:transaction) do |*args, &blk|
        calls << args.first
        super(*args, &blk)
      end
    end.new(@conn)
    ct = TenguDB::CustomTables.new(probe, logger: Logger.new(IO::NULL))

    ct.update_dice(chat_id: CHAT, name: "测试表", dice_name: "b", dice_string: "2d6")
    ct.update_data(chat_id: CHAT, name: "测试表", data_index: 3, data_string: "x")
    ct.set_datarange(chat_id: CHAT, name: "测试表", is_use: true, max: 6, min: 1)
    ct.set_permissions(chat_id: CHAT, name: "测试表", permissions: [AUTHOR, 1])
    ct.delete_dice(chat_id: CHAT, name: "测试表", dice_name: "b")
    ct.delete_data(chat_id: CHAT, name: "测试表", data_index: 3)

    assert_equal [:immediate] * 6, calls,
                 "spec/permissions/datarange 的读改写都必须走 :immediate 事务"
  end

  def test_a_failure_inside_the_transaction_rolls_the_whole_thing_back
    seed_private
    before = raw("spec", name: "测试表")

    assert_raises(RuntimeError) do
      @conn.transaction(:immediate) do
        @conn.execute("UPDATE custom_tables SET name = '改坏了' WHERE name = ?",
                      ["测试表"])
        raise "boom"
      end
    end

    assert_equal before, raw("spec", name: "测试表")
    refute_nil @ct.fetch(chat_id: CHAT, name: "测试表"), "异常必须回滚"
  end

  def test_custom_tables_is_reentrant_inside_an_outer_transaction
    seed_private

    @conn.transaction(:immediate) do
      assert @ct.update_dice(chat_id: CHAT, name: "测试表",
                             dice_name: "b", dice_string: "2d6").ok?
      assert @ct.update_data(chat_id: CHAT, name: "测试表",
                             data_index: 1, data_string: "x").ok?
    end

    table = @ct.fetch(chat_id: CHAT, name: "测试表")
    assert_equal "2d6", table.dice_string("b")
    assert_equal "x", table.data_entry(1)
  end

  def test_storage_failure_is_reported_as_error_not_as_a_missing_table
    probe = Class.new(SimpleDelegator) do
      define_method(:transaction) { |*_a, &_b| raise SQLite3::BusyException, "locked" }
    end.new(@conn)
    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |msg| warnings << msg }
    ct = TenguDB::CustomTables.new(probe, logger: logger)

    result = ct.update_dice(chat_id: CHAT, name: "测试表",
                            dice_name: "b", dice_string: "2d6")

    assert result.error?, "存储层失败必须与「表不存在」区分开"
    refute result.not_found?
    assert_equal 1, warnings.size
    assert_includes warnings.first, "SQLite3::BusyException",
                    "锁竞争要留结构性日志（只有异常类名，无用户正文）"
  end

  # =========================================================================
  # O. JSON 列容错（坏 JSON 不当致命，参照 db/bank.rb parse_array）
  # =========================================================================

  def test_corrupt_spec_column_degrades_to_an_empty_table_with_a_warning
    seed_private
    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |msg| warnings << msg }
    ct = TenguDB::CustomTables.new(@conn, logger: logger)
    @conn.execute("UPDATE custom_tables SET spec = '这不是 JSON' WHERE name = ?",
                  ["测试表"])

    table = ct.fetch(chat_id: CHAT, name: "测试表")

    refute_nil table, "坏 spec 不得让整张表读不出来"
    assert_empty table.dice
    assert_empty table.data
    assert_equal 1, warnings.size
    assert_includes warnings.first, "spec"
  end

  def test_corrupt_permissions_and_datarange_columns_degrade_gracefully
    seed_public(name: "损坏表")
    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |msg| warnings << msg }
    ct = TenguDB::CustomTables.new(@conn, logger: logger)
    @conn.execute(
      "UPDATE custom_tables SET permissions = '{oops', datarange = '[]' WHERE name = ?",
      ["损坏表"]
    )

    table = ct.fetch(chat_id: 0, name: "损坏表", scope: :public)

    assert_empty table.permissions, "坏 permissions 按空数组处理"
    assert table.datarange.unbounded?, "非对象的 datarange 按不设限处理"
    assert_equal 2, warnings.size
  end

  def test_spec_with_wrong_inner_types_degrades_to_empty_maps
    seed_private
    @conn.execute(
      "UPDATE custom_tables SET spec = ? WHERE name = ?",
      [JSON.generate({ "dice" => "不是 map", "data" => [1, 2] }), "测试表"]
    )

    table = @ct.fetch(chat_id: CHAT, name: "测试表")
    assert_empty table.dice
    assert_empty table.data
  end

  def test_empty_columns_are_treated_as_defaults
    seed_private
    @conn.execute(
      "UPDATE custom_tables SET spec = '', permissions = '', datarange = '' WHERE name = ?",
      ["测试表"]
    )

    table = @ct.fetch(chat_id: CHAT, name: "测试表")
    assert_empty table.dice
    assert_empty table.permissions
    assert table.datarange.unbounded?
  end

  # =========================================================================
  # P. 反射守卫 + 迁移联动（群升级不丢自定义表）
  # =========================================================================

  def test_custom_tables_table_is_covered_by_migration_tables
    assert @conn.table_exists?("custom_tables"), "sanity：schema.sql 应建出 custom_tables"
    assert_includes @conn.column_names("custom_tables"), "chat_id"

    assert_includes TelegramBot::Migration::TABLES, "custom_tables",
                 "custom_tables 含 chat_id 却不在 Migration::TABLES（群升级会丢全部表）"
  end

  def test_chat_upgrade_moves_private_tables_and_leaves_public_rows_alone
    seed_private(name: "迁移表", chat_id: -123_456_789)
    seed_public(name: "不受影响表")

    result = TelegramBot::Migration.new(connection: @conn, logger: Logger.new(IO::NULL))
             .handle(chat_id: -123_456_789, migrate_to: -1_009_876_543_210)

    refute_nil result
    assert_equal 1, result.rows["custom_tables"], "私有表必须跟着群走"

    moved = @ct.fetch(chat_id: -1_009_876_543_210, name: "迁移表")
    refute_nil moved, "升级后自定义表必须还在（否则群升级=表全丢）"
    assert_nil @ct.fetch(chat_id: -123_456_789, name: "迁移表")
    refute_nil @ct.fetch(chat_id: 0, name: "不受影响表", scope: :public),
               "公共行 chat_id=0，不该被 re-key 波及"
  end

  def test_migration_of_chats_holding_same_named_tables_does_not_break_uniqueness
    # 两个群各有同名私有表；老群迁到已有同名表的群 → 撞 UNIQUE → 整笔回滚
    seed_private(name: "同名迁移", chat_id: -1_000)
    seed_private(name: "同名迁移", chat_id: -2_000)
    # 把 -2_000 侧先改挂到 -1_001，模拟「目标群已有一张同名表」
    @conn.execute("UPDATE custom_tables SET chat_id = -1_001 WHERE chat_id = -2_000")

    assert_raises(SQLite3::ConstraintException) do
      TelegramBot::Migration.new(connection: @conn, logger: Logger.new(IO::NULL))
        .handle(chat_id: -1_000, migrate_to: -1_001)
    end

    refute_nil @ct.fetch(chat_id: -1_000, name: "同名迁移"), "冲突时整体不动"
    assert_equal 1, @ct.count_for(chat_id: -1_001), "目标侧也不许被改坏"
  end

  # =========================================================================
  # Q. 值对象
  # =========================================================================

  def test_value_object_helpers
    seed_private(name: "对象表", permissions: [AUTHOR, GUILD_OWNER, 5, 6])
    @ct.update_data(chat_id: CHAT, name: "对象表", data_index: 2, data_string: "結果")
    table = @ct.fetch(chat_id: CHAT, name: "对象表")

    assert table.private?
    refute table.public?
    assert_equal "1d6", table.dice_string("a")
    assert_nil table.dice_string("nope")
    assert_equal "結果", table.data_entry("2")

    hash = table.to_h
    assert_equal %i[author_id chat_id created_at data datarange dice id name
                    permissions scope updated_at].sort, hash.keys.sort,
                 "to_h 键集固定（诊断/日志靠它）"
    assert_equal({ "isUse" => false, "max" => nil, "min" => nil }, hash[:datarange])

    resolution = @ct.resolve_table(name: "对象表", chat_id: CHAT)
    assert_equal %i[builtin source table].sort, resolution.to_h.keys.sort
  end

  def test_value_objects_are_frozen
    seed_private
    table = @ct.fetch(chat_id: CHAT, name: "测试表")

    assert table.frozen?, "值对象对外不可变（调用方手滑改了不会污染后续读）"
    assert table.dice.frozen?
    assert table.data.frozen?
    assert table.permissions.frozen?
    assert table.datarange.frozen?
  end

  def test_mutation_result_predicates_are_disjoint
    ok = TenguDB::MutationResult.ok(nil)
    not_found = TenguDB::MutationResult.not_found
    dup = TenguDB::MutationResult.already_exists
    bad = TenguDB::MutationResult.invalid_argument
    missing = TenguDB::MutationResult.data_missing(nil)
    err = TenguDB::MutationResult.error(SQLite3::Exception)

    [ok, not_found, dup, bad, missing, err].each do |r|
      assert_kind_of TenguDB::MutationResult, r
      assert_equal 1, [
        r.ok?, r.not_found?, r.already_exists?, r.invalid_argument?,
        r.data_missing?, r.error?
      ].count(true), "每个结果只能命中一个状态谓词（#{r.status}）"
    end
    assert ok.success?
    assert missing.success?, "「本来就没有该出目」也算成功（天狗 result:true）"
    refute not_found.success?
    refute err.success?
    assert_equal %i[status table error changed].sort, err.to_h.keys.sort
  end
end
