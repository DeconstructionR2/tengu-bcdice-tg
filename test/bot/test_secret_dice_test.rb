# frozen_string_literal: true

# ============================================================================
# test/bot/test_secret_dice_test.rb — 暗骰 handler + callback 路由分支（T3.1）
#
# 覆盖计划 §8 T3.1 / §12 R6 / §15.3 E5 的全部验收点：
#
# handler 层：
#   - /secret <式> 跑**当前作用域**规则系统（三级查找复用 T2.4），结果落 secrets
#   - 回发是 ephemeral（参数含 ephemeral_message_parameters.receiver_user_id）
#     且**带内联「公开」按钮**；handler 恒返回 nil（结果绝不经 router 代发）
#   - 引擎 nil / 空文本 / 规则系统缺失 → ephemeral 回提示，不落库
#   - /secret last：本人最近一次重取（带同一个按钮）；别人的行拿不到
#   - 无参 → 用法提示；拿不到 user_id → 完全静默（不放任何东西进群）
#   - **防泄**：/secret 的结果文本绝不出现在普通消息里
#
# callback 路由分支：
#   - data 定位 secrets 行 → 本人公开成功：answerCallbackQuery **先答**、
#     普通消息发到记录的 chat_id/thread_id、**随后删行**（E5）
#   - 非本人拒绝：只 toast、不发消息、不删行
#   - 未知 data / 已过期 / 已公开过 → 兜底应答，绝不静默转圈
#   - handler 抛异常 → router 兜底补答（客户端不会永远转圈）
#   - 未注册 :callback_query handler → warn + 照答
#
# 真身接线（防「看着接了实则从不执行」）：用**真 handler + 真 Router** 端到端。
# 全程 mock，零联网、零真 token。
# ============================================================================

require "minitest/autorun"
require "logger"
require_relative "test_helper"
require_relative "../../bot/router"
require_relative "../../bot/handlers/secret_dice"
require_relative "../../db/connection"
require_relative "../../db/settings"
require_relative "../../db/secrets"
require_relative "../../lib/engine_bootstrap"

EngineBootstrap.bootstrap!(reload_backend: true)

