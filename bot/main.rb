# frozen_string_literal: true

# ============================================================================
# bot/main.rb — 入口（T2.1 起 / T2.3 接入路由 / T2.4 挂真 handler / T2.5 挂 migration
#              / T2.6 挂 /settings + 管理员助手 + 辅助轨开关持久化
#              / T3.1 挂暗骰 /secret + 按钮回调路由
#              / T3.2 挂天狗银行 /bank
#              / T3.4 挂自定义表 /ct
#              / T3.5 挂跑团 log /log + 录制挂钩）
#
# 本文件保证 `bundle exec ruby bot/main.rb` 能起：
#   1. 加载引擎（lib/engine_bootstrap.rb —— 与测试/spike 共用同一初始化序列）；
#   2. 解析 token（bot/config.rb，绝不打印值）；
#   3. 建 TelegramApi，setMyCommands 注册主轨菜单；
#   4. 建 Router（slash 主轨 + 裸 ASCII 辅助轨 + 按钮回调分支 + log 录制挂钩）
#      并挂 handler；
#   5. 起长轮询。
#
# 已挂的 handler（T3.5 起 —— 菜单十条命令**全部**有真 handler）：
#   /start /help /settings /roll /nd /system /secret /bank /ct /log
#   + 辅助轨（裸 ASCII）+ **:callback_query**（暗骰「公开」按钮）
#   + log 录制挂钩（router 的 session_log: 注入，bot/session_log_recorder.rb）
#
# T3.5 范围纪律（跑团 log 录制，计划 §13 第 6 项 / §12 R8）：
#   - **主开关 LOGGING_ENABLED**（.env，Config.logging_enabled?）同时传给
#     handler（未启用 → /log 各子命令统一应答「未启用」）与 recorder
#     （未启用 → 一次 DB 都不碰，全链路短路）。不要只传一处。
#   - recorder 与 handler **共用同一个 Connection**（单连接纪律，§3 决9）
#     与同一个 TenguDB::SessionLogs 工厂；bot_name 给导出里的 bot 条目显示名。
#   - 录制挂钩挂在 router（dispatch 集中点）；本文件只做接线，不碰录制逻辑。
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
#
# T4.1：Docker/管道语境 stdout/stderr 同步——非 TTY 时 Ruby 默认**块缓冲**，
# 容器里 `docker logs` 会一直看不到启动序列（全攒在缓冲，等到写满或进程死）。
# 容器入口直接跑本文件（Dockerfile CMD），故在此显式开启；本机调试用的
# `-e '$stdout.sync=true; …'` 包装与之叠加也是幂等的。
# ============================================================================

$stdout.sync = true
$stderr.sync = true

# docker stop 的 SIGTERM 落 Ruby 默认处理会以 exit 1 收尾——监控/编排视角的
# 「脏退出」。显式 trap 成 exit 0（正常停止语义；kimi T4.1 评审提案 #5）
Signal.trap("TERM") { exit(0) }

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
require_relative "handlers/custom_table"
require_relative "handlers/session_log"
require_relative "session_log_recorder"
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
#
# 2026-10-12 修复（双评审实证，RestartCount=10）：register_main_commands 内部
# 已对瞬态故障（429/5xx/Faraday 族）做有界退避重试（RetryPolicy），能落到
# 这里的只剩「非瞬态错误」或「重试耗尽」——按 error_code 分文案，
# 不再把 429 误报成「token 无效/已吊销」（旧文案曾误导排障方向）。
begin
  api.register_main_commands
rescue Telegram::Bot::Exceptions::ResponseError => e
  case e.error_code.to_i
  when 401, 404
    warn("[T2.4] 注册主轨菜单失败：Telegram API 拒绝请求（HTTP #{e.error_code}）。")
    warn("[T2.4] 常见原因：token 无效/已吊销，或该 token 属于另一个 bot。")
    warn("[T2.4] 请核对 .env 中 #{TelegramBot::Config.token_key} 的值（agent 不打印、不代填）。")
  when 409
    warn("[T2.4] 注册主轨菜单失败：HTTP 409 Conflict——另一个同 token 的轮询者在线（双轮询红线）。")
    warn("[T2.4] 处置：docs/OPERATIONS.md §5 互斥操作法；先清掉多余容器/进程再起本 bot。")
  when 429
    wait = TelegramBot::RetryPolicy.retry_after_seconds(e)
    warn("[T2.4] 注册主轨菜单失败：Telegram 限流（HTTP 429#{wait ? "，retry after #{wait}s" : ""}），" \
         "已退避重试 #{TelegramBot::RetryPolicy::REGISTER_MAX_ATTEMPTS} 次仍受限。")
    warn("[T2.4] 常见原因：限流风暴，或同 token 的其它实例在刷请求；容器重启会再试。")
  else
    warn("[T2.4] 注册主轨菜单失败：HTTP #{e.error_code}（非瞬态错误，或退避重试后仍失败）。")
  end
  exit(1)
