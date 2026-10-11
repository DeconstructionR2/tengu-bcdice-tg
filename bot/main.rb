# frozen_string_literal: true

# ============================================================================
# bot/main.rb — 入口（T2.1 起 / T2.3 接入路由）
#
# 本文件保证 `bundle exec ruby bot/main.rb` 能起：
#   1. 加载引擎（lib/engine_bootstrap.rb —— 与测试/spike 共用同一初始化序列）；
#   2. 解析 token（bot/config.rb，绝不打印值）；
#   3. 建 TelegramApi，setMyCommands 注册主轨菜单；
#   4. 建 Router（T2.3：slash 主轨 + 裸 ASCII 辅助轨）并起长轮询。
#
# T2.3 范围纪律：**只挂最小 /start 欢迎语**证明「入站 → 解析 → 分发 →
# 经 TelegramApi 回发（带 thread 透传）」链路通；真正的掷骰 handler 归 T2.4。
# 其余命令（roll/nd/system/secret/bank/ct/log）已注册进路由表但**没有 handler**，
# 按 router 的静默策略不回复——等 T2.4 起逐个填 handler。
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
require_relative "router"
require_relative "../lib/engine_bootstrap"

# --- 启动 -------------------------------------------------------------------

TelegramBot::Config.load_dotenv!

begin
  token = TelegramBot::Config.bot_token
rescue TelegramBot::MissingTokenError, TelegramBot::InvalidTokenError => e
  warn("[T2.3] 启动中止：#{e.message}")
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
  warn("[T2.3] 注册主轨菜单失败：Telegram API 拒绝请求。")
  warn("[T2.3] 常见原因：token 无效/已吊销，或该 token 属于另一个 bot。")
  warn("[T2.3] 请核对 .env 中 #{TelegramBot::Config.token_key} 的值（agent 不打印、不代填）。")
  exit(1)
rescue StandardError => e
  # 兜底：网络错误（Faraday）/RawApiError 等不得裸 stack trace 崩出。
  # 只打印异常类名，**不打印 e.message**（消息体可能夹带敏感串）。
  warn("[T2.3] 注册主轨菜单失败：#{e.class}（异常消息不打印，防泄漏）。")
  warn("[T2.3] 常见原因：网络不通/代理问题，或 Telegram API 临时故障；稍后重试。")
  exit(1)
end

# 本 bot 的 username（供 router 校验 `/cmd@BotName` 的 @后缀）。
# 取不到就降级为 nil（= 不校验），单 bot 部署下不影响正确性。
# 失败不阻断启动：这是锦上添花项，不是启动前置。
bot_username =
  begin
    api.api_client.api.get_me.username
  rescue StandardError => e
    warn("[T2.3] 取 bot username 失败（@后缀校验降级为不校验）：#{e.class}")
    nil
  end

puts "[T2.3] 天狗骰子 bot 启动中…（token_key=#{TelegramBot::Config.token_key}，值不打印）"
puts "[T2.3] 主轨菜单已注册：#{TelegramBot::TelegramApi.commands_payload.map { |c| "/#{c['command']}" }.join(' ')}"
puts "[T2.3] @username=#{bot_username.inspect}；路由=slash 主轨 + 裸 ASCII 辅助轨（辅助轨默认开）"

# 路由（T2.3）：
#   - slash 主轨：/start /help /settings /roll /nd /system /secret /bank /ct /log
#     命令集合以 MainMenu::ENTRIES 为准；未注册 handler 的命令一律静默。
#   - 辅助轨：裸 ASCII 骰式（N4,3 / SB / 2d6>=4…），不命中一律静默（防抢话，§12 R4）。
#   - aux_enabled 默认开；每群可关的**持久化**归 T2.4（读 chat_settings），
#     本任务只留可注入的开关查询接口（router.rb 里改一行即可接 DB）。
router = TelegramBot::Router.new(
  api: api,
  handlers: { start: TelegramBot::StartHandler.new },
  bot_username: bot_username,
  aux_enabled: ->(_chat_id, _thread_id) { true } # T2.4 接 chat_settings
)

# 长轮询（零入境端口，计划 §3 决7）。单条消息异常由 api.start 内部兜底，
# 不会杀死循环；router 自身对 handler 异常也逐条兜底（T2.3）。
api.start(dispatch: router.method(:dispatch))