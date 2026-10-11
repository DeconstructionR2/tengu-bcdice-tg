# frozen_string_literal: true

# ============================================================================
# test/db/test_bank_test.rb — 天狗银行 DB 层（T3.2）
#
# 覆盖计划 §8 T3.2 / §4.2 验收单的银行四条（存取钱 / 存取道具 / 查账 / 清零）
# 与 §13 第 4 项（全量忠实移植）、§13 第 8 项（话题级作用域）：
#
#   - 存取钱：首次建档 / 累加 / 取钱 / **透支允许**（余额可为负）
#   - 流水断言：money_record 是 **JSON 数组**、逐笔按顺序、0 不入流水
#   - 存取道具：追加 / 元素级删除 / **quirk 修复实证**（删「ポット」不误伤
#     「ポット改」）/ 账上没有该道具 → item_missing
#   - 查账：不改账；空账返回 nil
#   - 清零：DELETE 本话题那一行，**别的本不动**；空账也报成功（天狗语义）
#   - 结算（statement）：出流水后清零 / 查无此账早退且不删
#   - 话题级隔离：两个话题两本账互不串；E4 归一（General=1 与群级 0 同一本）
#   - 事务回滚：块内异常 → 一行都不留；range 越界 → 不写半截
#   - int64 边界 / 入参守卫 / JSON 列损坏时的容错
#   - **反射守卫**：bank_record 必须在 Migration::TABLES 内（群升级不丢账）
#   - **迁移联动**：群升级后 bank_record 行真的跟着 chat_id 走
#
# 全程 :memory: 库，零文件、零联网。
# ============================================================================

require "minitest/autorun"
require "json"
require "logger"
require "delegate"
require_relative "../../db/connection"
require_relative "../../db/bank"
require_relative "../../bot/migration"