rescue Faraday::Error => e
  # 网络错误退避重试耗尽：只打印异常类名，**不打印 e.message**（消息体可能夹带敏感串）。
  warn("[T2.4] 注册主轨菜单失败：#{e.class}（已退避重试 #{TelegramBot::RetryPolicy::REGISTER_MAX_ATTEMPTS} 次仍不通；异常消息不打印，防泄漏）。")
  warn("[T2.4] 常见原因：网络不通/代理问题，或 Telegram API 临时故障；容器重启会再试。")
  exit(1)
rescue StandardError => e
  # 兜底：RawApiError 等不得裸 stack trace 崩出。
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

# 跑团 log 录制的主开关（.env LOGGING_ENABLED）。**只在这里读一次**，
# 同时传给下面的 handler（/log 未启用应答）与 recorder（全链路短路）——
# 两处各自读 env 会漂移。启动日志行也要用它，故在 puts 之前就取好。
logging_enabled = TelegramBot::Config.logging_enabled?

puts "[T3.1] 天狗骰子 bot 启动中…（token_key=#{TelegramBot::Config.token_key}，值不打印）"
puts "[T3.1] 主轨菜单已注册：#{TelegramBot::TelegramApi.commands_payload.map { |c| "/#{c['command']}" }.join(' ')}"
puts "[T3.1] @username=#{bot_username.inspect}；路由=slash 主轨 + 裸 ASCII 辅助轨 + 按钮回调分支"
puts "[T3.5] 已挂 handler：/start /help /settings /roll /nd /system /secret(暗骰) /bank(天狗银行) /ct(自定义表) /log(跑团 log)" \
     "（bot/handlers/dice.rb + handlers/settings.rb + handlers/help.rb + handlers/secret_dice.rb + handlers/bank.rb + handlers/custom_table.rb + handlers/session_log.rb）；菜单十条命令全部有真身"
puts "[T3.2] 天狗银行：bank_record 按 (chat_id, thread_id) 话题级一本账；流水/道具为 JSON 数组（元素级删道具）" \
     "；余额可为负（忠实保留天狗无透支校验）；893 彩蛋照搬天狗 change893（金额串含 893 即小怪装饰）"
puts "[T3.4] 自定义表：custom_tables 群级一表一行（话题共享）；改表权限=权限名单或本群管理员（getChatMember fail-closed）" \
     "；查找顺序 内置(i18n 桥)→本群→公共；范围钳自动维护，掷表超钳取端点并明示"
puts "[T3.1] 暗骰：结果落 secrets 表（TTL 7 天惰性清理），「公开」按钮 = callback 分支 + 本人校验 + 公开后删行"
puts "[T3.5] 跑团 log：/log new|off|on|end|list，话题级录制（文本+非文本占位+bot 掷骰结果），导出 txt+json 发回原作用域；" \
     "暗骰命令消息与 ephemeral 结果均不落盘；LOGGING_ENABLED=#{logging_enabled ? 1 : 0}（=0 时 /log 一律应答「未启用」且录制路径零 DB 触碰）"
puts "[T2.6] 群升级 re-key 已挂（bot/migration.rb，5 表事务 + chat_id_aliases 审计）"
puts "[T2.6] 管理员助手已挂（bot/admin.rb，getChatMember；查询失败 fail-closed）"

# 路由（T2.3 建，T3.4 挂满 handler）：
#   - slash 主轨：/start /help /settings /roll /nd /system /secret /bank /ct /log
#     命令集合以 MainMenu::ENTRIES 为准；未注册 handler 的命令一律静默
#     （现仅 /log 是占位应答——菜单上架命令不留静默，见 handlers/help.rb）。
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
# secret_dice 的构造挪到 session_log_recorder 之后（见下方 T3.5 段）——
# 公开按钮路径要注入录制器（kimi T3.5 评审提案 #4）。

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