# ============================================================================
# 层 1：handler 直调（注入内存 DB + 假 api，验语义）
# ============================================================================
class TestSecretDiceHandler < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789
  TOPIC = 88
  USER = 42
  OTHER = 43

  # 假 api：把 ephemeral / 普通发送分别记下来（形态与 bot/telegram_api.rb 一致）
  class RecordingApi
    attr_reader :ephemeral, :plain, :answered

    def initialize(raise_on_send: nil)
      @ephemeral = []
      @plain = []
      @answered = []
      @raise_on_send = raise_on_send
    end

    def send_ephemeral(chat_id, text, user_id:, thread_id: nil, **extra)
      raise @raise_on_send if @raise_on_send

      @ephemeral << { chat_id: chat_id, text: text, user_id: user_id,
                      thread_id: thread_id }.merge(extra)
      :ephemeral_message
    end

    def send_text(chat_id, text, thread_id: nil, **extra)
      raise @raise_on_send if @raise_on_send

      @plain << { chat_id: chat_id, text: text, thread_id: thread_id }.merge(extra)
      :plain_message
    end
  end

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @settings = TenguDB::Settings.new(@conn)
    @store = TenguDB::Secrets.new(@conn)
    @api = RecordingApi.new
    @handler = TelegramBot::Handlers::SecretDiceHandler.new(
      settings: @settings, secrets: @store, logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    @conn.close
  end

  # 造一个 handler 上下文（形状与 router run_handler 完全一致）
  def ctx(name: "secret", args: "", chat_id: CHAT_ID, thread_id: nil, user_id: USER,
          api: nil, data: nil, answer: nil)
    answer ||= ->(_text = nil, alert: false) {}
    { router: nil, api: api || @api, kind: name ? :slash : :callback_query,
      command: nil, name: name, args: args, text: nil,
      chat_id: chat_id, thread_id: thread_id, user_id: user_id, message: nil,
      callback_query: nil, data: data, answer_callback_query: answer }
  end

  # --- /secret <式> ------------------------------------------------------

  def test_roll_stores_result_and_replies_ephemeral_with_button
    out = @handler.call(ctx(args: "SB@6", thread_id: TOPIC))

    assert_nil out, "handler 恒返回 nil——返回 String 会被 router 代发进群（暗骰命门）"

    assert_equal 1, @api.ephemeral.size
    msg = @api.ephemeral.first
    assert_equal CHAT_ID, msg[:chat_id]
    assert_equal TOPIC, msg[:thread_id], "话题内暗骰也要带 thread（否则掉到 General）"
    assert_equal USER, msg[:user_id]

    record, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    refute_nil record, "结果必须落 secrets 表（ephemeral 25 分钟就消失，R6）"
    assert_equal "SB@6", record.command
    assert_includes record.result_text, "6"
    assert_includes msg[:text], record.result_text, "ephemeral 必须带结果全文"
    assert_includes msg[:text], "/secret SB@6", "呈现仿天狗：`/snd <式>` + 结果"
  end

  def test_roll_attaches_public_button_with_secrets_namespace
    @handler.call(ctx(args: "SB"))

    markup = @api.ephemeral.first[:reply_markup]
    refute_nil markup, "必须有内联「公开」按钮"
    button = markup.inline_keyboard.first.first

    assert_equal TelegramBot::Handlers::SecretDiceHandler::BUTTON_TEXT, button.text
    data = button.callback_data
    assert data.start_with?("sec:"), "callback_data 必须带命名空间前缀"
    record, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    assert_equal record.id, TenguDB::Secrets.secret_id_from_callback_data(data)
    assert_operator data.bytesize, :<=, 64, "callback_data 上限 64 字节"
  end

  def test_roll_uses_topic_game_system_then_group_then_default
    # 三级查找：话题设置（话题内走 NinjaSlayerEx）
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "NinjaSlayerEx")
    @handler.call(ctx(args: "JITSB", thread_id: TOPIC))
    in_topic, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    assert_includes in_topic.result_text, "ジツ拡張", "话题内应走话题规则系统"

    # 三级查找：群默认（话题外看群级行）
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: "NinjaSlayerEx")
    @handler.call(ctx(args: "JITSB", thread_id: nil))
    in_group, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    assert_includes in_group.result_text, "ジツ拡張", "话题外回落到群级设置"

    # 三级查找：全局默认（都没设 → NinjaSlayer2Ex，该系统无 JITSB 扩展）
    @conn.execute("DELETE FROM chat_settings")
    @api.ephemeral.clear
    @handler.call(ctx(args: "JITSB", thread_id: nil))

    assert_includes @api.ephemeral.first[:text],
                    TelegramBot::Handlers::DiceHandler::UNKNOWN_COMMAND,
                    "全都没设时应回全局默认 NinjaSlayer2Ex（该系统不认识 JITSB）"
    assert_equal 2, @store.count_for, "全局默认这一档没有新结果入库"
  end

  def test_roll_nonexistent_system_reports_ephemerally_and_stores_nothing
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: "NoSuchSystemXYZ")

    @handler.call(ctx(args: "SB"))

    assert_equal 1, @api.ephemeral.size
    assert_includes @api.ephemeral.first[:text], "不可用"
    assert_equal 0, @store.count_for, "引擎不可用不该写库"
  end

  def test_roll_engine_nil_reports_unknown_command_ephemerally
    @handler.call(ctx(args: "NRS")) # 引擎 nil（NRS@3 才有效）

    assert_equal 1, @api.ephemeral.size
    assert_includes @api.ephemeral.first[:text], "不接受"
    refute @api.ephemeral.first.key?(:reply_markup),
           "没有结果就没有按钮（按钮会指向不存在的 secrets 行）"
    assert_equal 0, @store.count_for
  end

  def test_roll_still_delivers_when_persisting_fails
    broken = Object.new
    def broken.create(**_args) = [nil, SQLite3::ConstraintException]

    handler = TelegramBot::Handlers::SecretDiceHandler.new(
      settings: @settings, secrets: broken, logger: Logger.new(IO::NULL)
    )
    handler.call(ctx(args: "SB"))

    assert_equal 1, @api.ephemeral.size, "落库失败不该让结果丢失——仍以 ephemeral 送达"
    assert_includes @api.ephemeral.first[:text], "未能存档"
    refute @api.ephemeral.first.key?(:reply_markup), "没落库就不能挂按钮"
  end

  # --- 防泄（暗骰的命门）-----------------------------------------------

  def test_secret_result_never_leaves_the_ephemeral_channel
    @handler.call(ctx(args: "SB", thread_id: TOPIC))

    assert_empty @api.plain, "暗骰结果绝不走普通消息（只有点「公开」按钮才公开）"
    record, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    refute_empty record.result_text
    # 结果正文既没被加进 plain，也没被单独发一条
    assert_equal 1, @api.ephemeral.size
  end

  def test_secret_is_silent_without_a_resolvable_sender
    assert_nil @handler.call(ctx(args: "SB", user_id: nil))
    assert_nil @handler.call(ctx(args: "SB", user_id: 0))

    assert_empty @api.ephemeral, "定不出接收人就不该发任何东西（不放暗骰内容进群）"
    assert_empty @api.plain
    assert_equal 0, @store.count_for
  end

  # --- 无参 /secret ------------------------------------------------------

  def test_usage_without_args_goes_ephemeral
    @handler.call(ctx(args: "   "))

    assert_equal 1, @api.ephemeral.size
    assert_includes @api.ephemeral.first[:text], "/secret <骰式或命令>"
    assert_includes @api.ephemeral.first[:text], "/secret last"
  end

  # --- /secret last（R6 缓解）-------------------------------------------

  def test_last_replays_the_latest_result_with_the_same_button
    @handler.call(ctx(args: "SB@6", thread_id: TOPIC))
    first, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    @api.ephemeral.clear

    @handler.call(ctx(args: "last", thread_id: TOPIC))

    replay = @api.ephemeral.first
    assert_equal first.result_text, replay[:text].split("\n", 2).last
    assert_equal first.id,
                 TenguDB::Secrets.secret_id_from_callback_data(
                   replay[:reply_markup].inline_keyboard.first.first.callback_data
                 ),
                 "last 是「重看」不是「再掷」——复用原行与同一个按钮"
    assert_equal 1, @store.count_for, "last 不该新增 secrets 行（否则每次 last 都会把 TTL 往后推）"
  end

  def test_last_is_case_insensitive
    @handler.call(ctx(args: "SB"))
    @api.ephemeral.clear

    @handler.call(ctx(args: "  LAST "))

    assert_includes @api.ephemeral.first[:text], "SB"
  end

  def test_last_without_any_record_says_so_ephemerally
    @handler.call(ctx(args: "last"))

    assert_equal 1, @api.ephemeral.size
    assert_includes @api.ephemeral.first[:text], "还没有暗骰记录"
    refute @api.ephemeral.first.key?(:reply_markup)
  end

  def test_last_never_leaks_another_players_result
    @handler.call(ctx(args: "SB@6", user_id: USER))
    @api.ephemeral.clear

    @handler.call(ctx(args: "last", user_id: OTHER))

    assert_includes @api.ephemeral.first[:text], "还没有暗骰记录",
                    "别人的暗骰结果不该被重取（R6 重取只对本人开放）"
    refute_includes @api.ephemeral.first[:text], "6"
  end

  def test_last_is_scoped_per_chat
    @handler.call(ctx(args: "SB@6", chat_id: CHAT_ID))
    @api.ephemeral.clear

    @handler.call(ctx(args: "last", chat_id: -100_222_222))

    assert_includes @api.ephemeral.first[:text], "还没有暗骰记录"
  end

  # --- 「公开」按钮回调（handler 侧：权限 + 发送 + 删行）-----------------

  def seed_secret(user_id: USER, chat_id: CHAT_ID, thread_id: TOPIC, text: "seeded")
    record, = @store.create(chat_id: chat_id, thread_id: thread_id, user_id: user_id,
                            command: "SB@6", result_text: text)
    record
  end

  def cb_ctx(record, user_id: USER, api: nil)
    answers = []
    answer = lambda do |text = nil, alert: false|
      answers << { text: text, alert: alert }
      nil
    end
    { router: nil, api: api || @api, kind: :callback_query, command: nil,
      name: nil, args: nil, text: nil, chat_id: nil, thread_id: nil,
      user_id: user_id, message: nil, callback_query: nil,
      data: TenguDB::Secrets.callback_data(record.id), answer_callback_query: answer,
      answers: answers }
  end

  def test_owner_clicking_public_posts_normal_message_and_deletes_row
    record = seed_secret(text: "6 サツバツ")

    @handler.handle_callback(cb_ctx(record))

    assert_equal 1, @api.plain.size, "公开走**普通消息**（任何客户端都看得见）"
    assert_equal "6 サツバツ", @api.plain.first[:text], "逐字发结果，不加前缀"
    assert_equal CHAT_ID, @api.plain.first[:chat_id], "发到记录里的 chat_id"
    assert_equal TOPIC, @api.plain.first[:thread_id], "发回记录里的话题（§3 决6）"
    assert_empty @api.ephemeral, "公开不发 ephemeral"
    assert_nil @store.find(record.id), "E5：公开成功后删行"
  end

  def test_public_answers_the_callback_before_sending
    record = seed_secret
    calls = []
    # 记录时序：应答必须发生在发送之前（先答后干活）
    ctx = cb_ctx(record)
    ctx[:api] = Object.new.tap do |api|
      api.define_singleton_method(:send_text) do |_chat, text, thread_id: nil, **_kw|
        calls << [:send, text]
        :ok
      end
    end
    ctx[:answer_callback_query] = lambda do |text = nil, alert: false|
      calls << [:answer, text, alert]
      nil
    end

    @handler.handle_callback(ctx)

    assert_equal %i[answer send], calls.map(&:first),
                 "必须先 answerCallbackQuery 再发消息（否则用户干等一轮往返）"
  end

  def test_non_owner_clicking_public_is_refused_and_row_survives
    record = seed_secret
    ctx = cb_ctx(record, user_id: OTHER)

    @handler.handle_callback(ctx)

    assert_empty @api.plain, "非本人点按钮绝不能公开结果"
    refute_nil @store.find(record.id), "被拒的行必须留着（本人之后还能公开）"
    assert_equal 1, ctx[:answers].size
    assert_includes ctx[:answers].first[:text], "只有掷骰的本人"
    assert ctx[:answers].first[:alert],
           "拒绝应该用弹窗（alert），用户不会忽略"
  end

  def test_unknown_or_expired_callback_data_gets_a_toast_and_nothing_else
    answered = []
    answer = ->(text = nil, alert: false) { answered << text }
    base = { router: nil, api: @api, kind: :callback_query, name: nil,
             user_id: USER, answer_callback_query: answer, callback_query: nil }

    @handler.handle_callback(base.merge(data: "ct:not-ours"))
    assert_equal 1, answered.size
    assert_includes answered.last, "失效"
    assert_empty @api.plain

    # 已过期（行不存在）
    @handler.handle_callback(base.merge(data: TenguDB::Secrets.callback_data("f" * 16)))
    assert_equal 2, answered.size
    assert_includes answered.last, "过期"
    assert_empty @api.plain, "过期/失效都只是 toast，不得发任何消息"
  end

  def test_clicking_twice_second_time_reports_expired
    record = seed_secret
    @handler.handle_callback(cb_ctx(record)) # 第一次：公开 + 删行
    ctx = cb_ctx(record)

    @handler.handle_callback(ctx)

    assert_includes ctx[:answers].last[:text], "过期", "E5 删行后按钮不再可用（防重复公开）"
    assert_equal 1, @api.plain.size, "只该发过一次"
  end

  def test_send_failure_keeps_the_row_for_a_retry
    record = seed_secret
    failing = RecordingApi.new(raise_on_send: IOError.new("network down"))

    @handler.handle_callback(cb_ctx(record, api: failing))

    refute_nil @store.find(record.id),
               "发送失败时行必须留着（否则按钮提示已公开、群里却没有）"
  end

  def test_public_without_api_injection_warns_and_keeps_the_row
    record = seed_secret
    ctx = cb_ctx(record)
    ctx[:api] = nil

    @handler.handle_callback(ctx)

    refute_nil @store.find(record.id)
  end
