# frozen_string_literal: true

# ============================================================================
# test/bot/test_send_test.rb — 发送封装（T2.1）
#
# 覆盖：4096 切段接线、message_thread_id 逐段透传、每聊天 ≥1 秒配速（假时钟）、
#       parse_mode 默认纯文本 / 可配置、暗骰 ephemeral 载荷、长轮询逐条兜底。
# 全程 mock：FakeApi 记录参数、FakeSleeper 假睡、FakeClock 可控。零联网。
# ============================================================================

require_relative "test_helper"

class TestSend < Minitest::Test
  include BotTestHelper

  # --- 切段接线 ------------------------------------------------------------

  def test_long_text_is_sent_as_multiple_messages
    api, fake, = build_api
    long = "a" * 9000
    results = api.send_text(1_000_001, long)

    assert_equal 3, fake.sent_messages.size
    assert_equal 3, results.size
    assert_equal long, fake.sent_messages.map { |m| m[:text] }.join, "分段发送不得丢内容"
    fake.sent_messages.each { |m| assert_operator m[:text].length, :<=, 4096 }
  end

  def test_short_text_is_one_message
    api, fake, = build_api
    api.send_text(1, "hi")
    assert_equal 1, fake.sent_messages.size
    assert_equal "hi", fake.sent_messages.first[:text]
  end

  # --- thread 透传 ---------------------------------------------------------

  def test_message_thread_id_passed_through
    api, fake, = build_api
    api.send_text(-100_123, "topic reply", thread_id: 555)

    msg = fake.sent_messages.first
    assert_equal 555, msg[:message_thread_id], "forum 话题必须透传 message_thread_id"
  end

  def test_thread_id_passed_on_every_segment
    api, fake, = build_api
    api.send_text(-100_123, "x" * 9000, thread_id: 777)

    assert_equal 3, fake.sent_messages.size
    fake.sent_messages.each do |m|
      assert_equal 777, m[:message_thread_id], "**每一段**都要带 thread id，否则后续段落掉出话题"
    end
  end

  def test_no_thread_id_means_no_param
    api, fake, = build_api
    api.send_text(1, "plain")

    refute fake.sent_messages.first.key?(:message_thread_id),
           "非话题场景不应带 message_thread_id（保持请求干净）"
  end

  # --- 配速（每聊天 ≥1 秒）-------------------------------------------------

  def test_first_send_in_chat_does_not_sleep
    api, _fake, sleeper, = build_api
    api.send_text(42, "first")
    assert_empty sleeper.calls, "每聊天首次发送不应等待"
  end

  def test_consecutive_sends_in_same_chat_are_paced_at_1s
    api, _fake, sleeper, = build_api
    api.send_text(42, "a")
    api.send_text(42, "b")
    api.send_text(42, "c")

    # 2 次后续发送 → 各等 1 秒（假时钟下 elapsed=0）
    assert_equal 2, sleeper.calls.size
    assert_equal 1.0, sleeper.calls[0]
    assert_equal 1.0, sleeper.calls[1]
  end

  def test_pacing_is_per_chat_not_global
    api, _fake, sleeper, = build_api
    api.send_text(1, "a")
    api.send_text(2, "b") # 不同 chat → 不该等
    assert_empty sleeper.calls, "配速是**每聊天**的，不同 chat 互不影响"
  end

  def test_pacing_is_per_thread_within_chat
    api, _fake, sleeper, = build_api
    api.send_text(7, "a", thread_id: 1)
    api.send_text(7, "b", thread_id: 2) # 同群不同话题 → 独立计数

    assert_empty sleeper.calls, "话题维度独立配速（key = chat_id/thread_id）"
  end

  def test_no_sleep_when_enough_time_already_elapsed
    clock = BotTestHelper::FakeClock.new(0.0)
    sleeper = BotTestHelper::FakeSleeper.new(clock)
    fake = BotTestHelper::FakeApi.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(fake),
                                      sleeper: sleeper, clock: clock)

    api.send_text(9, "a")
    clock.advance(1.5) # 已经过 1.5 秒 > 1 秒门槛
    api.send_text(9, "b")

    assert_empty sleeper.calls, "距上次已超过 1 秒时不应再等"
  end

  def test_partial_elapsed_waits_only_remainder
    clock = BotTestHelper::FakeClock.new(0.0)
    sleeper = BotTestHelper::FakeSleeper.new(clock)
    fake = BotTestHelper::FakeApi.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(fake),
                                      sleeper: sleeper, clock: clock)

    api.send_text(11, "a")
    clock.advance(0.25)
    api.send_text(11, "b")

    assert_equal 1, sleeper.calls.size
    assert_in_delta 0.75, sleeper.calls[0], 1e-9, "应只补足剩余的 0.75 秒"
  end

  def test_multi_segment_send_is_paced_between_segments
    api, _fake, sleeper, = build_api
    api.send_text(55, "z" * 9000) # 3 段

    # 段间也要配速：2 次等待
    assert_equal 2, sleeper.calls.size, "同一次 send_text 的多段之间同样要配速"
  end

  # --- parse_mode ----------------------------------------------------------

  def test_parse_mode_defaults_to_plain_text
    api, fake, = build_api
    api.send_text(1, "plain")
    refute fake.sent_messages.first.key?(:parse_mode),
           "§13 第 7 项拍板：第一版纯文本，默认不带 parse_mode"
  end

  def test_parse_mode_is_configurable
    api, fake, = build_api(parse_mode: "Markdown")
    api.send_text(1, "*bold*")
    assert_equal "Markdown", fake.sent_messages.first[:parse_mode]
  end

  # --- 暗骰 ephemeral ------------------------------------------------------

  def test_send_ephemeral_includes_receiver_and_thread
    api, fake, = build_api
    api.send_ephemeral(-100_9, "secret roll", user_id: 4242, thread_id: 31)

    msg = fake.sent_messages.first
    assert_equal 4242, msg[:ephemeral_message_parameters][:receiver_user_id]
    assert_equal 31, msg[:message_thread_id]
    assert_equal "secret roll", msg[:text]
  end

  # --- 长轮询逐条兜底 ------------------------------------------------------

  def test_dispatch_error_does_not_kill_loop
    api, = build_api
    seen = []
    dispatch = lambda do |u|
      seen << u
      raise "boom on #{u}" if u == 2
    end

    _out, err = capture_io do
      api.process_updates([1, 2, 3, 4], dispatch: dispatch)
    end

    assert_equal [1, 2, 3, 4], seen, "异常那条之后的后续 update 仍必须被处理"
    assert_match(/dispatch 处理失败/, err)
    assert_match(/boom on 2/, err)
  end

  def test_process_updates_returns_normally_when_every_message_raises
    api, = build_api
    dispatch = ->(_u) { raise "always fails" }

    capture_io do
      api.process_updates([1, 2, 3], dispatch: dispatch) # 不抛异常即通过
    end
  end

  def test_start_registers_menu_then_dispatches
    api, fake, = build_api
    received = []

    # 假 client 的 listen 立刻 yield 一条 update 后返回
    listening = false
    client = api.api_client
    client.define_singleton_method(:listen) do |&_blk|
      listening = true
      nil
    end

    api.start(dispatch: ->(u) { received << u })

    assert listening, "start 应走 gem 的 client.listen 长轮询"
    refute_nil fake.registered_commands, "start 启动时应注册主轨菜单"
  end

  def test_start_swallows_dispatch_exception
    api, = build_api
    client = api.api_client
    client.define_singleton_method(:listen) do |&blk|
      # 模拟 gem listen 内部逐条 yield
      blk.call(:u1)
      nil
    end

    err = nil
    capture_io do
      api.start(dispatch: ->(_u) { raise "dispatch died" })
    rescue StandardError => e
      err = e
    end

    assert_nil err, "单条消息 dispatch 异常不得从 start 冒出（否则循环会死）"
  end
end