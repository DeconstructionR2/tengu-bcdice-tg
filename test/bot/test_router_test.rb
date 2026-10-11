# frozen_string_literal: true

# ============================================================================
# test/bot/test_router_test.rb — 路由层（T2.3）
#
# 覆盖：
#   - slash 解析：裸 / 带参数 / 带@本bot / 带@别bot / 未知命令静默
#   - 辅助轨裸 ASCII：N4,3 / SB / SB@6 / NRS_E4 / 2d6>=4[=6] 命中；
#     「今天天气3d6怎么样」（子串不算命中）与「サツバツ」静默
#   - 辅助轨开关关闭 → 骰式静默
#   - message_thread_id 从入站消息透传到发送
#   - handler 异常不杀循环（逐条 dispatch 继续）
#   - 64 位 chat_id
#   - 迁移消息 / 非文本消息安静跳过
# 全程 mock：假 api 记录发送参数，零联网。
# ============================================================================

require_relative "test_helper"
require_relative "../../bot/router"
require_relative "../../lib/engine_bootstrap"

EngineBootstrap.bootstrap!(reload_backend: true)

class TestRouter < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789 # 超 32 位，验证 64 位处理
  BIG_CHAT_ID = -1_000_000_000_000_123_456

  def setup
    @api, @fake, = build_api
    @calls = []
    @router = TelegramBot::Router.new(
      api: @api,
      bot_username: "example_dice_bot",
      logger: Logger.new(IO::NULL)
    )
  end

  # --- 测试夹具 -------------------------------------------------------------

  # 构造一个 update（用 gem 的真类型，避免自造假对象掩盖真实语义）
  def update(text: nil, chat_id: CHAT_ID, chat_type: "supergroup",
             thread_id: nil, user_id: 42, username: "Tester",
             message_id: 100, migrate: nil, extra: {})
    attrs = { message_id: message_id, date: 1_700_000_000,
              chat: { id: chat_id, type: chat_type },
              from: { id: user_id, is_bot: false, first_name: "Tester" } }
    attrs[:text] = text if text
    attrs[:message_thread_id] = thread_id if thread_id
    case migrate
    when :to then attrs[:migrate_to_chat_id] = BIG_CHAT_ID
    when :from then attrs[:migrate_from_chat_id] = BIG_CHAT_ID
    end
    Telegram::Bot::Types::Update.new(update_id: message_id,
                                      message: Telegram::Bot::Types::Message.new(**attrs.merge(extra)))
  end

  # 注册一个把入站记进 @calls 的 handler
  def spy(key, &block)
    @router.register(key) do |ctx|
      @calls << ctx
      block&.call(ctx)
    end
  end

  def sent_texts
    @fake.sent_messages.map { |m| m[:text] }
  end

  # --- slash 解析 -----------------------------------------------------------

  def test_bare_slash_command_routes
    spy(:start) { |ctx| "hello #{ctx[:chat_id]}" }
    @router.dispatch(update(text: "/start"))

    assert_equal 1, @calls.size
    assert_equal :slash, @calls.first[:kind]
    assert_equal "start", @calls.first[:name]
    assert_equal "", @calls.first[:args]
    assert_equal ["hello #{CHAT_ID}"], sent_texts, "handler 返回字符串应由 router 代发"
  end

  def test_slash_command_with_args
    spy(:roll)
    @router.dispatch(update(text: "/roll 2d6>=4"))

    assert_equal 1, @calls.size
    assert_equal "roll", @calls.first[:name]
    assert_equal "2d6>=4", @calls.first[:args]
  end

  def test_slash_command_with_bot_username_ours
    spy(:help)
    @router.dispatch(update(text: "/help@example_dice_bot all"))

    assert_equal 1, @calls.size
    assert_equal "help", @calls.first[:name]
    assert_equal "all", @calls.first[:args]
  end

  def test_slash_command_with_bot_username_case_insensitive
    spy(:help)
    @router.dispatch(update(text: "/help@example_dice_bot"))

    assert_equal 1, @calls.size, "Bot username 大小写不敏感（Telegram 语义）"
  end

  def test_slash_command_addressed_to_other_bot_is_silent
    spy(:help)
    spy(:start)
    @router.dispatch(update(text: "/help@SomeOtherBot"))

    assert_empty @calls, "@别 bot 的命令必须静默"
    assert_empty sent_texts
  end

  def test_unknown_slash_command_is_silent
    spy(:start)
    @router.dispatch(update(text: "/notacommand arg"))

    assert_empty @calls, "未注册命令静默（群里别的 bot 可能注册过）"
    assert_empty sent_texts
  end

  def test_slash_command_with_leading_double_slash_is_silent
    spy(:start)
    @router.dispatch(update(text: "//start"))

    assert_empty @calls, "`//start` 的命令名是 `/start`，非法"
  end

  def test_slash_command_with_only_at_is_silent
    spy(:start)
    @router.dispatch(update(text: "/@example_dice_bot"))

    assert_empty @calls
  end

  def test_all_menu_commands_are_registerable
    TelegramBot::MainMenu::ENTRIES.each do |e|
      spy(e[:command].to_sym)
    end
    TelegramBot::MainMenu::ENTRIES.each do |e|
      @router.dispatch(update(text: "/#{e[:command]}"))
    end

    assert_equal TelegramBot::MainMenu::ENTRIES.size, @calls.size,
                 "菜单里的每个命令都应可路由（命令集合以 MainMenu::ENTRIES 为准）"
  end

  def test_router_command_names_match_menu
    assert_equal TelegramBot::MainMenu::ENTRIES.map { |e| e[:command] },
                 TelegramBot::Router.menu_command_names,
                 "router 的命令集合不得与 MainMenu 漂移"
  end

  # --- 辅助轨：裸 ASCII 骰式 -----------------------------------------------

  def test_aux_dice_expressions_route
    spy(:aux)
    ["N4,3", "SB", "SB@6", "NRS_E4", "2d6>=4[=6]"].each do |cmd|
      @calls.clear
      @router.dispatch(update(text: cmd))

      assert_equal 1, @calls.size, "`#{cmd}` 应命中辅助轨"
      assert_equal cmd, @calls.first[:text]
      assert_equal :aux, @calls.first[:kind]
    end
  end

  def test_aux_dice_is_case_insensitive
    spy(:aux)
    ["2d6", "2D6+3", "d6", "sB", "nrs_e4", "SEISEN2", "NJI", "NJI@3"].each do |cmd|
      @calls.clear
      @router.dispatch(update(text: cmd))
      assert_equal 1, @calls.size, "`#{cmd}` 应命中辅助轨（大小写不敏感）"
    end
  end

  def test_aux_generic_dice_expressions_route
    spy(:aux)
    ["1d100", "2d", "d6", "d100", "3d6/2", "1d6*2", "-1d6", "2B6", "2B6>=4",
     "D66", "3TY3", "3R4", "3U4", "choice[a,b]", "BCDiceVersion", "C1", "C1+2",
     "2d6+3", "N4,3,3", "K6", "E1,N2,H3", "N3,H3[S5]", "K6[J]", "10d10>=8"].each do |cmd|
      @calls.clear
      @router.dispatch(update(text: cmd))
      assert_equal 1, @calls.size, "`#{cmd}` 应命中辅助轨"
    end
  end

  def test_aux_secret_s_prefix_route
    spy(:aux)
    # 引擎把首字母 S 当暗骰标记剥掉后重跑解析，故 S 对任何命令都成立
    ["S2d6", "sB", "SSB", "SK6", "SK6[J]", "s2d6+3"].each do |cmd|
      @calls.clear
      @router.dispatch(update(text: cmd))
      assert_equal 1, @calls.size, "`#{cmd}` 应命中辅助轨（暗骰 S 前缀）"
    end
  end

  def test_aux_appendix_brackets_route
    spy(:aux)
    ["N4,3[S]", "N4,3[C5]", "N3,H3[>4][>=4]", "K6[J][L]",
     "K6[>=5*2]", "N5,3,U4[s65+][c666+]", "2d6>=4[=6]"].each do |cmd|
      @calls.clear
      @router.dispatch(update(text: cmd))
      assert_equal 1, @calls.size, "`#{cmd}` 追加判定形态应命中"
    end
  end

  def test_aux_rule_table_names_route
    spy(:aux)
    ["SBX", "WSX", "NSRS_D", "NSRS", "KRS_D", "KRA_A", "WSE", "WS12", "SOUL",
     "KRM_C", "KRM_C@2", "SUMMON", "BIOCYBER", "BIOCYBER@12", "JITSB", "BK",
     "BK@12", "DKKI", "NJ4", "EV4", "AT4[H]", "EL4@K", "NJI", "NJI@3",
     "SEISEN2", "SEISEN9"].each do |cmd|
      @calls.clear
      @router.dispatch(update(text: cmd))
      assert_equal 1, @calls.size, "`#{cmd}` 应命中辅助轨（本仓库注册的规则命令）"
    end
  end

  def test_aux_repeat_command_with_space_routes
    spy(:aux)
    # repeat 形态**必须**含空白（引擎 Repeat#parse 要求 keyword+次数+空白+内容），
    # 且被重复的内容必须本身是条合法命令（`x3 hello` 不得放行）
    ["x3 2d6", "x3 K6", "repeat10 2D6+5"].each do |cmd|
      @calls.clear
      @router.dispatch(update(text: cmd))
      assert_equal 1, @calls.size, "`#{cmd}` 应命中辅助轨"
    end
  end

  def test_aux_space_separated_expression_is_silent
    spy(:aux)
    # 引擎 Lexer 在第一个空格处截断（`"2d6 + 3"` → `"2d6"`），若闸门照抄那个
    # 语义做前缀匹配，`2d6 roll please` 就会命中 = 抢话。故含空白的表达式一律静默。
    @router.dispatch(update(text: "2d6 + 3"))

    assert_empty @calls, "含空白的表达式不命中（宁漏不抢）；玩家写 `2d6+3` 即可"
  end

  # --- 辅助轨静默策略（§12 R4）---------------------------------------------

  def test_substring_dice_expression_in_chinese_chat_is_silent
    spy(:aux)
    @router.dispatch(update(text: "今天天气3d6怎么样"))

    assert_empty @calls, "命令只在整条消息时才算命中，聊天里的子串不算"
    assert_empty sent_texts, "中文闲聊必须静默（防抢话）"
  end

  def test_japanese_chat_is_silent
    spy(:aux)
    ["サツバツ", " nue", "2d6 人", "サツバツ判定", "3d6 で"].each do |text|
      @calls.clear
      @router.dispatch(update(text: text))
      assert_empty @calls, "日文输入一律不响应：`#{text}`"
      assert_empty sent_texts
    end
  end

  def test_plain_words_are_silent
    spy(:aux)
    ["hello", "hi", "ok", "no", "yes", "version", "today", "abc", "x",
     "nj", "ev", "today is 3d6 day"].each do |text|
      @calls.clear
      @router.dispatch(update(text: text))
      assert_empty @calls, "普通单词不得触发辅助轨：`#{text}`"
    end
  end

  def test_bare_numbers_are_silent
    spy(:aux)
    # 引擎实测：`6` / `100` / `4` / `4,3` 全部返回 nil，闸门必须同样拒绝
    ["1", "6", "100", "4", "4,3", "6+3", "2024-10-11", "12:30", "3.5"].each do |text|
      @calls.clear
      @router.dispatch(update(text: text))
      assert_empty @calls, "裸数字不是骰式：`#{text}`"
    end
  end

  def test_sentence_containing_dice_at_start_is_silent
    spy(:aux)
    ["2d6 roll please", "N4,3 hi", "SB thanks", "roll 2d6"].each do |text|
      @calls.clear
      @router.dispatch(update(text: text))
      assert_empty @calls, "骰式不在整条 → 静默：`#{text}`"
    end
  end

  def test_empty_and_whitespace_only_messages_are_silent
    spy(:aux)
    ["", " ", "\n", "  \t "].each do |text|
      @calls.clear
      @router.dispatch(update(text: text))
      assert_empty @calls, "空白消息不该触发：`#{text.inspect}`"
    end
  end

  # --- 辅助轨开关（可注入查询接口，持久化归 T2.4+）--------------------------

  def test_aux_track_can_be_disabled_per_chat
    api, fake, = build_api
    calls = []
    router = TelegramBot::Router.new(
      api: api,
      bot_username: "example_dice_bot",
      aux_enabled: ->(chat_id, _thread_id) { chat_id == 999 },
      logger: Logger.new(IO::NULL)
    )
    router.register(:aux) { |ctx| calls << ctx }

    router.dispatch(update(text: "N4,3", chat_id: CHAT_ID))
    assert_empty calls, "开关关闭的群：辅助轨静默"

    router.dispatch(update(text: "N4,3", chat_id: 999))
    assert_equal 1, calls.size, "开关开启的群：正常命中"
  end

  def test_aux_switch_receives_thread_id
    api, = build_api
    seen = []
    router = TelegramBot::Router.new(
      api: api,
      aux_enabled: ->(chat_id, thread_id) { seen << [chat_id, thread_id]; true },
      logger: Logger.new(IO::NULL)
    )
    router.register(:aux) { |_ctx| nil }
    router.dispatch(update(text: "N4,3", thread_id: 777))

    assert_equal [[CHAT_ID, 777]], seen, "开关接口须拿到 (chat_id, thread_id)"
  end

  def test_aux_track_defaults_to_enabled
    spy(:aux)
    @router.dispatch(update(text: "N4,3"))

    assert_equal 1, @calls.size, "默认辅助轨开启"
  end

  def test_aux_switch_failure_fails_closed
    api, = build_api
    calls = []
    router = TelegramBot::Router.new(
      api: api,
      aux_enabled: ->(_c, _t) { raise "db down" },
      logger: Logger.new(IO::NULL)
    )
    router.register(:aux) { |ctx| calls << ctx }

    router.dispatch(update(text: "N4,3"))
    assert_empty calls, "开关查询异常时按关闭处理（fail-closed，不抢话）"
  end

  def test_slash_still_works_when_aux_disabled
    api, = build_api
    calls = []
    router = TelegramBot::Router.new(
      api: api,
      aux_enabled: ->(_c, _t) { false },
      logger: Logger.new(IO::NULL)
    )
    router.register(:start) { |ctx| calls << ctx }

    router.dispatch(update(text: "/start"))
    assert_equal 1, calls.size, "关辅助轨不影响 slash 主轨"
  end

  # --- thread_id 透传（§3 决6）---------------------------------------------

  def test_thread_id_passthrough_from_inbound_to_send
    @router.register(:start) { "欢迎" }
    @router.dispatch(update(text: "/start", thread_id: 4242))

    assert_equal 1, @fake.sent_messages.size
    assert_equal 4242, @fake.sent_messages.first[:message_thread_id],
                 "forum 话题回复必须透传入站消息的 message_thread_id"
  end

  def test_thread_id_passthrough_for_aux_track
    @router.register(:aux) { |ctx| "掷骰 #{ctx[:text]}" }
    @router.dispatch(update(text: "N4,3", thread_id: 99))

    assert_equal 99, @fake.sent_messages.first[:message_thread_id]
  end

  def test_no_thread_id_means_no_message_thread_param
    @router.register(:start) { "hi" }
    @router.dispatch(update(text: "/start"))

    assert_nil @fake.sent_messages.first[:message_thread_id],
               "非话题场景不得凭空带 message_thread_id"
  end

  def test_handler_can_send_with_context_thread
    @router.register(:aux) do |ctx|
      ctx[:api].send_text(ctx[:chat_id], "自发自收", thread_id: ctx[:thread_id])
      nil # 返回 nil → router 不代发
    end
    @router.dispatch(update(text: "SB", thread_id: 31337))

    assert_equal 1, @fake.sent_messages.size, "handler 返回 nil 时 router 不重复代发"
    assert_equal 31337, @fake.sent_messages.first[:message_thread_id]
  end

  # --- 64 位 chat_id --------------------------------------------------------

  def test_64bit_chat_id_passed_through_unchanged
    seen = nil
    @router.register(:start) { |ctx| seen = ctx[:chat_id]; nil }
    @router.dispatch(update(text: "/start", chat_id: BIG_CHAT_ID))

    assert_equal BIG_CHAT_ID, seen, "chat_id 必须原样按 64 位整型传递"
    assert_operator BIG_CHAT_ID.abs, :>, 2**32, "该用例本身须超 32 位有效位"
  end

  def test_64bit_chat_id_works_for_aux_track_and_send
    @router.register(:aux) { "ok" }
    @router.dispatch(update(text: "2d6", chat_id: BIG_CHAT_ID))

    assert_equal 1, @fake.sent_messages.size
    assert_equal BIG_CHAT_ID, @fake.sent_messages.first[:chat_id]
  end

  def test_private_chat_and_groups_all_route
    seen = []
    @router.register(:start) { |ctx| seen << [ctx[:chat_id], ctx[:message].chat.type]; nil }

    [[12_345, "private"], [CHAT_ID, "group"], [BIG_CHAT_ID, "supergroup"]].each do |cid, type|
      @router.dispatch(update(text: "/start", chat_id: cid, chat_type: type))
    end

    assert_equal [[12_345, "private"], [CHAT_ID, "group"], [BIG_CHAT_ID, "supergroup"]], seen,
                 "私聊/群/超级群都应可路由（路由层不限制 chat.type，行为差异归 handler）"
  end

  # --- 迁移消息 / 非文本消息：安静跳过 --------------------------------------

  def test_migration_messages_are_skipped_silently
    spy(:aux)
    spy(:start)
    [@router.dispatch(update(text: "N4,3", migrate: :to)),
     @router.dispatch(update(text: "SB", migrate: :from))].each do |result|
      assert_nil result
    end

    assert_empty @calls, "迁移服务消息不得当普通消息处理（re-key 归 T2.5）"
    assert_empty sent_texts
  end

  def test_non_text_messages_are_skipped
    spy(:aux)
    spy(:start)

    non_text = [
      { photo: [{ file_id: "f", file_unique_id: "u", width: 1, height: 1 }] },
      { sticker: { file_id: "f", file_unique_id: "u", type: "regular",
                   width: 1, height: 1, is_animated: false, is_video: false } },
      { location: { latitude: 1.5, longitude: 2.5 } },
      # 有 caption 但无 text 的媒体消息：text 为 nil，同样不路由
      { caption: "2d6" }
    ]
    non_text.each_with_index do |extra, i|
      @router.dispatch(update(message_id: 200 + i, extra: extra))
    end

    assert_empty @calls, "贴纸/图片等服务消息一律安静跳过"
    assert_empty sent_texts
  end

  def test_update_without_message_is_skipped
    spy(:aux)
    update = Telegram::Bot::Types::Update.new(
      update_id: 9,
      callback_query: { id: "cb", from: { id: 1, is_bot: false, first_name: "x" },
                        chat_instance: "ci", data: "1" }
    )

    assert_nil @router.dispatch(update), "非消息 update（callback_query 等）本层不处理"
    assert_empty @calls
  end

  def test_non_message_update_types_are_ignored
    spy(:aux)
    update = Telegram::Bot::Types::Update.new(
      update_id: 10,
      inline_query: { id: "q1", from: { id: 1, is_bot: false, first_name: "x" },
                      query: "N4,3", offset: "" }
    )

    assert_nil @router.dispatch(update)
    assert_empty @calls
  end

  # --- 错误兜底 -------------------------------------------------------------

  def test_handler_exception_does_not_kill_loop
    @router.register(:start) { raise "boom" }
    good = []
    @router.register(:aux) { |ctx| good << ctx[:text]; nil }

    ["/start", "N4,3", "SB"].each { |t| @router.dispatch(update(text: t)) }

    assert_equal ["N4,3", "SB"], good, "一个 handler 抛异常不得影响后续消息"
  end

  def test_handler_exception_logs_structural_info_only
    io = StringIO.new
    router = TelegramBot::Router.new(api: @api, logger: Logger.new(io))
    router.register(:roll) { |_ctx| raise "secret user text: 掷骰失败" }
    router.dispatch(update(text: "/roll 2d6 我的私房内容"))

    log = io.string
    assert_includes log, "handler 异常"
    refute_includes log, "我的私房内容", "日志绝不含用户正文（隐私红线）"
    refute_includes log, "掷骰失败", "日志不打印异常 message"
    assert_includes log, "RuntimeError", "只记异常类名"
  end

  def test_send_failure_does_not_raise
    failing = Object.new
    def failing.send_text(*) = raise(IOError, "network down")
    router = TelegramBot::Router.new(api: failing, logger: Logger.new(IO::NULL))
    router.register(:start) { "hi" }

    result = router.dispatch(update(text: "/start"))
    assert_equal "hi", result, "发送失败只记不抛，handler 的返回值仍照常回传"
  end

  def test_handler_returning_empty_string_sends_nothing
    @router.register(:start) { "" }
    @router.dispatch(update(text: "/start"))

    assert_empty @fake.sent_messages, "空串不得发出去（Telegram 会 400 拒）"
  end

  def test_processor_loop_survives_exceptions
    api, fake, = build_api
    router = TelegramBot::Router.new(api: api, logger: Logger.new(IO::NULL))
    router.register(:roll) { raise "kaboom" }
    router.register(:aux) { |ctx| "掷 #{ctx[:text]}" }

    api.process_updates(
      [update(text: "/roll 1d6"), update(text: "2d6"), update(text: "/roll 2d6")],
      dispatch: router.method(:dispatch)
    )

    assert_equal ["掷 2d6"], fake.sent_messages.map { |m| m[:text] }
  end

  # --- handler 注册表 -------------------------------------------------------

  def test_register_returns_self_for_chaining
    assert_same @router, @router.register(:start) { "x" }
  end

  def test_register_accepts_string_and_symbol_keys
    seen = []
    @router.register("help") { |ctx| seen << ctx[:name] }
    @router.register(:settings) { |ctx| seen << ctx[:name] }

    ["/help", "/settings"].each { |t| @router.dispatch(update(text: t)) }
    assert_equal %w[help settings], seen
  end

  def test_register_with_block_syntax
    seen = []
    @router.register(:roll) { |ctx| seen << ctx[:args] }
    @router.dispatch(update(text: "/roll 2d6"))

    assert_equal ["2d6"], seen
  end

  def test_handlers_hash_is_copied_not_mutated
    handlers = {}
    router = TelegramBot::Router.new(api: @api, handlers: handlers)
    router.register(:start) { "x" }

    assert_empty handlers, "构造参数不应被 router 就地改写（调用方字典保持干净）"
  end

  def test_aux_handler_absent_means_silent
    @router.dispatch(update(text: "N4,3"))

    assert_empty @fake.sent_messages, "未注册辅助轨 handler 时静默，不自发消息"
  end

  # --- context 内容 ---------------------------------------------------------

  def test_context_carries_all_fields_handlers_need
    seen = nil
    @router.register(:system) { |ctx| seen = ctx; nil }
    msg = update(text: "/system NinjaSlayer2Ex", thread_id: 12, user_id: 777)
    @router.dispatch(msg)

    assert_equal :slash, seen[:kind]
    assert_equal "system", seen[:name]
    assert_equal "NinjaSlayer2Ex", seen[:args]
    assert_equal CHAT_ID, seen[:chat_id]
    assert_equal 12, seen[:thread_id]
    assert_equal 777, seen[:user_id]
    assert_equal "/system NinjaSlayer2Ex", seen[:command].raw_text
    assert_same @router, seen[:router]
    assert_same @api, seen[:api]
  end

  def test_aux_context_has_no_command_but_has_text
    seen = nil
    @router.register(:aux) { |ctx| seen = ctx; nil }
    @router.dispatch(update(text: "N4,3"))

    assert_nil seen[:command]
    assert_equal "N4,3", seen[:text]
    assert_equal "", seen[:args].to_s
  end

  # --- 解析器纯函数 ---------------------------------------------------------

  def test_parse_slash_returns_struct
    cmd = @router.parse_slash("/roll 2d6 >= 4")

    assert_instance_of TelegramBot::SlashCommand, cmd
    assert_equal "roll", cmd.name
    assert_equal "2d6 >= 4", cmd.args
    assert cmd.args?
    assert_equal "/roll 2d6 >= 4", cmd.raw_text
  end

  def test_parse_slash_without_args
    cmd = @router.parse_slash("/start")

    refute cmd.args?
    assert_equal "", cmd.args
  end

  def test_parse_slash_with_other_bot_returns_nil
    assert_nil @router.parse_slash("/start@OtherBot")
  end

  def test_bot_username_nil_rejects_at_suffix
    # fail-closed（kimi T2.3 评审）：username 未知时带 @后缀的命令一律拒答——
    # 宁可不答也不抢别的 bot 的命令（多 bot 群里的静默策略承诺）。
    router = TelegramBot::Router.new(api: @api, bot_username: nil)
    refute router.bot_matched?("anything"), "未注入 username 时不得响应任何 @后缀命令"
  end

  def test_edited_message_is_routed
    seen = []
    @router.register(:aux) { |ctx| seen << ctx[:text]; nil }
    edited = Telegram::Bot::Types::Update.new(
      update_id: 11,
      edited_message: Telegram::Bot::Types::Message.new(
        message_id: 500, date: 1, chat: { id: CHAT_ID, type: "supergroup" },
        from: { id: 42, is_bot: false, first_name: "T" }, text: "2d6"
      )
    )
    @router.dispatch(edited)

    assert_equal ["2d6"], seen, "编辑后的消息同样应可路由"
  end

  # --- 辅助轨判定的独立断言（防回归）---------------------------------------

  def test_aux_match_is_pure_function_of_whole_text
    assert @router.aux_match?("N4,3")
    refute @router.aux_match?("N4,3 hello")
    refute @router.aux_match?("看看 N4,3")
    refute @router.aux_match?("今天天气3d6怎么样")
  end

  # 闸门与引擎的一致性是本任务的核心风险，下面两条把它钉住：
  #   - 凡是引擎接受的 ASCII 命令，闸门不得漏（漏 = 用户掷不出骰）
  #   - 凡是闲聊/裸数字，闸门不得放（放 = 抢话，§12 R4）
  def test_gate_covers_every_engine_accepted_command
    toml_inputs = engine_accepted_ascii_commands

    # 含空白的形态被刻意排除：引擎 Lexer 会在第一个空格处截断
    # （`"K6 [J]"` → `"K6"`），若闸门照抄该语义做前缀匹配，
    # `2d6 roll please` 就会命中 = 抢话。故闸门只放行**整条无空白**的形态。
    space_free = toml_inputs.reject { |cmd| cmd.match?(/\s/) }
    missed = space_free.reject { |cmd| @router.aux_match?(cmd) }
    assert_empty missed,
                 "闸门漏掉了引擎接受的命令（玩家掷不出骰）：#{missed.first(10).inspect}"
    assert_operator space_free.size, :>, 200, "语料本身须足够大才有意义"
  end

  def test_gate_rejects_chatter_and_bare_numbers
    noise = ["hello", "hi", "ok", "OK", "no", "yes", "version", "today", "abc",
             "x", "NJ", "EV", "AT", "EL", "K", "CC", "1", "4", "6", "100",
             "3.5", "2024-10-11", "12:30", "6+3", "SOULx", "BIOCYBERR", "AT4x",
             "NJ4x", "SB_", "(1+2)*3", "today is 3d6 day",
             # 追加判定子片段裸用（kimi T2.3 评审抓到 RE_EX_APPENDIX_ONE 泄漏）：
             # 单字母闲聊最常见的形态，四类引擎全返回 nil，闸门必须拒
             "J", "L", "j", "l", "=6", ">=4", "sJ", "S=6", "x3 l", "x3 =6"]

    hits = noise.select { |text| @router.aux_match?(text) }
    assert_empty hits, "闸门放行了非骰式文本（会抢话）：#{hits.inspect}"
  end

  def test_aux_pattern_anchors_both_ends
    src = @router.aux_pattern.source

    assert_includes src, "\\A", "必须锚定开头"
    assert_includes src, "\\z", "必须锚定结尾（整条匹配）"
  end

  def test_aux_pattern_is_derived_from_engine_command_regexes
    refute_empty TelegramBot::AuxMatcher::DEFAULT_SYSTEM_IDS
    assert TelegramBot::Router.default_systems.any?,
           "默认规则集应可解析（引擎已 bootstrap）"
    refute_empty TelegramBot::AuxMatcher.command_pattern_sources(TelegramBot::Router.default_systems),
                 "命令正则应反射自各规则的锚定 RE_* 常量（新增命令自动进网）"
  end

  def test_aux_match_without_engine_falls_back_to_generic
    router = TelegramBot::Router.new(api: @api, aux_systems: [], logger: Logger.new(IO::NULL))

    assert router.aux_match?("2d6+3"), "无引擎时通用骰式仍应命中"
    assert router.aux_match?("1d100")
    refute router.aux_match?("SB"), "无引擎时规则表名无从判定（保守静默）"
    refute router.aux_match?("1"), "无引擎时裸数字仍须静默"
  end

  # --- 闸门构造的可测性 ---------------------------------------------------

  def test_gate_harvests_anchored_engine_patterns
    sources = TelegramBot::AuxMatcher.command_pattern_sources(TelegramBot::Router.default_systems)

    refute_empty sources, "应从引擎反射到锚定命令正则"
    sources.each do |src|
      refute src.start_with?('\A') || src.start_with?('^'),
             "反射来的源不应再带首锚点（由外层统一包裹）：#{src[0, 30]}"
      refute src.end_with?('\z') || src.end_with?('$'),
             "反射来的源不应再带尾锚点（由外层统一包裹）：#{src[-30..]}"
    end
  end

  def test_gate_skips_loose_diceroll_patterns
    sources = TelegramBot::AuxMatcher.command_pattern_sources(TelegramBot::Router.default_systems)
    joined = sources.join("|")

    # RE_JUDGE_DICEROLL 脱掉 prefixes_pattern 前缀闸门后会放行裸数字
    refute_match(/\d\+,/i, joined)
    refute(@router.aux_match?("4"), "松散的正则绝不能把裸数字放进闸门")
  end

  private

  # 引擎真正接受的 ASCII 命令语料（来自本仓库 toml 确定性用例）。
  # 只取「引擎 eval 返回非 nil」的——即用户真的能掷出来的命令。
  def engine_accepted_ascii_commands
    require "tomlrb"

    Dir[File.expand_path("../data/*.toml", __dir__)].flat_map do |path|
      Tomlrb.load_file(path, symbolize_keys: true)[:test].filter_map do |case_data|
        next if case_data[:failure] || case_data[:fumble]

        system_id = case_data[:game_system].to_s
        input = case_data[:input].to_s
        next unless system_id.start_with?("NinjaSlayer")
        next unless input.ascii_only? && !input.empty?

        klass = begin
          BCDice.game_system_class(system_id)
        rescue StandardError
          nil
        end
        next if klass.nil?
        next if klass.eval(input).nil?

        input
      end
    end.uniq
  end
end