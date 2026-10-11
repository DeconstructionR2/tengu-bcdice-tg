# frozen_string_literal: true

# ============================================================================
# bot/telegram_api.rb — Telegram API 封装层（T2.1）
#
# 职责（计划 §2 / §6 / §8 T2.1）：
#   1. 发送封装：4096 字符切段（按字符不按字节）、message_thread_id 透传、
#      **每聊天** ≥1 秒配速（key 只含 chat_id，话题不是独立限流桶）、
#      parse_mode 可配置（默认纯文本，§13 第 7 项拍板）；
#   2. 长轮询循环封装（包 telegram-bot-ruby 的 Client#listen），
#      **逐消息错误兜底**——单条消息异常不得杀死循环；
#   3. 启动时 setMyCommands 注册主轨菜单（§6），/secret 带 is_ephemeral=true；
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
require_relative "config"

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
      segments.map do |segment|
        send_one(chat_id, segment, thread_id: thread_id, **extra)
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

      begin
        @api_client.api.send_message(**params)
      rescue NoMethodError => e
        # gem 白名单缺该端点 → 降级走 raw 通道（§12 R2 保底）。
        # 但**只认** receiver 为 api 本体的那个（method_missing → super 抛出）；
        # 其它 NoMethodError 是我们自己的代码 bug，必须原样抛出，否则
        # gem 已在 POST 之后才做响应类型映射（api.rb:28-32），重发会造成重复消息。
        raise unless gem_endpoint_missing?(e)

        raw_api_call("sendMessage", params)
      rescue Telegram::Bot::Exceptions::ResponseError => e
        raise SendError, format_send_error(e, params)
      end
    end

    # 发送到话题内的指定用户（暗骰用）。ephemeral 特性：
    #   - bot 为管理员时随时可发；非管理员须在触发后 15 秒内（§0.2.4）
    #   - 用户离线不保证送达（§12 R6）→ 由 T3.1 的 secrets 持久化兜底
    #
    # **extra 透传**（T3.1）：暗骰要挂内联「公开」按钮，故 `reply_markup`
    # 等标准 sendMessage 参数必须能原样透传。gem 白名单只拦方法名不校验参数
    # （见文件头），reply_markup 会经 jsonify_value → to_json 变成 Bot API
    # 要的 inline_keyboard 形状。
    def send_ephemeral(chat_id, text, user_id:, thread_id: nil, **extra)
      send_one(chat_id,
               text,
               thread_id: thread_id,
               ephemeral_message_parameters: { receiver_user_id: user_id },
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

        raw_api_call("answerCallbackQuery", params)
      rescue Telegram::Bot::Exceptions::ResponseError => e
        raise SendError, format_send_error(e, params)
      end
    end

    # 发送文档（跑团 log 导出，T3.5 用）
    #
    # file 三形态的处理（**只认 String 才自己开文件**）：
    #   - String（路径）→ File.open(file, "rb")，由本方法负责 close；
    #   - IO / Tempfile  → **原样透传**给 gem/faraday（multipart 直接读 fd）。
    #     早期实现把 IO 也塞进 File.open：无 to_path 的 IO（IO.pipe 等）会
    #     TypeError，而 File/Tempfile 被按路径重开，丢掉了 fd 语义
    #     （已关闭/已 rewind 到别处的 fd 会被静默重读错内容）。
    #   - 其他对象 → 交给 gem（它只 jsonify Hash/Array，其余原样传）。
    #
    # filename 透传（T3.5 修复）：形参此前存在但从未进 params——Telegram 在
    # 未给 filename 时按上传文件名的 basename 取名，于是「临时路径的随机名」
    # 会原样出现在用户看到的文件上。T3.5 的 log 导出显式传 filename 保住
    # `tengu-log-<id>.txt/json`；此处把这层透传补齐（发送侧文件名的唯一真相）。
    def send_document(chat_id, file, thread_id: nil, caption: nil, filename: nil)
      @rate_limiter.wait(chat_id)

      opened = file.is_a?(String) ? File.open(file, "rb") : nil
      document = opened || file
      params = { chat_id: chat_id, document: document }
      params[:caption] = caption if caption
      params[:message_thread_id] = thread_id if thread_id
      params[:filename] = filename if filename
      params[:parse_mode] = @parse_mode if @parse_mode

      begin
        @api_client.api.send_document(**params)
      rescue NoMethodError => e
        raise unless gem_endpoint_missing?(e)

        # raw 通道走的是 JSON body，**无法上传文件**（File/IO 塞进去只会得到
        # 一个坏请求）。与其静默发出必然失败的请求，不如明确报错。
        raise SendError,
              "sendDocument 降级失败：raw 通道暂不支持文件上传" \
              "（multipart 待 T3.5 实现）。gem 报端点缺失：#{e.name.inspect}"
      ensure
        # 只 close 本方法自己打开的 IO —— 调用方传进来的 IO 生命周期归调用方
        opened&.close
      end
    end

    # ----------------------------------------------------------------------
    # 2. 长轮询循环
    # ----------------------------------------------------------------------

    # 启动长轮询并注册主菜单。
    #
    # @param dispatch [#call] 收到 update 时的回调（T2.3 接路由；本任务为占位）
    # @yieldparam update [Telegram::Bot::Types::Update]
    #
    # 错误兜底契约：**单条 update 的异常不得杀死循环**——记日志后继续下一条。
    # 这是硬要求（计划 §2 "错误兜底"）：一条脏消息不该让骰子 bot 下线。
    def start(dispatch: nil, &block)
      register_main_commands
      dispatch ||= block || ->(_update) {}

      client = @api_client
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
    # gem 侧走 `set_my_commands`（Api::ENDPOINTS 白名单含 'setMyCommands'，
    # 见 endpoints.rb:96）。BotCommand 支持 is_ephemeral
    # （types/bot_command.rb:9），且 gem 不校验参数 → 直传即可（已离线实证）。
    # 仅当 gem 因**白名单缺失**（receiver == api 本体）才降级走 raw_api_call；
    # 其它 NoMethodError 一律原样抛出（见 gem_endpoint_missing? 的两条理由）。
    def register_main_commands
      commands = MainMenu::ENTRIES.map do |e|
        attrs = { command: e[:command], description: e[:description] }
        attrs[:is_ephemeral] = true if e[:ephemeral]
        Telegram::Bot::Types::BotCommand.new(**attrs)
      end

      begin
        @api_client.api.set_my_commands(commands: commands)
      rescue NoMethodError => e
        raise unless gem_endpoint_missing?(e)

        raw_api_call("setMyCommands", { commands: commands_payload })
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
    # @param params [Hash] 参数（Hash/Array 自动 JSON 化，与 gem 行为一致）
    # @return [Hash] 解析后的完整响应（{"ok"=>true,"result"=>...}）
    # @raise [RawApiError] HTTP 层失败或 ok=false
    def raw_api_call(method, params = {})
      url = "#{@base_url}/bot#{@token}/#{method}"
      body = params.transform_values { |v| jsonify(v) }

      response = @http_executor.call(url, body)
      status = response[:status] || response["status"]
      raw = response[:body] || response["body"] || ""

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

    def jsonify(value)
      (value.respond_to?(:to_compact_hash) || value.is_a?(Array) || value.is_a?(Hash)) ? value.to_json : value
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
  class SendError < StandardError; end
  # message 含截断 300 字的 API 响应体（truncate_for_log）——**任何日志只准打
  # e.class，不准打 e.message**（kimi T2.4 评审：安全靠调用点自觉维持，故在此立约）。
  class RawApiError < StandardError; end
end