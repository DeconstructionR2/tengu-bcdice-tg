# frozen_string_literal: true

# ============================================================================
# bot/config.rb — 环境与 token 解析（T2.1）
#
# token 纪律（硬红线，贯穿全任务）：
#   - **绝不**打印 token 值（包括报错信息、debug 输出、日志、异常 message）；
#   - **绝不**把 token 值写进任何入库文件；
#   - .env 由用户本人填写（.env.example 只给键位），.env 已在 .gitignore；
#   - 本文件只**读** token 与**校验**链路，绝不代写值。
#
# 分支语义：ENV['TENGU_ENV']=='test' 时用 TELEGRAM_BOT_TOKEN_TEST，
# 否则用 TELEGRAM_BOT_TOKEN（计划 §0.2.4「双 bot 账号」惯例）。
# ============================================================================

require "dotenv"

module TelegramBot
  module Config
    ROOT = File.expand_path("..", __dir__)
    TELEGRAM_API_BASE_URL = "https://api.telegram.org"

    # token 形如 "1234567890:AA..." —— 只用它做**形状**校验，绝不回显值。
    TOKEN_SHAPE = /\A\d+:[A-Za-z0-9_-]{20,}\z/

    module_function

    # 加载 .env（若存在）。已存在的 ENV 变量优先，不被 .env 覆盖。
    # 生产部署把 .env 放数据卷（计划 §9），路径仍可用 TELEGRAM_ENV_FILE 覆盖。
    def load_dotenv!
      path = ENV["TELEGRAM_ENV_FILE"] || File.join(ROOT, ".env")
      Dotenv.load(path) if File.exist?(path)
      path
    end

    def test_env?
      ENV["TENGU_ENV"].to_s == "test"
    end

    # 当前分支应使用的 token 键名
    def token_key
      test_env? ? "TELEGRAM_BOT_TOKEN_TEST" : "TELEGRAM_BOT_TOKEN"
    end

    # 取 token。缺失或形状非法时抛**不含值**的清晰错误。
    #
    # 错误文案只提「键名 + 该去哪儿填」，绝不 echo 实际值（哪怕是空串回显也不行——
    # 形状错误时值可能已被误填成真实 token，回显即泄漏）。
    def bot_token
      key = token_key
      value = ENV[key].to_s.strip

      if value.empty?
        raise MissingTokenError,
              "缺少环境变量 #{key}。\n" \
              "  · 正式 bot: 在 .env 填 TELEGRAM_BOT_TOKEN（@BotFather 提供）\n" \
              "  · 测试 bot: 设 TENGU_ENV=test 并在 .env 填 TELEGRAM_BOT_TOKEN_TEST\n" \
              "  · .env 模板见 .env.example（token 值由用户本人填写，agent 不代写）\n" \
              "  · 当前分支（token_key）= #{key}（由 TENGU_ENV=#{ENV['TENGU_ENV'].inspect} 决定）"
      end

      unless value.match?(TOKEN_SHAPE)
        raise InvalidTokenError,
              "环境变量 #{key} 的值**形状**不合法（期望形如 <数字>:<至少20位字母数字_- >）。\n" \
              "  为防泄漏，此处不回显实际值；请核对是否复制完整、是否含多余引号或空格。\n" \
              "  若你确信值正确，请检查是否带了前导/尾随空白（已 strip）或换行。"
      end

      value
    end

    # 功能开关（.env，缺省值与计划一致）
    def log_rolls?
      ENV["LOG_ROLLS"].to_s == "1"
    end

    def logging_enabled?
      ENV.fetch("LOGGING_ENABLED", "1").to_s == "1"
    end

    def db_path
      ENV["DB_PATH"] || "/app/data/tengu.db"
    end
  end

  # 缺 token（只报键名，不报值）
  class MissingTokenError < StandardError; end
  # token 形状非法（不回显值）
  class InvalidTokenError < StandardError; end
end