# T3.4：自定义表 /ct。custom_tables 与上面共用同一 Connection；admin 用**同一
# 个** Admin 实例（缓存跨消息复用，见 T2.6 纪律）；builtin 缺省 = BuiltinTables
# 真桥（读引擎侧 i18n，懒构建——此刻 bootstrap 已完成）。
custom_table_handler = TelegramBot::Handlers::CustomTableHandler.new(
  custom_tables: TenguDB::CustomTables.new(dice_db),
  admin: admin
)

# T3.5：跑团 log 录制。主开关（.env LOGGING_ENABLED）**同时**传给 handler
# 与 recorder——handler 管「/log 各子命令的未启用应答」，recorder 管「一次
# DB 都不碰的全链路短路」。两处同源（启动时读取的 logging_enabled），不要各自读 env。
# bot_name：导出里 bot 条目的显示名（get_me 的 username，取不到退化为固定名）。
session_logs_store = TenguDB::SessionLogs.new(dice_db)
session_log_handler = TelegramBot::Handlers::SessionLogHandler.new(
  session_logs: session_logs_store, enabled: logging_enabled
)
session_log_recorder = TelegramBot::SessionLogRecorder.new(
  session_logs: session_logs_store, enabled: logging_enabled,
  bot_name: bot_username || "骰子bot"
)

# T3.1：暗骰 handler 在 recorder 之后构造——「公开」按钮把结果发成群内公开
# 消息的路径要进 log（自走 api.send_text 不到 router 挂钩②，由 handler 显式
# 录；录的是已公开内容，符合 R8 口径。kimi T3.5 评审提案 #4）
secret_dice = TelegramBot::Handlers::SecretDiceHandler.new(
  settings: settings, secrets: secrets_store,
  session_log: session_log_recorder
)

router = TelegramBot::Router.new(
  api: api,
  handlers: { start: TelegramBot::StartHandler.new,
              # /help 与「菜单已上架、尚未实现」的占位应答模式（真机验收教训：
              # 菜单里有的命令没 handler = 用户视角「bot 死了」；菜单外的
              # 未知 slash 仍一律静默）。/log 已由 T3.5 换成真 handler——
              # 至此菜单十条命令全部有真身，PendingHandler 暂无用武之位。
              help: TelegramBot::Handlers::HelpHandler.new,
              log: session_log_handler }
                .merge(TelegramBot::Handlers::DiceHandler.registry(dice))
                .merge(TelegramBot::Handlers::SecretDiceHandler.registry(secret_dice))
                .merge(TelegramBot::Handlers::SettingsHandler.registry(settings_handler))
                .merge(TelegramBot::Handlers::BankHandler.registry(bank_handler))
                .merge(TelegramBot::Handlers::CustomTableHandler.registry(custom_table_handler)),
  # T3.5：录制挂钩（router 只调注入的对象；DB 在 recorder 里）。
  # LOGGING_ENABLED=0 时这个对象自身短路，注入与否行为等价；恒注入让接线
  # 只有一条路径（不给「忘了注入」留静默失效面）。
  session_log: session_log_recorder,
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
# 轮询层瞬态故障（429/5xx/Faraday 族）由 api.start 内部退避重进
# （RetryPolicy，2026-10-12 修复）；这里只兜**致命**出口——非瞬态
# ResponseError（401 token 失效 / 409 双轮询红线等）与意外异常。
# 此前这里无兜底：fetch_updates 的 429 裸崩出 → 进程退出 → 容器重启循环
# （生产实证 RestartCount=10）。exit(1) 前给可读报错，不回显 token。
begin
  api.start(dispatch: router.method(:dispatch))
rescue Telegram::Bot::Exceptions::ResponseError => e
  if e.error_code.to_i == 409
    warn("[T2.4] 长轮询中止：HTTP 409 Conflict——另一个同 token 的轮询者在线（双轮询红线，docs/OPERATIONS.md §5）。")
  else
    warn("[T2.4] 长轮询中止：Telegram API 致命错误（HTTP #{e.error_code}；响应体不打印，防泄漏）。")
  end
  exit(1)
rescue StandardError => e
  warn("[T2.4] 长轮询中止：#{e.class}（异常消息不打印，防泄漏）。")
  exit(1)
end
