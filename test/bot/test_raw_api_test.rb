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

  # HTTParty::Response 形状的替身（2026-10-12 验收轮修复 [1]）。
  #
  # 关键：**不实现 `#[]`**。真 HTTParty::Response 的 `#[]` 是 parsed_response
  # 语义（Telegram 响应里没有 "status"/"body" 键 → 恒 nil），状态码与原始 body
  # 只在 `.code`/`.body` 上（服务器实测留档：HTTParty 0.24.3，本机回环 200
  # 响应 → code=200、body=原始 JSON 串、response[:status]=nil）。
  # 旧实现按 Hash 取值，在本替身下取不到即必红——正是修复前生产降级路径的必炸形态。
  class HttpartyShapedResponse
    attr_reader :code, :body

    def initialize(code:, body:)
      @code = code
      @body = body
    end
  end

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

  def test_hash_and_array_params_pass_as_native_json_types
    http = BotTestHelper::FakeHttpExecutor.new
    api = api_with(http)

    api.raw_api_call("sendMessage",
                     chat_id: 1,
                     text: "x",
                     ephemeral_message_parameters: { receiver_user_id: 5 },
                     list: [1, 2])

    # wire 形态是 application/json body → Hash/Array 必须是**原生 JSON 类型**
    # （2026-10-12 二审修复：旧实现 to_json 成字符串，Telegram 会收到
    # {"list":"[1,2]"} 这种 JSON-in-JSON 坏载荷）
    assert_equal({ receiver_user_id: 5 }, http.last_body[:ephemeral_message_parameters])
    assert_equal [1, 2], http.last_body[:list]

    # wire 层形状（default_http_executor 就是 body.to_json 发出去）
    wire = JSON.parse(http.last_body.to_json)
    assert_kind_of Array, wire["list"], "wire JSON 里 list 必须是真数组"
    assert_kind_of Hash, wire["ephemeral_message_parameters"], "wire JSON 里对象必须是真对象"
  end

  # --- 错误路径：HTTP 失败 ------------------------------------------------

  # 生产执行器形状（HTTParty::Response，2026-10-12 验收轮修复 [1]）：
  # 状态码与 body 只在 `.code`/`.body` 上，按 Hash 取值恒 nil → 旧实现在
  # HTTP 200 上也会抛 `RawApiError: "... HTTP :"`。
  def test_httparty_shaped_response_returns_parsed_hash_on_200
    http = BotTestHelper::FakeHttpExecutor.new(
      response: HttpartyShapedResponse.new(
        code: 200,
        body: { "ok" => true, "result" => { "message_id" => 9 } }.to_json
      )
    )
    api = api_with(http)

    result = api.raw_api_call("getMe")

    assert_equal true, result["ok"], "HTTP 200 + 合法 JSON 必须正常返回解析后的 Hash"
    assert_equal 9, result["result"]["message_id"]
  end

  def test_httparty_shaped_response_raises_with_the_real_status_code
    http = BotTestHelper::FakeHttpExecutor.new(
      response: HttpartyShapedResponse.new(code: 502, body: "Bad Gateway")
    )
    api = api_with(http)

    err = assert_raises(TelegramBot::RawApiError) { api.raw_api_call("sendMessage") }
    assert_match(/502/, err.message, "错误消息必须含**真实**状态码（旧实现只会打 `HTTP :`）")
    assert_match(/Bad Gateway/, err.message, "响应体应带进错误消息")
  end

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
    # 用仿 gem 的 api（method_missing → super）而不是裸 NoMethodError：
    # 只有 method_missing 路径抛出的异常才带 receiver == api 本体，
    # 而那正是 F3 的降级判别条件（裸 NoMethodError.new(msg) 的 receiver 是 nil）。
    gem_like = BotTestHelper::FakeGemLikeApi.new(missing: ["sendMessage"])
    clock = BotTestHelper::FakeClock.new
    http = BotTestHelper::FakeHttpExecutor.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(gem_like),
                                      sleeper: BotTestHelper::FakeSleeper.new(clock),
                                      clock: clock,
                                      http_executor: http)

    api.send_text(123, "hi", thread_id: 5)

    assert_empty gem_like.sent_messages, "白名单缺失时 gem 侧不应真的派发成功"
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

  # --- NoMethodError 降级判别：只有 gem 白名单缺失才降级 ----------------------
  #
  # gem 2.8.1 的 ENDPOINTS 已含 sendMessage/sendDocument/setMyCommands
  # （endpoints.rb:14/22/96），生产里这条 rescue 捕获到的几乎必是**代码 bug**。
  # 且 gem 的响应类型映射在 POST **之后**才执行（api.rb:28-32），此时若误降级
  # 重发 → 重复消息。故：receiver 不是 @api_client.api 时必须原样抛出。

  # 模拟真实业务 bug：响应类型映射阶段的 NoMethodError（receiver 不会是 api 本体）
  def test_buggy_no_method_error_is_not_swallowed_into_raw_fallback
    bug = NoMethodError.new("undefined method `gone' for nil", :gone, [], receiver: nil)
    fake = BotTestHelper::FakeApi.new(raise_on: { send_message: bug })
    clock = BotTestHelper::FakeClock.new
    http = BotTestHelper::FakeHttpExecutor.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(fake),
                                      sleeper: BotTestHelper::FakeSleeper.new(clock),
                                      clock: clock,
                                      http_executor: http)

    raised = assert_raises(NoMethodError) { api.send_text(1, "x") }
    assert_equal :gone, raised.name, "业务 bug 必须原样向外抛出，不得被降级吞掉"
    assert_empty http.calls, "业务 bug 绝不可降级重发（会导致重复消息）"
  end

  # 模拟"别的对象"上的 NoMethodError（如 helper 内部对 nil 调方法）
  def test_no_method_error_from_other_receiver_is_re_raised
    helper = Object.new
    bug = NoMethodError.new("undefined method `call' for #<Object>", :call, [], receiver: helper)
    fake = BotTestHelper::FakeApi.new(raise_on: { send_message: bug })
    clock = BotTestHelper::FakeClock.new
    http = BotTestHelper::FakeHttpExecutor.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(fake),
                                      sleeper: BotTestHelper::FakeSleeper.new(clock),
                                      clock: clock,
                                      http_executor: http)

    assert_raises(NoMethodError) { api.send_text(1, "x") }
    assert_empty http.calls, "receiver 不是 api 本体 → 不得走 raw 降级"
  end

  # 对照组：receiver 正是 gem 的 api 对象（白名单缺失）→ 仍应降级 raw
  def test_gem_whitelist_miss_still_falls_back_to_raw
    gem_like = BotTestHelper::FakeGemLikeApi.new(missing: ["sendMessage"])
    clock = BotTestHelper::FakeClock.new
    http = BotTestHelper::FakeHttpExecutor.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(gem_like),
                                      sleeper: BotTestHelper::FakeSleeper.new(clock),
                                      clock: clock,
                                      http_executor: http)

    api.send_text(123, "hi", thread_id: 5)

    assert_empty gem_like.sent_messages, "白名单缺失 → gem 侧不应真的发出"
    assert_equal 1, http.calls.size, "白名单缺失仍须降级走 raw 通道（保底能力不丢）"
    assert_match(%r{/sendMessage\z}, http.last_url)
    assert_equal 5, http.last_body[:message_thread_id], "降级路径也必须透传 thread id"
  end

  # 白名单缺失 → setMyCommands 仍降级 raw（对照组，保底能力不丢）
  def test_register_main_commands_whitelist_miss_still_falls_back_to_raw
    gem_like = BotTestHelper::FakeGemLikeApi.new(missing: ["setMyCommands"])
    clock = BotTestHelper::FakeClock.new
    http = BotTestHelper::FakeHttpExecutor.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(gem_like),
                                      sleeper: BotTestHelper::FakeSleeper.new(clock),
                                      clock: clock,
                                      http_executor: http)

    api.register_main_commands

    assert_nil gem_like.registered_commands
    assert_equal 1, http.calls.size
    assert_match(%r{/setMyCommands\z}, http.last_url)
  end

  # gem 2.8.1 白名单缺 setMyCommands 之外的路径时同样只对 api 本体降级
  def test_register_main_commands_re_raises_business_bug_no_method_error
    bug = NoMethodError.new("undefined method `command' for nil", :command, [], receiver: nil)
    fake = BotTestHelper::FakeApi.new(raise_on: { set_my_commands: bug })
    clock = BotTestHelper::FakeClock.new
    http = BotTestHelper::FakeHttpExecutor.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(fake),
                                      sleeper: BotTestHelper::FakeSleeper.new(clock),
                                      clock: clock,
                                      http_executor: http)

    assert_raises(NoMethodError) { api.register_main_commands }
    assert_empty http.calls, "业务 bug 不得被 setMyCommands 降级路径吞掉"
  end

  # --- answer_callback_query 封装分支（T3.1，kimi 评审提案 #3 补盲）-----------

  def test_answer_callback_query_rejects_blank_id
    api = api_with(BotTestHelper::FakeHttpExecutor.new)

    assert_raises(ArgumentError) { api.answer_callback_query(callback_query_id: "") }
  end

  def test_answer_callback_query_raises_send_error_on_api_rejection
    err = Telegram::Bot::Exceptions::ResponseError.allocate
    # 构造一个最小可用的 ResponseError（与 send 侧测试同款手法）
    response = Struct.new(:body).new('{"ok":false,"description":"query is too old"}')
    err.define_singleton_method(:response) { response }
    err.define_singleton_method(:message) { "Telegram API error" }

    fake = BotTestHelper::FakeApi.new(raise_on: { answer_callback_query: err })
    clock = BotTestHelper::FakeClock.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                       api_client: BotTestHelper::FakeClient.new(fake),
                                       sleeper: BotTestHelper::FakeSleeper.new(clock),
                                       clock: clock)

    raised = assert_raises(TelegramBot::SendError) do
      api.answer_callback_query(callback_query_id: "q1", text: "x", alert: true)
    end
    assert_match(/query is too old/, raised.message)
    refute_match(/#{Regexp.escape(FAKE_TOKEN)}/, raised.message, "SendError 不得泄漏 token")
  end

  def test_answer_callback_query_whitelist_miss_falls_back_to_raw
    # FakeGemLikeApi 的 ENDPOINTS 白名单不含 answerCallbackQuery → 模拟 gem 未收录
    gem_like = BotTestHelper::FakeGemLikeApi.new
    clock = BotTestHelper::FakeClock.new
    http = BotTestHelper::FakeHttpExecutor.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                       api_client: BotTestHelper::FakeClient.new(gem_like),
                                       sleeper: BotTestHelper::FakeSleeper.new(clock),
                                       clock: clock,
                                       http_executor: http)

    api.answer_callback_query(callback_query_id: "q9", text: "ok", alert: true)

    assert_equal 1, http.calls.size, "gem 白名单缺失时应降级走 raw 通道"
    assert_match(%r{/answerCallbackQuery\z}, http.last_url)
    assert_equal "q9", http.last_body[:callback_query_id]
    assert_equal true, http.last_body[:show_alert], "alert 语义须转成 wire 参数 show_alert"
  end

  # --- raw 降级失败 → SendError（2026-10-13 审核修复） ------------------------

  def test_send_one_raw_fallback_failure_becomes_send_error
    # raw 降级失败此前裸抛 RawApiError，破坏「发送入口只抛 SendError」契约
    # （与 send_document 的降级实现对齐修复）。
    gem_like = BotTestHelper::FakeGemLikeApi.new(missing: ["sendMessage"])
    clock = BotTestHelper::FakeClock.new
    http = BotTestHelper::FakeHttpExecutor.new(response: { status: 502, body: "Bad Gateway" })
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                       api_client: BotTestHelper::FakeClient.new(gem_like),
                                       sleeper: BotTestHelper::FakeSleeper.new(clock),
                                       clock: clock,
                                       http_executor: http)

    err = assert_raises(TelegramBot::SendError) { api.send_text(123, "hi") }
    assert_match(/降级失败/, err.message)
    refute_match(/#{Regexp.escape(FAKE_TOKEN)}/, err.message, "不得泄漏 token")
  end

  def test_answer_callback_query_raw_fallback_failure_becomes_send_error
    gem_like = BotTestHelper::FakeGemLikeApi.new
    clock = BotTestHelper::FakeClock.new
    http = BotTestHelper::FakeHttpExecutor.new(response: { status: 502, body: "Bad Gateway" })
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                       api_client: BotTestHelper::FakeClient.new(gem_like),
                                       sleeper: BotTestHelper::FakeSleeper.new(clock),
                                       clock: clock,
                                       http_executor: http)

    err = assert_raises(TelegramBot::SendError) do
      api.answer_callback_query(callback_query_id: "q1", text: "x")
    end
    assert_match(/降级失败/, err.message)
  end
end