end

# ============================================================================
# 层 2：真身 handler + 真 Router 端到端接线（T2.6 教训：只测单元会漏接线 bug）
# ============================================================================
class TestSecretDiceRouting < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789
  TOPIC = 88
  USER = 42
  OTHER = 43

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @store = TenguDB::Secrets.new(@conn)
    # 录制探针（kimi T3.5 评审提案 #4 的钉）：只收 record_bot_output
    @log_spy = Object.new
    @log_spy.define_singleton_method(:record_bot_output) do |chat_id:, thread_id:, text:|
      (@recorded ||= []) << { chat_id: chat_id, thread_id: thread_id, text: text }
    end
    @log_spy.define_singleton_method(:recorded) { @recorded ||= [] }
    @handler = TelegramBot::Handlers::SecretDiceHandler.new(
      settings: TenguDB::Settings.new(@conn), secrets: @store,
      session_log: @log_spy,
      logger: Logger.new(IO::NULL)
    )
    @api, @fake, = build_api
    @answers = []
    # gem 形态的 CallbackQuery（真实形状：id / from / chat_instance / data / message）
    @router = TelegramBot::Router.new(
      api: @api,
      handlers: TelegramBot::Handlers::SecretDiceHandler.registry(@handler),
      bot_username: "example_dice_bot",
      answer_callback: ->(id, text = nil, alert: false) { @answers << { id: id, text: text, alert: alert } },
      logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    @conn.close
  end

  def message_update(text:, user_id: USER, thread_id: nil, chat_id: CHAT_ID)
    attrs = { message_id: 1, date: 1_700_000_000,
              chat: { id: chat_id, type: "supergroup" },
              from: { id: user_id, is_bot: false, first_name: "Tester" }, text: text }
    attrs[:message_thread_id] = thread_id if thread_id
    Telegram::Bot::Types::Message.new(**attrs)
  end

  def callback_update(data:, user_id: USER, query_id: "q-1")
    Telegram::Bot::Types::CallbackQuery.new(
      id: query_id,
      from: { id: user_id, is_bot: false, first_name: "Tester" },
      chat_instance: "ci-1", data: data,
      message: { message_id: 9, date: 1_700_000_000,
                 chat: { id: CHAT_ID, type: "supergroup" }, text: "/secret SB" }
    )
  end

  def ephemeral_sends
    @fake.sent_messages.select { |m| m[:ephemeral_message_parameters] }
  end

  def plain_sends
    @fake.sent_messages.reject { |m| m[:ephemeral_message_parameters] }
  end

  # --- slash 主轨 --------------------------------------------------------

  def test_secret_slash_is_routed_and_only_ephemeral_reaches_the_chat
    @router.dispatch(message_update(text: "/secret SB@6", thread_id: TOPIC))

    assert_equal 1, ephemeral_sends.size, "结果必须走 ephemeral"
    assert_empty plain_sends, "普通消息一条都不许有（暗骰命门）"
    assert_equal USER, ephemeral_sends.first[:ephemeral_message_parameters][:receiver_user_id]
    assert_equal TOPIC, ephemeral_sends.first[:message_thread_id], "thread 透传"

    button = ephemeral_sends.first[:reply_markup].inline_keyboard.first.first
    record, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    assert_equal TenguDB::Secrets.callback_data(record.id), button.callback_data
  end

  def test_secret_last_is_routed_end_to_end
    @router.dispatch(message_update(text: "/secret SB@6"))
    @fake.sent_messages.clear

    @router.dispatch(message_update(text: "/secret last"))

    assert_equal 1, ephemeral_sends.size
    assert_includes ephemeral_sends.first[:text], "/secret SB@6"
    assert_empty plain_sends
  end

  def test_secret_usage_without_args_is_routed
    @router.dispatch(message_update(text: "/secret"))

    assert_equal 1, ephemeral_sends.size
    assert_includes ephemeral_sends.first[:text], "用法：/secret"
    assert_empty plain_sends
  end

  # --- 防泄回归：普通轨的 S 前缀仍然不回结果（T2.4 的活，不能回归）------

  def test_bare_secret_prefixed_roll_still_never_leaks_through_normal_channel
    dice = TelegramBot::Handlers::DiceHandler.new(
      settings: TenguDB::Settings.new(@conn), logger: Logger.new(IO::NULL)
    )
    router = TelegramBot::Router.new(
      api: @api,
      handlers: TelegramBot::Handlers::DiceHandler.registry(dice).merge(
        TelegramBot::Handlers::SecretDiceHandler.registry(@handler)
      ),
      bot_username: "example_dice_bot", logger: Logger.new(IO::NULL)
    )

    router.dispatch(message_update(text: "/roll S2d6")) # slash 轨：提示，无结果
    router.dispatch(message_update(text: "S2d6"))      # 辅助轨：完全静默

    assert_equal 1, plain_sends.size, "只有 slash 轨的一句指路提示"
    assert_includes plain_sends.first[:text], "/secret"
    refute_match(/\d+\s*\+\s*\d+/, plain_sends.first[:text],
                 "提示里绝不能出现暗骰结果")
  end

  # --- callback 分支 ----------------------------------------------------

  def test_owner_button_click_publices_and_deletes_end_to_end
    @router.dispatch(message_update(text: "/secret SB@6", thread_id: TOPIC))
    record, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)

    @router.dispatch(callback_update(data: TenguDB::Secrets.callback_data(record.id)))

    assert_equal 1, plain_sends.size, "公开应发一条普通消息"
    assert_includes plain_sends.first[:text], record.result_text
    assert_equal TOPIC, plain_sends.first[:message_thread_id]
    assert_equal 1, @answers.size, "answerCallbackQuery 必须被调一次"
    assert_equal "q-1", @answers.first[:id], "应答必须带 query 的 id（否则客户端转圈）"
    assert_nil @store.find(record.id), "E5：公开后删行"
  end

  def test_button_click_does_not_re_route_the_attached_message_as_a_new_roll
    @router.dispatch(message_update(text: "/secret SB@6", thread_id: TOPIC))
    record, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    @fake.sent_messages.clear
    @answers.clear

    # 回调所附的原消息文本是 "/secret SB"（含骰式）——绝不能被二次掷骰
    @router.dispatch(callback_update(data: TenguDB::Secrets.callback_data(record.id)))

    assert_equal 1, @fake.sent_messages.size, "只有公开那一条，不得凭空多掷一次"
    assert_empty ephemeral_sends
  end

  def test_non_owner_button_click_is_refused_end_to_end
    @router.dispatch(message_update(text: "/secret SB@6"))
    record, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    @fake.sent_messages.clear
    @answers.clear

    @router.dispatch(callback_update(data: TenguDB::Secrets.callback_data(record.id),
                                     user_id: OTHER))

    assert_empty plain_sends, "非本人不得触发公开"
    refute_nil @store.find(record.id)
    assert_equal 1, @answers.size, "拒绝也要应答（否则客户端一直转圈）"
    assert @answers.first[:alert], "拒绝用 alert 弹窗"
  end

  def test_unregistered_callback_data_still_gets_answered
    @router.dispatch(callback_update(data: "bank:someone-elses-namespace"))

    assert_equal 1, @answers.size, "不是自己的按钮也要应答（否则客户端转圈到天荒地老）"
    assert_empty @fake.sent_messages
  end

  def test_callback_without_registered_handler_warns_but_answers
    bare = TelegramBot::Router.new(api: @api, bot_username: "x",
                                  logger: Logger.new(IO::NULL))

    bare.dispatch(callback_update(data: "sec:#{'a' * 16}"))

    assert_empty @fake.sent_messages
  end

  def test_handler_exception_still_gets_answered_so_the_client_stops_spinning
    boom = Class.new do
      def call(_context) = raise(IOError, "boom")
    end
    router = TelegramBot::Router.new(
      api: @api, handlers: { callback_query: boom.new },
      bot_username: "x", logger: Logger.new(IO::NULL),
      answer_callback: ->(id, text = nil, alert: false) { @answers << { id: id, text: text, alert: alert } }
    )

    router.dispatch(callback_update(data: "sec:#{'a' * 16}"))

    assert_equal 1, @answers.size, "handler 炸了也必须兜底应答（run_handler 只 warn 不抛）"
    assert_empty @fake.sent_messages
  end

  # --- TelegramApi#answer_callback_query 的接线（T2.1 层的封装）----------

  def test_default_answer_channel_goes_through_telegram_api
    api, fake, = build_api
    router = TelegramBot::Router.new(api: api, bot_username: "x",
                                     logger: Logger.new(IO::NULL))
    router.register(:callback_query) { |ctx| ctx[:answer_callback_query].call("ok"); nil }

    router.dispatch(callback_update(data: "sec:#{'b' * 16}"))

    assert_equal 1, fake.answered.size, "默认应答通道应走 TelegramApi#answer_callback_query"
    assert_equal "q-1", fake.answered.first[:callback_query_id]
    assert_equal "ok", fake.answered.first[:text]
  end

  def test_default_answer_channel_delivers_alert_flag_to_wire
    # kimi T3.1 评审提案 #1 的回归钉：router 层曾自行拼 wire 参数 show_alert:，
    # 撞 TelegramApi 的关键字形参（alert:）→ ArgumentError 被 rescue 吞掉，
    # 拒绝路径（唯一 alert:true 场景）应答静默丢失、客户端永久转圈。
    api, fake, = build_api
    router = TelegramBot::Router.new(api: api, bot_username: "x",
                                     logger: Logger.new(IO::NULL))
    router.register(:callback_query) do |ctx|
      ctx[:answer_callback_query].call("拒绝", alert: true)
      nil
    end

    router.dispatch(callback_update(data: "sec:#{'c' * 16}"))

    assert_equal 1, fake.answered.size, "alert:true 也必须真的送达（不再 ArgumentError）"
    assert_equal true, fake.answered.first[:show_alert],
                 "alert 语义必须经 TelegramApi 转成 wire 参数 show_alert"
    assert_equal "拒绝", fake.answered.first[:text]
  end

  def test_public_send_omits_thread_id_for_group_level_scope
    # kimi T3.1 评审提案 #2 的回归钉：非 forum 群（入站无 thread）掷骰存 0，
    # 公开时不得把 message_thread_id: 0 拍上 wire（Ruby 0 为真，forum 群 400 风险）
    @router.dispatch(message_update(text: "/secret SB@6"))
    record, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    assert_equal 0, record.thread_id, "群级作用域应存 0"
    @fake.sent_messages.clear

    @router.dispatch(callback_update(data: TenguDB::Secrets.callback_data(record.id)))

    assert_equal 1, plain_sends.size, "公开应发出一条普通消息"
    refute plain_sends.first.key?(:message_thread_id),
           "群级（0）公开不得带 message_thread_id 上 wire"
  end

  def test_public_reveal_is_recorded_as_bot_output
    # kimi T3.5 评审提案 #4 的回归钉：公开路径自走 api.send_text、不到 router
    # 挂钩②——handler 显式录，否则导出的跑团 log 缺这段群内公开内容
    @router.dispatch(message_update(text: "/secret SB@6"))
    record, = @store.latest_for(chat_id: CHAT_ID, user_id: USER)
    revealed_text = record.result_text

    @router.dispatch(callback_update(data: TenguDB::Secrets.callback_data(record.id)))

    assert_equal 1, @log_spy.recorded.size, "公开的暗骰结果必须以 bot 输出落 log"
    assert_equal revealed_text, @log_spy.recorded.first[:text],
                 "录的是公开后的结果全文（此刻它已是群内公开消息）"
    assert_equal CHAT_ID, @log_spy.recorded.first[:chat_id]
  end
end