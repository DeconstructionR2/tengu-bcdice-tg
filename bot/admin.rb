# frozen_string_literal: true

# ============================================================================
# bot/admin.rb — 管理员权限助手（T2.6，计划 §8 T2.6 / §0.2.4 getChatMember）
#
# 一句话：**「这个人是不是这个群的管理员」，且失败时一律说不是。**
#
# ── 为什么需要 ──────────────────────────────────────────────────────────────
#   T3.4 的自定义表改表权限要判「建表者或群管理员」（计划 §5），T2.6 的
#   `/settings aux` 要判「只有管理员能关辅助轨」——两处都要求同一个能力。
#   本类就是那个能力的**唯一**实现，别处不再各写一遍 getChatMember。
#
# ── 三个硬纪律 ──────────────────────────────────────────────────────────────
#
#   1. **fail-closed**：查询失败（网络异常、gem 端点缺失、响应体不对、
#      权限不足被拒……）一律返回 false。理由：误判成「是管理员」会让任何
#      群成员改掉别人的群设置 / 改别人的自定义表；误判成「不是」最坏只是
#      「管理员自己没改成功，再试一次」。**权限判定的错误方向必须选安全的
#      那一侧**——这与 router 辅助轨开关的 fail-closed 是同一条原则。
#
#   2. **私聊恒 true**：私聊（chat.type == "private"）里没有「群管理员」
#      这回事，且 getChatMember 对私聊也不该用来判权限。私聊是**用户自己**
#      的对话，改自己的设置不需要任何审核。故先判 chat_type 再决定要不要
#      打 API（私聊场景零网络）。
#
#   3. **64 位 chat_id**（§0.2.4）：chat_id 可超 32 位有效位，一律 to_i 后
#      传，**绝不**转字符串之外的处理。user_id 同理（user_id 本就是 32 位内，
#      但统一 to_i 可防入站给字符串时的类型分歧）。
#
# ── 匿名管理员（§0.2.4 实证）────────────────────────────────────────────────
#
#   Telegram 允许管理员**匿名**发言：这类消息的 `message.from` 是
#   `GroupAnonymousBot`（user id = 1087968824），**不是真人 id**。
#   后果（本类的关键设计）：
#     - 用 `message.from.id` 去查 getChatMember，查到的是「匿名 bot 是不是
#       管理员」，**永远返回 false** → 匿名管理员会被误拒。
#     - 但本类**不读 message**（只吃 chat_id + user_id，由 handler 从
#       update 里取），**职责分离**让这个坑在 handler 侧解决：handler 应把
#       `callback_query.from`（§0.2.4：按钮回调里仍是真人 id）或本人
#       `/settings` 时的 user_id 传进来。T3.1 的暗骰「公开」按钮走
#       callback_query.from，正是天然正确的来源。
#     - 本类保留 ANONYMOUS_ADMIN_USER_ID 常量与 is_anonymous_admin? 供
#       handler 在**已经拿到 user_id** 时做防御性判定：若入参就是匿名 bot
#       id，说明调用方取错了来源，**fail-closed 返回 false**（并 warn 一次），
#       而不是去查「匿名 bot 的权限」再拿一个必然为 false 的结果。
#     - 附注：匿名管理员**本人**执行 `/settings` 时，Telegram 会把
#       `message.from` 也置为 GroupAnonymousBot——这是平台限制，bot 侧
#       无从分辨，本类的契约是「不因此给出错误授权」，故 fail-closed。
#
# ── 匿名 bot 不可查的前提（§0.2.4）─────────────────────────────────────────
#
#   `getChatMember` 仅当 **bot 自己是管理员**时保证可用（计划 §3 决4：bot
#   进群即设管理员、零实权，已是既定部署口径）。bot 不是管理员时，Telegram
#   对该端点的行为随版本而变（有的返回 ok=false，有的能查到有限信息）。
#   本类**不因为「可能查不到」就退化成「都算管理员」**，而是让查询失败的
#   路径走 fail-closed false——这在 bot 未设管理员的群里表现为「管理员也
#   改不了 /settings」，是可诊断的症状（看日志），比静默放开权限安全得多。
#
# ── 缓存 ────────────────────────────────────────────────────────────────────
#
#   同一 (chat_id, user_id) 在 TTL 内不重复打 API。理由：Telegram 对
#   getChatMember **不计入消息发送配额**，但每次仍是一次 HTTPS 往返；
#   在「20 条/分/群」限额下（§0.2.4）每条消息多打一次 API 是白捡的
#   延迟与故障面（API 抖动时管理员连 /settings 都用不了）。
#   缓存**只缓存「已确认」的 true**——false 不缓存。理由：管理员身份是
#   **可变的**（被撤职/被提升），缓存一个 false 会让刚上任的管理员在 TTL
#   内用不了 /settings（用户看到的是「明明是管理员却被拒」），而缓存一个
#   true 最多让刚被撤职的人多改一次设置，TTL 到期即恢复——两者不对称的
#   代价决定了该只缓存哪一侧。
#
#   缓存 TTL 与时钟都可注入（测试传假时钟，零真实等待）。
#
# ── 依赖注入 ────────────────────────────────────────────────────────────────
#   api_client: 传 TelegramApi（真身或测试假身）。真身走
#   `@api.api_client.api.get_chat_member`（gem 白名单已收录 getChatMember，
#   endpoints.rb:71 → Types::ChatMember）；gem 缺失时经 raw_api_call 兜底
#   （计划 §12 R2 的保底通道，与 bot/telegram_api.rb 里其它端点同一纪律）。
#   两条通道的返回**都被归一成 String status**，故 gem 返回 dry-struct
#   ChatMember 对象与 raw 通道返回 Hash 都能吃。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require_relative "telegram_api"

