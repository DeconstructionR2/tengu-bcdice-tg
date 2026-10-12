# frozen_string_literal: true

# ============================================================================
# bot/telegram_api.rb — Telegram API 封装层（T2.1）
#
# 职责（计划 §2 / §6 / §8 T2.1）：
#   1. 发送封装：4096 字符切段（按字符不按字节）、message_thread_id 透传、
#      **每聊天** ≥1 秒配速（key 只含 chat_id，话题不是独立限流桶）、
#      parse_mode 可配置（默认纯文本，§13 第 7 项拍板）；
#   2. 长轮询循环封装（包 telegram-bot-ruby 的 Client#listen），
#      **逐消息错误兜底**——单条消息异常不得杀死循环；轮询层瞬态故障
#      （429/5xx/Faraday 族）退避重进、不杀进程（RetryPolicy）；gem 内部的
#      无退避紧密重试由 ClientPollingBackoff patch 接管（均 2026-10-12 修复）；
#   3. setMyCommands 注册主轨菜单（§6），/secret 带 is_ephemeral=true，瞬态
#      故障有界退避重试（RetryPolicy）；**由 main.rb 启动期显式调一次**
#      （start 不再重复调——T2.1 遗留的双注册已于 2026-10-12 消除）；
#   4. raw_api_call 薄封装：gem 白名单端点不支持的方法/参数走此通道（计划 §12 R2）；
#   5. token 解析：TENGU_ENV=='test' 时取 TELEGRAM_BOT_TOKEN_TEST，否则正式 token。
#
# 可测试性设计（test/bot/ 全部 mock，零联网、零真 token）：
#   - sleeper / clock 可注入 → 配速断言不依赖真实时间；
#   - http_executor 可注入 → raw_api_call 不碰网络；
#   - api_client 可注入 → 长轮询循环可喂假 update 流。
#
# 关键事实（2026-10-11 静态核查 + 离线实证，见 docs/t2.1-report.md §3）：
#   telegram-bot-ruby 2.8.1 的白名单（Api::ENDPOINTS）只约束**方法名**，
#   **不校验参数**——api.rb:44-51 的 `call(endpoint, raw_params)` 把 params
#   原样 JSON 化后 POST 出去。因此 setMyCommands + BotCommand(is_ephemeral)
#   与 sendMessage 的新参数**都能正常到达 wire**（实测已验），
#   且 gem 未收录的方法名（如未来新端点）会 NoMethodError → 走 raw_api_call。
#   尽管如此，本层仍保留 raw_api_call 作为**保底通道**（R2 缓解措施），
#   且不依赖该结论：gem 能走就走，不能走自动降级。
#   降级只在 **NoMethodError 的 receiver 就是 api 本体** 时触发（真·白名单缺失）；
#   其余 NoMethodError 一律原样抛出（gem 在 POST 之后才做响应类型映射，
#   误降级重发会造成重复消息，见 gem_endpoint_missing? 的注释）。
# ============================================================================

require "json"
require "httparty"
require "telegram/bot"
require "faraday/multipart" # send_document 的 FilePart（gem 也依赖它，显式声明）
require_relative "config"

# ============================================================================
# 全局配置：HTTP 读超时必须严格大于长轮询窗口（2026-10-13 审核轮修复）
#
# gem 的 Client 默认把长轮询窗口（getUpdates 的 timeout）设为 20s，而
# Configuration#connection_timeout 默认也是 20s——两个 20s 完全相等时，
# 空闲轮询在「服务端 hold 满 20s 返回」与「客户端 20s 读超时」之间边界竞争，
# 客户端偶发先到期：生产日志实测约 19 次/小时的 Faraday::TimeoutError，
# 每次触发 2~8s 的轮询退避停摆（消息延迟）与一条 warn。
# 读超时放宽到 30s 后，服务端总是先返回，竞争消除。
# 钉测：test_transient_retry_test.rb#test_http_read_timeout_exceeds_the_long_poll_window
# ============================================================================
Telegram::Bot.configure do |config|
  config.connection_timeout = 30
end

