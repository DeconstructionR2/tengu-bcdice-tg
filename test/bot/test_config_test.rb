# frozen_string_literal: true

# ============================================================================
# test/bot/test_config_test.rb — token 解析两分支（T2.1）
#
# 纪律（本文件的**首要**断言）：
#   - 缺失/形状非法时报错信息**绝不回显 token 值**；
#   - 形状非法分支尤其危险——值可能已被误填成真 token，回显即泄漏。
#
# 全程 mock：直接注入 ENV，不读真 .env（真 .env 在仓库里但本测试绝不碰它）。
# ============================================================================

require_relative "test_helper"

class TestConfigToken < Minitest::Test
  include BotTestHelper

  VALID = "1234567890:AAFakeTokenForUnitTestsOnly_do_not_use"

  def setup
    @saved = ENV.to_h.select { |k, _| k.start_with?("TELEGRAM_") || k == "TENGU_ENV" }
    %w[TELEGRAM_BOT_TOKEN TELEGRAM_BOT_TOKEN_TEST TENGU_ENV].each { |k| ENV.delete(k) }
  end

  def teardown
    @saved.each { |k, v| ENV[k] = v }
    %w[TELEGRAM_BOT_TOKEN TELEGRAM_BOT_TOKEN_TEST TENGU_ENV].each { |k| ENV.delete(k) unless @saved.key?(k) }
  end

  # --- 分支一：默认走正式 token -------------------------------------------

  def test_default_env_uses_production_token
    ENV["TELEGRAM_BOT_TOKEN"] = VALID
    ENV["TELEGRAM_BOT_TOKEN_TEST"] = "9999999999:AAOtherFakeTokenForUnitTestsOnly_x"

    assert_equal "TELEGRAM_BOT_TOKEN", TelegramBot::Config.token_key
    assert_equal VALID, TelegramBot::Config.bot_token
  end

  # --- 分支二：TENGU_ENV=test 走测试 token ---------------------------------

  def test_test_env_uses_test_token
    ENV["TENGU_ENV"] = "test"
    ENV["TELEGRAM_BOT_TOKEN"] = VALID
    ENV["TELEGRAM_BOT_TOKEN_TEST"] = "9999999999:AAOtherFakeTokenForUnitTestsOnly_x"

    assert_equal "TELEGRAM_BOT_TOKEN_TEST", TelegramBot::Config.token_key
    assert_equal "9999999999:AAOtherFakeTokenForUnitTestsOnly_x", TelegramBot::Config.bot_token
  end

  def test_test_env_ignores_production_token_entirely
    ENV["TENGU_ENV"] = "test"
    ENV["TELEGRAM_BOT_TOKEN"] = VALID
    # 测试 token 缺失 → 必须报错，**不得**回退到正式 token
    # （否则一次误操作就会拿正式 bot 去跑测试）
    assert_raises(TelegramBot::MissingTokenError) { TelegramBot::Config.bot_token }
  end

  def test_non_test_env_values_use_production
    %w[production dev staging Test TEST].each do |v|
      ENV["TENGU_ENV"] = v
      ENV["TELEGRAM_BOT_TOKEN"] = VALID
      assert_equal "TELEGRAM_BOT_TOKEN", TelegramBot::Config.token_key,
                   "TENGU_ENV=#{v.inspect} 不应被当成 test 分支"
    end
  end

  # --- 缺失 ---------------------------------------------------------------

  def test_missing_token_raises_with_actionable_message
    err = assert_raises(TelegramBot::MissingTokenError) { TelegramBot::Config.bot_token }
    msg = err.message

    assert_match(/TELEGRAM_BOT_TOKEN/, msg, "报错须指明缺哪个键")
    assert_match(/\.env/, msg, "报错须提示去哪里填")
    assert_match(/TENGU_ENV/, msg, "报错须说明测试分支怎么切")
  end

  def test_blank_token_treated_as_missing
    ENV["TELEGRAM_BOT_TOKEN"] = "   "
    assert_raises(TelegramBot::MissingTokenError) { TelegramBot::Config.bot_token }
  end

  # --- 形状非法 -----------------------------------------------------------

  def test_malformed_token_raises_without_echoing_value
    bad = "this-is-not-a-real-token-but-secret-abcdefghij"
    ENV["TELEGRAM_BOT_TOKEN"] = bad

    err = assert_raises(TelegramBot::InvalidTokenError) { TelegramBot::Config.bot_token }
    refute_match(/#{Regexp.escape(bad)}/, err.message,
                 "**绝不回显 token 值**——这是本任务的红线")
  end

  def test_malformed_token_does_not_leak_any_part_of_value
    ENV["TELEGRAM_BOT_TOKEN"] = "12345:SHORTSECRET"
    err = assert_raises(TelegramBot::InvalidTokenError) { TelegramBot::Config.bot_token }
    refute_match(/SHORTSECRET/, err.message, "不得回显值的任何片段")
  end

  def test_token_with_surrounding_whitespace_is_stripped_then_accepted
    ENV["TELEGRAM_BOT_TOKEN"] = "  #{VALID}  "
    assert_equal VALID, TelegramBot::Config.bot_token
  end

  # --- 泄露防线：全文件扫描 -----------------------------------------------

  def test_no_token_value_in_source_files
    # 仓库内任何入库文件都不得含真 token 值（.env 本身不在 git 内）
    repo = File.expand_path("../..", __dir__)
    real = ENV.select { |k, v| k.start_with?("TELEGRAM_BOT_TOKEN") }
                .values.reject { |v| v.to_s.empty? }
                .reject { |v| v.include?("FakeTokenForUnitTests") }
    skip "环境里没有真 token（正常情况：CI/开发机不应有）" if real.empty?

    offenders = []
    Dir.glob(File.join(repo, "**", "*.{rb,md,toml,yml,yaml,example}"),
             File::FNM_DOTMATCH)
       .reject { |f| f.include?("/vendor/") || f.include?("/references/") || f.include?("/.git/") }
       .each do |f|
         content = File.read(f)
         real.each { |t| offenders << f if content.include?(t) }
       end

    assert_empty offenders.uniq, "这些入库文件含 token 值：#{offenders.uniq.inspect}"
  end

  # --- 功能开关 -----------------------------------------------------------

  def test_feature_flags_defaults
    ENV.delete("LOG_ROLLS")
    refute TelegramBot::Config.log_rolls?, "LOG_ROLLS 默认关"

    ENV.delete("LOGGING_ENABLED")
    assert TelegramBot::Config.logging_enabled?, "LOGGING_ENABLED 默认开"
  end
end