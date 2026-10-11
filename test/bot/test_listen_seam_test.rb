# frozen_string_literal: true

# ============================================================================
# test/bot/test_listen_seam_test.rb — listen 接缝回归测试（T2.6 真机事故）
#
# 事故回放（2026-10-12 Phase 2 真机验收）：bot 在线、长轮询连接正常、
# 测试 356 条全绿，但群里发任何命令**完全无反应、零日志**。
# 根因：telegram-bot-ruby 2.8.1 的 `Client#listen` yield 的是
# `handle_update(update)` 的返回值 = `update.current_message`——**Message
# 而非 Update**（gem client.rb:41-47）。而 `TelegramApi#start` 把它直接喂给
# 期望 Update 的 `Router#extract_message` → 取不到消息 → nil → 静默。
#
# 为什么测试没拦住：既有测试全用假 Update 对象直接喂 Router#dispatch /
# process_updates，没有任何一条经过**真 gem 的 yield 形状**——
# mock 的边界与真实边界不一致。本文件钉住这个接缝：
#   1. FakeListenClient 按 gem 实测形状 yield Message（不是 Update）；
#   2. 经 TelegramApi#start → Router 全链路，断言 /start 真的被应答。
# ============================================================================

require "minitest/autorun"
require_relative "test_helper"
require_relative "../../bot/router"

