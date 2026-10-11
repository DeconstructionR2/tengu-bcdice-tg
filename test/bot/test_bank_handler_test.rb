# frozen_string_literal: true

# ============================================================================
# test/bot/test_bank_handler_test.rb — 天狗银行 /bank handler（T3.2）
#
# 覆盖计划 §8 T3.2 / §6 命令设计 / §13 第 4 项：
#
# handler 层：
#   - 子命令映射：deposit/withdraw/item add/item del/balance/statement/reset/help
#   - 金额解析逐字忠实 record.js：只收 `\d+`（先剥光全部空白，record.js:15）；
#     0 / 小数 / 千分位 / 全角 / 十六进制 / 超 INT64_MAX（两侧对称）一律输入错误；
#     **透支允许**（余额变负且如实呈现）
#   - 893 彩蛋（change893）：金额串**含** 893 即小怪装饰（1893/8930/-893 都命中）
#   - 天狗文案语义：查账「不动账」vs 结算「出完清零」；账上没有的道具 → 专句
#   - 未知子命令 / 空参 → 输入错误或用法表（天狗 default 分支）
#
# 真身接线层（防「看着接了实则从不执行」，T2.6 教训）：
#   用**真 handler + 真 Router** 跑 /bank 全流程；断言回发的 thread 透传、
#   话题级隔离（两个话题两本账在真实路由下互不串）。
#
# 全程 mock，零联网、零真 token、零 bot 进程。
# ============================================================================

require "minitest/autorun"
require "logger"
require_relative "test_helper"
require_relative "../../bot/router"
require_relative "../../bot/handlers/dice"
require_relative "../../bot/handlers/bank"
require_relative "../../db/connection"
require_relative "../../db/bank"

