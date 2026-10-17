# frozen_string_literal: true

require "logger"

# ============================================================================
# bot/handlers/secret_dice.rb — 暗骰 /secret（T3.1，计划 §6 / §8 T3.1 / §12 R6）
#
# 注册两个键：
#   :secret         `/secret <骰式>`  跑当前作用域规则系统 → 结果落 secrets 表
#                                   → **ephemeral** 回本人 + 内联「公开」按钮
#                   `/secret last`     本人最近一次暗骰结果的 ephemeral 重取（R6 缓解）
#   :callback_query 暗骰「公开」按钮的回调（router 的 callback 路由分支调用）
#
# ── 三条不可让步的纪律 ──────────────────────────────────────────────────────
#
# 1. **结果永不走普通消息。**
#    本 handler 的 `call` **一律返回 nil**：一切输出都由自己经
#    `api.send_ephemeral(...)`（ephemeral_message_parameters）发出去。
#    router 的契约是「handler 返回 String 就代发」（bot/router.rb run_handler），
#    只要返回结果文本，它就会把暗骰广播进群。返回 nil 是这里的**结构性**保证，
#    不是靠 if 判断小心。
#
# 2. **先答回调，再干活。**
#    按钮被按下后若不调 answerCallbackQuery，用户客户端会一直转圈（计划 §8 T3.1
#    前置注记）。router 传进来的 `context[:answer_callback_query]` 是**幂等**的
#    （首次调用生效，后续调用 no-op）：handler 抛异常时由 router 的兜底补答，
#    不会出现「答两次 → 400 query is too old」。
#
# 3. **权限只看真人 user_id。**
#    `CallbackQuery#from` 是真人（Telegram 的匿名管理员消息没有 from）。
#    公开分支要求 `secrets.user_id == query.from.id`，不查群管理员名单——
#    暗骰的主人就是掷骰的那个人（§0.2.4 / 计划 §8 T3.1 注记）。
#
# ── 「公开」之后的删除（§15.3 E5 定案）────────────────────────────────────
#   公开成功后**删掉该 secrets 行**：结果已经公开，行留着就是无主残留
#   （E5 原文的两个建议方向之一，语义最正确的一条）。**删除放在发送成功之后**：
#   发送失败时行还在 → 用户还能再按一次（或 /secret last 重新拿到带按钮的副本），
#   而不会出现「按钮提示已公开、库里也没了、群里其实没这条」。
#
# ── 规则系统作用域 ──────────────────────────────────────────────────────────
#   与 /roll 走**同一套三级查找**（话题 → 群 → 全局默认 NinjaSlayer2Ex，
#   db/settings.rb）。暗骰不是「另一个规则世界」：掷什么由本群设置决定，
#   只有**投递方式**是私密的。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require_relative "dice"       # EngineResolver + UNKNOWN_COMMAND 文案（不抄第二份）
require_relative "../telegram_api"
require_relative "../../db/settings"
require_relative "../../db/secrets"
require_relative "../../lib/dice_limits"

