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

  # 按 gem 2.8.1 实测形状工作的假 client：listen yield **Message**（含 nil，
  # 对应 callback_query 等非消息 update 被 yield nil 的真实行为）
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

  def gem_shaped_message(text, thread_id: nil)
    attrs = {
      message_id: 1, date: 1_700_000_000,
      chat: { id: CHAT_ID, type: "supergroup" },
      from: { id: 42, is_bot: false, first_name: "T" },
      text: text
    }
    attrs[:message_thread_id] = thread_id if thread_id
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
end