class TestBank < Minitest::Test
  BIG_CHAT_ID = -1_000_000_000_123_456_789 # 超 32 位有效位（§0.2.4）
  OTHER_CHAT_ID = -1_000_000_000_987_654_321
  TOPIC = 88
  OTHER_TOPIC = 99
  GENERAL_TOPIC = 1 # forum 的 General 话题（E4：归群级）

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @bank = TenguDB::Bank.new(@conn)
  end

  def teardown
    @conn.close
  end

  # 原始列值（验「落库形态」而不是只有对象视图）
  def raw(chat_id: BIG_CHAT_ID, thread_id: 0, column: "money_record")
    @conn.get_first_value(
      "SELECT #{column} FROM bank_record WHERE chat_id = ? AND thread_id = ?",
      [chat_id, thread_id]
    )
  end

  # =========================================================================
  # A. 存取钱（天狗 recordMoney ← m+N / m-N）
  # =========================================================================

  def test_first_deposit_creates_the_ledger
    result = @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)

    assert result.ok?, "首次存钱应成功（天狗：无数据→建档）"
    record = result.record
    assert_equal 100, record.sum_money
    assert_equal [100], record.money_record, "首次流水就是这一笔"
    assert_empty record.item_record
    assert_equal 0, record.thread_id, "未传 thread 时落群级行"
    assert_equal BIG_CHAT_ID, record.chat_id, "64 位 chat_id 不能被截断"
  end

  def test_first_ledger_row_stores_json_arrays_not_delimited_string
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)

    assert_equal "[100]", raw, "money_record 必须是 JSON 数组（§4.1 定案，非「、」字符串）"
    assert_equal "[]", raw(column: "item_record")
    assert_kind_of Array, JSON.parse(raw), "解析回来必须是数组"
  end

  def test_deposits_accumulate_and_the_flow_keeps_every_entry
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 250)
    result = @bank.save_money(chat_id: BIG_CHAT_ID, amount: -50)

    assert_equal 300, result.record.sum_money
    assert_equal [100, 250, -50], result.record.money_record,
                 "流水逐笔按发生顺序（含负数），断言到元素级"
    assert_equal [100, 250, -50], JSON.parse(raw)
  end

  def test_zero_amount_makes_no_flow_entry
    # 天狗：`if (money != 0)` 才追加流水（0 是 JS 的 falsy）
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    result = @bank.save_record(chat_id: BIG_CHAT_ID, money: 0)

    assert result.ok?
    assert_equal 100, result.record.sum_money
    assert_equal [100], result.record.money_record, "金额 0 不该进流水（天狗同款）"
  end

  def test_overdraft_is_allowed_and_balance_goes_negative
    # §4.1 / §4.2：sum_money 可为负（天狗**无**透支校验，忠实保留）
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    result = @bank.save_money(chat_id: BIG_CHAT_ID, amount: -9999)

    assert result.ok?, "透支必须允许（不得被当成错误）"
    assert_equal(-9899, result.record.sum_money, "余额应为负")
    assert_equal(-9899, raw(column: "sum_money"))
  end

  def test_int64_boundaries_are_accepted_and_overflow_is_refused
    max = TenguDB::Bank::INT64_MAX
    first = @bank.save_money(chat_id: BIG_CHAT_ID, amount: max)
    assert first.ok?, "int64 上界本身合法"

    over = @bank.save_money(chat_id: BIG_CHAT_ID, amount: 1)
    assert over.error?, "超出 int64 必须拒绝（否则 SQLite 静默存成 REAL 污染余额）"
    assert_equal max, @bank.fetch(chat_id: BIG_CHAT_ID).sum_money,
                 "拒绝时余额不许被改动"

    min = TenguDB::Bank::INT64_MIN
    other = @bank.save_money(chat_id: BIG_CHAT_ID, thread_id: TOPIC, amount: min)
    assert other.ok?, "int64 下界本身合法"
    assert_equal min, other.record.sum_money
  end

  # =========================================================================
  # B. 存取道具（天狗 recordItem ← i+名字 / i-名字）
  # =========================================================================

  def test_items_accumulate_as_json_array
    @bank.add_item(chat_id: BIG_CHAT_ID, name: "茶")
    result = @bank.add_item(chat_id: BIG_CHAT_ID, name: "茶")

    assert result.ok?
    assert_equal %w[茶 茶], result.record.item_record, "同名道具按件计（天狗同款，不去重）"
    assert_equal '["茶","茶"]', raw(column: "item_record")
  end

  def test_item_names_with_sql_metacharacters_round_trip
    nasty = %q{茶'; DROP TABLE bank_record; --}
    result = @bank.add_item(chat_id: BIG_CHAT_ID, name: nasty)

    assert result.ok?
    assert_equal [nasty], result.record.item_record, "值必须走绑定，不得拼进 SQL"
    assert @conn.table_exists?("bank_record")
  end

  def test_removing_an_item_is_element_wise_not_substring
    # §4.1 注记：**quirk 修复实证**。天狗 tb_db_wrapper.js:38 是
    #   `data.item_record = String(data.item_record).replace(item, '')`
    # ——删的是首个**子串**，与上面 checkRecSplit 的「完全相等」判据不一致：
    #   账 = 「ポット改、ポット」、删「ポット」
    #     checkRecSplit → 命中（有个元素正好等于「ポット」）→ 放行
    #     replace      → 首个子串在「ポッ**ト**改」里 → 结果「改、ポット」
    #   即：删掉的**不是**用户要的那一件，还顺手毁了另一件的前缀。
    # 本项目改为元素级删除（只摘掉第一个完全相等的元素）。
    @bank.add_item(chat_id: BIG_CHAT_ID, name: "ポット改")
    @bank.add_item(chat_id: BIG_CHAT_ID, name: "ポット")
    result = @bank.remove_item(chat_id: BIG_CHAT_ID, name: "ポット")

    assert result.ok?, "checkRecSplit 命中后本该删成功"
    assert_equal ["ポット改"], result.record.item_record,
                 "删「ポット」绝不能顺带削掉「ポット改」的前缀（字符串 replace 的坑已修）"
  end

  def test_removing_a_prefix_only_item_is_refused_not_silently_mangled
    # 同上 quirk 的另一半：账上只有「ポット改」时，天狗的 checkRecSplit 判 false
    # → saveRecord 回 null → 「そのアイテムの記録はありません。」，
    # **不会**去动「ポット改」（删不到就不删，不是删坏）。
    @bank.add_item(chat_id: BIG_CHAT_ID, name: "ポット改")
    result = @bank.remove_item(chat_id: BIG_CHAT_ID, name: "ポット")

    assert result.item_missing?, "账上没有完全相等的元素就不该删（天狗同款判据）"
    assert_equal ["ポット改"], @bank.fetch(chat_id: BIG_CHAT_ID).item_record,
                 "删不到就不许顺带削掉别的东西"
  end

  def test_removing_an_item_only_drops_the_first_exact_match
    @bank.add_item(chat_id: BIG_CHAT_ID, name: "茶")
    @bank.add_item(chat_id: BIG_CHAT_ID, name: "茶")
    result = @bank.remove_item(chat_id: BIG_CHAT_ID, name: "茶")

    assert_equal ["茶"], result.record.item_record, "按件取走一件，不是清空所有同名"
  end

  def test_removing_an_absent_item_reports_item_missing_and_keeps_the_row
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    result = @bank.remove_item(chat_id: BIG_CHAT_ID, name: "不存在")

    assert result.item_missing?, "天狗 saveRecord → null（该道具没有记录）"
    assert_equal 100, @bank.fetch(chat_id: BIG_CHAT_ID).sum_money, "失败的删除不许改账"
    assert_empty @bank.fetch(chat_id: BIG_CHAT_ID).item_record
  end

  def test_item_only_operations_leave_money_untouched
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    result = @bank.add_item(chat_id: BIG_CHAT_ID, name: "茶")

    assert_equal 100, result.record.sum_money, "只存道具不得动钱（天狗 money 默认 0）"
    assert_equal [100], result.record.money_record, "money=0 不入流水"
    assert_equal ["茶"], result.record.item_record
  end

  def test_first_write_with_only_an_item_still_opens_the_ledger
    # 天狗 saveRecord 的「データなし」分支**无条件建档**（money 默认 0，
    # money_record = String(0) = "0"）→ 本项目是 sum=0 / money_record=[0]。
    # 后果（天狗原样行为）：空账上第一次**删**道具不会报「没有该道具」，
    # 而是开出一个空账。单测把这个副作用钉住，免得日后被当成 bug 顺手改掉。
    result = @bank.add_item(chat_id: BIG_CHAT_ID, name: "茶")

    assert result.ok?
    assert_equal 0, result.record.sum_money
    assert_equal [0], result.record.money_record, "对应天狗的 money_record=String(0)"
    assert_equal ["茶"], result.record.item_record
  end

  def test_first_write_that_is_only_a_delete_still_opens_an_empty_ledger
    # 天狗 saveRecord 的「データなし、新規作成」分支**无条件建档**，
    # 且 `item_record: item ? String(item) : ""` **不看 isItemAdd**：
    # 空账上执行「取道具 茶」→ 账被建出来，且 item_record 直接变成「茶」
    # （看起来像「取走道具反而多了一件」，是真实 quirk，忠实保留）。
    # 玩家随后查账会看到 0 元 + 一件「茶」——这是天狗的原样行为。
    result = @bank.remove_item(chat_id: BIG_CHAT_ID, name: "茶")

    assert result.ok?, "天狗此路径不判「没有该道具」，而是开账（本项目忠实保留）"
    assert_equal 0, result.record.sum_money
    assert_equal ["茶"], result.record.item_record,
                 "quirk：空账上「取道具」反而把那件道具记进了账（天狗同款）"
    assert_equal 1, @bank.count_for(chat_id: BIG_CHAT_ID)
  end

  def test_remove_item_requires_a_non_blank_name
    result = @bank.remove_item(chat_id: BIG_CHAT_ID, name: "")
    assert result.error?, "空道具名无意义（否则会退化成删第一个元素）"
    assert_equal 0, @bank.count_for(chat_id: BIG_CHAT_ID), "被拒的入参不该建出账本"
  end

  # =========================================================================
  # C. 查账（天狗 getRecord ← `check`）
  # =========================================================================

  def test_fetch_returns_nothing_for_an_unknown_ledger
    assert_nil @bank.fetch(chat_id: BIG_CHAT_ID)
    assert_nil @bank.fetch(chat_id: BIG_CHAT_ID, thread_id: TOPIC)
  end

  def test_fetch_does_not_mutate_anything
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    @bank.add_item(chat_id: BIG_CHAT_ID, name: "茶")

    before = raw
    @bank.fetch(chat_id: BIG_CHAT_ID)
    @bank.fetch(chat_id: BIG_CHAT_ID)

    assert_equal before, raw, "查账必须只读（天狗 getRecord 不写库）"
    assert_equal 1, @bank.count_for(chat_id: BIG_CHAT_ID)
  end

  def test_fetched_record_is_immutable
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    record = @bank.fetch(chat_id: BIG_CHAT_ID)

    assert record.frozen?
    assert record.money_record.frozen?
    assert_raises(FrozenError) { record.item_record << "茶" }
  end

  def test_money_flow_text_reproduces_tengu_visual_form
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: -50)
    record = @bank.fetch(chat_id: BIG_CHAT_ID)

    # 天狗：money_record.replace(/、/g, " + ").replace(/\s\+\s-/g, " - ")
    assert_equal "100 - 50", record.money_flow_text,
                 "负数连排应显示成减法（与天狗拼出的算式同形）"
    assert_nil TenguDB::BankRecord.new(
      chat_id: 1, thread_id: 0, sum_money: 0, money_record: [], item_record: []
    ).money_flow_text, "无流水时是 nil（天狗的假值分支）"
  end

  def test_broken_json_column_degrades_to_empty_instead_of_raising
    @conn.execute(
      "INSERT INTO bank_record (chat_id, thread_id, sum_money, money_record, item_record) " \
      "VALUES (?, 0, 4200, 'not-json', '[[[')", [BIG_CHAT_ID]
    )

    record = nil
    capture_io { record = @bank.fetch(chat_id: BIG_CHAT_ID) }

    assert_equal 4200, record.sum_money, "余额仍要读得出来（用户要看到现状）"
    assert_empty record.money_record
    assert_empty record.item_record
  end

  # =========================================================================
  # D. 清零（天狗 deleteRecord ← `reset`）
  # =========================================================================

  def test_clear_removes_only_the_target_scope_row
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    @bank.save_money(chat_id: BIG_CHAT_ID, thread_id: TOPIC, amount: 700)
    @bank.save_money(chat_id: OTHER_CHAT_ID, amount: 900)

    assert @bank.clear(chat_id: BIG_CHAT_ID, thread_id: TOPIC)

    assert_nil @bank.fetch(chat_id: BIG_CHAT_ID, thread_id: TOPIC), "目标话题被清空"
    assert_equal 100, @bank.fetch(chat_id: BIG_CHAT_ID).sum_money, "同群群级行不受影响"
    assert_equal 900, @bank.fetch(chat_id: OTHER_CHAT_ID).sum_money, "别群不受影响"
  end

  def test_clear_on_an_empty_ledger_still_succeeds
    # 天狗 deleteChannel：Firestore 删不存在的文档也返回 true → 照播「已重置」
    assert @bank.clear(chat_id: BIG_CHAT_ID, thread_id: TOPIC)
    assert @bank.clear(chat_id: BIG_CHAT_ID)
  end

  # =========================================================================
  # E. 结算（天狗 getRecordResult ← `result`）
  # =========================================================================

  def test_statement_returns_the_ledger_then_clears_it
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 250)

    record, attempted, deleted = @bank.statement(chat_id: BIG_CHAT_ID)

    assert attempted, "结算应真的执行了清零"
    assert deleted
    assert_equal 350, record.sum_money
    assert_equal [100, 250], record.money_record, "报表取的是清零**前**的流水"
    assert_nil @bank.fetch(chat_id: BIG_CHAT_ID), "结算后账本为空"
  end

  def test_statement_on_an_unknown_ledger_early_exits_without_deleting
    record, attempted, deleted = @bank.statement(chat_id: BIG_CHAT_ID)

    assert_nil record
    refute attempted, "天狗：查无记录直接早退，连 DELETE 都不发"
    refute deleted
  end

  def test_statement_does_not_touch_the_sibling_topic
    @bank.save_money(chat_id: BIG_CHAT_ID, thread_id: TOPIC, amount: 100)
    @bank.save_money(chat_id: BIG_CHAT_ID, thread_id: OTHER_TOPIC, amount: 500)

    @bank.statement(chat_id: BIG_CHAT_ID, thread_id: TOPIC)

    assert_nil @bank.fetch(chat_id: BIG_CHAT_ID, thread_id: TOPIC)
    assert_equal 500, @bank.fetch(chat_id: BIG_CHAT_ID, thread_id: OTHER_TOPIC).sum_money,
                 "结算只清自己那一本"
  end

  # =========================================================================
  # F. 话题级作用域（§13 第 8 项 + E4 归一）
  # =========================================================================

  def test_two_topics_keep_two_independent_ledgers
    @bank.save_money(chat_id: BIG_CHAT_ID, thread_id: TOPIC, amount: 100)
    @bank.save_money(chat_id: BIG_CHAT_ID, thread_id: OTHER_TOPIC, amount: 500)
    @bank.add_item(chat_id: BIG_CHAT_ID, thread_id: TOPIC, name: "A的话")

    a = @bank.fetch(chat_id: BIG_CHAT_ID, thread_id: TOPIC)
    b = @bank.fetch(chat_id: BIG_CHAT_ID, thread_id: OTHER_TOPIC)

    assert_equal 100, a.sum_money
    assert_equal 500, b.sum_money
    assert_equal ["A的话"], a.item_record
    assert_empty b.item_record, "两本账的道具互不串"
  end

  def test_general_topic_is_the_group_ledger
    # E4：forum 的 General 话题恒为 1，与群级 0 是**同一本**账
    @bank.save_money(chat_id: BIG_CHAT_ID, thread_id: GENERAL_TOPIC, amount: 100)

    assert_equal 100, @bank.fetch(chat_id: BIG_CHAT_ID).sum_money,
                 "General 话题写的钱应能在群级查到（E4 归一）"
    assert_equal 1, @bank.count_for(chat_id: BIG_CHAT_ID), "只该有一行（0 与 1 同义）"
  end

  def test_negative_and_nil_thread_ids_normalize_to_group_scope
    assert_equal 0, TenguDB::Bank.normalize_thread_id(nil)
    assert_equal 0, TenguDB::Bank.normalize_thread_id(-5)
    assert_equal 0, TenguDB::Bank.normalize_thread_id(0)
    assert_equal 0, TenguDB::Bank.normalize_thread_id(1)
    assert_equal TOPIC, TenguDB::Bank.normalize_thread_id(TOPIC)
  end

  def test_thread_id_is_normalized_on_both_read_and_write
    @bank.save_money(chat_id: BIG_CHAT_ID, thread_id: GENERAL_TOPIC, amount: 100)

    stored_thread = @conn.get_first_value(
      "SELECT thread_id FROM bank_record WHERE chat_id = ?", [BIG_CHAT_ID]
    )
    assert_equal 0, stored_thread.to_i, "写入必须过归一（否则群级查不到 General 写的行）"
    assert_equal 100, @bank.fetch(chat_id: BIG_CHAT_ID, thread_id: 1).sum_money
    assert_equal 100, @bank.fetch(chat_id: BIG_CHAT_ID, thread_id: nil).sum_money
  end

  # =========================================================================
  # G. 入参守卫
  # =========================================================================

  def test_chat_id_zero_is_refused_instead_of_creating_a_black_hole_row
    [0, nil, "", "   "].each do |bad|
      result = @bank.save_money(chat_id: bad, amount: 100)
      assert result.error?, "chat_id=#{bad.inspect} 必须被拒（Ruby 里 0 为真，不拦会写进黑洞）"
    end
    assert_equal 0, @conn.get_first_value("SELECT count(*) FROM bank_record").to_i
  end

  def test_clear_refuses_a_zero_chat_id
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)

    assert_raises(TenguDB::InvalidArgument) { @bank.clear(chat_id: 0) }
    assert_equal 100, @bank.fetch(chat_id: BIG_CHAT_ID).sum_money
  end

  # =========================================================================
  # H. 事务：读改写与回滚
  # =========================================================================

  def test_read_modify_write_happens_inside_a_transaction
    # 竞态防线：整个「读 → 改 → 写」必须在同一个事务里，否则两笔并发写入
    # 会出现「都读到旧 sum → 都写回 → 少了一笔」。做法是把事务入口包一层
    # 探针，看 save_record 的写路径是否真的从 transaction 里走过。
    calls = []
    probe = Class.new(SimpleDelegator) do
      define_method(:transaction) do |*args, &blk|
        calls << args.first
        super(*args, &blk)
      end
    end.new(@conn)

    bank = TenguDB::Bank.new(probe)
    assert bank.save_money(chat_id: BIG_CHAT_ID, amount: 100).ok?

    assert_equal [:immediate], calls,
                 "整行读改写必须走 :immediate 事务（deferred 到首次写才取锁，防不住竞态）"
    assert_equal 100, bank.fetch(chat_id: BIG_CHAT_ID).sum_money
  end

  def test_statement_read_and_delete_happen_inside_a_transaction
    # kimi T3.2 评审提案 #1 的回归钉：结算的「读账 → 清零」也必须在事务内——
    # 否则并发下两步之间落入的存款会被静默清掉且不上报表
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)

    calls = []
    probe = Class.new(SimpleDelegator) do
      define_method(:transaction) do |*args, &blk|
        calls << args.first
        super(*args, &blk)
      end
    end.new(@conn)

    bank = TenguDB::Bank.new(probe)
    record, attempted, deleted = bank.statement(chat_id: BIG_CHAT_ID)

    assert_equal [:immediate], calls, "statement 的读删必须走 :immediate 事务"
    assert attempted
    assert deleted
    assert_equal 100, record.sum_money
    assert_nil bank.fetch(chat_id: BIG_CHAT_ID)
  end

  def test_busy_exception_is_warned_not_disguised_as_bad_input_only
    # kimi T3.2 评审提案 #5：锁竞争被译成「输入有误」会误导排障——
    # 回 :error 的同时必须留一条结构性 warn（只有异常类名）
    probe = Class.new(SimpleDelegator) do
      define_method(:transaction) do |*args, &blk|
        raise SQLite3::BusyException, "database is locked"
      end
    end.new(@conn)

    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |msg| warnings << msg }

    bank = TenguDB::Bank.new(probe, logger: logger)
    result = bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)

    assert result.error?, "锁竞争应回 :error（天狗 catch→null→输入错误文案）"
    assert_equal 1, warnings.size
    assert_includes warnings.first, "SQLite3::BusyException"
    assert_equal 0, @bank.count_for(chat_id: BIG_CHAT_ID), "失败不得留下半截账"
  end

  def test_a_failure_inside_the_transaction_leaves_no_partial_row
    @conn.execute(
      "INSERT INTO bank_record (chat_id, thread_id, sum_money, money_record, item_record) " \
      "VALUES (?, 0, 100, '[100]', '[]')", [BIG_CHAT_ID]
    )

    # 造一个必然失败的写入（money_record 列 NOT NULL）来验证回滚路径：
    # 直接在事务块里写一个非法值，异常穿出 save_record 后整笔都不该留下。
    before = raw
    assert_equal "[100]", before

    assert_raises(RuntimeError) do
      @conn.transaction(:immediate) do
        @conn.execute(
          "UPDATE bank_record SET sum_money = 999 WHERE chat_id = ? AND thread_id = 0",
          [BIG_CHAT_ID]
        )
        raise "boom"
      end
    end

    assert_equal 100, @bank.fetch(chat_id: BIG_CHAT_ID).sum_money, "异常必须回滚"
  end

  def test_overflow_does_not_commit_a_half_written_row
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: TenguDB::Bank::INT64_MAX)

    result = @bank.save_money(chat_id: BIG_CHAT_ID, amount: 5)

    assert result.error?
    assert_equal TenguDB::Bank::INT64_MAX, @bank.fetch(chat_id: BIG_CHAT_ID).sum_money
    assert_equal "[#{TenguDB::Bank::INT64_MAX}]", raw, "流水也不许被追加进去"
  end

  def test_item_missing_branch_commits_nothing
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    before = [raw, raw(column: "item_record")]

    result = @bank.remove_item(chat_id: BIG_CHAT_ID, name: "没有这件")

    assert result.item_missing?
    assert_equal before, [raw, raw(column: "item_record")], "早退分支不得留下任何写"
  end

  def test_bank_is_reentrant_inside_an_outer_transaction
    # sqlite 不可嵌套事务：Connection#transaction 在已激活时直接复用外层。
    @conn.transaction(:immediate) do
      assert @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100).ok?
      assert @bank.save_money(chat_id: BIG_CHAT_ID, amount: 50).ok?
    end

    assert_equal 150, @bank.fetch(chat_id: BIG_CHAT_ID).sum_money
  end

  # =========================================================================
  # I. 反射守卫 + 迁移联动（群升级不丢账）
  # =========================================================================

  def test_bank_record_table_is_covered_by_migration_tables
    assert @conn.table_exists?("bank_record"), "sanity：schema.sql 应建出 bank_record"
    assert_includes @conn.column_names("bank_record"), "chat_id"

    assert_includes TelegramBot::Migration::TABLES, "bank_record",
                 "bank_record 含 chat_id 却不在 Migration::TABLES（群升级会丢整本账）"
  end

  def test_chat_upgrade_moves_bank_rows_to_new_chat_id
    @bank.save_money(chat_id: -123_456_789, thread_id: TOPIC, amount: 100)
    @bank.add_item(chat_id: -123_456_789, thread_id: TOPIC, name: "茶")

    result = TelegramBot::Migration.new(connection: @conn, logger: Logger.new(IO::NULL))
             .handle(chat_id: -123_456_789, migrate_to: -1_009_876_543_210)

    refute_nil result
    assert_equal 1, result.rows["bank_record"]

    moved = @bank.fetch(chat_id: -1_009_876_543_210, thread_id: TOPIC)
    refute_nil moved, "升级后账本必须跟着群走（否则群升级=账本清零）"
    assert_equal 100, moved.sum_money
    assert_equal [100], moved.money_record
    assert_equal ["茶"], moved.item_record
    assert_equal TOPIC, moved.thread_id, "话题定位不能被迁移改坏"
    assert_nil @bank.fetch(chat_id: -123_456_789, thread_id: TOPIC)
  end

  def test_value_object_helpers
    @bank.save_money(chat_id: BIG_CHAT_ID, amount: 100)
    @bank.add_item(chat_id: BIG_CHAT_ID, name: "茶")
    record = @bank.fetch(chat_id: BIG_CHAT_ID)

    assert_equal "茶", record.items_label
    assert_equal "无", TenguDB::BankRecord.new(
      chat_id: 1, thread_id: 0, sum_money: 0, money_record: [], item_record: []
    ).items_label, "空账显示「无」（天狗 `item_record ? … : なし`）"
    assert_equal "本群", record.scope_label
    assert_equal "本话题", TenguDB::BankRecord.new(
      chat_id: 1, thread_id: 88, sum_money: 0, money_record: [], item_record: []
    ).scope_label

    hash = record.to_h
    assert_equal %i[chat_id thread_id sum_money money_record item_record updated_at].sort,
                 hash.keys.sort, "to_h 键集固定（诊断/日志靠它）"
    assert_equal 100, hash[:sum_money]
    assert_equal ["茶"], hash[:item_record]
  end
end