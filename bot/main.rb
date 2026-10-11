# frozen_string_literal: true

# ============================================================================
# bot/main.rb — 入口（T2.1 起 / T2.3 接入路由 / T2.4 挂真 handler / T2.5 挂 migration
#              / T2.6 挂 /settings + 管理员助手 + 辅助轨开关持久化
#              / T3.1 挂暗骰 /secret + 按钮回调路由）
#
# 本文件保证 `bundle exec ruby bot/main.rb` 能起：
#   1. 加载引擎（lib/engine_bootstrap.rb —— 与测试/spike 共用同一初始化序列）；
#   2. 解析 token（bot/config.rb，绝不打印值）；
#   3. 建 TelegramApi，setMyCommands 注册主轨菜单；
#   4. 建 Router（slash 主轨 + 裸 ASCII 辅助轨 + 按钮回调分支）并挂 handler；
#   5. 起长轮询。
#
# 已挂的 handler（T3.1 起）：
#   /start /help /settings /roll /nd /system /secret + 辅助轨（裸 ASCII）
#   + **:callback_query**（暗骰「公开」按钮）
#   **尚无 handler**（按 router 静默策略不回复，等 T3.x 逐个填）：
#   bank / ct / log（各自挂 PendingHandler 占位）
#
# T3.1 范围纪律（暗骰）：
#   - Secrets 落库走 **写入时惰性 TTL 清理**（7 天），**不建定时任务**——
#     单进程长轮询没有调度器，为一天几次的表引入常驻执行路径不值得；
#   - handler **恒返回 nil**：结果只能经 send_ephemeral 出，一返回 String
#     router 就会代发进群（暗骰的命门）；
#   - 「公开」按钮经 router 的 callback 分支：先 answerCallbackQuery、
#     只认本人（secrets.user_id == query.from.id）、**公开成功后删行**（E5）。
#
# T2.6 范围纪律：
#   - aux_enabled **已持久化**：读群级 chat_settings.aux_enabled（schema.sql
#     加列 + db/connection.rb 的 COLUMN_ADDITIONS 补旧库，两条腿缺一不可）。
#   - 管理员助手 Admin 是 getChatMember 的**唯一**实现，只构造一个实例注入
#     SettingsHandler（缓存要跨消息复用）；T3.4 会复用同一个对象。
#   - Admin 在 API 查询失败时 **fail-closed 返回 false**（权限判定的错误方向
#     必须选安全的那侧）；私聊恒 true。
#
# T2.4 范围纪律（roll / nd / system / aux 已挂真 handler；secret / bank /
#   ct / log / settings 当时尚无 handler → 静默。/settings 已由 T2.6 补上。）
#
# T2.5 范围纪律（群升级 re-key）：
#   - Migration 由本文件构造并**注入** Router，router 自己 require 不它、不碰 DB；
#   - 与 DiceHandler / SettingsHandler **共用同一 Connection 实例**（单连接
#     纪律，§3 决9）。
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
require_relative "admin"
require_relative "handlers/dice"
require_relative "handlers/settings"
require_relative "handlers/help"
require_relative "handlers/secret_dice"
require_relative "handlers/bank"
require_relative "migration"
require_relative "../db/connection"
require_relative "../lib/engine_bootstrap"

# --- 启动 -------------------------------------------------------------------

TelegramBot::Config.load_dotenv!

begin
  token = TelegramBot::Config.bot_token
rescue TelegramBot::MissingTokenError, TelegramBot::InvalidTokenError => e
  warn("[T2.4] 启动中止：#{e.message}")
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
  warn("[T2.4] 注册主轨菜单失败：Telegram API 拒绝请求。")
  warn("[T2.4] 常见原因：token 无效/已吊销，或该 token 属于另一个 bot。")
  warn("[T2.4] 请核对 .env 中 #{TelegramBot::Config.token_key} 的值（agent 不打印、不代填）。")
  exit(1)