module TelegramBot
  # --------------------------------------------------------------------------
  # 切段工具（4096 字符上限，§0.2.4 / §7）
  # --------------------------------------------------------------------------
  module Chunker
    MAX_MESSAGE_LENGTH = 4096

    module_function

    # 把长文本切成每段 ≤ limit 字符的数组。
    #
    # 三条硬要求（缺一即验收不过）：
    #   1. **不丢内容**——所有段 join 回去 == 原文本；
    #   2. **优先按行边界切**——单行能放下就整行走，放不下才回退到强制切；
    #   3. **按字符数而非字节数**——Telegram 上限是 4096 **字符**（UTF-8
    #      码点），中文/日文表文本一字符 3 字节；按字节切会把文本切得过碎，
    #      按 `byteslice` 切还会切坏多字节字符产生乱码。
    #      故：按 String#each_char 累积字符数，**绝不**用 byteslice/sub。
    #
    # 保留换行：切点落在 "\n" 之后时，换行符归**前**一段，避免产生空行噪声。
    def split(text, limit: MAX_MESSAGE_LENGTH)
      text = text.to_s
      # 空串在此已被上面一行拦下（[""] 就是正确返回值），后面不再重复判空。
      return [text] if text.length <= limit

      segments = []
      current = +""

      # 按行扫（保留行尾换行）
      text.each_line do |line|
        if line.length > limit
          # 单行超长（无换行的超长文本）：先把已攒的段落冲出去，再硬切这一行
          unless current.empty?
            segments << current
            current = +""
          end
          segments.concat(hard_split(line, limit))
          next
        end

        if current.length + line.length > limit
          segments << current
          current = +""
        end
        current << line
      end

      segments << current unless current.empty?
      segments
    end

    # 无换行长文本的兜底硬切：按字符逐个累积，**不**用 byteslice（防切坏多字节）
    def hard_split(text, limit)
      parts = []
      buf = +""
      text.each_char do |ch|
        if buf.length + 1 > limit
          parts << buf
          buf = +""
        end
        buf << ch
      end
      parts << buf unless buf.empty?
      parts
    end
  end

  # --------------------------------------------------------------------------
  # 主菜单命令定义（计划 §6 主轨，逐条中文描述）
  # --------------------------------------------------------------------------
  module MainMenu
    # command（≤32 拉丁字符，平台规则）/ 中文描述 / ephemeral 标记
    # is_ephemeral: true → Bot API 10.3 的 BotCommand.is_ephemeral，
    # 该命令发出后群内不可见（计划 §6 `/secret` 硬性要求）。
    ENTRIES = [
      { command: "start",    description: "开始使用天狗骰子", ephemeral: false },
      { command: "help",     description: "查看帮助与命令列表", ephemeral: false },
      { command: "settings", description: "查看/调整本群设置", ephemeral: false },
      { command: "roll",     description: "掷骰子（用当前群规则系统）", ephemeral: false },
      { command: "nd",       description: "忍杀快捷直通（无视群设置）", ephemeral: false },
      { command: "system",   description: "切换规则系统（支持话题级）", ephemeral: false },
      { command: "secret",   description: "暗骰（仅自己可见）", ephemeral: true },
      { command: "bank",     description: "天狗银行：存取钱/道具", ephemeral: false },
      { command: "ct",       description: "自定义表：建/改/删/查", ephemeral: false },
      { command: "log",      description: "跑团 log 录制与导出", ephemeral: false }
    ].freeze
  end

  # --------------------------------------------------------------------------
  # RetryPolicy：瞬态故障退避重试策略（2026-10-12 双评审实证修复）
  #
  # 背景（生产崩溃链，容器 RestartCount=10 实证）：
  #   fetch_updates 撞 429 → gem 只 rescue Timeout/ConnectionFailed
  #   （gem client.rb:30-31）→ ResponseError 冒泡出 listen → main.rb 无兜底
  #   → 进程退出 → --restart unless-stopped 拉起 → 启动期 setMyCommands 又撞
  #   限流/Faraday 超时 → exit(1) → 重启循环。429 与网络抖动是同一条链的
  #   两个触发源，本模块统一收口。
  #
  # 策略：
  #   - 瞬态可重试：HTTP 429 / 500 / 502 / 503 / 504 + Faraday 网络错误族；
  #   - 致命不重试：401/404（token 无效/吊销——配置错误，重试无意义）、
  #     409（双轮询红线，见 docs/OPERATIONS.md §5 互斥操作法——静默重试会
  #     掩盖「真有第二个轮询者」）、400 及其它 4xx（请求本身有问题）；
  #   - 退避：429 优先按响应 parameters.retry_after；否则指数退避 2/4/8/16…
  #     封顶。所有 warn 只打 error_code / 异常类名，**不打 e.message**
  #     （响应体/URL 可能夹带 token——与 SendError 同一条纪律）。
  # --------------------------------------------------------------------------
  module RetryPolicy
    TRANSIENT_HTTP_CODES = [429, 500, 502, 503, 504].freeze

    # 启动期注册：有界重试（10 次重试 = 共 11 次调用；指数退避 2/4/8/16 后
    # 封顶 30s，合计约 3.5 分钟），耗尽仍失败则
    # 上抛 → main.rb 分码给文案后 exit(1)，交容器重启策略。有界而非无限：
    # 启动期的「真起不来」必须在 RestartCount 与日志里可见，静默空转更难排查。
    REGISTER_MAX_ATTEMPTS = 10
    REGISTER_BACKOFF_CAP = 30

    # 轮询期：无界重试（退避封顶 60s）——长循环的职责就是待在场上，瞬态风暴
    # （限流/网络抖动/Telegram 服务端故障）不该让进程退场。计数在成功吃到
    # 事件时清零，即统计口径是「连续失败次数」。
    POLL_BACKOFF_CAP = 60

    # 发送：429 重投一次。**只重投 429**——被限流的请求确定未被执行（无重复
    # 消息风险）；5xx 不重投（请求可能已落库，重投会重复发消息）。
    SEND_MAX_RETRIES = 1

    # retry_after 钳制上限：防异常/恶意响应把进程挂死在一次 sleep 里
    RETRY_AFTER_CAP = 300

    module_function

    # 瞬态 ResponseError？（429/5xx；401/404/409/400 等一律非瞬态）
    def transient_response_error?(error)
      error.is_a?(Telegram::Bot::Exceptions::ResponseError) &&
        TRANSIENT_HTTP_CODES.include?(error.error_code.to_i)
    end

    # 429 响应体 parameters.retry_after（秒）；取不到/异常值 → nil（回落退避）。
    # gem 的 data 对合法 JSON 响应体给字符串键，对解析失败的响应体给符号键
    # （exceptions/response_error.rb），两种形状都要吃。
    def retry_after_seconds(error)
      data = error.data
      params = data["parameters"] || data[:parameters]
      return nil unless params.is_a?(Hash)

      seconds = (params["retry_after"] || params[:retry_after]).to_i
      seconds.positive? ? [seconds, RETRY_AFTER_CAP].min : nil
    rescue StandardError
      nil # data 解析失败（非 JSON 响应体等）不挡重试主路
    end

    # 指数退避：2, 4, 8, 16, 32…封顶 cap（秒）
    def backoff(attempt, cap:)
      [2.0 * (2**(attempt - 1)), cap].min
    end

    # 日志标签：ResponseError 打 HTTP 码，其余打异常类名（绝不打 message）
    def label(error)
      if error.is_a?(Telegram::Bot::Exceptions::ResponseError)
        "HTTP #{error.error_code}"
      else
        error.class.to_s
      end
    end
  end

  # --------------------------------------------------------------------------
  # ClientPollingBackoff：gem 长轮询「无退避紧密重试」的补丁（2026-10-12 二审实证）
  #
  # gem client.rb:30-31 对 Faraday::TimeoutError/ConnectionFailed 的处理是
  # `retry if @running`——**原地立即重试、无 sleep、无日志**。网络中断/Telegram
  # 故障期这是一层沉默的高频重试（假 api 探针 0.5s 内 34 万次调用；真机受连接
  # 超时开销限制量级低得多，但同样无退避、无观测性），且 RetryPolicy 从外层
  # **插不进去**（异常根本没机会逃出 gem 的 rescue）。
  #
  # 本模块 prepend 进 Telegram::Bot::Client 重定义 fetch_updates（gem 2.8.1 源码
  # 仅 5 行，逐字对应 + 接管这两类异常）：
  #   - 连续失败按 RetryPolicy.backoff 退避（封顶 30s），每次 warn 一行（可观测）；
  #   - `@running` 语义原样保留（`stop` 后不再重试）；成功一轮后失败计数清零；
  #   - ResponseError（429/401/409…）**不在此接管**——原样上抛，归
  #     TelegramApi#start 的 RetryPolicy 兜底（职责分层不重叠）；
  #   - warn 只打异常类名——Faraday 的 message 可能夹带含 token 的 URL。
  #
  # ⚠️ gem 升级复核点（钉版 2.8.1，test/bot/test_polling_backoff_test.rb 有版本
  #   绊线测试）：本方法复制了 client.rb fetch_updates 的方法体，升级
  #   telegram-bot-ruby 时必须对照新版源码复核本 patch（docs/EXTENDING.md 轴①
  #   已登记）。
  # --------------------------------------------------------------------------
  module ClientPollingBackoff
    # 连续失败退避上限（秒）
    BACKOFF_CAP = 30

    # 可注入（测试传假身）：默认真 sleep + stderr warn
    @sleeper = ->(seconds) { sleep(seconds) }
    @warner = ->(message) { warn(message) }

    class << self
      attr_accessor :sleeper, :warner
    end

    def fetch_updates(&block)
      api.getUpdates(options).each do |update|
        yield handle_update(update)
      end
      @tengu_poll_failures = 0 # 成功一轮：连续失败计数清零
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      return unless @running # gem 原契约：stop 后不再重试

      @tengu_poll_failures = (@tengu_poll_failures || 0) + 1
      delay = RetryPolicy.backoff(@tengu_poll_failures, cap: BACKOFF_CAP)
      ClientPollingBackoff.warner.call(
        "[telegram_api] getUpdates 网络错误（#{e.class}），#{delay}s 后重试" \
        "（连续第 #{@tengu_poll_failures} 次；gem 原生为无退避紧密重试，本 patch 接管）"
      )
      ClientPollingBackoff.sleeper.call(delay)
      retry
    end
  end

  # prepend 即全局生效（本进程只有一个 Client；测试的假 client 不继承 gem
  # Client，不受影响）
  Telegram::Bot::Client.prepend(ClientPollingBackoff)

  # --------------------------------------------------------------------------
  # TelegramApi 主类
  # --------------------------------------------------------------------------
  class TelegramApi
    DEFAULT_PARSER_MODE = nil # §13 第 7 项：第一版纯文本（nil = 不带 parse_mode）
    MIN_INTERVAL_SECONDS = 1.0 # 计划 §0.2.4：每聊天 1 条/秒

    attr_reader :token, :api_client, :parse_mode, :rate_limiter

    # @param token [String] bot token（由 Config 解析，绝不打印）
    # @param api_client [Telegram::Bot::Client, nil] 注入用；nil 则按 token 自建
    # @param sleeper [#call] 可注入的休眠器（测试传假 sleeper，零真实等待）
    # @param clock [#call] 可注入的时钟（返回 Float 秒；测试传假时钟）
    # @param parse_mode [String, nil] 默认纯文本；可传 "Markdown"/"MarkdownV2"
    # @param http_executor [#call] raw_api_call 的 HTTP 执行器（测试注入假执行器）
    def initialize(token:,
                   api_client: nil,
                   sleeper: nil,
                   clock: nil,
                   parse_mode: DEFAULT_PARSER_MODE,
                   http_executor: nil,
                   base_url: nil)
      @token = token
      @api_client = api_client || Telegram::Bot::Client.new(token)
      @parse_mode = parse_mode
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @http_executor = http_executor || method(:default_http_executor)
      @base_url = base_url || Config::TELEGRAM_API_BASE_URL
      @rate_limiter = RateLimiter.new(interval: MIN_INTERVAL_SECONDS, sleeper: @sleeper, clock: @clock)
    end

    # ----------------------------------------------------------------------
    # 1. 发送封装
    # ----------------------------------------------------------------------

    # 发送长文本：自动 4096 切段，逐段发送。
    #
    # 空文本**短路**：发空消息会被 Telegram 以 400 拒（"text must be non-empty"），
    # 且一旦发出就是一条脏消息。这里在发送层拦住（不改动 Chunker.split 的语义——
    # split("") == [""] 是被单测钉住的行为）。
    #
    # @param chat_id [Integer, String] 64 位 chat_id 必须整型存（§0.2.4）
    # @param text [String]
    # @param thread_id [Integer, nil] forum 话题 id（message_thread_id 透传，§3 决6）
    # @return [Array<Telegram::Bot::Types::Message, nil>] 每段的返回值
    def send_text(chat_id, text, thread_id: nil, **extra)
      return [] if text.to_s.empty?

      segments = Chunker.split(text)
      sent = []
      segments.map do |segment|
        result = send_one(chat_id, segment, thread_id: thread_id, **extra)
        sent << result
        result
      rescue SendError => e
        # 多段发送中途失败：把「已发出段数」挂在异常上再抛——调用方（router）
        # 的 warn 得以区分「全没发」与「发了一半」（2026-10-12 三审）
        e.segments_sent = sent.size
        raise
      end
    end

    # 发送单段（不切段）。thread_id 非 nil 时**每次都透传**——
    # forum 群漏传会把消息发到 General 话题（§3 决6）。
    def send_one(chat_id, text, thread_id: nil, **extra)
      # 每聊天配速：确保距该聊天上次发送 ≥1 秒（key 只用 chat_id，见 RateLimiter）
      @rate_limiter.wait(chat_id)

      params = { chat_id: chat_id, text: text }.merge(extra)
      params[:parse_mode] = @parse_mode if @parse_mode
      params[:message_thread_id] = thread_id if thread_id

      retries = 0
      begin
        @api_client.api.send_message(**params)
      rescue NoMethodError => e
        # gem 白名单缺该端点 → 降级走 raw 通道（§12 R2 保底）。
        # 但**只认** receiver 为 api 本体的那个（method_missing → super 抛出）；
        # 其它 NoMethodError 是我们自己的代码 bug，必须原样抛出，否则
        # gem 已在 POST 之后才做响应类型映射（api.rb:28-32），重发会造成重复消息。
        raise unless gem_endpoint_missing?(e)

        # 统一「发送入口只抛 SendError」契约（2026-10-13 审核：raw 失败此前
        # 裸抛 RawApiError，破坏本文件 send_document 段的契约声明；与
        # send_document 的降级实现对齐）。生产不可达（gem 白名单含
        # sendMessage），属沉睡路径的契约一致性修复；消息只带类名。
        begin
          raw_api_call("sendMessage", params)
        rescue RawApiError => raw_err
          raise SendError, "sendMessage 降级失败（#{raw_err.class}）"
        end
      rescue Telegram::Bot::Exceptions::ResponseError => e
        # 429 重投一次（2026-10-12 评审实证：发送失败此前只在 router 层 warn
        # 一行、返回 []，用户看到「bot 掷了骰却没回」）。**只重投 429**：被限流
        # 的请求确定未被执行，重投不会重复发消息；5xx 不重投（请求可能已落库，
        # 重投会重复发消息）。retry_after ≥ RateLimiter 的 1s 间隔，故重投前
        # 不再过配速器。重投仍败 → 抛 SendError（router 记 warn，不杀轮询）。
        if e.error_code.to_i == 429 && retries < RetryPolicy::SEND_MAX_RETRIES
          retries += 1
          delay = RetryPolicy.retry_after_seconds(e) || 2
          warn("[telegram_api] 发送遇 429 限流（chat_id=#{chat_id}），#{delay}s 后重投一次")
          @sleeper.call(delay)
          retry
        end
        raise SendError, format_send_error(e, params)
      end
    end

    # 发送到话题内的指定用户（暗骰用）。ephemeral 特性（Bot API 官方
    # 「Reply Targets and Conditions」2026-10-12 三审核对原文）：
    #   - bot 为群管理员时随时可发（只需 receiver_user_id）；
    #   - 非管理员须在触发动作后 15 秒内，且**必须**带 callback_query_id 或
    #     reply_parameters.ephemeral_message_id——故本方法支持
    #     reply_to_ephemeral_id 透传（handler 从入站命令消息取
    #     ephemeral_message_id；管理员场景不带也成立）；
    #   - 用户离线不保证送达（§12 R6）→ 由 T3.1 的 secrets 持久化兜底
    #
    # **extra 透传**（T3.1）：暗骰要挂内联「公开」按钮，故 `reply_markup`
    # 等标准 sendMessage 参数必须能原样透传。gem 白名单只拦方法名不校验参数
    # （见文件头），reply_markup 会经 jsonify_value → to_json 变成 Bot API
    # 要的 inline_keyboard 形状。
    def send_ephemeral(chat_id, text, user_id:, thread_id: nil, reply_to_ephemeral_id: nil, **extra)
      params = { ephemeral_message_parameters: { receiver_user_id: user_id } }
      # 非管理员 bot 的 ephemeral 依赖「触发后 15 秒窗口 + 回指触发消息」
      # （Bot API 官方：Reply Targets and Conditions）——入站命令消息的
      # ephemeral_message_id 由 handler 从 context[:message] 取来透传。
      # 管理员 bot 不需要它（随时可发）；带上无害。
      if reply_to_ephemeral_id
        params[:reply_parameters] = { ephemeral_message_id: reply_to_ephemeral_id }
      end
      send_one(chat_id,
               text,
               thread_id: thread_id,
               **params,
               **extra)
    end

    # ----------------------------------------------------------------------
    # 1b. 按钮回调应答（T3.1：answerCallbackQuery）
    # ----------------------------------------------------------------------

    # 应答一次按钮回调。
    #
    # **不答则用户客户端一直转圈**（计划 §8 T3.1 前置注记），故 bot 的任何
    # 按钮路径都必须走到这里——包括「不认识的 data」与「handler 抛异常」
    # 两种兜底（那两种只需要一个空的应答即可让客户端收手）。
    #
    # 三条实现决定：
    #   1. **不过配速**：answerCallbackQuery 不计入群消息速率，按消息计的
    #      RateLimiter 对它是纯开销（且它通常要抢在用户等待之前发出）。
    #   2. **不过切段**：toast 文本上限远小于 4096，text 过长会被服务端截断，
    #      本层不代为裁剪（handler 侧的文案是写死的短句）。
    #   3. **降级同 send_one**：仅当 gem 白名单缺该端点（receiver == api 本体）
    #      才走 raw_api_call，其余异常原样抛出。
    #
    # @param callback_query_id [String] 被按下的那个 query 的 id（必填）
    # @param text [String, nil] 客户端 toast 文本；nil = 空应答（只是收手）
    # @param alert [Boolean] true = 弹窗式提示（用于「无权限」这类需要看见的拒绝）
    # @return [Object] gem 的响应（Bool）
    def answer_callback_query(callback_query_id:, text: nil, alert: false)
      id = callback_query_id.to_s
      raise ArgumentError, "callback_query_id 不能为空" if id.empty?

      params = { callback_query_id: id }
      params[:text] = text if text && !text.to_s.empty?
      params[:show_alert] = true if alert

      begin
        @api_client.api.answer_callback_query(**params)
      rescue NoMethodError => e
        raise unless gem_endpoint_missing?(e)

        # 同 send_one 的降级契约（2026-10-13 审核）：raw 失败转 SendError
        begin
          raw_api_call("answerCallbackQuery", params)
        rescue RawApiError => raw_err
          raise SendError, "answerCallbackQuery 降级失败（#{raw_err.class}）"
        end
      rescue Telegram::Bot::Exceptions::ResponseError => e
        raise SendError, format_send_error(e, params)
      end
    end

    # 发送文档（跑团 log 导出，T3.5 用）
    #
    # file 三形态的处理（**只认 String 才自己开文件**）：
    #   - String（路径）→ File.open(file, "rb")，由本方法负责 close；
    #   - IO / Tempfile  → **原样**包进 FilePart（不从路径重开，保住 fd 语义——
    #     已关闭/已 rewind 到别处的 fd 会被重开静默重读错内容，T2.1 F2 纪律）。
    #   - 其他对象 → 交给 gem（它只 jsonify Hash/Array，其余原样传）。
    #
    # multipart 的硬事实（kimi T3.5 评审必修 #1）：faraday-multipart 只把
    # **respond_to?(:content_type) 的值**当文件部件（middleware.rb 的
    # has_multipart?）。裸 File/IO 不满足 → 整个请求落 urlencoded、
    # document 变 inspect 字符串 → Telegram 400。所以这里必须包
    # Faraday::Multipart::FilePart（= Multipart::Post::UploadIO）。
    #
    # 文件名（kimi T3.5 评审提案 #2）：Bot API 的 sendDocument **没有**
    # filename 表单字段——往 params 塞它是被服务端忽略的额外表单项。
    # 用户可见文件名的唯一真相 = FilePart 第三参（Content-Disposition 的
    # filename）。不给 filename 时取文件路径 basename，无名 IO 兜底 "document"。
    def send_document(chat_id, file, thread_id: nil, caption: nil, filename: nil)
      @rate_limiter.wait(chat_id)

      opened = nil
      begin
        # 文件打开也进 begin：缺文件/权限错误的 Errno 族必须统一转 SendError
        # （「发送入口只抛 SendError」契约，2026-10-12 三审实证此前裸抛 ENOENT）
        opened = file.is_a?(String) ? File.open(file, "rb") : nil
        io = opened || file
        base = filename
        base ||= File.basename(io.path) if io.respond_to?(:path) && io.path
        base ||= "document"
        document = Faraday::Multipart::FilePart.new(io, document_content_type(base), base)
        params = { chat_id: chat_id, document: document }
        params[:caption] = caption if caption
        params[:message_thread_id] = thread_id if thread_id
        params[:parse_mode] = @parse_mode if @parse_mode
      rescue SystemCallError => e
        raise SendError, "sendDocument 文件不可读（#{e.class}）"
      end

      retries = 0
      begin
        @api_client.api.send_document(**params)
      rescue NoMethodError => e
        raise unless gem_endpoint_missing?(e)

        # raw 通道走的是 JSON body，**无法上传文件**（FilePart 塞进去只会得到
        # 一个坏请求）。与其静默发出必然失败的请求，不如明确报错。
        raise SendError,
              "sendDocument 降级失败：raw 通道不支持文件上传" \
              "（JSON body 无法承载文件）。gem 报端点缺失：#{e.name.inspect}"
      rescue Telegram::Bot::Exceptions::ResponseError => e
        # 与 send_one 同一契约（2026-10-12 二审对齐——此前裸抛 gem 异常，
        # 破坏「发送入口只抛 SendError」的统一契约）：429 按 retry_after 重投
        # 一次（被限流的请求确定未执行，无重复风险；5xx 不重投防重复）；
        # 重投前回卷 IO——首次尝试可能已读走半段流（FilePart 内包 UploadIO）。
        # retry 不触发 ensure（ensure 只在最终退出时跑），IO 不会在重投前被关。
        if e.error_code.to_i == 429 && retries < RetryPolicy::SEND_MAX_RETRIES
          # 重投前**必须**回卷 IO（见 rewind_for_retry）。回卷不了就不重投——
          # 重投只会从已读到的位置继续读，发出残缺文件（2026-10-12 验收轮
          # 修复 [9]：旧实现让不可 seek IO 的 Errno::ESPIPE 裸抛出本方法，
          # 逃出「发送入口只抛 SendError」的契约）。
          if rewind_for_retry(io)
            retries += 1
            delay = RetryPolicy.retry_after_seconds(e) || 2
            warn("[telegram_api] 文档发送遇 429 限流（chat_id=#{chat_id}），#{delay}s 后重投一次")
            @sleeper.call(delay)
            retry
          else
            warn("[telegram_api] 文档发送遇 429 但 IO 不可回卷（#{io.class}），放弃重投")
          end
        end
        raise SendError, format_send_error(e, params)
      ensure
        # 只 close 本方法自己打开的 IO —— 调用方传进来的 IO 生命周期归调用方
        opened&.close
      end
    end

    # ----------------------------------------------------------------------
    # 2. 长轮询循环
    # ----------------------------------------------------------------------

    # 启动长轮询。
    #
    # @param dispatch [#call] 收到 update 时的回调（T2.3 接路由；本任务为占位）
    # @yieldparam update [Telegram::Bot::Types::Update]
    #
    # 错误兜底契约：**单条 update 的异常不得杀死循环**——记日志后继续下一条。
    # 这是硬要求（计划 §2 "错误兜底"）：一条脏消息不该让骰子 bot 下线。
    #
    # 2026-10-12 修复（双评审实证，RestartCount=10）：契约扩展到**轮询层**——
    # fetch_updates 抛出的瞬态故障（429/5xx/Faraday 族）同样不得杀死进程：
    # 退避后重进 listen。非瞬态（401 token 失效 / 409 双轮询红线 / 400 等）
    # 原样上抛，由 main.rb 兜底 exit(1)。全貌见 RetryPolicy 模块注释。
    #
    # 菜单注册**不在此方法内**（2026-10-12 二审修复 T2.1 遗留的双注册：
    # main.rb 显式调一次 + 这里又调一次，限流风暴期白撞一倍请求量）——
    # 由 main.rb 启动期显式调 `register_main_commands` 一次（带分码文案兜底）。
    def start(dispatch: nil, &block)
      dispatch ||= block || ->(_update) {}

      client = @api_client
      poll_retries = 0 # 连续失败计数：成功吃到任何事件即清零
      begin
        client.listen do |event|
          # ⚠️ gem 接缝实测：listen yield 的是 handle_update 的返回值 =
          # update.current_message——**通常是 Message 而非 Update**
          # （gem client.rb:41-47）。Router#extract_message 两种形态都收。
          # current_message 的准确语义 = 「第一个非 nil 属性」（update.rb），故：
          #   - 无负载 update（如纯 my_chat_member 以外的空壳）会 yield nil
          #     → Router 对 nil 安全（extract_message 直接返回 nil）；
          #   - callback_query update 会 yield **CallbackQuery 本体**（不是 nil），
          #     edited_message update 会 yield **编辑后的 Message**（edit_date 非 nil）
          #     → 两者由 Router#extract_message 显式守卫跳过（2026-10-12 验收期
          #     实证更正：本注释早先版本「callback_query 会被 yield nil」是错的）。
          begin
            dispatch.call(event)
          rescue StandardError => e
            # 兜底：记录后继续，绝不把异常抛出循环
            warn("[telegram_api] dispatch 处理失败（已忽略该条）: #{e.class}")
          end
          poll_retries = 0 # 能吃到事件 = 链路健康，连续失败计数清零
        end
      rescue Telegram::Bot::Exceptions::ResponseError => e
        raise unless RetryPolicy.transient_response_error?(e)

        poll_retries += 1
        delay = RetryPolicy.retry_after_seconds(e) ||
                RetryPolicy.backoff(poll_retries, cap: RetryPolicy::POLL_BACKOFF_CAP)
        warn("[telegram_api] 长轮询遇瞬态故障（#{RetryPolicy.label(e)}），" \
             "#{delay}s 后重新拉取（连续第 #{poll_retries} 次，进程保持）")
        @sleeper.call(delay)
        retry # 重进 listen；gem 的 offset 在 client options 里续传，不丢更新
      rescue Faraday::Error => e
        # gem 原生对 Timeout/ConnectionFailed 的无退避 retry 已由
        # ClientPollingBackoff patch 接管（有退避、有日志）；能走到这里的只剩
        # 两边都没兜住的 Faraday 族（SSLError 等）——退避后重进，同一条
        # 「不杀进程」契约。
        poll_retries += 1
        delay = RetryPolicy.backoff(poll_retries, cap: RetryPolicy::POLL_BACKOFF_CAP)
        warn("[telegram_api] 长轮询遇网络错误（#{RetryPolicy.label(e)}），" \
             "#{delay}s 后重新拉取（连续第 #{poll_retries} 次，进程保持）")
        @sleeper.call(delay)
        retry
      end
    end

    # 逐条处理 update 流的通用封装（供测试直接喂假流，不起真实轮询）。
    # start 复用同一份兜底逻辑，保证两者行为一致。
    def process_updates(updates, dispatch:)
      updates.each do |update|
        begin
          dispatch.call(update)
        rescue StandardError => e
          warn("[telegram_api] dispatch 处理失败（已忽略该条）: #{e.class}")
        end
      end
    end

    # ----------------------------------------------------------------------
    # 3. 启动时注册主轨菜单（计划 §6）
    # ----------------------------------------------------------------------

    # setMyCommands 注册主菜单。/secret 带 is_ephemeral=true。
    #
    # **全进程只由 main.rb 启动期调一次**（2026-10-12 二审消除 T2.1 遗留的
    # 双注册：start 内部曾再调一次，幂等无害但限流风暴期白撞一倍请求量）。
    #
    # gem 侧走 `set_my_commands`（Api::ENDPOINTS 白名单含 'setMyCommands'，
    # 见 endpoints.rb:96）。BotCommand 支持 is_ephemeral
    # （types/bot_command.rb:9），且 gem 不校验参数 → 直传即可（已离线实证）。
    # 仅当 gem 因**白名单缺失**（receiver == api 本体）才降级走 raw_api_call；
    # 其它 NoMethodError 一律原样抛出（见 gem_endpoint_missing? 的两条理由）。
    #
    # 瞬态故障（429/5xx/Faraday 族）有界退避重试（2026-10-12 生产实证：
    # 启动期撞限流此前被 main.rb 当配置错误 exit(1)，叠加容器重启策略形成
    # 重启循环）。重试耗尽或非瞬态（401/404/409…）原样抛出，由 main.rb
    # 按 error_code 分文案兜底。raw 降级通道（RawApiError）不参与重试——
    # 走到那里说明 gem 白名单缺端点，属部署事故而非瞬态。
    def register_main_commands
      commands = MainMenu::ENTRIES.map do |e|
        attrs = { command: e[:command], description: e[:description] }
        attrs[:is_ephemeral] = true if e[:ephemeral]
        Telegram::Bot::Types::BotCommand.new(**attrs)
      end

      attempts = 0
      begin
        @api_client.api.set_my_commands(commands: commands)
      rescue NoMethodError => e
        raise unless gem_endpoint_missing?(e)

        raw_api_call("setMyCommands", { commands: commands_payload })
      rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
        raise unless e.is_a?(Faraday::Error) || RetryPolicy.transient_response_error?(e)

        attempts += 1
        raise if attempts > RetryPolicy::REGISTER_MAX_ATTEMPTS

        delay = RetryPolicy.retry_after_seconds(e) ||
                RetryPolicy.backoff(attempts, cap: RetryPolicy::REGISTER_BACKOFF_CAP)
        warn("[telegram_api] 注册主轨菜单遇瞬态故障（#{RetryPolicy.label(e)}），" \
             "#{delay}s 后重试（#{attempts}/#{RetryPolicy::REGISTER_MAX_ATTEMPTS}）")
        @sleeper.call(delay)
        retry
      end
    end

    # 纯 Hash 形态的命令载荷（raw 通道用；也是测试断言的权威形状）
    def self.commands_payload
      MainMenu::ENTRIES.map do |e|
        payload = { "command" => e[:command], "description" => e[:description] }
        payload["is_ephemeral"] = true if e[:ephemeral]
        payload
      end
    end

    def commands_payload
      self.class.commands_payload
    end

    # ----------------------------------------------------------------------
    # 4. raw_api_call：gem 白名单之外的保底通道（计划 §12 R2）
    # ----------------------------------------------------------------------

    # 直接打 Bot API HTTP。gem 未收录的方法名会 NoMethodError（ENDPOINTS 白名单
    # 只管方法名），未收录的参数其实能透传，但**不依赖**该结论——统一通道更稳。
    #
    # @param method [String] Bot API 方法名，如 "ephemeral_message_parameters" 相关端点
    # @param params [Hash] 参数。本通道 wire 形态是 **application/json body**
    #   （default_http_executor），故 Hash/Array/gem 类型递归 unwrap 成**原生
    #   JSON 类型**（unwrap_for_json）——「数组编成 JSON 字符串」是
    #   form-urlencoded 通道的约定，JSON body 里 Telegram 期望真数组/真对象
    #   （2026-10-12 二审实证旧实现的 JSON-in-JSON 二次编码：沉睡 bug，
    #   白名单全覆盖时不可达，一旦降级兜底就是坏的）。
    # @return [Hash] 解析后的完整响应（{"ok"=>true,"result"=>...}）
    # @raise [RawApiError] HTTP 层失败或 ok=false
    def raw_api_call(method, params = {})
      url = "#{@base_url}/bot#{@token}/#{method}"
      body = params.transform_values { |v| unwrap_for_json(v) }

      response = @http_executor.call(url, body)
      # 2026-10-12 验收轮修复 [1]：生产执行器返回 **HTTParty::Response**，它的
      # `#[]` 是 parsed_response 语义（Telegram 响应里没有 "status"/"body" 键
      # → 恒 nil），状态码与原始 body 只在 `.code`/`.body` 上。旧实现按 Hash
      # 取值 → HTTP 200 也会抛 `RawApiError: "... HTTP :"`（沉睡 bug：gem 白名单
      # 全覆盖时不可达，一旦降级兜底就是坏的）。取形状的统一收口见
      # http_status_and_body（纯 Hash 响应保持兼容）。
      status, raw = http_status_and_body(response)

      unless status.to_i == 200
        raise RawApiError, "#{method} HTTP #{status}: #{truncate_for_log(raw)}"
      end

      # 网关/代理返回非 JSON（HTML 错误页等）时不能让 JSON::ParserError 裸奔出去——
      # 调用方只应看到 RawApiError，错误处理链路才统一。
      parsed =
        begin
          raw.is_a?(String) ? JSON.parse(raw) : raw
        rescue JSON::ParserError => e
          raise RawApiError, "#{method} 返回非 JSON 响应（HTTP #{status}）：" \
                             "#{truncate_for_log(raw.to_s)}（#{e.class}）"
        end

      unless parsed.is_a?(Hash) && parsed["ok"]
        raise RawApiError, "#{method} 返回 ok=false: #{truncate_for_log(parsed.inspect)}"
      end

      parsed
    end

    private

    # 按扩展名给个像样 content_type（Telegram 预览用）；未知归 octet-stream
    def document_content_type(name)
      case File.extname(name.to_s).downcase
      when ".txt" then "text/plain"
      when ".json" then "application/json"
      else "application/octet-stream"
      end
    end

    # 429 重投前的 IO 回卷（2026-10-12 验收轮修复 [9]）。
    #
    # IO#rewind 在**不可 seek** 的 IO（管道/套接字等）上抛 Errno::ESPIPE，而这类
    # 对象同样 `respond_to?(:rewind)`——旧实现的 `io.rewind if io.respond_to?(:rewind)`
    # 拦不住它，异常会裸抛出 send_document（调用方只应看到 SendError）。
    #
    # @return [Boolean] true = 已回到流首（可安全重投）；false = 回卷不了（不重投）
    def rewind_for_retry(io)
      return false unless io.respond_to?(:rewind)

      io.rewind
      true
    rescue StandardError
      false
    end

    # 这个 NoMethodError 是不是"gem 白名单没收录该端点"的信号？
    #
    # 判别依据是 **receiver**：`Telegram::Bot::Api#method_missing` 在
    # `return super unless ENDPOINTS.key?(endpoint)`（api.rb:27）处抛出，
    # 只有这一条路径 Ruby 才会把 receiver 填成 api 本体。其余任何
    # NoMethodError（我们自己的代码 bug、gem 响应类型映射阶段炸的）receiver
    # 都不是 api 本体或压根没有 → 一律**不降级**，原样向上抛。
    #
    # 为什么必须这么严（两个真实故障）：
    #   1. gem 2.8.1 白名单已含 sendMessage/sendDocument/setMyCommands
    #      （endpoints.rb:14/22/96）→ 生产里这条 rescue 捕获到的大概率是 bug，
    #      吞掉它只会把故障变成"消息莫名重发"；
    #   2. gem 的调用顺序是「先 POST，再 ENDPOINTS[endpoint].call(result) 做响应
    #      类型映射」（api.rb:28-32）→ 若在映射阶段炸了却降级重发，
    #      **消息已经发出去了**，用户会收到两条。
    def gem_endpoint_missing?(err)
      receiver = err.receiver
      !receiver.nil? && receiver.equal?(@api_client.api)
    rescue ArgumentError
      # `NoMethodError.new("msg")` 这类手工构造的异常没有 receiver，
      # 调 #receiver 会抛 ArgumentError —— 视为「不是白名单缺失」。
      false
    end

    def default_http_executor(url, body)
      HTTParty.post(url,
                    body: body.to_json,
                    headers: { "Content-Type" => "application/json" })
    end

    # 从执行器返回值里取「状态码 / 原始 body」（2026-10-12 验收轮修复 [1]）。
    #
    # 两种形状都要收：
    #   - 生产：default_http_executor 返回 HTTParty::Response → `.code`/`.body`
    #     （实测该对象的 `#[]` 取 "status"/"body" 恒 nil，见 raw_api_call 注释）；
    #   - 测试：FakeHttpExecutor 返回纯 Hash（Symbol 或 String 键）→ 原样兼容。
    # body 为 nil（如 204 之类无体响应）时按空串处理，交由「非 JSON」分支报错。
    #
    # @return [Array(Object, String)] [状态码, 原始 body]
    def http_status_and_body(response)
      if response.respond_to?(:code) && response.respond_to?(:body)
        [response.code, response.body.to_s]
      else
        [response[:status] || response["status"], response[:body] || response["body"] || ""]
      end
    end

    # 递归 unwrap 成原生 JSON 可序列化形态：gem 类型（to_compact_hash）→ 纯
    # Hash；Array/Hash 逐层展开；标量原样。**不再** to_json 成字符串——那是
    # form-urlencoded 通道的约定，本通道（application/json body）发字符串化的
    # 数组会让 Telegram 收到 {"commands":"[…]"} 这种 JSON-in-JSON 坏载荷。
    def unwrap_for_json(value)
      if value.respond_to?(:to_compact_hash)
        unwrap_for_json(value.to_compact_hash)
      elsif value.is_a?(Array)
        value.map { |v| unwrap_for_json(v) }
      elsif value.is_a?(Hash)
        value.to_h { |k, v| [k, unwrap_for_json(v)] }
      else
        value
      end
    end

    def format_send_error(err, params)
      body = err.respond_to?(:response) ? err.response&.body : nil
      "#{err.class}: #{body || err.message} (chat_id=#{params[:chat_id]} " \
        "thread_id=#{params[:message_thread_id]})"
    end

    # 只截断长度，不打印 token：Bot API 报错体不含 token，但 URL 会——一律不记录 URL
    def truncate_for_log(text, limit = 300)
      s = text.to_s
      s.length > limit ? "#{s[0, limit]}…" : s
    end
  end

  # --------------------------------------------------------------------------
  # 每聊天配速器（Telegram 限流：每聊天 1 条/秒，§0.2.4）
  #
  # key **只按 chat_id**，绝不掺 thread_id：Telegram 的限流口径是「每聊天」，
  # 话题（forum topic）不是独立的限流桶。早期把 key 拼成 "chat_id/thread_id"
  # 会让同一群的多个话题各自独立计数，forum 多话题并发时同聊天超速 → 429。
  #
  # ⚠️ **尚未实现的限额**：Telegram 对每个 bot 另有「每群 20 条/分钟」的独立
  # 限额（另见全局 30 msg/s、每分钟 1 万条总量）。本类**只覆盖 1 条/秒的
  # 最小间隔**，20 条/分钟的滑动窗口**未实现**——连续发送 25 条（每秒 1 条）
  # 仍会触发 429。该缺口后置到 T2.3 / T3.x 补滑动窗口计数，不要误读为已覆盖。
  # --------------------------------------------------------------------------
  class RateLimiter
    attr_reader :interval

    def initialize(interval: TelegramApi::MIN_INTERVAL_SECONDS, sleeper: nil, clock: nil)
      @interval = interval
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @last_sent = {}
    end

    # 等待到距该 key 上次发送 ≥ interval 才返回。
    # 首次调用不等待。每条消息的等待都通过注入的 sleeper 走 → 测试零真实睡眠。
    def wait(key)
      now = @clock.call
      last = @last_sent[key]

      if last
        elapsed = now - last
        remaining = @interval - elapsed
        if remaining.positive?
          @sleeper.call(remaining)
          now += remaining # 假时钟下把时间推进（真实时钟下也正确）
        end
      end

      @last_sent[key] = now
      now
    end

    # 测试辅助：某 key 上次发送时刻
    def last_sent_at(key)
      @last_sent[key]
    end
  end

  # --------------------------------------------------------------------------
  # 异常
  # --------------------------------------------------------------------------
  class SendError < StandardError
    # 多段发送（send_text 切段）中途失败时，已发出的段数（nil/0 = 一段没发出去）。
    # 由 send_text 在重抛前挂上，供 router 的 warn 与后续录制判定用
    # （2026-10-12 三审：「发了一半、log 一条不记」的可观测性缺口）。
    attr_accessor :segments_sent
  end
  # message 含截断 300 字的 API 响应体（truncate_for_log）——**任何日志只准打
  # e.class，不准打 e.message**（kimi T2.4 评审：安全靠调用点自觉维持，故在此立约）。
  class RawApiError < StandardError; end
end