module TelegramBot
  module Handlers
    # ----------------------------------------------------------------------
    # SecretDiceHandler
    # ----------------------------------------------------------------------
    class SecretDiceHandler
      # 无参 /secret 的用法提示（含 last 子命令，避免用户发现不了重取入口）
      USAGE = "用法：/secret <骰式或命令>，例：/secret SB、/secret 2d6>=4\n" \
              "/secret last —— 重看本聊天你最近一次暗骰的结果（约 25 分钟后自行消失）"

      # /secret last 无可重取的记录
      NO_RESULT = "本聊天你还没有暗骰记录。先用 /secret <骰式> 掷一次。"

      # 「公开」按钮文案（天狗本家日文「結果を公開する」的中文对照）
      BUTTON_TEXT = "公开"

      # 公开按钮回调的兜底应答文案（客户端只等这一个 toast）
      CB_UNKNOWN = "这个按钮已失效（不是本 bot 的暗骰按钮）。"
      CB_EXPIRED = "这条暗骰已过期或已公开过（记录已删除）。"
      CB_DENIED = "只有掷骰的本人可以公开这条暗骰。"
      CB_SENDING = "正在公开…"

      # 规则系统不可用（引擎里没有这个 ID：换 gem 版本 / 手改 DB）
      SYSTEM_UNAVAILABLE = "当前规则系统不可用（可能已被移除）。请用 /system <其他ID> 切换。"

      # 落库失败时的追加说明（结果仍以 ephemeral 送达，只是事后取不回）
      PERSIST_FAILED = "\n（未能存档，之后无法用 /secret last 取回）"

      # 存储层故障的本人可见回执（**只走 ephemeral**——暗骰的静默契约是
      # 「群里什么都看不见」，DB 故障也不能在群里出声；2026-10-12 二审修复）
      STORAGE_ERROR = "存储层出错，操作未完成，请稍后再试。"

      # `last` 子命令（大小写不敏感）
      LAST = "last"

      attr_reader :settings, :secrets, :resolver

      # @param settings [TenguDB::Settings, nil] 规则系统三级查找
      # @param secrets [TenguDB::Secrets, nil] 暗骰结果存取（nil = 单连接新建）
      # @param resolver [#call] id → 规则类（nil = 走 EngineResolver）
      # @param session_log [#record_bot_output, nil] 跑团 log 录制器（nil = 不录）——
      #   只用于「公开」路径：公开后的结果已是群内公开消息，进 log 符合 R8 口径
      #   （kimi T3.5 评审提案 #4）
      # @param logger [#warn, nil] 只记结构性信息，绝不记用户正文
      def initialize(settings: nil, secrets: nil, resolver: nil, session_log: nil,
                     logger: ::Logger.new($stderr))
        @settings = settings
        @secrets = secrets
        @resolver = resolver || EngineResolver.method(:call)
        @session_log = session_log
        @logger = logger
      end

      # 两处依赖都懒加载：注入了假身的用例**完全不碰** SQLite / 引擎
      def settings
        @settings ||= TenguDB::Settings.new
      end

      def secrets
        @secrets ||= TenguDB::Secrets.new
      end

      # ------------------------------------------------------------------
