source "https://rubygems.org"

# ============================================================
# 引擎：BCDice 钉版。升级纪律（计划 §9 / R9）：
#   改版本号 → bundle update bcdice → 全量测试绿 → 提交 Gemfile.lock
# 上游零修改，扩展类在 game_systems/ 继承注册（计划 §3 决2）
# ============================================================
gem "bcdice", "3.17.0"

# Telegram bot 层
# telegram-bot-ruby 2.8.1（2026-08-02）早于 Bot API 10.3，
# ephemeral 等新参数走 HTTParty 直调（计划 §12 R2 / §15.2 E2）
gem "telegram-bot-ruby", "2.8.1"
gem "httparty", "~> 0.24"

# DB：SQLite3（WAL 模式，连接层 PRAGMA foreign_keys=ON，§15.5 E10）
gem "sqlite3", "~> 2.9"

# .env 读取（token 用户自填，agent 不写值）
gem "dotenv", "~> 3.2"

group :test do
  # toml 确定性测试 runner：与上游同为 test-unit + tomlrb，
  # 避免解析器行为差异（§15.5 E9）
  gem "test-unit", "~> 3.7"
  gem "tomlrb", "~> 2.0"
  # DB/bot 层单元测试
  gem "minitest", "~> 5.25"
  gem "rake", "~> 13.4"
end
