# frozen_string_literal: true

# ============================================================================
# test/bot/test_main_menu_test.rb — setMyCommands 主轨菜单（T2.1，计划 §6）
#
# 验收要点：
#   - 九个命令齐全：/start /help /settings /roll /nd /system /secret /bank /ct /log
#   - 逐条带中文描述（非空、≤256 字符）
#   - /secret 带 is_ephemeral=true；**其余不带**（不可误标）
#   - command 符合平台规则：≤32 字符、纯拉丁字母+数字+下划线
#   - gem 不支持时降级到 raw_api_call，且 raw 载荷形状一致
# ============================================================================

require_relative "test_helper"

class TestMainMenu < Minitest::Test
  include BotTestHelper

  REQUIRED_COMMANDS = %w[start help settings roll nd system secret bank ct log].freeze

  def payload
    TelegramBot::TelegramApi.commands_payload
  end

  # --- 完整性 --------------------------------------------------------------

  def test_all_nine_commands_registered
    commands = payload.map { |c| c["command"] }
    REQUIRED_COMMANDS.each do |c|
      assert_includes commands, c, "主轨菜单缺少 /#{c}"
    end
  end

  def test_no_duplicate_commands
    commands = payload.map { |c| c["command"] }
    assert_equal commands.uniq, commands, "setMyCommands 载荷含重复命令"
  end

  # --- 描述 ---------------------------------------------------------------

  def test_every_command_has_a_chinese_description
    payload.each do |c|
      desc = c["description"]
      refute_nil desc, "/#{c['command']} 缺描述"
      refute_empty desc.strip, "/#{c['command']} 描述为空"
      assert_operator desc.length, :<=, 256, "/#{c['command']} 描述超 256 上限"
      assert_match(/[\p{Han}\p{Hiragana}\p{Katakana}]/u, desc,
                   "/#{c['command']} 描述应为中文/日文：#{desc.inspect}")
    end
  end

  # --- is_ephemeral：/secret 必带、其余必不带 -------------------------------

  def test_secret_command_is_ephemeral
    secret = payload.find { |c| c["command"] == "secret" }
    refute_nil secret
    assert_equal true, secret["is_ephemeral"], "/secret 必须带 is_ephemeral=true（计划 §6 硬要求）"
  end

  def test_other_commands_are_not_ephemeral
    payload.reject { |c| c["command"] == "secret" }.each do |c|
      refute c.key?("is_ephemeral"),
             "/#{c['command']} 不应带 is_ephemeral（误标会让普通命令群内不可见）"
    end
  end

  # --- 平台规则：≤32 字符、纯拉丁+数字+下划线 -------------------------------

  def test_command_names_obey_platform_rules
    payload.each do |c|
      name = c["command"]
      assert_operator name.length, :<=, 32, "/#{name} 超 32 字符上限"
      assert_match(/\A[a-z0-9_]+\z/, name,
                   "/#{name} 含平台不允许的字符（仅允许拉丁字母+数字+下划线）")
    end
  end

  # --- gem 调用路径 --------------------------------------------------------

  def test_register_main_commands_uses_gem_when_available
    api, fake, = build_api
    api.register_main_commands

    refute_nil fake.registered_commands, "gem 支持时应走 set_my_commands"
    assert fake.registered_commands.key?(:commands)

    commands = fake.registered_commands[:commands]
    assert_equal REQUIRED_COMMANDS.size, commands.size
    commands.each { |c| assert_kind_of Telegram::Bot::Types::BotCommand, c }
  end

  def test_gem_bot_command_carries_is_ephemeral
    api, fake, = build_api
    api.register_main_commands

    secret = fake.registered_commands[:commands].find { |c| c.command == "secret" }
    assert_equal true, secret.is_ephemeral, "BotCommand 对象须带 is_ephemeral"

    start = fake.registered_commands[:commands].find { |c| c.command == "start" }
    assert_nil start.is_ephemeral, "/start 不应带 is_ephemeral"
  end

  # --- 降级路径（gem 缺端点/参数 → raw_api_call）---------------------------

  def test_falls_back_to_raw_call_when_gem_rejects
    gem_like = BotTestHelper::FakeGemLikeApi.new(missing: ["setMyCommands"])
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(gem_like),
                                      sleeper: BotTestHelper::FakeSleeper.new(BotTestHelper::FakeClock.new),
                                      clock: BotTestHelper::FakeClock.new,
                                      http_executor: http = BotTestHelper::FakeHttpExecutor.new)

    api.register_main_commands

    assert_nil gem_like.registered_commands, "gem 抛错时不应假装成功"
    assert_equal 1, http.calls.size, "应降级走一次 raw HTTP"
    assert_match(%r{/setMyCommands\z}, http.last_url)

    # raw 通道 wire 形态是 application/json body（2026-10-12 二审修复
    # JSON-in-JSON 二次编码）：commands 是**原生数组**而非 JSON 字符串——
    # 「数组编成 JSON 字符串」是 form-urlencoded 通道约定，JSON body 里
    # Telegram 期望真数组。
    assert_equal payload, http.last_body[:commands],
                 "raw 载荷形状须与主定义一致（原生 JSON 类型）"
    wire = JSON.parse(http.last_body.to_json)
    assert_kind_of Array, wire["commands"], "wire JSON 里 commands 必须是真数组"
    assert_equal "start", wire["commands"].first["command"]
  end

  def test_raw_fallback_does_not_leak_token_into_body
    gem_like = BotTestHelper::FakeGemLikeApi.new(missing: ["setMyCommands"])
    http = BotTestHelper::FakeHttpExecutor.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(gem_like),
                                      sleeper: BotTestHelper::FakeSleeper.new(BotTestHelper::FakeClock.new),
                                      clock: BotTestHelper::FakeClock.new,
                                      http_executor: http)
    api.register_main_commands

    # URL 里含 token 是 API 形态决定的，但 body **不得**含 token
    refute_match(FAKE_TOKEN, http.last_body.inspect, "token 不得出现在请求体")
  end

  # --- 启动时自动注册 ------------------------------------------------------
  #
  # 2026-10-12 二审修复（T2.1 遗留双注册）：菜单注册唯一入口 = main.rb 启动期
  # 显式调 register_main_commands；start **不再**内部注册（限流风暴期双注册
  # 白撞一倍 setMyCommands 请求量）。本条钉死新契约，防回归。
  def test_start_does_not_register_menu
    api, fake, = build_api
    api.api_client.define_singleton_method(:listen) { |&_b| nil }

    api.start(dispatch: ->(_u) {})

    assert_nil fake.registered_commands,
               "start 不得注册菜单（唯一注册点是 main.rb 的显式调用）"
  end

  def test_explicit_register_then_start_registers_exactly_once
    api, fake, = build_api
    api.api_client.define_singleton_method(:listen) { |&_b| nil }

    api.register_main_commands
    api.start(dispatch: ->(_u) {})

    assert_equal REQUIRED_COMMANDS.size, fake.registered_commands[:commands].size,
                 "显式注册一次 + start 后应只有一次注册记录"
  end
end