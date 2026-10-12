# frozen_string_literal: true

# ============================================================================
# test/bot/test_polling_backoff_test.rb — gem 长轮询无退避紧密重试的补丁钉测
# （2026-10-12 二审必修：minimax 探针实证 gem client.rb:30-31 对
# Faraday::TimeoutError/ConnectionFailed 是 `retry if @running` 原地重试，
# 无 sleep、无日志；RetryPolicy 从外层插不进去——异常逃不出 gem 的 rescue）
#
# ClientPollingBackoff（bot/telegram_api.rb）prepend 进 Telegram::Bot::Client，
# 接管 fetch_updates：这两类异常改走指数退避 + warn 可观测，@running 契约保留；
# ResponseError 不在此接管（归 start 的 RetryPolicy，职责不重叠）。
#
# ⚠️ 本文件第一条是**版本绊线**：patch 复制了 gem 2.8.1 fetch_updates 的方法体，
#   telegram-bot-ruby 一升级这里就红——逼着复核 patch 与新版源码的对齐。
# ============================================================================

require "minitest/autorun"
require "json"
require_relative "test_helper"

class TestClientPollingBackoff < Minitest::Test
  FAKE_TOKEN = "1234567890:FakeTokenForUnitTests0000"

  # 版本绊线：升级 gem 必须复核 ClientPollingBackoff（docs/EXTENDING.md 轴①）
  def test_gem_version_pinned_for_patch_review
    assert_equal "2.8.1", Telegram::Bot::VERSION,
                 "telegram-bot-ruby 已升级——ClientPollingBackoff 复制了 " \
                 "fetch_updates 方法体，必须对照新版 client.rb 复核"
  end

  # getUpdates 按序抛指定异常、耗尽后回 updates 的假 api（零网络）
  class FakePollApi
    attr_accessor :failures
    attr_reader :calls

    def initialize(failures: [], updates: [])
      @failures = failures
      @updates = updates
      @calls = 0
    end

    def getUpdates(_options)
      @calls += 1
      raise @failures.shift if @failures.any?

      @updates
    end
  end

  def build_client(api, running: true)
    client = Telegram::Bot::Client.new(FAKE_TOKEN)
    client.instance_variable_set(:@api, api)
    client.instance_variable_set(:@running, running)
    client
  end

  def update(n)
    Telegram::Bot::Types::Update.new(update_id: n)
  end

  def response_error(code, retry_after: nil)
    body = { ok: false, error_code: code, description: "error #{code}" }
    body[:parameters] = { retry_after: retry_after } if retry_after
    err = Telegram::Bot::Exceptions::ResponseError.allocate
    response = Struct.new(:body).new(JSON.dump(body))
    err.define_singleton_method(:response) { response }
    err.define_singleton_method(:message) { "Telegram API error #{code}" }
    err
  end

  def setup
    @sleeps = []
    @warns = []
    @old_sleeper = TelegramBot::ClientPollingBackoff.sleeper
    @old_warner = TelegramBot::ClientPollingBackoff.warner
    TelegramBot::ClientPollingBackoff.sleeper = ->(s) { @sleeps << s }
    TelegramBot::ClientPollingBackoff.warner = ->(m) { @warns << m }
  end

  def teardown
    TelegramBot::ClientPollingBackoff.sleeper = @old_sleeper
    TelegramBot::ClientPollingBackoff.warner = @old_warner
  end

  def test_connection_failed_retries_with_backoff_then_recovers
    api = FakePollApi.new(
      failures: [Faraday::ConnectionFailed, Faraday::ConnectionFailed],
      updates: [update(1)]
    )
    client = build_client(api)
    seen = []
    client.fetch_updates { |event| seen << event }

    assert_equal 3, api.calls, "两次失败后退避重试，第三轮成功"
    assert_equal [2.0, 4.0], @sleeps, "指数退避 2→4（不再是无退避紧密重试）"
    assert_equal 2, @warns.size, "每次重试都有 warn（gem 原生是沉默的）"
    assert_equal 1, seen.size, "恢复后滞留更新照常派发"
  end

  def test_no_retry_when_stopped
    api = FakePollApi.new(failures: [Faraday::TimeoutError])
    client = build_client(api, running: false)

    client.fetch_updates { |_event| }

    assert_equal 1, api.calls, "stop 后不再重试（gem 原契约保留）"
    assert_empty @sleeps
  end

  def test_response_error_propagates_untouched
    api = FakePollApi.new(failures: [response_error(429, retry_after: 5)])
    client = build_client(api)

    assert_raises(Telegram::Bot::Exceptions::ResponseError) do
      client.fetch_updates { |_event| }
    end
    assert_equal 1, api.calls, "429 不在 patch 层接管——上抛给 start 的 RetryPolicy"
    assert_empty @sleeps
  end

  def test_failure_counter_resets_after_successful_round
    api = FakePollApi.new(failures: [Faraday::ConnectionFailed], updates: [update(1)])
    client = build_client(api)

    client.fetch_updates { |_event| }
    api.failures = [Faraday::ConnectionFailed]
    client.fetch_updates { |_event| }

    assert_equal [2.0, 2.0], @sleeps,
                 "成功一轮后连续失败计数清零（第二轮退避从 2 重来，不累积成 4）"
  end

  def test_warn_message_never_contains_error_message_body
    leaky = Faraday::ConnectionFailed.new("open https://api.telegram.org/bot#{FAKE_TOKEN}/x")
    api = FakePollApi.new(failures: [leaky], updates: [])
    client = build_client(api)

    client.fetch_updates { |_event| }

    assert_equal 1, @warns.size
    refute_includes @warns.first, FAKE_TOKEN, "warn 只打异常类名（Faraday message 可能夹带 token URL）"
    assert_includes @warns.first, "Faraday::ConnectionFailed"
  end
end