module TelegramBot
  # ------------------------------------------------------------------
  # Admin
  # ------------------------------------------------------------------
  class Admin
    # 管理员/创建者的 status（Bot API ChatMember.status 枚举）
    #
    # 只认这两个：administrator 是被授予的管理员，creator 是群主。
    # member / restricted / left / banned 都不是管理员。
    ADMIN_STATUSES = %w[creator administrator].freeze

    # Telegram 匿名管理员（消息 sender 为 GroupAnonymousBot 时的 user id，
    # §0.2.4）。见文件头「匿名管理员」一节。
    ANONYMOUS_ADMIN_USER_ID = 1_087_968_824

    # 私聊 chat.type（§0.2.4 的 type 枚举）。private 恒 true（文件头纪律 2）。
    PRIVATE_CHAT_TYPE = "private"

    # 「确认是管理员」结果的缓存时长（秒）。
    #
    # 选 300s（5 分钟）而不是更长：撤职后最多 5 分钟生效，对一个每群
    # 20 条/分的低频 bot 完全够用；同时把「管理身份变更」的感知延迟
    # 压在人工可接受范围。不缓存 false 的理由见文件头。
    DEFAULT_TTL = 300.0

    # 构造一个 Admin（handler 与 main.rb 共享同一实例，才能共用缓存）
    #
    # @param api [TelegramBot::TelegramApi, nil] 发送通道（提供 gem api_client
    #   与 raw_api_call 两条 getChatMember 通道）。nil 时所有群内查询走
    #   fail-closed false（**不会**去打网络）——测试无 api 注入时用得上。
    # @param clock [#call] 返回 Float 秒（可注入假时钟，测试零真实等待）
    # @param ttl [Float] 缓存时长（秒）
    # @param logger [#warn] 日志器（只记结构性信息，绝不记用户正文）
    def initialize(api: nil, clock: nil, ttl: DEFAULT_TTL, logger: $stderr)
      @api = api
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @ttl = ttl
      @logger = logger
      @admin_cache = {}
    end

    # ------------------------------------------------------------------
    # 公开判定
    # ------------------------------------------------------------------

    # 判断某人在某聊天里是不是管理员
    #
    # @param chat_id [Integer] 64 位（§0.2.4）
    # @param user_id [Integer, nil] nil/0 = 未知发起人 → **false**
    #   （fail-closed：不知道是谁就没有任何理由放行）
    # @param chat_type [String, nil] "private"/"group"/"supergroup"/"channel"；
    #   nil = **按群处理**（打 API 查询），只有显式 "private" 才走豁免。
    #   这与 router 的处理一致（router 不因 type 缺省而放开任何东西）。
    # @return [Boolean]
    def admin?(chat_id, user_id, chat_type: nil)
      return false if chat_id.nil? || chat_id.to_i.zero?

      # 私聊豁免（文件头纪律 2）：私聊是用户自己的对话，没有「群管理员」
      # 这回事，改自己的设置不需要审核。先判这一条 → 私聊场景零网络。
      return true if private_chat?(chat_type)

      uid = normalize_user_id(user_id)
      return false if uid.nil?

      cached = cached_admin?(chat_id.to_i, uid)
      return true if cached

      status = fetch_status(chat_id.to_i, uid)
      return false if status.nil? # fail-closed（网络/gem/响应异常）

      unless ADMIN_STATUSES.include?(status)
        # 不缓存 false：管理身份可升可降，缓存 false 会让刚上任的管理员被拒。
        return false
      end

      remember_admin(chat_id.to_i, uid)
      true
    end

    # 是不是匿名 bot 发来的（调用方取错 user_id 来源的防御性判定）
    #
    # 刻意**不经 normalize_user_id**：那个方法把匿名 bot id 当无效值滤掉了，
    # 用它判「是不是匿名 bot」会永远返回 false（实施期实测踩过）。
    #
    # @see 文件头「匿名管理员」一节
    def anonymous_admin?(user_id)
      return false if user_id.nil?
      return false if user_id.is_a?(String) && user_id.strip.empty?

      user_id.to_i == ANONYMOUS_ADMIN_USER_ID
    end

    # 辅助判据：是否私聊。**只认显式 "private"**——nil 视为未知 → 按群处理
    # （打 API），避免「没传 type 就当私聊免检」这种默认放行。
    def private_chat?(chat_type)
      chat_type.to_s == PRIVATE_CHAT_TYPE
    end

    # 缓存维护（测试用 / 撤职后想立刻失效时用）
    def clear_cache!
      @admin_cache = {}
    end

    # 缓存条目数（测试断言「命中不重复打 API」的辅助证据）
    def cached_admin_count
      @admin_cache.size
    end

    # ------------------------------------------------------------------
    # 查询：先 gem、后 raw_api_call 兜底
    # ------------------------------------------------------------------

    # 取 status 字符串；任何异常/异常形态都归一成 nil（= fail-closed）
    #
    # ⚠️ **必须先收 gem 的异常、再打 raw 兜底**：早期实现把 gem 通道的
    #   StandardError 直接 `raise` 交给 fetch_status 的统一 rescue，
    #   于是「gem 报了网络错 → raw 兜底」这条路**根本走不到**（网络错时
    #   raw 也大概率一起错，等于白白丢了一条保底通道；实施期实测踩到）。
    #   正确分工：gem 异常 → 记一笔 → **仍试 raw**；两条都失败才 false。
    #
    # @return [String, nil]
    def fetch_status(chat_id, user_id)
      return nil if @api.nil?

      from_gem(chat_id, user_id) || from_raw(chat_id, user_id)
    rescue StandardError => e
      # 兜底网：连「取结果」这一步本身都炸（如 @api 结构不对）。
      # 日志**只记 class**（kimi T2.4 评审立的 RawApiError 契约：异常消息
      # 可能夹带 token/响应体，绝不打）。
      warn_line("[admin] getChatMember 查询异常（chat_id=#{chat_id}）：#{e.class}")
      nil
    end

    private

    # 通道一：gem 白名单（endpoints.rb 已收录 getChatMember）。
    #
    # 2.8.1 的 method_missing 对未收录端点 `return super` → 抛 NoMethodError，
    # 其 receiver 就是 @api_client.api（与 telegram_api.rb 的
    # gem_endpoint_missing? 同款判别）。这里只认这一个形态；其余
    # NoMethodError 与所有别的异常（ResponseError / 网络）**就地收口成 nil**
    # ——因为 fetch_status 的 `from_gem || from_raw` 必须能继续走保底通道。
    def from_gem(chat_id, user_id)
      client = @api.api_client
      member = client.api.get_chat_member(chat_id: chat_id, user_id: user_id)
      status_of(member)
    rescue StandardError => e
      # 日志只记 class（异常消息可能夹带 token/响应体）
      warn_line("[admin] getChatMember gem 通道失败（chat_id=#{chat_id}）：#{e.class}")
      nil
    end

    # 通道二：raw_api_call 保底（计划 §12 R2）。gem 能走就走，能走时
    # from_gem 已经有结果，这条根本不会被打到。
    def from_raw(chat_id, user_id)
      parsed = @api.raw_api_call("getChatMember", { chat_id: chat_id, user_id: user_id })
      result = parsed.is_a?(Hash) ? (parsed["result"] || parsed[:result]) : nil
      status_of(result)
    rescue StandardError => e
      warn_line("[admin] getChatMember raw 兜底失败（chat_id=#{chat_id}）：#{e.class}")
      nil
    end

    # 两条通道的返回形态归一：
    #   - gem 路径：Types::ChatMemberOwner/Administrator/…（dry-struct，有 #status）
    #   - raw 路径：{"status" => "creator", "user" => {...}}（普通 Hash）
    # 空/异常形态一律 nil（fail-closed）。
    def status_of(member)
      return nil if member.nil?

      status =
        if member.is_a?(Hash)
          member["status"] || member[:status]
        elsif member.respond_to?(:status)
          member.status
        elsif member.is_a?(String)
          member
        end

      s = status.to_s
      s.empty? ? nil : s
    end

    # user_id 归一：nil / 空串 / 0 / 匿名 bot → nil（调用方按 fail-closed 处理）
    def normalize_user_id(user_id)
      return nil if user_id.nil?
      return nil if user_id.is_a?(String) && user_id.strip.empty?

      id = user_id.to_i
      return nil if id.zero?
      return nil if id == ANONYMOUS_ADMIN_USER_ID # 见文件头「匿名管理员」

      id
    end

    # ------------------------------------------------------------------
    # 缓存（只缓存 true）
    # ------------------------------------------------------------------

    # 命中未过期的 true 缓存？
    def cached_admin?(chat_id, user_id)
      key = [chat_id, user_id]
      return false unless @admin_cache.key?(key)

      expires_at = @admin_cache[key]
      if expires_at > now
        true
      else
        @admin_cache.delete(key) # 顺手清掉过期项，别让表无限长
        false
      end
    end

    def remember_admin(chat_id, user_id)
      @admin_cache[[chat_id, user_id]] = now + @ttl
      true
    end

    def now
      @clock.call.to_f
    rescue StandardError
      # 时钟坏了不能让权限判定崩成 false（那等于全体失去管理员能力）：
      # 退化到「不用缓存」——返回 0（恒过期）。
      0.0
    end

    # 只记结构性信息（chat_id / 异常类），绝不记用户正文
    def warn_line(message)
      @logger.warn(message)
    rescue StandardError
      nil # logger 坏了也不能让权限判定失败
    end
  end
end