class TestListenSeam < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_001_234_567_890 # 示例群（forum 超级群）

  # 按 gem 2.8.1 实测形状工作的假 client：listen yield **Message**。
  # 真实形状补正（2026-10-12 验收期实证，gem update.rb 的 current_message =
  # 第一个非 nil 属性）：空载 update 才 yield nil；callback_query update
  # yield 的是 **CallbackQuery 本体**，edited_message update yield 的是
  # **编辑后的 Message**（edit_date 非 nil）——两者由 Router#extract_message
  # 显式守卫跳过（本文件早先注释「callback_query 会被 yield nil」是错的）。
  class FakeListenClient
    attr_reader :api

    def initialize(api, yields)
      @api = api
      @yields = yields
    end

    def listen(&block)
      @yields.each(&block)
    end
  end

  def gem_shaped_message(text, thread_id: nil, edit_date: nil)
    attrs = {
      message_id: 1, date: 1_700_000_000,
      chat: { id: CHAT_ID, type: "supergroup" },
      from: { id: 42, is_bot: false, first_name: "T" },
      text: text
    }
    attrs[:message_thread_id] = thread_id if thread_id
    attrs[:edit_date] = edit_date if edit_date
    Telegram::Bot::Types::Message.new(**attrs)
  end

  def build_router_with_listen_client(yields)
    fake_api = BotTestHelper::FakeApi.new
    client = FakeListenClient.new(fake_api, yields)
    clock = BotTestHelper::FakeClock.new
    sleeper = BotTestHelper::FakeSleeper.new(clock)
    http = BotTestHelper::FakeHttpExecutor.new

    api = TelegramBot::TelegramApi.new(
      token: "1234567890:***",
      api_client: client,
      sleeper: sleeper,
      clock: clock,
      http_executor: http
    )
    router = TelegramBot::Router.new(api: api, bot_username: "example_dice_bot")
    [api, router, fake_api]
  end

  def test_listen_yielding_gem_message_shape_is_routed
    _api, router, fake_api =
      build_router_with_listen_client([gem_shaped_message("/start", thread_id: 2468)])
    router.register(:start) { TelegramBot::StartHandler::MESSAGE }

    _api.start(dispatch: router)

    sent = fake_api.sent_messages
    assert_equal 1, sent.size,
                 "listen yield Message 时 /start 必须被应答（T2.6 事故回归钉）"
    assert_equal TelegramBot::StartHandler::MESSAGE, sent.first[:text]
    assert_equal 2468, sent.first[:message_thread_id], "thread 透传不能丢"
  end

  def test_listen_yielding_nil_is_safe
    api, router, fake_api = build_router_with_listen_client([nil])
    router.register(:start) { "不应到达" }

    api.start(dispatch: router)

    assert_empty fake_api.sent_messages, "非消息 update（yield nil）必须安静跳过"
  end

  def test_listen_yielding_aux_dice_message_is_routed
    msg = gem_shaped_message("N4,3", thread_id: 2468)
    api, router, fake_api = build_router_with_listen_client([msg])
    seen = []
    router.register(:aux) { |ctx| seen << ctx[:text]; nil }

    api.start(dispatch: router)

    assert_equal ["N4,3"], seen, "裸骰式经 Message 形态也必须路由到 aux handler"
    assert_empty fake_api.sent_messages
  end

  # --- 2026-10-12 验收期实证补钉：current_message 的另两类真实形状 ----------

  def gem_shaped_callback_query(attached_text: "SB")
    Telegram::Bot::Types::CallbackQuery.new(
      id: "q1",
      from: { id: 42, is_bot: false, first_name: "T" },
      chat_instance: "ci-123",
      data: "reveal:abc",
      message: { message_id: 9, date: 1_700_000_000,
                 chat: { id: CHAT_ID, type: "supergroup" }, text: attached_text }
    )
  end

  def test_listen_yielding_callback_query_is_not_routed
    # 按钮回调不是消息：原消息文本（哪怕恰好是骰式）绝不被二次路由
    cq = gem_shaped_callback_query(attached_text: "SB")
    api, router, fake_api = build_router_with_listen_client([cq])
    seen = []
    router.register(:aux) { |ctx| seen << ctx[:text]; nil }
    router.register(:start) { "不应到达" }

    api.start(dispatch: router)

    assert_empty seen, "CallbackQuery 不得触发 aux（按钮所附原消息不是新发言）"
    assert_empty fake_api.sent_messages, "CallbackQuery 不得产生任何回复"
  end

  def test_extract_message_rejects_callback_query_in_update_form
    # Update 形态同样被守卫（update.current_message = CallbackQuery 本体）
    update = Telegram::Bot::Types::Update.new(update_id: 1, callback_query: gem_shaped_callback_query)
    _api, router, _fake = build_router_with_listen_client([])

    assert_nil router.extract_message(update)
    assert_equal Telegram::Bot::Types::CallbackQuery, update.current_message.class,
                 "sanity：gem 真实行为是 yield CallbackQuery 本体而非 nil"
  end

  def test_listen_yielding_edited_message_is_not_rerolled
    # 编辑消息不重掷：edit_date 非 nil 是 Message 形态接缝上唯一的判别点
    # （dry-struct 不可变，edit_date 必须在构造期传入）
    edited = gem_shaped_message("SB", edit_date: 1_700_000_500)
    api, router, fake_api = build_router_with_listen_client([edited])
    seen = []
    router.register(:aux) { |ctx| seen << ctx[:text]; nil }

    api.start(dispatch: router)

    assert_empty seen, "编辑过的消息不得再次触发掷骰（防双结果混乱与刷骰）"
    assert_empty fake_api.sent_messages
  end

  def test_fresh_message_with_nil_edit_date_still_routed
    # 对照组：新消息 edit_date 为 nil，必须照常路由（守卫不能误伤正常路径）
    fresh = gem_shaped_message("SB")
    assert_nil fresh.edit_date, "sanity：新消息的 edit_date 应为 nil"
    api, router, fake_api = build_router_with_listen_client([fresh])
    seen = []
    router.register(:aux) { |ctx| seen << ctx[:text]; nil }

    api.start(dispatch: router)

    assert_equal ["SB"], seen
  end

  # ==========================================================================
  # T3.1 接缝：按钮回调经 **gem 真实 yield 形状** 走到公开分支
  #
  # 上面的两条钉「回调不得触发消息路由」——那是 T2.6 的守卫。T3.1 起回调
  # **有了正式路由分支**，故这里补上正向的一半：同一个真实形状（listen yield
  # CallbackQuery 本体）现在必须到达 :callback_query handler，并带上
  # query.id / data / from 三样 handler 赖以工作的字段。
  #
  # 假 handler 只**记录 context**，不碰 DB/引擎——本文件验的是边界形状
  # （gem 产出的字段能不能喂饱 handler），不是业务语义。
  # ==========================================================================

  def test_callback_query_reaches_callback_handler_via_gem_shape
    cq = gem_shaped_callback_query(attached_text: "SB")
    api, router, fake_api = build_router_with_listen_client([cq])
    answers = []
    seen = nil
    router.register(:callback_query) do |ctx|
      seen = ctx
      ctx[:answer_callback_query].call("ok", alert: true)
      nil
    end

    api.start(dispatch: router)

    refute_nil seen, "CallbackQuery 必须到达 :callback_query handler（T3.1 的正式分支）"
    assert_equal "q1", seen[:callback_query].id, "handler 需要 query.id 去应答"
    assert_equal "reveal:abc", seen[:data], "handler 需要 data 定位记录"
    assert_equal 42, seen[:user_id], "handler 需要 from.id 做本人校验"
    refute_nil seen[:answer_callback_query], "handler 必须拿到幂等的应答通道"
    assert_empty fake_api.sent_messages, "回调路径本身不发消息"
  end

  def test_callback_query_answer_goes_through_telegram_api
    cq = gem_shaped_callback_query(attached_text: "SB")
    api, router, = build_router_with_listen_client([cq])
    router.register(:callback_query) { |ctx| ctx[:answer_callback_query].call("已公开。"); nil }

    api.start(dispatch: router)

    # build_router_with_listen_client 用的是 BotTestHelper::FakeApi
    assert_equal 1, router.instance_variable_get(:@api).api_client.api.answered.size,
                 "默认应答通道必须真的发出 answerCallbackQuery"
    answered = router.instance_variable_get(:@api).api_client.api.answered.first
    assert_equal "q1", answered[:callback_query_id]
    assert_equal "已公开。", answered[:text]
  end

  def test_callback_query_with_no_handler_still_answers
    # 「未注册 handler」时客户端照样在转圈 —— 必须照答（warn 由 logger 收）
    cq = gem_shaped_callback_query(attached_text: "SB")
    api, router, = build_router_with_listen_client([cq])

    api.start(dispatch: router)

    answers = router.instance_variable_get(:@api).api_client.api.answered
    assert_equal 1, answers.size, "没有 callback handler 也必须应答（否则按钮转圈到天荒地老）"
    assert_equal "q1", answers.first[:callback_query_id]
  end
end
