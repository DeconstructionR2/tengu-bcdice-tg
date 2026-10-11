# frozen_string_literal: true

# ============================================================================
# test/bot/test_raw_api_test.rb — raw_api_call 保底通道（T2.1，计划 §12 R2）
#
# raw_api_call 存在的意义：telegram-bot-ruby 的 ENDPOINTS 是**方法名白名单**
# （api.rb:28 `return super unless ENDPOINTS.key?(endpoint)`），未收录的方法名
# 会 NoMethodError。Bot API 10.3（2026-08-24）晚于 gem 2.8.1（2026-08-02），
# 任何新端点都不在白名单里 → 统一走 HTTP 直调保底。
#
# 全程 mock：FakeHttpExecutor 记录 (url, body) 并返回预置响应。**零联网**。
# ============================================================================

require_relative "test_helper"

class TestRawApiCall < Minitest::Test
  include BotTestHelper

  def api_with(http)
    fake = BotTestHelper::FakeApi.new
    TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                 api_client: BotTestHelper::FakeClient.new(fake),
                                 sleeper: BotTestHelper::FakeSleeper.new(BotTestHelper::FakeClock.new),
                                 clock: BotTestHelper::FakeClock.new,
                                 http_executor: http)
  end

  # --- 成功路径 -----------------------------------------------------------

  def test_successful_call_returns_parsed_response
    http = BotTestHelper::FakeHttpExecutor.new(
      response: { status: 200, body: { "ok" => true, "result" => { "message_id" => 7 } }.to_json }
    )
    api = api_with(http)

    result = api.raw_api_call("getMe")
    assert_equal true, result["ok"]
    assert_equal 7, result["result"]["message_id"]
  end

  def test_url_shape_is_bot_endpoint
    http = BotTestHelper::FakeHttpExecutor.new
    api = api_with(http)

    api.raw_api_call("sendMessage", chat_id: 1, text: "hi")

    assert_equal "#{TelegramBot::Config::TELEGRAM_API_BASE_URL}/bot#{FAKE_TOKEN}/sendMessage",
                 http.last_url
  end

  def test_params_are_passed_as_body
    http = BotTestHelper::FakeHttpExecutor.new
    api = api_with(http)

    api.raw_api_call("sendMessage", chat_id: 42, text: "hello", message_thread_id: 9)

    body = http.last_body
    assert_equal 42, body[:chat_id]
    assert_equal "hello", body[:text]
    assert_equal 9, body[:message_thread_id]
  end

  def test_hash_and_array_params_are_jsonified
    http = BotTestHelper::FakeHttpExecutor.new
    api = api_with(http)

    api.raw_api_call("sendMessage",
                     chat_id: 1,
                     text: "x",
                     ephemeral_message_parameters: { receiver_user_id: 5 },
                     list: [1, 2])

    assert_equal '{"receiver_user_id":5}', http.last_body[:ephemeral_message_parameters]
    assert_equal "[1,2]", http.last_body[:list]
  end

  # --- 错误路径：HTTP 失败 ------------------------------------------------

  def test_non_200_raises_raw_api_error
    http = BotTestHelper::FakeHttpExecutor.new(
      response: { status: 502, body: "Bad Gateway" }
    )
    api = api_with(http)

    err = assert_raises(TelegramBot::RawApiError) { api.raw_api_call("sendMessage") }
    assert_match(/502/, err.message)
  end

  def test_ok_false_raises_with_body
    http = BotTestHelper::FakeHttpExecutor.new(
      response: { status: 200, body: { "ok" => false, "error_code" => 400, "description" => "chat not found" }.to_json }
    )
    api = api_with(http)

    err = assert_raises(TelegramBot::RawApiError) { api.raw_api_call("sendMessage") }
    assert_match(/ok=false/, err.message)
    assert_match(/chat not found/, err.message)
  end

  def test_invalid_json_raises
    http = BotTestHelper::FakeHttpExecutor.new(
      response: { status: 200, body: "<html>gateway error</html>" }
    )
    api = api_with(http)

    assert_raises(TelegramBot::RawApiError) { api.raw_api_call("sendMessage") }
  end

  # --- 错误消息不得泄漏 token --------------------------------------------

  def test_error_message_does_not_leak_token
    http = BotTestHelper::FakeHttpExecutor.new(
      response: { status: 401, body: "Unauthorized" }
    )
    api = api_with(http)

    err = assert_raises(TelegramBot::RawApiError) { api.raw_api_call("sendMessage") }
    refute_match(/#{Regexp.escape(FAKE_TOKEN)}/, err.message,
                 "错误消息**不得**含 token（URL 里有 token，报错只应报方法名与状态）")
  end

  def test_long_error_body_is_truncated
    long = "E" * 5000
    http = BotTestHelper::FakeHttpExecutor.new(response: { status: 500, body: long })
    api = api_with(http)

    err = assert_raises(TelegramBot::RawApiError) { api.raw_api_call("sendMessage") }
    assert_operator err.message.length, :<, 500, "超长报错体应被截断，避免日志爆炸"
  end

  # --- gem 端点缺失时的降级 -----------------------------------------------

  def test_send_one_falls_back_to_raw_when_gem_lacks_endpoint
    fake = BotTestHelper::FakeApi.new(raise_on: { send_message: NoMethodError.new("undefined method") })
    clock = BotTestHelper::FakeClock.new
    http = BotTestHelper::FakeHttpExecutor.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(fake),
                                      sleeper: BotTestHelper::FakeSleeper.new(clock),
                                      clock: clock,
                                      http_executor: http)

    api.send_text(123, "hi", thread_id: 5)

    assert_equal 1, http.calls.size, "gem 端点缺失时应降级走 raw 通道"
    assert_match(%r{/sendMessage\z}, http.last_url)
    assert_equal 5, http.last_body[:message_thread_id], "降级路径也必须透传 thread id"
  end

  def test_send_one_raises_send_error_on_api_rejection
    err = Telegram::Bot::Exceptions::ResponseError.allocate
    # 构造一个最小可用的 ResponseError
    response = Struct.new(:body).new('{"ok":false,"description":"chat not found"}')
    err.define_singleton_method(:response) { response }
    err.define_singleton_method(:message) { "Telegram API error" }

    fake = BotTestHelper::FakeApi.new(raise_on: { send_message: err })
    clock = BotTestHelper::FakeClock.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(fake),
                                      sleeper: BotTestHelper::FakeSleeper.new(clock),
                                      clock: clock)

    raised = assert_raises(TelegramBot::SendError) { api.send_text(1, "x") }
    assert_match(/chat not found/, raised.message)
    refute_match(/#{Regexp.escape(FAKE_TOKEN)}/, raised.message, "SendError 不得泄漏 token")
  end
end