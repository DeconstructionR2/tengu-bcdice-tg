# frozen_string_literal: true

# ============================================================================
# bot/main.rb — 最小入口（T2.1）
#
# 范围纪律：真正的路由归 T2.3（router.rb），**不在本任务实现**。
# 本文件只保证 `bundle exec ruby bot/main.rb` 能起：
#   1. 加载引擎（lib/engine_bootstrap.rb —— 与测试/spike 共用同一初始化序列）；
#   2. 解析 token（bot/config.rb，绝不打印值）；
#   3. 建 TelegramApi，setMyCommands 注册主轨菜单；
#   4. 起长轮询；dispatch 暂为**占位**：记录并静默忽略。
#
# 跑法：
#   bundle exec ruby bot/main.rb                # 正式 token（.env 的 TELEGRAM_BOT_TOKEN）
#   TENGU_ENV=test bundle exec ruby bot/main.rb # 测试 token（.env 的 TELEGRAM_BOT_TOKEN_TEST）
#
# 注意：无 token 时以清晰错误退出（只报键名，不报值）。
# ============================================================================

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require_relative "config"
require_relative "telegram_api"
require_relative "../lib/engine_bootstrap"

module TelegramBot
  # T2.1 占位 dispatch：记录并静默忽略。
  # T2.3 接入 router 后替换为 Router#dispatch（slash 主轨 + 裸 ASCII 辅助轨）。
  class PlaceholderDispatch
    def initialize(logger: $stdout)
      @logger = logger
      @count = 0
    end

    attr_reader :count

    def call(update)
      @count += 1
      message = update.respond_to?(:current_message) ? update.current_message : nil
      chat = message.respond_to?(:chat) ? message.chat&.id : nil
      # 只记结构性信息（chat_id / 消息长度），**不记正文**——正文可能含用户隐私
      @logger.puts("[T2.1 placeholder] update ##{@count} chat=#{chat} " \
                   "len=#{message.respond_to?(:text) ? message.text.to_s.length : 0} " \
                   "（路由由 T2.3 实现，当前静默忽略）")
      nil
    end
  end
end

# --- 启动 -------------------------------------------------------------------

TelegramBot::Config.load_dotenv!

begin
  token = TelegramBot::Config.bot_token
rescue TelegramBot::MissingTokenError, TelegramBot::InvalidTokenError => e
  warn("[T2.1] 启动中止：#{e.message}")
  exit(1)
end

# 引擎初始化：与测试/spike/脚本共用同一序列（T2.1 收敛的成果）。
# 缺 reload! 会静默全量 MissingTranslationData —— 这里统一兜住。
# EngineBootstrap 是顶层模块（lib/engine_bootstrap.rb），不在 TelegramBot 命名空间下。
EngineBootstrap.bootstrap!

api = TelegramBot::TelegramApi.new(token: token)

# 启动期错误处理：菜单注册失败就别硬起（否则长轮询起来也是空菜单），
# 但**必须**给出可读报错，且不得回显 token（响应体/URL 都可能带）。
begin
  api.register_main_commands
rescue Telegram::Bot::Exceptions::ResponseError => e
  warn("[T2.1] 注册主轨菜单失败：Telegram API 拒绝请求。")
  warn("[T2.1] 常见原因：token 无效/已吊销，或该 token 属于另一个 bot。")
  warn("[T2.1] 请核对 .env 中 #{TelegramBot::Config.token_key} 的值（agent 不打印、不代填）。")
  exit(1)
end

puts "[T2.1] 天狗骰子 bot 启动中…（token_key=#{TelegramBot::Config.token_key}，值不打印）"
puts "[T2.1] 主轨菜单已注册：#{TelegramBot::TelegramApi.commands_payload.map { |c| "/#{c['command']}" }.join(' ')}"

dispatch = TelegramBot::PlaceholderDispatch.new

# 长轮询（零入境端口，计划 §3 决7）。单条消息异常由 api.start 内部兜底，
# 不会杀死循环。
api.start(dispatch: dispatch)