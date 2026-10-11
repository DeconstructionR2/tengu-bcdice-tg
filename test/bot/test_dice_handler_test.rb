# frozen_string_literal: true

# ============================================================================
# test/bot/test_dice_handler_test.rb — 掷骰 + /system 双作用域（T2.4）
#
# 覆盖计划 §6 / §8 T2.4 的全部验收点：
#   - /roll 用当前群/话题规则系统（注册 NinjaSlayer2Ex 后 `SB` 输出含サツバツ）
#   - /roll 无参 → 用法提示
#   - /nd **无视群设置**，固定 NinjaSlayer2Ex
#   - 辅助轨 ≡ /roll；引擎 nil 时 **slash 提示 vs aux 静默**
#   - /system 话题内/话题外双作用域切换 + 回复明示作用域与系统名
#   - /system 无效 ID 拒答（并给几颗可用示例）
#   - /system 无参显示当前系统 + 来源（话题/群/默认）
#   - E4：General 话题（thread_id=1）的读写对称
#   - 64 位 chat_id、thread 透传（经 router 端到端）
#
# 两层测试：
#   1. handler 直调（注入内存 DB + 真引擎）——验语义；
#   2. 经 Router 端到端（假 TelegramApi）——验接线、thread 透传、静默。
#
# 全程零联网、零真 token、零落盘（DB 用 :memory:）。
# ============================================================================

require_relative "test_helper"
require_relative "../../bot/router"
require_relative "../../bot/handlers/dice"
require_relative "../../db/settings"
require_relative "../../lib/engine_bootstrap"

EngineBootstrap.bootstrap!(reload_backend: true)