rescue StandardError => e
  # 兜底：网络错误（Faraday）/RawApiError 等不得裸 stack trace 崩出。
  # 只打印异常类名，**不打印 e.message**（消息体可能夹带敏感串）。
  warn("[T2.4] 注册主轨菜单失败：#{e.class}（异常消息不打印，防泄漏）。")
  warn("[T2.4] 常见原因：网络不通/代理问题，或 Telegram API 临时故障；稍后重试。")
  exit(1)
end

# 本 bot 的 username（供 router 校验 `/cmd@BotName` 的 @后缀）。
# 取不到就降级为 nil（= 不校验），单 bot 部署下不影响正确性。
# 失败不阻断启动：这是锦上添花项，不是启动前置。
bot_username =
  begin
    api.api_client.api.get_me.username
  rescue StandardError => e
    warn("[T2.4] 取 bot username 失败（@后缀校验降级为不校验）：#{e.class}")
    nil
  end

puts "[T3.1] 天狗骰子 bot 启动中…（token_key=#{TelegramBot::Config.token_key}，值不打印）"
puts "[T3.1] 主轨菜单已注册：#{TelegramBot::TelegramApi.commands_payload.map { |c| "/#{c['command']}" }.join(' ')}"
puts "[T3.1] @username=#{bot_username.inspect}；路由=slash 主轨 + 裸 ASCII 辅助轨 + 按钮回调分支"
puts "[T3.2] 已挂 handler：/start /help /settings /roll /nd /system /secret(暗骰) /bank(天狗银行) + 辅助轨" \
     "（bot/handlers/dice.rb + handlers/settings.rb + handlers/help.rb + handlers/secret_dice.rb + handlers/bank.rb）；ct/log 占位应答待 T3.x"
puts "[T3.2] 天狗银行：bank_record 按 (chat_id, thread_id) 话题级一本账；流水/道具为 JSON 数组（元素级删道具）" \
     "；余额可为负（忠实保留天狗无透支校验）；893 彩蛋照搬天狗 change893（金额串含 893 即小怪装饰）"
puts "[T3.1] 暗骰：结果落 secrets 表（TTL 7 天惰性清理），「公开」按钮 = callback 分支 + 本人校验 + 公开后删行"
puts "[T2.6] 群升级 re-key 已挂（bot/migration.rb，5 表事务 + chat_id_aliases 审计）"
puts "[T2.6] 管理员助手已挂（bot/admin.rb，getChatMember；查询失败 fail-closed）"

# 路由（T2.3 建，T2.4 挂真 handler）：
#   - slash 主轨：/start /help /settings /roll /nd /system /secret /bank /ct /log
#     命令集合以 MainMenu::ENTRIES 为准；未注册 handler 的命令一律静默
#     （故 /secret /bank /ct /log 目前静默，等 T3.x；/help 同样静默）。
#   - 辅助轨：裸 ASCII 骰式（N4,3 / SB / 2d6>=4…），不命中一律静默（防抢话，§12 R4）。
#   - aux_enabled 已持久化（T2.6）：读群级 chat_settings.aux_enabled，
#     查不到行 = 默认开；查询失败由 router 的 fail-closed 兜底（异常→按关）。
# 启动期强制打开 DB（建表 + schema）。
#
# 为什么不等第一次掷骰再惰性开：DB_PATH 写错 / 数据卷没挂这类**部署期**故障，
# 越早炸越好——真到了群消息里才炸，玩家看到的是「bot 装上了但一直不掷骰」，
# 排查成本高一个数量级。这与上面「菜单注册失败就 exit 1」是同一条纪律。
#
# 连接**只开一次**并同时交给 DiceHandler 与 Migration（T2.5）：单连接纪律
# （§3 决9）——两个 Connection 指向同一文件会各自持有 sqlite3 句柄，WAL 下
# 不会坏数据，但写锁竞争与可见性不确定性都是白捡的。
dice_db = nil
begin
  dice_db = TenguDB::Connection.instance
