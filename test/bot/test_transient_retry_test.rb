# frozen_string_literal: true

# ============================================================================
# test/bot/test_transient_retry_test.rb — 瞬态故障退避重试（2026-10-12 修复）
#
# 背景（生产实证，容器 RestartCount=10，双评审报告复核确认）：
#   fetch_updates 撞 429 → gem 只 rescue Timeout/ConnectionFailed
#   （gem client.rb:30-31）→ ResponseError 冒泡出 listen → main.rb 无兜底
#   → 进程退出 → 容器重启 → 启动期 setMyCommands 又撞限流/超时 → exit(1)
#   → 重启循环。修复 = RetryPolicy（bot/telegram_api.rb）：
#     ① register_main_commands：瞬态错误有界退避重试，耗尽/非瞬态上抛；
#     ② start 的 listen 循环：瞬态错误退避重进、不杀进程，401/409 上抛；
#     ③ send_one：429 按 retry_after 重投一次（5xx 不重投，防重复消息）。
#
# 本文件钉住这三条新契约。全程假 api/假时钟，零联网、零真实睡眠。
# ============================================================================

require "minitest/autorun"
require "json"
require_relative "test_helper"

class TestTransientRetry < Minitest::Test
  include BotTestHelper

  FAKE_TOKEN = "1234567890:FakeTokenForUnitTests0000"

  # 造一个行为与真 gem 一致的 ResponseError（error_code/data 从 body JSON 解析，
  # 与 exceptions/response_error.rb 同路径；allocate+singleton 手法同
  # test_raw_api_test.rb 的既有钉点）
  def response_error(code, retry_after: nil)
    body = { ok: false, error_code: code, description: "error #{code}" }
    body[:parameters] = { retry_after: retry_after } if retry_after
    err = Telegram::Bot::Exceptions::ResponseError.allocate
    response = Struct.new(:body).new(JSON.dump(body))
    err.define_singleton_method(:response) { response }
    err.define_singleton_method(:message) { "Telegram API error #{code}" }
    err
  end

  # 前 N 次调用抛指定异常、之后正常记录的假 api（set_my_commands / send_message）
  class FlakyApi
    attr_reader :set_calls, :send_calls

    def initialize(set_failures: [], send_failures: [])
      @set_failures = set_failures
      @send_failures = send_failures
      @set_calls = 0
      @send_calls = 0
      @registered = nil
    end

    def set_my_commands(**_params)
      @set_calls += 1
      raise @set_failures.shift if @set_failures.any?

      true
    end

    def send_message(**_params)
      @send_calls += 1
      raise @send_failures.shift if @send_failures.any?

      :fake_message
    end
  end

  # 前 N 次 listen 抛指定异常、之后按 gem 实测形状 yield 事件的假 client
  class FlakyListenClient
    attr_reader :api, :listen_calls

    def initialize(api, failures: [], yields: [])
      @api = api
      @failures = failures
      @yields = yields
      @listen_calls = 0
    end

    def listen(&block)
      @listen_calls += 1
      raise @failures.shift if @failures.any?

      @yields.each(&block)
    end
  end

  def build_api(fake_api)
    clock = FakeClock.new
    sleeper = FakeSleeper.new(clock)
    api = TelegramBot::TelegramApi.new(
      token: FAKE_TOKEN,
      api_client: BotTestHelper::FakeClient.new(fake_api),
      sleeper: sleeper,
      clock: clock
    )
    [api, sleeper]
  end

  def gem_shaped_message(text)
    Telegram::Bot::Types::Message.new(
      message_id: 1, date: 1_700_000_000,
      chat: { id: -1_000_000_000_123_456_789, type: "supergroup" },
      from: { id: 42, is_bot: false, first_name: "T" },
      text: text
    )
  end

  # --- ① 启动期注册：有界退避重试 ---------------------------------------------

  def test_register_retries_429_with_retry_after_then_succeeds
    fake = FlakyApi.new(set_failures: [response_error(429, retry_after: 5)])
    api, sleeper = build_api(fake)

    api.register_main_commands

    assert_equal 2, fake.set_calls, "429 后应退避重试并成功"
    assert_equal [5], sleeper.calls, "应按响应里的 retry_after=5 退避（不打印 message）"
  end

  def test_register_gives_up_after_max_attempts_on_persistent_429
    always_429 = Array.new(20) { response_error(429, retry_after: 5) }
    fake = FlakyApi.new(set_failures: always_429)
    api, sleeper = build_api(fake)

    assert_raises(Telegram::Bot::Exceptions::ResponseError) { api.register_main_commands }
    assert_equal TelegramBot::RetryPolicy::REGISTER_MAX_ATTEMPTS + 1, fake.set_calls,
                 "初发 + 有界重试，耗尽后应上抛（交 main.rb / 容器重启策略）"
    assert_equal TelegramBot::RetryPolicy::REGISTER_MAX_ATTEMPTS, sleeper.calls.size
  end

  def test_register_does_not_retry_401
    fake = FlakyApi.new(set_failures: [response_error(401)])
    api, sleeper = build_api(fake)

    assert_raises(Telegram::Bot::Exceptions::ResponseError) { api.register_main_commands }
    assert_equal 1, fake.set_calls, "401 是配置错误（token 无效），重试无意义"
    assert_empty sleeper.calls
  end

  def test_register_retries_faraday_timeout_then_succeeds
    fake = FlakyApi.new(set_failures: [Faraday::TimeoutError])
    api, sleeper = build_api(fake)

    api.register_main_commands

    assert_equal 2, fake.set_calls, "Faraday 超时同属瞬态（生产日志实证 5 连超时）"
    assert_equal [2.0], sleeper.calls, "无 retry_after 时走指数退避（首次 2s）"
  end

  # --- ② 轮询循环：瞬态退避重进、不杀进程 -------------------------------------

  def test_listen_recovers_from_429_and_dispatches_pending_events
    fake = FlakyApi.new
    client = FlakyListenClient.new(
      fake,
      failures: [response_error(429, retry_after: 3)],
      yields: [gem_shaped_message("SB")]
    )
    clock = FakeClock.new
    sleeper = FakeSleeper.new(clock)
    api = TelegramBot::TelegramApi.new(
      token: FAKE_TOKEN, api_client: client, sleeper: sleeper, clock: clock
    )
    seen = []

    api.start(dispatch: ->(event) { seen << event })

    assert_equal 2, client.listen_calls, "429 应退避后重进 listen，不再杀进程"
    assert_equal [3], sleeper.calls, "按 retry_after=3 退避"
    assert_equal 1, seen.size, "恢复后滞留事件应继续派发"
  end

  def test_listen_reraises_401_without_retry
    fake = FlakyApi.new
    client = FlakyListenClient.new(fake, failures: [response_error(401)])
    clock = FakeClock.new
    api = TelegramBot::TelegramApi.new(
      token: FAKE_TOKEN, api_client: client, sleeper: FakeSleeper.new(clock), clock: clock
    )

    assert_raises(Telegram::Bot::Exceptions::ResponseError) { api.start(dispatch: ->(_e) {}) }
    assert_equal 1, client.listen_calls, "401 token 失效：立即上抛交 main.rb 兜底"
  end

  def test_listen_reraises_409_without_retry
    fake = FlakyApi.new
    client = FlakyListenClient.new(fake, failures: [response_error(409)])
    clock = FakeClock.new
    api = TelegramBot::TelegramApi.new(
      token: FAKE_TOKEN, api_client: client, sleeper: FakeSleeper.new(clock), clock: clock
    )

    assert_raises(Telegram::Bot::Exceptions::ResponseError) { api.start(dispatch: ->(_e) {}) }
    assert_equal 1, client.listen_calls,
                 "409 双轮询红线（OPERATIONS §5）：不静默重试，上抛让冲突可见"
  end

  def test_listen_recovers_from_faraday_ssl_error
    fake = FlakyApi.new
    client = FlakyListenClient.new(
      fake, failures: [Faraday::SSLError], yields: [gem_shaped_message("SB")]
    )
    clock = FakeClock.new
    api = TelegramBot::TelegramApi.new(
      token: FAKE_TOKEN, api_client: client, sleeper: FakeSleeper.new(clock), clock: clock
    )

    api.start(dispatch: ->(_e) {})

    assert_equal 2, client.listen_calls, "gem 没兜住的 Faraday 族（SSLError 等）退避重进"
  end

  # --- ③ 发送：429 重投一次，5xx 不重投 ---------------------------------------

  def test_send_one_retries_429_once_and_delivers
    fake = FlakyApi.new(send_failures: [response_error(429, retry_after: 4)])
    api, sleeper = build_api(fake)

    result = api.send_text(42, "命中")

    assert_equal [:fake_message], result, "重投成功应按正常路径返回"
    assert_equal 2, fake.send_calls, "429 后应重投一次"
    assert_equal [4], sleeper.calls, "按 retry_after=4 等待（首次发送无配速等待）"
  end

  def test_send_one_raises_send_error_after_single_retry
    fake = FlakyApi.new(send_failures: [response_error(429, retry_after: 4),
                                        response_error(429, retry_after: 4)])
    api, sleeper = build_api(fake)

    assert_raises(TelegramBot::SendError) { api.send_text(42, "x") }
    assert_equal 2, fake.send_calls, "只重投一次，仍败则抛 SendError（router 记 warn）"
    assert_equal [4], sleeper.calls
  end

  def test_send_one_does_not_retry_500
    fake = FlakyApi.new(send_failures: [response_error(500)])
    api, sleeper = build_api(fake)

    assert_raises(TelegramBot::SendError) { api.send_text(42, "x") }
    assert_equal 1, fake.send_calls,
                 "5xx 不重投：请求可能已落库，重投会重复发消息"
    assert_empty sleeper.calls
  end

  def test_send_one_does_not_retry_400_like_before
    fake = FlakyApi.new(send_failures: [response_error(400)])
    api, = build_api(fake)

    assert_raises(TelegramBot::SendError) { api.send_text(42, "x") }
    assert_equal 1, fake.send_calls, "400 请求本身有问题，行为与修复前一致"
  end

  # --- RetryPolicy 小件 --------------------------------------------------------

  def test_retry_after_seconds_reads_string_and_symbol_keys
    assert_equal 5, TelegramBot::RetryPolicy.retry_after_seconds(response_error(429, retry_after: 5))
    assert_nil TelegramBot::RetryPolicy.retry_after_seconds(response_error(429)),
               "缺 parameters 时回落指数退避"
    assert_equal TelegramBot::RetryPolicy::RETRY_AFTER_CAP,
                 TelegramBot::RetryPolicy.retry_after_seconds(response_error(429, retry_after: 999_999)),
                 "异常大的 retry_after 必须被钳制"
  end

  def test_backoff_grows_exponentially_and_caps
    policy = TelegramBot::RetryPolicy
    assert_equal 2.0, policy.backoff(1, cap: 30)
    assert_equal 4.0, policy.backoff(2, cap: 30)
    assert_equal 8.0, policy.backoff(3, cap: 30)
    assert_equal 30, policy.backoff(9, cap: 30), "超过上限后恒为 cap"
  end
end