class TestDiceHandler < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789 # 超 32 位（§0.2.4）
  TOPIC = 88
  NS2EX = "NinjaSlayer2Ex" # 2 版扩展（扩展命令 NSRS/JITSB 等都在这）
  NS1EX = "NinjaSlayerEx"  # 1 版扩展（JITSB/WS/DKKI 等在这）

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @settings = TenguDB::Settings.new(@conn)
    @handler = TelegramBot::Handlers::DiceHandler.new(
      settings: @settings, logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    @conn.close
  end

  # 造一个 handler 上下文（形状与 router run_handler 完全一致）
  def ctx(name: nil, args: "", text: nil, chat_id: CHAT_ID, thread_id: nil)
    { router: nil, api: nil, kind: name ? :slash : :aux, command: nil,
      name: name, args: args, text: text, chat_id: chat_id,
      thread_id: thread_id, user_id: 42, message: nil }
  end

  # --- /roll ---------------------------------------------------------------

  def test_roll_uses_default_game_system
    out = @handler.call(ctx(name: "roll", args: "SB"))

    assert_includes out, "サツバツ", "默认系统 NinjaSlayer2Ex 的 SB 应出力"
  end

  def test_roll_uses_topic_game_system
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: NS1EX)

    in_topic = @handler.call(ctx(name: "roll", args: "JITSB", thread_id: TOPIC))
    assert_includes in_topic, "ジツ拡張",
                    "话题内应走话题规则系统（1版扩展）"

    outside = @handler.call(ctx(name: "roll", args: "JITSB", thread_id: nil))
    refute_includes outside.to_s, "ジツ拡張",
                    "话题外不该被话题设置污染（仍走默认 2版扩展）"
  end

  def test_roll_respects_group_game_system
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    out = @handler.call(ctx(name: "roll", args: "WS"))
    assert_includes out, "wasshoi", "群默认切到 1 版后 WS 应生效"
  end

  def test_roll_without_args_shows_usage
    out = @handler.call(ctx(name: "roll", args: ""))

    assert_includes out, "/roll"
    assert_includes out, "SB"
  end

  def test_roll_with_unknown_command_gives_hint
    # 语法合法但引擎 nil（如 NRS 需 @3）：slash 轨应给提示而非静默
    out = @handler.call(ctx(name: "roll", args: "NRS"))

    assert_includes out, "不接受"
    assert_includes out, "/system"
  end

  def test_roll_ignores_extra_whitespace_in_args
    out = @handler.call(ctx(name: "roll", args: "  SB  "))

    assert_includes out, "サツバツ", "参数应 strip 后再送引擎"
  end

  # --- /nd（§6 无视群设置）-------------------------------------------------

  def test_nd_ignores_chat_setting
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: NS1EX)

    out = @handler.call(ctx(name: "nd", args: "SB"))
    assert_includes out, "サツバツ", "/nd 固定 2 版扩展，无视群设置"
  end

  def test_nd_accepts_ex_command_while_group_is_other_system
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    out = @handler.call(ctx(name: "nd", args: "NSRS"))
    # NSRS 是 2 版扩展命令（群设 1 版时 1 版引擎对它返回 nil），群设 1 版仍须可用。
    # 断言命令族前缀而非某条具体台词（表文本随机，断言台词=间歇红）。
    assert_includes out, "nsrs発狂",
                    "NSRS 是 2 版扩展命令，群设 1 版时仍须可用"
    refute_includes out, "不接受"
  end

  def test_nd_without_args_shows_usage
    out = @handler.call(ctx(name: "nd", args: ""))

    assert_includes out, "/nd"
    assert_includes out, "NSRS"
    assert_includes out, "SB"
  end

  def test_nd_unknown_command_gives_hint
    out = @handler.call(ctx(name: "nd", args: "JITSB")) # 1 版扩展命令，2 版不认

    assert_includes out, "不接受"
  end

  # --- 辅助轨 --------------------------------------------------------------

  def test_aux_behaves_like_roll
    out = @handler.call(ctx(text: "SB"))

    assert_includes out, "サツバツ", "辅助轨应等价于 /roll（当前规则系统）"
  end

  def test_aux_uses_chat_game_system
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    out = @handler.call(ctx(text: "JITSB"))
    assert_includes out, "ジツ拡張"
  end

  def test_aux_silent_when_engine_returns_nil
    out = @handler.call(ctx(text: "NRS")) # 语法合法、引擎 nil

    assert_nil out, "辅助轨遇到引擎 nil 必须静默（防抢话，§12 R4）"
  end

  # --- 暗骰（S 前缀）绝不公开回发（kimi T2.4 评审必修）----------------------

  def test_slash_secret_roll_returns_notice_without_result
    out = @handler.call(ctx(name: "roll", args: "S2d6", text: "S2d6"))

    assert_equal TelegramBot::Handlers::DiceHandler::SECRET_NOT_SUPPORTED, out
    refute_match(/\d+\s*＞|\[\d/, out, "提示文案不得含任何骰值/出目")
  end

  def test_aux_secret_roll_is_silent
    out = @handler.call(ctx(text: "S2d6"))

    assert_nil out, "辅助轨暗骰必须静默（结果绝不公开回发）"
  end

  def test_aux_silent_for_empty_text
    assert_nil @handler.call(ctx(text: nil))
    assert_nil @handler.call(ctx(text: "   "))
  end

  def test_aux_with_64bit_chat_id
    out = @handler.call(ctx(text: "SB", chat_id: CHAT_ID))

    assert_includes out, "サツバツ", "超 32 位 chat_id 应正常掷骰"
  end

  # --- /system 切换 --------------------------------------------------------

  def test_system_in_topic_sets_topic_scope
    out = @handler.call(ctx(name: "system", args: NS1EX, thread_id: TOPIC))

    assert_includes out, "本话题", "话题内执行应明示作用域为「本话题」"
    assert_includes out, NS1EX
    refute_nil @settings.fetch_row(CHAT_ID, TOPIC), "话题级应落 (chat, topic) 行"
    assert_nil @settings.fetch_row(CHAT_ID, 0), "话题级不应动群级行"
  end

  def test_system_outside_topic_sets_group_scope
    out = @handler.call(ctx(name: "system", args: NS1EX, thread_id: nil))

    assert_includes out, "本群", "话题外执行应明示作用域为「本群」"
    refute_nil @settings.fetch_row(CHAT_ID, 0)
    assert_nil @settings.fetch_row(CHAT_ID, TOPIC)
  end

  def test_system_in_general_topic_sets_group_scope
    out = @handler.call(ctx(name: "system", args: NS1EX, thread_id: 1))

    assert_includes out, "本群", "forum General 话题按群级处理（E4）"
    refute_nil @settings.fetch_row(CHAT_ID, 0), "应写到群级行"
    assert_empty @settings.entries_for_chat(CHAT_ID).reject { |r| r["thread_id"].to_i.zero? }
  end

  def test_system_reply_includes_display_name
    out = @handler.call(ctx(name: "system", args: NS2EX, thread_id: nil))

    assert_includes out, NS2EX
    assert_includes out, "ニンジャスレイヤー",
                    "回复应带规则系统名而不只是 ID"
  end

  def test_system_takes_first_token_and_ignores_trailing
    out = @handler.call(ctx(name: "system", args: "#{NS1EX} 谢谢", thread_id: nil))

    assert_includes out, NS1EX
    assert_equal "NinjaSlayerEx", @settings.game_system(CHAT_ID)
  end

  def test_system_rejects_unknown_id
    out = @handler.call(ctx(name: "system", args: "NotASystem", thread_id: nil))

    assert_includes out, "未知规则系统"
    assert_includes out, "NotASystem"
    assert_includes out, NS2EX, "拒答应给几颗可用示例"
    assert_empty @settings.entries_for_chat(CHAT_ID), "拒答不得写库"
  end

  def test_system_examples_are_limited_and_real
    out = @handler.call(ctx(name: "system", args: "NotASystem"))

    examples = out[/可用示例：(.+)/, 1].to_s.split("、")
    assert_operator examples.size, :<=, TelegramBot::Handlers::DiceHandler::EXAMPLE_COUNT
    assert_operator examples.size, :>, 0, "示例不应为空"
    examples.each do |id|
      refute_nil BCDice.game_system_class(id), "示例 #{id} 必须是真存在的规则系统"
    end
    assert_includes examples, NS2EX, "示例应优先给忍杀系列"
  end

  def test_system_switch_affects_subsequent_roll
    @handler.call(ctx(name: "system", args: NS1EX, thread_id: nil))

    out = @handler.call(ctx(name: "roll", args: "JITSB"))
    assert_includes out, "ジツ拡張", "切到 1 版后 /roll 应改走 1 版命令"
  end

  # --- /system 无参：显示来源 ----------------------------------------------

  def test_system_no_args_shows_global_default_source
    out = @handler.call(ctx(name: "system", args: ""))

    assert_includes out, NS2EX
    assert_includes out, "全局默认"
    assert_includes out, "尚未设置"
  end

  def test_system_no_args_shows_group_source
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    out = @handler.call(ctx(name: "system", args: ""))

    assert_includes out, NS1EX
    assert_includes out, "本群设置"
  end

  def test_system_no_args_shows_topic_source
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: NS2EX)

    out = @handler.call(ctx(name: "system", args: "", thread_id: TOPIC))

    assert_includes out, NS2EX
    assert_includes out, "本话题设置"
    refute_includes out, "本群设置"
  end

  def test_system_no_args_shows_group_source_in_general_topic
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    out = @handler.call(ctx(name: "system", args: "", thread_id: 1))

    assert_includes out, "本群设置", "General 话题看到的是群设置"
  end

  def test_system_no_args_in_unset_topic_shows_fallback
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    out = @handler.call(ctx(name: "system", args: "", thread_id: TOPIC))

    assert_includes out, NS1EX, "未设话题应回落到群设置"
    assert_includes out, "本群设置"
  end

  # --- 注册表与异常兜底 ---------------------------------------------------

  def test_registry_covers_four_keys
    keys = TelegramBot::Handlers::DiceHandler.registry(@handler).keys

    assert_equal %i[aux nd roll system].sort, keys.sort
    assert_same @handler, TelegramBot::Handlers::DiceHandler.registry(@handler)[:aux]
  end

  def test_unregistered_command_falls_through_to_aux_path
    # call 的 else 分支 = 辅助轨（name 为 nil 或未知）
    out = @handler.call(ctx(name: nil, text: "SB"))

    assert_includes out, "サツバツ"
  end

  def test_stale_game_system_id_reports_instead_of_crashing
    # 模拟手改 DB / 换 gem 版本导致设置指向不存在的规则
    @conn.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, game_system) VALUES (?, 0, ?)",
      [CHAT_ID, "GhostSystem"]
    )

    out = @handler.call(ctx(name: "roll", args: "SB"))
    assert_includes out, "不可用"
    assert_includes out, "GhostSystem"
  end

  def test_stale_game_system_id_is_silent_on_aux
    @conn.execute(
      "INSERT INTO chat_settings (chat_id, thread_id, game_system) VALUES (?, 0, ?)",
      [CHAT_ID, "GhostSystem"]
    )

    assert_nil @handler.call(ctx(text: "SB")), "辅助轨对不可用系统应静默"
  end

  def test_engine_exception_is_contained
    boom = Class.new(StandardError)
    fake_class = Class.new do
      define_singleton_method(:eval) { |_text| raise boom, "kaboom" }
    end
    handler = TelegramBot::Handlers::DiceHandler.new(
      settings: @settings,
      resolver: ->(_id) { fake_class },
      logger: Logger.new(IO::NULL)
    )

    # nil 化（提示/静默）而非让异常冒到 router
    out = handler.call(ctx(name: "roll", args: "SB"))
    assert_includes out, "不接受"
    assert_nil handler.call(ctx(text: "SB"))
  end