# ============================================================================
# 层 1：handler 直调（注入内存 DB，验语义与文案）
# ============================================================================
class TestBankHandler < Minitest::Test
  CHAT_ID = -1_000_000_000_123_456_789
  TOPIC = 88

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @bank = TenguDB::Bank.new(@conn)
    @handler = TelegramBot::Handlers::BankHandler.new(
      bank: @bank, logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    @conn.close
  end

  # 直接以 handler 的形状调（真 Router 在层 2）
  def call(args, chat_id: CHAT_ID, thread_id: nil)
    @handler.call(name: "bank", args: args,
                  chat_id: chat_id, thread_id: thread_id, user_id: 42)
  end

  def balance(thread_id: nil)
    @bank.fetch(chat_id: CHAT_ID, thread_id: thread_id)
  end

  # --- 用法与输入守卫 -------------------------------------------------------

  def test_no_args_shows_the_usage_table
    out = call("")

    assert_includes out, "/bank deposit"
    assert_includes out, "/bank withdraw"
    assert_includes out, "/bank item add"
    assert_includes out, "/bank item del"
    assert_includes out, "/bank balance"
    assert_includes out, "/bank statement"
    assert_includes out, "/bank reset"
  end

  def test_help_subcommand_is_the_same_usage
    assert_equal call(""), call("help")
  end

  def test_unknown_verb_is_rejected
    out = call("transfer 100")

    assert_includes out, "输入有误"
    assert_equal 0, @bank.count_for(chat_id: CHAT_ID), "非法输入不许开账"
  end

  def test_verb_is_case_insensitive_but_subcommand_names_stay_ascii
    # 逐条用**独立话题**验证大小写不敏感（余额会累加，不能共用群级本）
    first = call("DEPOSIT 100", thread_id: 10)
    second = call("deposIT 100", thread_id: 11)

    assert_includes first, "100"
    assert_includes second, "100", "动词大小写不敏感（各自一本账，故余额互不影响）"
    assert_equal 100, @bank.fetch(chat_id: CHAT_ID, thread_id: 10).sum_money
    assert_equal 100, @bank.fetch(chat_id: CHAT_ID, thread_id: 11).sum_money
    assert_includes call("BALANCE", thread_id: 10), "当前状况"
  end

  def test_zero_amount_is_rejected_like_tengu
    # 天狗 `if (!array[1]) return error`：0 是 JS falsy → 输入错误
    assert_includes call("deposit 0"), "输入有误"
    assert_includes call("withdraw 0"), "输入有误"
    assert_equal 0, @bank.count_for(chat_id: CHAT_ID)
  end

  def test_non_integer_amounts_are_rejected_like_tengu_regex
    # 天狗只认 /^m[+-]\d+$/：小数/千分位/科学计数/十六进制/全角都不匹配
    ["1.5", "1,000", "1e5", "0x10", "１００", "abc", "-", "+100", "100円", ""]
      .each do |bad|
      assert_includes call("deposit #{bad}"), "输入有误",
                      "#{bad.inspect} 必须被拒（与天狗正则一致）"
    end
    assert_equal 0, @bank.count_for(chat_id: CHAT_ID)
  end

  def test_amount_beyond_int64_is_rejected
    out = call("deposit #{TenguDB::Bank::INT64_MAX + 1}")

    assert_includes out, "输入有误"
    assert_equal 0, @bank.count_for(chat_id: CHAT_ID)
  end

  def test_withdraw_beyond_int64_is_rejected_symmetrically
    # kimi T3.2 评审提案 #2 的回归钉：无符号数字串两侧对称——
    # withdraw INT64_MAX+1 曾因 乘-1=INT64_MIN 落进界内而成功入账
    out = call("withdraw #{TenguDB::Bank::INT64_MAX + 1}")

    assert_includes out, "输入有误"
    assert_equal 0, @bank.count_for(chat_id: CHAT_ID)
  end

  def test_amount_with_inner_whitespace_is_stripped_like_tengu
    # record.js:15 对整条命令 replace(/\s+/g,"")：天狗 m+1 00 = m+100
    out = call("deposit 1 00")

    assert_includes out, "已更新万札"
    assert_equal 100, balance.sum_money
  end

  def test_missing_arguments_are_rejected
    assert_includes call("deposit"), "输入有误"
    assert_includes call("item add"), "输入有误"
    assert_includes call("item"), "输入有误"
  end

  def test_item_requires_a_known_action
    assert_includes call("item put 茶"), "输入有误"
  end

  # --- 存取钱 ---------------------------------------------------------------

  def test_deposit_and_withdraw_update_the_balance
    out = call("deposit 100")
    assert_includes out, "已更新万札"
    assert_includes out, "100"

    out = call("withdraw 50")
    assert_includes out, "50"
    assert_equal 50, balance.sum_money
    assert_equal [100, -50], balance.money_record, "流水逐笔（断言到元素级）"
  end

  def test_withdraw_allows_overdraft
    call("deposit 100")
    out = call("withdraw 9999")

    assert_includes out, "-9899", "透支必须允许并如实呈现（天狗无校验）"
    assert_equal(-9899, balance.sum_money)
  end

  def test_negative_deposit_is_refused_but_negative_withdrawal_is_the_normal_path
    # `deposit -50` 走 amount 解析后金额为 -50 → 天狗的正则不接受 m+-50，
    # 本项目把它并入 withdraw 语义前先拒：deposit 只收正整数。
    assert_includes call("deposit -50"), "输入有误"
    assert_equal 0, @bank.count_for(chat_id: CHAT_ID)
  end

  # --- 893 彩蛋（record.js change893）---------------------------------------

  def test_893_eggs_decorate_the_amount
    out = call("deposit 893")

    assert_includes out, "👺", "金额含 893 应套上小怪（天狗 :japanese_goblin:）"
    assert_includes out, "893"
  end

  def test_893_egg_is_a_substring_rule_not_an_equality_rule
    # 天狗判的是 String(money).indexOf("893") !== -1 —— 判的是**余额串**，
    # 不是本次入账额。故每条都用独立话题隔离，且断言的是余额串含 893。
    #   withdraw 893 → 余额 -893 （串里含 893）
    #   deposit 1893  → 余额 1893 （串里含 893）
    #   deposit 8930  → 余额 8930 （串里含 893）
    [["withdraw 893", 11], ["deposit 1893", 12], ["deposit 8930", 13]]
      .each do |(command, thread)|
      out = call(command, thread_id: thread)

      assert_includes out, "👺",
                      "#{command} 的余额串含 893，应命中彩蛋（含子串即命中，非等值）"
    end

    clean = call("deposit 900", thread_id: 15)
    refute_includes clean, "👺", "余额 900 不含 893，不该被装饰"
  end

  def test_amount_without_893_is_not_decorated
    out = call("deposit 900")

    refute_includes out, "👺", "不含 893 的金额不该被装饰"
  end

  def test_893_egg_also_decorates_the_balance_line
    call("deposit 893")
    out = call("balance")

    assert_includes out, "👺", "查账时余额含 893 也要套彩蛋"
  end

  # --- 存取道具 -------------------------------------------------------------

  def test_item_add_and_del
    out = call("item add 茶")
    assert_includes out, "道具已更新"
    assert_includes out, "茶"

    out = call("item del 茶")
    assert_includes out, "道具已更新"
    assert_empty balance.item_record
  end

  def test_item_delete_of_an_absent_item_uses_tengus_dedicated_line
    call("item add 茶")
    out = call("item del 锤子")

    assert_includes out, "账上没有这件道具的记录", "天狗该路径是专句而非输入错误"
    assert_equal ["茶"], balance.item_record
  end

  def test_item_name_whitespace_is_stripped_like_tengu
    # record.js:15 先剥光整条命令的空白——天狗道具名不可能含空格；
    # 「i+秘 传 的 茶」在天狗落账为「秘传的茶」，本项目对齐（评审提案 #3）
    assert_includes call("item add 秘 传 的 茶"), "秘传的茶"
    assert_equal ["秘传的茶"], balance.item_record
  end

  def test_item_names_with_metacharacters_are_bound_not_interpolated
    # 注：道具名先经 record.js:15 同款剥空白（上面那条测试钉过），
    # 故本用例的注入串不含空格——要验的是引号/分号/注释符全部按值绑定
    nasty = %q{茶';DROP_TABLE_bank_record;--}
    out = call("item add #{nasty}")

    assert_includes out, nasty
    assert @conn.table_exists?("bank_record"), "值必须绑定，不得拼进 SQL"
  end

  def test_item_delete_does_not_mangle_similar_names
    call("item add ポット改")
    call("item add ポット")

    out = call("item del ポット")

    assert_equal ["ポット改"], balance.item_record,
                 "删「ポット」不得误伤「ポット改」（quirk 修复）"
    assert_includes out, "ポット改", "回显里剩下的正是那件没被误伤的"
  end

  # --- 查账 vs 结算 ---------------------------------------------------------

  def test_balance_reports_without_touching_the_ledger
    call("deposit 100")
    call("item add 茶")

    out = call("balance")

    assert_includes out, "当前状况"
    assert_includes out, "100"
    assert_includes out, "茶"
    assert_includes out, "100 = 100", "出入金流水算式（天狗同款观感）"
    assert_equal 100, balance.sum_money, "查账必须不动账"
    refute_nil balance
  end

  def test_statement_reports_then_clears
    call("deposit 100")
    call("deposit 250")

    out = call("statement")

    assert_includes out, "结果"
    assert_includes out, "350"
    assert_includes out, "100 + 250 = 350", "流水算式"
    assert_includes out, "已重置"
    assert_nil balance, "结算必须真的清零"
  end

  def test_statement_on_an_empty_ledger_reports_nothing_found
    assert_includes call("statement"), "没有找到银行的记录"
    refute_includes call("statement"), "已重置", "查无此账时天狗不执行清零"
  end

  def test_balance_on_an_empty_ledger_reports_nothing_found
    assert_includes call("balance"), "没有找到银行的记录"
  end

  def test_reset_clears_the_ledger
    call("deposit 100")
    call("item add 茶")

    out = call("reset")

    assert_includes out, "已重置"
    assert_nil balance
  end

  def test_reset_on_an_empty_ledger_still_confirms
    # 天狗 deleteChannel 对不存在的文档也返回 true → 照播「已重置」
    assert_includes call("reset"), "已重置"
  end

  # --- 作用域（handler 层只看 thread 透传，DB 层管归一）-------------------

  def test_scope_wording_reflects_the_topic_level
    call("deposit 100", thread_id: TOPIC)

    assert_includes call("balance", thread_id: TOPIC), "当前状况",
                    "话题内查得到自己那本账（不回「没有找到」）"
    assert_includes call("reset", thread_id: TOPIC), "已重置本话题内的记录"
    assert_includes call("reset"), "已重置本群内的记录"
  end

  def test_two_topics_keep_two_ledgers_through_the_handler
    call("deposit 100", thread_id: 88)
    call("deposit 500", thread_id: 99)

    assert_equal 100, @bank.fetch(chat_id: CHAT_ID, thread_id: 88).sum_money
    assert_equal 500, @bank.fetch(chat_id: CHAT_ID, thread_id: 99).sum_money

    call("reset", thread_id: 88)
    assert_nil @bank.fetch(chat_id: CHAT_ID, thread_id: 88)
    assert_equal 500, @bank.fetch(chat_id: CHAT_ID, thread_id: 99).sum_money,
                 "清一个话题不许动另一个"
  end

  # 注入一个「statement 返回 deleted=false」的假 bank：真 DB 走的是抛异常，
  # 但分支必须真能跑通（否则它只是一段永远为假的死代码）。
  class FailingClearBank
    def statement(chat_id:, thread_id: nil)
      record = TenguDB::BankRecord.new(
        chat_id: chat_id, thread_id: 0, sum_money: 100,
        money_record: [100], item_record: [], updated_at: ""
      )
      [record, true, false] # 查到了、想删、但没删掉
    end
  end

  def test_statement_reports_clear_failure_instead_of_claiming_a_reset
    handler = TelegramBot::Handlers::BankHandler.new(
      bank: FailingClearBank.new, logger: Logger.new(IO::NULL)
    )
    out = handler.call(name: "bank", args: "statement",
                       chat_id: CHAT_ID, thread_id: nil, user_id: 42)

    assert_includes out, "清零失败"
    refute_includes out, "已重置", "没清掉就不许说「已重置」"
    refute_includes out, "100 + 100", "失败时不报流水算式（天狗此时整条替换成错误）"
  end

  # 天狗 saveRecord 的 .catch(() => null) → 输入错误文案，不炸循环。
  class RaisingBank
    def save_money(**_kw)
      TenguDB::SaveResult.error(SQLite3::BusyException)
    end

    def add_item(**_kw)
      TenguDB::SaveResult.error(SQLite3::BusyException)
    end

    def fetch(**_kw)
      nil
    end

    def clear(**_kw)
      true
    end

    def statement(**_kw)
      [nil, false, false]
    end
  end

  def test_storage_failure_degrades_to_bad_input_instead_of_raising
    handler = TelegramBot::Handlers::BankHandler.new(
      bank: RaisingBank.new, logger: Logger.new(IO::NULL)
    )

    money = handler.call(name: "bank", args: "deposit 100",
                         chat_id: CHAT_ID, thread_id: nil, user_id: 42)
    item = handler.call(name: "bank", args: "item add 茶",
                        chat_id: CHAT_ID, thread_id: nil, user_id: 42)

    assert_includes money, "输入有误", "存储层失败要降级成用户看得懂的输入错误"
    assert_includes item, "输入有误"
  end

  def test_handler_is_silent_without_chat_id
    assert_nil call("deposit 100", chat_id: 0)
    assert_nil @handler.call(name: "bank", args: "deposit 100", chat_id: nil,
                             thread_id: nil, user_id: 42)
  end

  def test_handler_ignores_commands_that_are_not_bank
    assert_nil @handler.call(name: "roll", args: "SB", chat_id: CHAT_ID, thread_id: nil)
    assert_nil @handler.call(name: nil, args: "deposit 100", chat_id: CHAT_ID, thread_id: nil)
  end
end

# ============================================================================
# 层 2：真身 handler + 真 Router 端到端接线（T2.6 教训）
# ============================================================================
class TestBankRouting < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789
  TOPIC = 88
  OTHER_TOPIC = 99

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @bank = TenguDB::Bank.new(@conn)
    @handler = TelegramBot::Handlers::BankHandler.new(
      bank: @bank, logger: Logger.new(IO::NULL)
    )
    @api, @fake, = build_api
    @router = TelegramBot::Router.new(
      api: @api,
      handlers: TelegramBot::Handlers::BankHandler.registry(@handler),
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
              from: { id: 42, is_bot: false, first_name: "Tester" }, text: text }
    attrs[:message_thread_id] = thread_id if thread_id
    Telegram::Bot::Types::Message.new(**attrs)
  end

  # 派发一条 /bank 并返回**最后一条**发送记录。
  #
  # 名字既不叫 send 也不叫 run：前者是 Object 内建（method_missing 底层），
  # 后者是 Minitest::Test 自己的测试执行入口（minitest 会调 test.run）——
  # 覆盖任何一个都会让整个测试框架的调用走错路径。bank_send 无此冲突。
  def bank_send(text:, thread_id: nil)
    @router.dispatch(update(text: text, thread_id: thread_id))
    @fake.sent_messages.pop
  end

  def sent_texts
    @fake.sent_messages.map { |m| m[:text] }
  end

  # --- 主轨接线 -------------------------------------------------------------

  def test_bank_slash_reaches_the_handler
    message = bank_send(text: "/bank deposit 100", thread_id: TOPIC)

    refute_nil message, "/bank 已有真 handler（菜单上架命令不许静默）"
    assert_includes message[:text], "100"
    assert_equal TOPIC, message[:message_thread_id], "thread 必须透传（forum 不掉话题）"
    assert_equal 100, @bank.fetch(chat_id: CHAT_ID, thread_id: TOPIC).sum_money
  end

  def test_full_journey_deposit_item_balance_statement
    bank_send(text: "/bank deposit 1000", thread_id: TOPIC)
    bank_send(text: "/bank deposit 250", thread_id: TOPIC)
    bank_send(text: "/bank item add 茶", thread_id: TOPIC)
    @fake.sent_messages.clear

    balance = bank_send(text: "/bank balance", thread_id: TOPIC)
    assert_includes balance[:text], "当前状况"
    assert_includes balance[:text], "1250"
    assert_includes balance[:text], "茶"
    assert_includes balance[:text], "1000 + 250 = 1250"

    statement = bank_send(text: "/bank statement", thread_id: TOPIC)
    assert_includes statement[:text], "结果"
    assert_includes statement[:text], "已重置"
    assert_nil @bank.fetch(chat_id: CHAT_ID, thread_id: TOPIC), "结算后账本清空"
  end

  def test_usage_is_routed_and_thread_is_passed_through
    message = bank_send(text: "/bank", thread_id: TOPIC)

    assert_includes message[:text], "/bank deposit"
    assert_equal TOPIC, message[:message_thread_id]
  end

  def test_topic_scope_isolation_end_to_end
    bank_send(text: "/bank deposit 100", thread_id: TOPIC)
    bank_send(text: "/bank deposit 500", thread_id: OTHER_TOPIC)
    @fake.sent_messages.clear

    a = bank_send(text: "/bank balance", thread_id: TOPIC)
    b = bank_send(text: "/bank balance", thread_id: OTHER_TOPIC)

    assert_includes a[:text], "100"
    refute_includes a[:text], "500"
    assert_includes b[:text], "500"
    refute_includes b[:text], "100"
    assert_equal 100, @bank.fetch(chat_id: CHAT_ID, thread_id: TOPIC).sum_money
    assert_equal 500, @bank.fetch(chat_id: CHAT_ID, thread_id: OTHER_TOPIC).sum_money
  end

  def test_general_topic_is_the_group_ledger_end_to_end
    # E4：forum 的 General 话题恒为 1 → 与群级 0 同一本账
    bank_send(text: "/bank deposit 300", thread_id: 1)
    @fake.sent_messages.clear

    message = bank_send(text: "/bank balance")

    assert_includes message[:text], "300", "General 话题的钱在群级查账里看得见"
    assert_nil message[:message_thread_id], "群级消息不带 thread"
    assert_equal 300, @bank.fetch(chat_id: CHAT_ID).sum_money
  end

  def test_reset_routes_and_only_touches_its_topic
    bank_send(text: "/bank deposit 100", thread_id: TOPIC)
    bank_send(text: "/bank deposit 500", thread_id: OTHER_TOPIC)
    @fake.sent_messages.clear

    message = bank_send(text: "/bank reset", thread_id: TOPIC)

    assert_includes message[:text], "已重置本话题内的记录"
    assert_nil @bank.fetch(chat_id: CHAT_ID, thread_id: TOPIC)
    assert_equal 500, @bank.fetch(chat_id: CHAT_ID, thread_id: OTHER_TOPIC).sum_money
  end

  def test_893_egg_survives_the_wire
    bank_send(text: "/bank deposit 893", thread_id: TOPIC)
    @fake.sent_messages.clear

    message = bank_send(text: "/bank balance", thread_id: TOPIC)

    assert_includes message[:text], "👺"
    assert_includes message[:text], "893"
  end

  def test_bad_input_still_gets_an_answer_never_silence
    message = bank_send(text: "/bank deposit abc", thread_id: TOPIC)

    refute_nil message, "显式命令的输入错误必须回（不静默）"
    assert_includes message[:text], "输入有误"
    assert_equal 0, @bank.count_for(chat_id: CHAT_ID)
  end

  def test_commands_not_owned_by_bank_stay_silent
    @router.dispatch(update(text: "/ct new x", thread_id: TOPIC))

    assert_empty sent_texts, "bank handler 不得越权处理别的命令（router 注册表按名分发）"
  end

  def test_bank_is_merged_alongside_other_handlers_without_clobbering
    # 回归钉：bank 与 dice/system/secret 共存于同一注册表
    dice = TelegramBot::Handlers::DiceHandler.new(
      settings: TenguDB::Settings.new(@conn), logger: Logger.new(IO::NULL)
    )
    router = TelegramBot::Router.new(
      api: @api,
      handlers: TelegramBot::Handlers::DiceHandler.registry(dice)
                      .merge(TelegramBot::Handlers::BankHandler.registry(@handler)),
      bot_username: "example_dice_bot", logger: Logger.new(IO::NULL)
    )

    router.dispatch(update(text: "/bank deposit 100", thread_id: TOPIC))

    assert_equal 100, @bank.fetch(chat_id: CHAT_ID, thread_id: TOPIC).sum_money
    assert_equal 1, @fake.sent_messages.size, "只该发银行那一条（没碰引擎）"
  end
end