# router 的 handler 注册表接口：slash + 按钮回调共用一个对象
      #
      # **按 kind 分发**（T2.6 接线教训的泛化）：注册表把同一个对象挂在
      # :secret 与 :callback_query 两个键上，若只按 name 分发，按钮回调会走到
      # 「未知命令」分支静默返回——看着接了，实则从不执行。
      # @return [Hash{Symbol=>#call}]
      def self.registry(handler = new)
        { secret: handler, callback_query: handler }
      end

      # ------------------------------------------------------------------
      # 统一入口
      # ------------------------------------------------------------------
      #
      # **恒返回 nil**（纪律 1：结果绝不经 router 代发）。返回真值仅在
      # 「连本人是谁都拿不出来」这种结构失败时也不发——那时既发不出 ephemeral，
      # 也不该发普通消息。
      def call(context)
        return handle_callback(context) if callback_kind?(context)

        return nil unless slash_secret?(context)

        args = context[:args].to_s.strip
        return ephemeral_usage(context) if args.empty?

        chat_id = context[:chat_id].to_i
        user_id = context[:user_id].to_i
        # 拿不到发送者 → 既无法定 ephemeral 的接收人，也无法做本人判定。
        # 静默（不放任何公开消息出去，暗骰的契约是「群里什么都看不见」）。
        return nil if user_id <= 0 || chat_id.zero?

        return handle_last(context, chat_id, user_id) if last?(args)

        handle_roll(context, chat_id, user_id, args)
      rescue StandardError => e
        # 未捕获异常（典型 = DB 锁/损坏）兜底：warn + 尽力 ephemeral 告知本人
        # （send_ephemeral 自兜发送失败，返回 nil；2026-10-12 二审修复）
        warn_line("[secret] 未捕获异常：#{e.class}")
        send_ephemeral(context, context[:chat_id].to_i, context[:user_id].to_i, STORAGE_ERROR)
      end

      # ------------------------------------------------------------------
      # 「公开」按钮回调 —— router 的 callback 路由分支
      # ------------------------------------------------------------------
      #
      # @return [nil] 恒返回 nil（回调路径没有「router 代发」这回事）
      def handle_callback(context)
        answer = context[:answer_callback_query]

        id = TenguDB::Secrets.secret_id_from_callback_data(context[:data])
        return answered(answer, CB_UNKNOWN) if id.nil?

        secret = secrets.find(id)
        return answered(answer, CB_EXPIRED) if secret.nil?

        unless secret.owned_by?(context[:user_id])
          # 非本人按（含：这条记录根本不属于你）
          return answered(answer, CB_DENIED, alert: true)
        end

        # 先答（纪律 2），再发。toast 说「正在公开…」——它对「成功」与「发送
        # 失败」两个结局都不撒谎；失败时行还在，用户可以再按一次。
        answered(answer, CB_SENDING)

        api = context[:api]
        if api.nil?
          warn_line("[secret] 回调缺 api 注入，暗骰未公开（id=#{id}）")
          return nil
        end

        begin
          # 普通消息（非 ephemeral）——**任何客户端都看得见**，这正是「公开」的含义。
          # thread_id 归一（kimi T3.1 评审提案 #2）：库里群级存 0，而 send_one 的
          # 守卫是「if thread_id」——Ruby 里 0 为真，不归一会把 message_thread_id: 0
          # 拍上 wire（正常路径只透传入站非 nil 值；forum 群内 0 不是合法话题 id，
          # 有 400 风险）。0 → nil。
          public_thread_id = secret.thread_id.positive? ? secret.thread_id : nil
          api.send_text(secret.chat_id, secret.result_text, thread_id: public_thread_id)
        rescue StandardError => e
          # 发送失败**不删行**：按钮还在、/secret last 还能重取，本次公开未生效
          warn_line("[secret] 公开暗骰发送失败（id=#{id} chat_id=#{secret.chat_id}）：#{e.class}")
          return nil
        end

        secrets.delete(secret.id) # E5：公开成功后删行（发送成功才删）

        # 公开后的暗骰已是群内公开消息——进 log（R8 口径：录的是公开内容）。
        # 本路径自走 api.send_text、不到 router 挂钩②，不显式录则导出的 log
        # 会缺这段「群里人人可见」的内容（kimi T3.5 评审提案 #4）
        @session_log&.record_bot_output(chat_id: secret.chat_id,
                                        thread_id: secret.thread_id,
                                        text: secret.result_text)
        nil
      rescue StandardError => e
        # 未捕获异常（典型 = DB 锁/损坏）兜底：不答则用户客户端一直转圈，
        # 尽力 alert 告知（answer 自身失败则由 answered 路径自然落空，
        # 不再二级兜底——2026-10-12 二审修复）
        warn_line("[secret] 回调处理未捕获异常：#{e.class}")
        begin
          answered(context[:answer_callback_query], STORAGE_ERROR, alert: true)
        rescue StandardError
          nil
        end
      end

      private

      # 这是不是按钮回调？（router 的 callback 分支会显式传 kind）
      #
      # **双判据**（kind + callback_query 对象）：只认 kind 的话，某个未来的
      # 分支若复用 :callback_query 这个 kind 而不带对象，会走到
      # `callback_query_shaped?` 的兜底路径上——那里 return nil 是安全的，
      # 但那是靠巧合而不是靠设计。
      def callback_kind?(context)
        context[:kind] == :callback_query || !context[:callback_query].nil?
      end

      # 这是 /secret 的 slash 上下文？
      def slash_secret?(context)
        context[:kind] == :slash && context[:name].to_s == "secret"
      end

      # ------------------------------------------------------------------
      # /secret <式>
      # ------------------------------------------------------------------
      def handle_roll(context, chat_id, user_id, command)
        resolved = settings.resolve(chat_id, thread_id: context[:thread_id])
        klass = @resolver.call(resolved.game_system)

        if klass.nil?
          return send_ephemeral(context, chat_id, user_id, SYSTEM_UNAVAILABLE)
        end

        # 引擎上限前置守卫（2026-10-18 审核）：超限静默给 0 的结果也是
        # 「暗骰结果」，同样不能当成正常出目展示给发起人。
        limit_error = TelegramBot::DiceLimits.violation(command)
        return send_ephemeral(context, chat_id, user_id, limit_error) if limit_error

        result =
          begin
            klass.eval(command)
          rescue ::BCDice::TooManyRandsError
            warn_line("[secret] 骰数超限（system=#{resolved.game_system}）：TooManyRandsError")
            return send_ephemeral(context, chat_id, user_id,
                                  TelegramBot::Handlers::DiceHandler::TOO_MANY_DICE)
          rescue StandardError => e
            warn_line("[secret] 引擎执行异常（system=#{resolved.game_system}）：#{e.class}")
            nil
          end

        if result.nil?
          return send_ephemeral(context, chat_id, user_id,
                                TelegramBot::Handlers::DiceHandler::UNKNOWN_COMMAND)
        end

        text = result.respond_to?(:text) ? result.text.to_s : result.to_s
        if text.empty?
          return send_ephemeral(context, chat_id, user_id,
                                TelegramBot::Handlers::DiceHandler::UNKNOWN_COMMAND)
        end

        record, err = secrets.create(chat_id: chat_id, thread_id: context[:thread_id],
                                     user_id: user_id, command: command,
                                     result_text: text)

        if record.nil?
          warn_line("[secret] 暗骰存档失败（chat_id=#{chat_id}）：#{err}")
          return send_ephemeral(context, chat_id, user_id, body(command, text) + PERSIST_FAILED)
        end

        send_ephemeral(context, chat_id, user_id, body(command, text),
                       button_secret_id: record.id)
      end

      # ------------------------------------------------------------------
      # /secret last（R6 缓解：ephemeral 约 25 分钟消失，必须能取回）
      # ------------------------------------------------------------------
      #
      # **复用原行**而不是新建一条：last 是「重看」，不是「再掷一次」。
      # 复用 id 意味着按钮还是同一个（同一份授权、同一份可公开内容），
      # 且不额外制造 secrets 行（否则每次 last 都会把 TTL 往后推、绕过 E5）。
      def handle_last(context, chat_id, user_id)
        record = secrets.latest_for(chat_id: chat_id, user_id: user_id)
        return send_ephemeral(context, chat_id, user_id, NO_RESULT) if record.nil?

        send_ephemeral(context, chat_id, user_id,
                       body(record.command, record.result_text),
                       button_secret_id: record.id)
      end

      def last?(args)
        args.to_s.strip.downcase == LAST
      end

      # 天狗本家的呈现（snd.js）：`/snd <式>` + 结果
      def body(command, text)
        "/secret #{command}\n#{text}"
      end

      # 造「公开」按钮的 inline markup（gem 的 InlineKeyboardMarkup 会被
      # jsonify_value → to_json 自动序列化成 Bot API 要的形状）
      def button_markup(secret_id)
        button = ::Telegram::Bot::Types::InlineKeyboardButton.new(
          text: BUTTON_TEXT,
          callback_data: TenguDB::Secrets.callback_data(secret_id)
        )
        ::Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [[button]])
      end

      # 统一出口：一切 /secret 的对外输出都从这里走（纪律 1）
      #
      # 非管理员 bot 的 ephemeral 需要「15 秒窗口 + 回指触发消息」（Bot API
      # Reply Targets and Conditions）：入站命令消息（is_ephemeral 命令本身是
      # ephemeral）自带 ephemeral_message_id，透传给 reply_parameters 即可让
      # 非管理员 bot 也发出暗骰（2026-10-12 三审修复，此前只带
      # receiver_user_id = 只有管理员 bot 发得出）。
      def send_ephemeral(context, chat_id, user_id, text, button_secret_id: nil)
        return nil if text.to_s.empty?

        msg = context[:message]
        eph_id = msg.respond_to?(:ephemeral_message_id) ? msg.ephemeral_message_id : nil

        extra = button_secret_id ? { reply_markup: button_markup(button_secret_id) } : {}
        context[:api]&.send_ephemeral(chat_id, text,
                                      user_id: user_id,
                                      thread_id: context[:thread_id],
                                      reply_to_ephemeral_id: eph_id,
                                      **extra)
        nil
      rescue StandardError => e
        warn_line("[secret] ephemeral 发送失败（chat_id=#{chat_id}）：#{e.class}")
        # 兜底（2026-10-18 审核）：ephemeral 发不出去时，此前用户端零反馈，
        # 结果只躺在 secrets 表里等他自己想到 /secret last。改为一并尝试
        # **私聊直发**——私聊不经过 ephemeral 语义，通常能送达；用户从未
        # 与 bot 私聊过时 Telegram 会拒，仍只剩日志（不群里广播，防泄漏）。
        dm_fallback(context, user_id, text, extra)
        nil
      end

      # ephemeral 失败后的私聊兜底（best-effort；失败只记日志）
      def dm_fallback(context, user_id, text, extra)
        return nil unless user_id.to_i.positive?

        context[:api]&.send_text(user_id.to_i, text, **extra)
        nil
      rescue StandardError => e
        warn_line("[secret] 私聊兜底也失败（user_id=#{user_id}）：#{e.class}")
        nil
      end

      # 应答回调并返回 nil（让调用点一个 return 收尾）
      def answered(answer, text, alert: false)
        answer&.call(text, alert: alert)
        nil
      end

      def ephemeral_usage(context)
        chat_id = context[:chat_id].to_i
        user_id = context[:user_id].to_i
        return nil if user_id <= 0 || chat_id.zero?

        send_ephemeral(context, chat_id, user_id, USAGE)
      end

      # 只记结构性信息，绝不记用户正文/结果正文
      def warn_line(message)
        @logger.warn(message)
      rescue StandardError
        nil
      end
    end
  end
end