rescue StandardError => e
  warn("[T2.6] 打开数据库失败（路径=#{TelegramBot::Config.db_path}）：#{e.class}（异常消息不打印）")
  warn("[T2.6] 请核对 DB_PATH 与数据卷权限（容器内应为 /app/data/tengu.db，且该目录可写）。")
  exit(1)
end

settings = TenguDB::Settings.new(dice_db)
dice = TelegramBot::Handlers::DiceHandler.new(settings: settings)

# T3.1：暗骰。与 DiceHandler / SettingsHandler **共用同一 Connection**（单连接
# 纪律，§3 决9）——Secrets 只新建一个对象，但底层句柄是同一个。
# 注意 Secrets 的 TTL 清理走「每次写入顺手删」，故它本身不持有常驻资源。
secrets_store = TenguDB::Secrets.new(dice_db)
secret_dice = TelegramBot::Handlers::SecretDiceHandler.new(
  settings: settings, secrets: secrets_store
)

# T2.6：管理员助手（getChatMember 的唯一实现）。**只构造一个实例**并注入
# SettingsHandler —— 缓存要跨消息复用，handler 各建一个就等于没有缓存。
# T3.4 的自定义表改表权限会复用同一个对象（计划 §5）。
admin = TelegramBot::Admin.new(api: api)
settings_handler = TelegramBot::Handlers::SettingsHandler.new(
  settings: settings, admin: admin
)

# T3.2：天狗银行。与上面共用同一 Connection（单连接纪律，§3 决9）。
# Bank 的四个操作都是「事务内整行读改写」，不持有常驻资源。
bank_store = TenguDB::Bank.new(dice_db)
bank_handler = TelegramBot::Handlers::BankHandler.new(bank: bank_store)

router = TelegramBot::Router.new(
  api: api,
  handlers: { start: TelegramBot::StartHandler.new,
              # /help 与「菜单已上架、T3.x 才实现」的占位应答（真机验收教训：
              # 菜单里有的命令没 handler = 用户视角「bot 死了」；菜单外的
              # 未知 slash 仍一律静默）。
              help: TelegramBot::Handlers::HelpHandler.new,
              ct: TelegramBot::Handlers::PendingHandler.new(feature: "自定义表 /ct"),
              log: TelegramBot::Handlers::PendingHandler.new(feature: "跑团 log /log") }
                .merge(TelegramBot::Handlers::DiceHandler.registry(dice))
                .merge(TelegramBot::Handlers::SecretDiceHandler.registry(secret_dice))
                .merge(TelegramBot::Handlers::SettingsHandler.registry(settings_handler))
                .merge(TelegramBot::Handlers::BankHandler.registry(bank_handler)),
  bot_username: bot_username,
  # 辅助轨开关（T2.6：**已持久化**）。读群级 chat_settings.aux_enabled，
  # 查不到行 = 默认开（db/settings.rb 的 DEFAULT_AUX_ENABLED）。
  #
  # 查询失败**不在这里兜底**：router 的 aux_track_enabled? 已经 fail-closed
  # （异常 → 按关闭处理，见 bot/router.rb），这层不必重复判断，且重复判断会
  # 出现「router 以为是关、这里是开」的双重真相。
  aux_enabled: lambda { |chat_id, thread_id|
    settings.aux_enabled(chat_id, thread_id: thread_id)
  },
  # T2.5：群升级 re-key。**与 dice 共用同一连接**（单连接纪律，§3 决9）——
  # 两个 Connection 指向同一个文件会各自持有 sqlite3 句柄，WAL 下虽然
  # 不会坏数据，但写锁竞争与「谁先看到对方提交」的不确定性都是白捡的。
  migration: TelegramBot::Migration.new(connection: dice_db)
)

# 长轮询（零入境端口，计划 §3 决7）。单条消息异常由 api.start 内部兜底，
# 不会杀死循环；router 自身对 handler 异常也逐条兜底（T2.3）。
api.start(dispatch: router.method(:dispatch))