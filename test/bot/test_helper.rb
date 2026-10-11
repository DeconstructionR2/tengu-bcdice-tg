# frozen_string_literal: true

# ============================================================================
# test/bot/test_helper.rb — bot 层单测脚手架（T2.1）
#
# 纪律：**全部 mock**——零联网、零真实 token、零真实等待。
#   - 假 sleeper：记录 sleep 秒数，不真睡；
#   - 假 clock：可控单调时钟；
#   - 假 http_executor：记录 (url, body)，返回预置响应；
#   - 假 api client：记录 send_message / set_my_commands 的参数。
# ============================================================================

require "minitest/autorun"
require "json"
require_relative "../../bot/config"
require_relative "../../bot/telegram_api"

module BotTestHelper
  # 假时钟：单调前进，sleep 时同步推进（零真实等待）
  class FakeClock
    attr_reader :now

    def initialize(start = 0.0)
      @now = start
    end

    def call
      @now
    end

    def advance(seconds)
      @now += seconds
      @now
    end
  end

  # 假 sleeper：记录调用参数并推进假时钟
  class FakeSleeper
    attr_reader :calls

    def initialize(clock)
      @clock = clock
      @calls = []
    end

    def call(seconds)
      @calls << seconds
      @clock.advance(seconds)
      seconds
    end

    def total_slept
      @calls.sum
    end
  end

  # 假 HTTP 执行器：记录请求，返回预置响应
  class FakeHttpExecutor
    attr_reader :calls

    def initialize(response: { status: 200, body: { "ok" => true, "result" => true }.to_json })
      @response = response
      @calls = []
    end

    def call(url, body)
      @calls << { url: url, body: body }
      @response
    end

    def last_body
      @calls.last[:body]
    end

    def last_url
      @calls.last[:url]
    end
  end

  # 假 api client：只记录调用的方法名与参数，**不碰网络**
  class FakeApi
    attr_reader :sent_messages, :registered_commands, :documents

    def initialize(raise_on: nil)
      @sent_messages = []
      @registered_commands = nil
      @documents = []
      @raise_on = raise_on # {method_name => Exception} 用于测降级
    end

    def send_message(**params)
      raise @raise_on[:send_message] if @raise_on&.key?(:send_message)

      @sent_messages << params
      :fake_message
    end

    def set_my_commands(**params)
      raise @raise_on[:set_my_commands] if @raise_on&.key?(:set_my_commands)

      @registered_commands = params
      true
    end

    def send_document(**params)
      raise @raise_on[:send_document] if @raise_on&.key?(:send_document)

      @documents << params
      :fake_document
    end
  end

  # 假 Client：暴露 .api 给 TelegramApi 用
  class FakeClient
    attr_reader :api

    def initialize(api)
      @api = api
    end
  end

  # 仿 gem 的 Telegram::Bot::Api：方法名白名单 + method_missing → super。
  #
  # 为什么要仿：**只有经 method_missing 的 super 抛出的 NoMethodError 才有
  # receiver == api 本体**（Ruby 只在该路径填 receiver；手工
  # `NoMethodError.new("msg")` 的 receiver 会 ArgumentError）。
  # F3 的降级判别（receiver 是不是 @api_client.api）必须用真 gem 语义验证，
  # 否则测试自己就假了。missing: 传端点名模拟"该 gem 版本白名单没收录"。
  class FakeGemLikeApi
    ENDPOINTS = {
      "sendMessage" => true, "sendDocument" => true, "setMyCommands" => true
    }.freeze

    attr_reader :sent_messages, :documents, :registered_commands, :requested

    def initialize(missing: [])
      @missing = Array(missing)
      @sent_messages = []
      @documents = []
      @registered_commands = nil
      @requested = []
    end

    def method_missing(name, *args, **kwargs, &blk)
      endpoint = camelize(name.to_s)
      @requested << endpoint
      return super unless ENDPOINTS.key?(endpoint) && !@missing.include?(endpoint)

      case endpoint
      when "sendMessage" then @sent_messages << kwargs
      when "sendDocument" then @documents << kwargs
      when "setMyCommands" then @registered_commands = kwargs
      end
    end

    def camelize(str)
      str.split("_").map { |s| s.sub(/\A./, &:upcase) }.join
    end
  end

  # 构造一个全 mock 的 TelegramApi
  def build_api(api: nil, clock: nil, http: nil, parse_mode: nil, raise_on: nil)
    clock ||= FakeClock.new
    sleeper = FakeSleeper.new(clock)
    fake_api = api || FakeApi.new(raise_on: raise_on)
    http ||= FakeHttpExecutor.new

    instance = TelegramBot::TelegramApi.new(
      token: "1234567890:FAKE_TOKEN_FOR_UNIT_TESTS_ONLY",
      api_client: FakeClient.new(fake_api),
      sleeper: sleeper,
      clock: clock,
      http_executor: http,
      parse_mode: parse_mode
    )

    [instance, fake_api, sleeper, clock, http]
  end

  # 假 token（形状合法，值是假的；**永不**读真 .env）
  FAKE_TOKEN = "1234567890:AAFakeTokenForUnitTestsOnly_do_not_use"
end