end

# ============================================================================
# 经 Router 的端到端接线（假 TelegramApi，零联网）
# ============================================================================
class TestDiceHandlerRouting < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789
  TOPIC = 88

  def setup
    @api, @fake, = build_api
    @conn = TenguDB::Connection.open(path: ":memory:")
    @settings = TenguDB::Settings.new(@conn)
    @handler = TelegramBot::Handlers::DiceHandler.new(
      settings: @settings, logger: Logger.new(IO::NULL)
    )
    @router = TelegramBot::Router.new(
      api: @api,
      handlers: TelegramBot::Handlers::DiceHandler.registry(@handler),
      bot_username: "example_dice_bot",
      logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    @conn.close
  end

  def update(text:, chat_id: CHAT_ID, thread_id: nil)
    attrs = { message_id: 1, date: 1_700_000_000,
              chat: { id: chat_id, type: "supergroup" },
              from: { id: 42, is_bot: false, first_name: "Tester" },
              text: text }
    attrs[:message_thread_id] = thread_id if thread_id
    Telegram::Bot::Types::Update.new(update_id: 1,
                                      message: Telegram::Bot::Types::Message.new(**attrs))
  end

  def sent_texts
    @fake.sent_messages.map { |m| m[:text] }
  end

  # 造一个 handler 上下文（与 router run_handler 的形状一致），供不经 router
  # 直调 handler 的用例使用
  def ctx(name:, args: "", text: nil, chat_id: CHAT_ID, thread_id: nil)
    { router: nil, api: nil, kind: name ? :slash : :aux, command: nil,
      name: name, args: args, text: text, chat_id: chat_id,
      thread_id: thread_id, user_id: 42, message: nil }
  end

  def test_slash_roll_is_sent_with_thread_id
    @router.dispatch(update(text: "/roll SB", thread_id: TOPIC))

    assert_equal 1, sent_texts.size
    assert_includes sent_texts.first, "サツバツ"
    assert_equal TOPIC, @fake.sent_messages.first[:message_thread_id],
                 "话题内回复必须带 message_thread_id（§3 决6）"
  end

  def test_aux_roll_is_sent
    @router.dispatch(update(text: "SB"))

    assert_equal 1, sent_texts.size
    assert_includes sent_texts.first, "サツバツ"
  end

  def test_aux_nil_result_sends_nothing
    @router.dispatch(update(text: "NRS")) # 引擎 nil

    assert_empty sent_texts, "辅助轨引擎 nil 必须一条都不发"
  end

  def test_slash_roll_nil_result_sends_hint
    @router.dispatch(update(text: "/roll NRS"))

    assert_equal 1, sent_texts.size
    assert_includes sent_texts.first, "不接受"
  end

  def test_nd_bypasses_chat_setting_end_to_end
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: "NinjaSlayerEx")
    @router.dispatch(update(text: "/nd NSRS"))

    assert_includes sent_texts.first, "nsrs発狂"
  end

  def test_system_switch_in_topic_then_roll_uses_it
    @router.dispatch(update(text: "/system NinjaSlayerEx", thread_id: TOPIC))
    @router.dispatch(update(text: "/roll JITSB", thread_id: TOPIC))

    assert_equal 2, sent_texts.size
    assert_includes sent_texts.first, "本话题"
    assert_includes sent_texts.last, "ジツ拡張"
  end

  def test_system_switch_outside_topic_then_topic_roll_falls_back
    @router.dispatch(update(text: "/system NinjaSlayerEx"))
    @router.dispatch(update(text: "/roll JITSB", thread_id: TOPIC))

    assert_includes sent_texts.first, "本群"
    # 话题未设置 → 回落到群设置（1 版扩展）
    assert_includes sent_texts.last, "ジツ拡張"
  end

  # 本 Router 只注册了 DiceHandler.registry（roll/nd/system/aux）。
  # 名单只留「**在本注册表里没有 handler**」的命令 —— /secret、/bank、/settings、
  # /help 自 T3.1/T3.2 起都有真 handler（挂在 main.rb 的完整注册表上），
  # 把它们列进来会让本用例的语义随版本漂移、且名不副实。
  # /ct、/log 仍是 PendingHandler 占位（挂不挂都静默），故这里也放行。
  def test_unregistered_commands_stay_silent
    %w[/secret SB2 /bank /ct /log /settings /help].each do |text|
      @router.dispatch(update(text: text))
    end

    assert_empty sent_texts,
                 "本注册表只有 dice 键：其余命令一律静默（未注册 → 不抢话，§12 R4）"
  end

  # 超长输出：handler **不截断**（它只交字符串），由 TelegramApi 的 Chunker
  # 切段兜底（§0.2.4 的 4096 字符上限）。这里用假引擎造一条超长文本，
  # 端到端验：切成了多段、每段都带 thread_id、拼回去一字不差。
  def test_long_output_is_chunked_by_send_layer
    long_text = ("サツバツ" * 2000) # 约 8000 字符，必切
    fake_class = Class.new do
      define_singleton_method(:eval) { |_t| Struct.new(:text).new(long_text) }
    end
    handler = TelegramBot::Handlers::DiceHandler.new(
      settings: @settings,
      resolver: ->(_id) { fake_class },
      logger: Logger.new(IO::NULL)
    )
    router = TelegramBot::Router.new(
      api: @api,
      handlers: TelegramBot::Handlers::DiceHandler.registry(handler),
      bot_username: "example_dice_bot",
      logger: Logger.new(IO::NULL)
    )

    router.dispatch(update(text: "/roll SB", thread_id: TOPIC))

    assert_operator @fake.sent_messages.size, :>=, 2, "超长输出应被切成多段"
    @fake.sent_messages.each do |m|
      assert_operator m[:text].length, :<=, TelegramBot::Chunker::MAX_MESSAGE_LENGTH
      assert_equal TOPIC, m[:message_thread_id], "切段后每段都须带 thread_id"
    end
    assert_equal long_text, @fake.sent_messages.map { |m| m[:text] }.join,
                 "切段不得丢内容（拼回须逐字一致）"
  end

  def test_handler_output_is_passed_through_verbatim
    # §13 第 7 项：引擎数据天生纯文本，直发不做 Markdown/富格式转换。
    # 双向断言：
    #   正向 — 表文本里的 ** 原样透传（不转义、不剥离、不二次包裹）
    #   反向 — 不注入任何本层自加的标记（handler 绝不加 ``` 或 * 包裹）
    # JITSB（1 版扩展）表文本本身带 **，故先把本群切到 1 版。
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: "NinjaSlayerEx")

    raw = @handler.call(ctx(name: "roll", args: "JITSB"))
    assert_includes raw, "**", "表文本自带的 Markdown 记号应原样透传"

    sb = @handler.call(ctx(name: "roll", args: "SB")) # 引擎输出里本无 *
    refute_includes sb, "```", "纯文本直发，不应注入代码块"
    refute_includes sb, "*", "不应注入 Markdown 星号"
  end
end