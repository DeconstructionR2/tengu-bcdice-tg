# frozen_string_literal: true

# ============================================================================
# bot/router.rb — 消息路由层（T2.3）
#
# 职责（计划 §2 / §6 / §8 T2.3 / §12 R4）：
#   1. **主轨 slash 命令**：解析 `/cmd`、`/cmd args`、`/cmd@BotName args`；
#      命令集合 = TelegramApi::MainMenu::ENTRIES（start/help/settings/roll/nd/
#      system/secret/bank/ct/log）。
#   2. **辅助轨裸 ASCII 骰式**：整条消息匹配骰式/命令语法特征才路由
#      （`N4,3`/`SB`/`SB@6`/`NRS_E4`/`2d6>=4`/`N4,3[J]`）。
#   3. **静默策略**：不命中一律不回复（防抢话）。群里常驻别的 bot，
#      bot 乱回就是噪声（§6「严格触发」「不命中 → 静默」）。
#   4. **分发 + 回发**：handler 结果经注入的 TelegramApi 发回，并带上入站
#      消息的 message_thread_id 透传（forum 话题不掉线，§3 决6）。
#
# ── 辅助轨闸门的设计（这是本任务最容易做错的地方）─────────────────────
#
#   **不能**直接拿 BCDice::Base.command_pattern 当闸门：
#     command_pattern = /^S?(#{prefixes.join('|')})/i —— 只有 ^ 没有 $，
#     它是给引擎内部 `dice_command` 用的**前缀筛子**，解析失败引擎自己返回 nil。
#     拿它当 bot 闸门会把 `hello`/`NJ`/`x3`/`SOULx` 之类全放进来 → 抢话。
#
#   故闸门 = **引擎自己暴露的整条锚定命令正则**（反射收集，见 harvest_command_patterns）
#          + 自建的表达式语法分支（镜像 CommonCommand 的 Lexer/Parser）。
#   两支合并后整体 \A…\z 锚定。
#
#   闸门是**语法闸**不是语义闸：语法像但引擎会返回 nil 的输入
#   （如 `NRS`——NRS@3 才有效）允许路由过去，由 T2.4 的 handler 调引擎拿结果。
#   这是刻意的——闸门宁可多放（handler 能给出"引擎不接受"）也不误杀（漏掷骰），
#   而**闲聊误命中**才是必须防的（§12 R4）。实测见 docs/t2.3-report.md §2。
#   （注：`SB_`/裸数字实测**不**过闸——锚定正则比前缀筛子严，安全方向。）
#
# ── 其余硬约束 ────────────────────────────────────────────────────────
#   - **纯 ASCII**：含非 ASCII 直接不命中（§13 第 2 项；日文一律不响应）。
#   - **@后缀只认本 bot**：别的 bot 的 `/cmd@OtherBot` 静默。
#   - **chat_id 按 64 位整型处理**；私聊/群/超级群同一路径（行为差异归 handler）。
#   - **迁移消息走注入的 migration handler**（T2.5：bot/migration.rb 做事务性
#     re-key；本层零 DB 依赖，只负责**不把它当普通消息处理** + 异常兜底）。
#   - **router 不写 DB、不联网**：发送只经注入的 TelegramApi，测试全 mock。
#   - **错误兜底**：handler 抛异常 → warn（只记结构性信息，不含用户正文）后继续。
# ============================================================================

require_relative "telegram_api"

module TelegramBot
  # --------------------------------------------------------------------------
  # AuxMatcher：辅助轨「裸 ASCII 骰式」闸门
  # --------------------------------------------------------------------------
  module AuxMatcher
    # 表达式语法（镜像 BCDice::CommonCommand 的 Lexer / AddDice::Parser）：
    #   词法单位 = 数字、比较符 [<>!=]、方括号、@、+-*/ 与单字母 D/B/T/R/U/C。
    #   覆盖 `2d6>=4`、`1d100>=50`、`2d6+3`、`3d6/2`、`1d6*2`、`2B6>=4`、
    #   `3TY3`、`3R4`、`3U4`、`D66`、`choice[a,b]`、`C1+2`、`d6` 等。
    #   （注：追加判定 `[J]`/`[=6]` 只对连续判定类命令有效——`N4,3[J]` 成立，
    #   `2d6>=4[=6]` 引擎四系统全 nil；评审实测更正，勿再把后者当命令示例。）
    #
    # **裸数字不进这一支**：引擎实测 `6` / `100` / `4` / `4,3` 全部返回 nil
    # （AddDice 需含 d/B；2 版连续判定需难度字母），放进来就是纯抢话。
    #
    # ⚠️ **不要用 /x（extended 模式）**：Regexp#source 返回**原始字符串**，
    #   /x 里用于排版的换行与空格会被原样嵌进 .source，再拼进一个**非** /x 的
    #   外层正则时，那些空白就变成了**字面空白要求**——`d6`/`C1`/`choice[a,b]`
    #   这类会全部失配（实测踩过，见报告 §2.3）。故一律单行书写。
    #
    # ⚠️ **不含 `.*` / 跨空白**：引擎 Lexer 在**第一个空格处截断**
    #   （`"2d6 + 3"` → `"2d6"`，见 Preprocessor#trim_after_whitespace），
    #   即「`2d6` 后面跟任何话」引擎都只当 `2d6`。若闸门学它做前缀匹配，
    #   `2d6 roll please` 会命中 → 抢话（§12 R4 要防的正是这个）。
    #   故闸门要求**整条无空白**（唯一例外是 repeat 形态：引擎要求 keyword
    #   与内容间有空格）。`2d6 + 3` 这种写法在闸门上不命中 → 静默；
    #   玩家写 `2d6+3` 即可。**这是刻意的取舍**：宁漏不抢。
    #
    # 数值 / 比较 / 追加判定 / 运算 / 定值
    NUM = /-?\d+(?:\.\d+)?/
    CMP = /(?:>=|<=|!=|==|[=<>])-?\d+(?:\.\d+)?/
    BRACKET = /\[[^\[\]]*\]/
    TAIL = /(?:#{CMP}|#{BRACKET}|[-+*\/]#{NUM}|@#{NUM})/
    TAILS = /#{TAIL}*/

    # 通用骰式/计算式本体
    # `d6`/`2d`/`d100` 都有效（引擎 replace_implicit_d 把 `2d` 补成 `2d6`），
    # 但裸 `d` 无效——故这里要求 `d` 后面至少一个数字。
    CORE_EXPR = /(?:#{NUM}d\d*|d\d+|#{NUM}B\d+|#{NUM}T[YZ]\d+|#{NUM}R\d+|#{NUM}U\d+|choice\[[^\[\]]*\]|BCDiceVersion|D66|C[+\-]?#{NUM})#{TAILS}/i

    # 忍杀 2 版连续判定（**必须带难度字母**）：引擎 prefixes_pattern 先要求命令
    #   以 [KENHU]/UH/SB/... 开头，再由 RE_JUDGE_DICEROLL 解。
    #   无难度字母的 `4,3` 引擎实测 nil。
    #
    #   **首项必须带难度字母**：引擎 prefixes_pattern 要求命令以 [KENHU]/UH/S
    #   开头才轮到 RE_JUDGE_DICEROLL，故 `4,3`（首项无字母）引擎实测 nil，
    #   而后续项可省略字母（沿承前一个难度）。`E1,N2,H3` 是首项带字母、后续各自换。
    DIFFICULTY_EXPR = /s?(?:UH|[KENHU])#{NUM}(?:,(?:UH|[KENHU])?#{NUM})*#{TAILS}/i

    # 上述两条构成「**不依赖规则前缀**」的通用表达式分支。
    #
    # 暗骰 S 前缀（`S2d6`/`sB`/`SSB`/`SK6`）**不**在这里做，而是由 build_pattern
    # 在整个交替组的外面统一套一个 `s?`——引擎把命令首字母 S 当暗骰标记剥掉后
    # 重跑同一套解析，故 S 对**任何**已支持命令都成立（含双 S：`SSB`）。
    # 统一套的好处：不必为每条命令各写一个 S 变体，也就不会漏。
    EXPRESSION_SOURCES = [CORE_EXPR, DIFFICULTY_EXPR].map(&:source).freeze

    # 参与闸门判定的规则系统（取全集，保守：宁可路由给 handler 再判当前规则）
    DEFAULT_SYSTEM_IDS = %w[
      NinjaSlayer2Ex NinjaSlayerEx NinjaSlayer2 NinjaSlayer
    ].freeze

    module_function

    # ------------------------------------------------------------------------
    # 反射收集各规则**自己暴露的整条锚定命令正则**
    # ------------------------------------------------------------------------
    #
    # 为什么收集 RE_* 而不是 command_pattern：
    #   command_pattern 只锚头（引擎内部用），而 RE_JUDGE_SATZ_BATZ 这类
    #   是 `^SB(?:@([1-6]))?$` 这种**首尾都锚**的完整命令语法。
    #   反射它们 = 规则新增命令自动进网（T1.3~T1.8 的扩展零改动受益），
    #   且**不抄本**：规则改了正则，闸门自动跟着改。
    #
    # 只收「首尾都锚」的（`\A…\z` 或 `^…$`）；单边锚定的（如 RE_COUNT_JUDGE
    # 只收尾）是子片段，直接收会误放行。
    # 「松散」正则的常量名排除名单（跨 NinjaSlayer2 / NinjaSlayer2Ex 同名）：
    #   - RE_JUDGE_DICEROLL / RE_EX_DICEROLL：连续判定。脱掉 prefixes_pattern
    #     前缀闸门后直接收它 = 放行裸数字（`4`/`6`/`100`）= 抢话。
    #     本模块的 DIFFICULTY_EXPR 正是「带难度字母」的严格版，覆盖同样命令。
    #   - RE_EX_APPENDIX_ONE：追加判定的**括号内子片段**（`[J]`/`[=6]` 等，只该
    #     跟在骰式后面）。整条收割会放行裸 `J`/`L`/`=6`（kimi 评审实测四类引擎
    #     全 nil、闸门却命中 = 单字母闲聊抢话）。括号形态由 TAILS 的 BRACKET
    #     覆盖（`N4,3[J]` 不受影响）。
    # ⚠️ `constants` 返回的是 **Symbol**，名单必须 %i[...]——写成字符串
    #   会静默永不命中（T2.3 实施期实测踩过，见报告 §2.3 D4-2）。
    EXCLUDED_PATTERN_NAMES = %i[RE_JUDGE_DICEROLL RE_EX_DICEROLL RE_EX_APPENDIX_ONE].freeze

    def anchored?(source)
      anchored_ends =
        (source.start_with?("\\A") && source.end_with?("\\z")) ||
        (source.start_with?("^") && source.end_with?("$"))
      return false unless anchored_ends

      # 加固（kimi T2.3 评审 Q5）：剥掉两端锚点后，中段不得再出现**裸** ^/$
      # （如 `^A$|^B$` 形态剥完会留下行锚，拼进外层造成奇异匹配）。
      # 转义的 \| \^ \$ 与字符类内的不算（当前 15 条源均无此形态，纯未来防御）。
      body = unwrap_anchor(source)
      stripped = body.gsub(/\\./, "").gsub(/\[[^\]]*\]/, "")
      !stripped.match?(/[\^$]/)
    end

    # 去掉两端的锚点，交由外层统一的 \A…\z 包裹
    def unwrap_anchor(source)
      if source.start_with?("\\A") && source.end_with?("\\z")
        source[2...-2]
      elsif source.start_with?("^") && source.end_with?("$")
        source[1...-1]
      else
        source
      end
    end

    # @param systems [Array<Class>] BCDice 规则类
    # @return [Array<String>] 去重后的命令正则源（已去锚点）
    def command_pattern_sources(systems)
      Array(systems).flat_map do |klass|
        klass.constants.filter_map do |const|
          # 某些常量取值可能抛（如 autoload 未就绪），跳过而非炸掉整条闸门
          value = begin
            klass.const_get(const)
          rescue StandardError
            next
          end
          next unless value.is_a?(Regexp)
          next unless anchored?(value.source)
          # 排除「脱掉引擎前缀闸门后会误放行」的松散正则/子片段
          # （名单与理由见 EXCLUDED_PATTERN_NAMES 注释；名单必须 Symbol）。
          next if EXCLUDED_PATTERN_NAMES.include?(const)

          unwrap_anchor(value.source)
        end
      end.uniq
    end

    # ------------------------------------------------------------------------
    # 组装闸门正则
    # ------------------------------------------------------------------------
    #
    # @param systems [Array<Class>] 参与判定的规则类
    # @return [Regexp]
    def build_pattern(systems)
      body = (EXPRESSION_SOURCES + command_pattern_sources(systems)).join("|")

      # repeat 系列：`x3 2d6` / `rep2 CC<=75` / `repeat10 2D6+5`。
      #   引擎 Repeat#parse 要求 keyword + 次数 + **空白** + 内容，故用 \s+；
      #   被重复的内容必须本身是条合法命令（不能是 `\S` 一坨，否则
      #   `x3 hello` 这类闲聊会被放行）。这里把已组装好的 body 再嵌一次——
      #   Ruby 正则源不支持自引用，故只能在 build_pattern 里拼。
      #   **不嵌套两层**：引擎明确禁止 repeat 套 repeat（REPEAT_LIMIT=100，
      #   上游注释「入れ子させることは許容しない」），一层即与引擎一致。
      repeat = "s?(?:repeat|rep|x)\\d+\\s+(?:#{body})"

      # 暗骰 S 前缀统一套在最外层（见 EXPRESSION_SOURCES 处注释）
      Regexp.new("\\As?(?:#{body}|#{repeat})\\z", Regexp::IGNORECASE)
    end
  end

  # --------------------------------------------------------------------------
  # slash 命令解析结果
  # --------------------------------------------------------------------------
  class SlashCommand
    attr_reader :name, :args, :raw_text

    # @param name [String] 不含斜杠的命令名
    # @param args [String] 命令名之后的参数（已 strip，可为空串）
    # @param raw_text [String] 原始消息正文
    def initialize(name:, args:, raw_text:)
      @name = name
      @args = args
      @raw_text = raw_text
    end

    def args?
      !args.empty?
    end
  end

  # --------------------------------------------------------------------------
  # StartHandler（T2.3 最小 handler，只为证明「入站 → 解析 → 分发 → 回发」链路通）
  # --------------------------------------------------------------------------
  #
  # 真正的掷骰 handler 归 T2.4。本文件放这个欢迎语有两个理由：
  #   1. main.rb 是**入口脚本**（加载即启动长轮询，不可被测试 require），
  #      handler 放这里才能被 test/bot/test_router_test.rb 直接测；
  #   2. 它演示 handler 契约：返回 String → router 代发并带 thread 透传。
  #
  # T2.4 起真 handler 落 bot/handlers/dice.rb 等，本类届时删除或降级为示例。
  class StartHandler
    MESSAGE = "天狗骰子 bot 已上线。/help 查看命令；裸打 N4,3、SB、2d6>=4 也能掷骰。"

    # @param _context [Hash] router 传入的上下文（本 handler 不需要）
    # @return [String] 交由 router 代发
    def call(_context)
      MESSAGE
    end
  end

  # --------------------------------------------------------------------------
  # Router
  # --------------------------------------------------------------------------
  class Router
    # slash 命令名集合（主轨）。**以 TelegramApi::MainMenu::ENTRIES 为准**，
    # 不在此另抄一份 —— 两处抄本必然漂移。
    def self.menu_command_names
      MainMenu::ENTRIES.map { |e| e[:command].to_s }
    end

    attr_reader :api, :aux_enabled, :handlers, :aux_pattern, :migration
    attr_accessor :bot_username

    # @param api [TelegramBot::TelegramApi] 发送通道（注入；router 自己不联网）
    # @param handlers [Hash{Symbol=>#call}] 预注册 handler（T2.4 往里加）
    # @param aux_enabled [#call] 辅助轨开关查询接口：
    #   `->(chat_id, thread_id) { true }`，**默认开**。持久化归 T2.4+
    #   （读 chat_settings）；本任务只留注入口。
    # @param bot_username [String, nil] 本 bot 的 username（不带 @）。
    #   nil = 不校验 @后缀（单 bot 部署常见情形）。
    # @param aux_systems [Array<Class>, nil] 辅助轨判定用的规则类；
    #   nil = 按 AuxMatcher::DEFAULT_SYSTEM_IDS 现取（需引擎已 bootstrap）。
    # @param migration [#call, nil] 群升级 re-key 处理器（T2.5）。签名
    #   `call(chat_id:, migrate_to:, migrate_from:)`，返回 nil 或 Result。
    #   nil = 未注入 → 迁移消息安静跳过（并 warn 一次/条），不崩。
    # @param answer_callback [#call, nil] 按钮回调的应答通道（T3.1）。
    #   签名 `answer_callback.call(query_id, text = nil, alert: false)`；nil = 用
    #   注入的 api（@api.answer_callback_query）。**必须有**：不答则用户客户端
    #   一直转圈（计划 §8 T3.1 前置注记），而本层拿不到别的兜底通道。
    # @param logger [#warn] 日志器（只记结构性信息）
    def initialize(api:,
                   handlers: {},
                   aux_enabled: nil,
                   bot_username: nil,
                   aux_systems: nil,
                   migration: nil,
                   answer_callback: nil,
                   logger: $stderr)
      @api = api
      @handlers = handlers.dup
      @aux_enabled = aux_enabled || ->(_chat_id, _thread_id) { true }
      @bot_username = bot_username
      @logger = logger
      @aux_systems = aux_systems
      @migration = migration
      @answer_callback = answer_callback || method(:default_answer_callback)
      @aux_pattern = AuxMatcher.build_pattern(aux_systems || self.class.default_systems)
    end

    # 按默认 ID 列表取规则类；引擎没 bootstrap 时返回 []（只走通用骰式）
    def self.default_systems
      return [] unless defined?(::BCDice)

      AuxMatcher::DEFAULT_SYSTEM_IDS.filter_map do |id|
        # 按 id 逐个兜：一个解析失败只丢这一个，**不得**让整个列表清零
        # （kimi T2.3 评审：整体 rescue 会让闸门静默退化成纯通用骰式且无报警）。
        begin
          ::BCDice.game_system_class(id)
        rescue StandardError => e
          warn("[router] 规则类 #{id} 解析失败，已跳过（闸门少一条规则分支）：#{e.class}")
          nil
        end
      end
    end

    # ------------------------------------------------------------------
    # handler 注册表（可注入）
    # ------------------------------------------------------------------

    # 注册 handler。T2.4 往表里加真 handler。
    #
    # @param key [Symbol, String] slash 命令名（"roll"）或辅助轨标记（:aux）
    # @param handler [#call] 签名 `handler.call(context)`，context 是 Hash：
    #   `{ router:, api:, kind:, command:, name:, args:, text:, chat_id:,
    #      thread_id:, user_id:, chat_type:, message: }`
    #   `chat_type`（T2.6 加）是入站 chat.type 原值（private/group/supergroup/
    #   channel，§0.2.4），handler 据它判「私聊豁免 / 群里要管理员」。
    #   缺失时是 nil —— handler 必须把 nil 当**群**处理（未知不等于豁免）。
    #   handler 可直接调 `ctx[:api].send_text(...)` 回发（T2.4 的真实职责），
    #   也可只 `return "文本"` —— **返回 String 时由 router 代发**（带 thread 透传）。
    # @return [self]
    def register(key, handler = nil, &block)
      @handlers[normalize_key(key)] = handler || block
      self
    end

    # ------------------------------------------------------------------
    # 入口：长轮询的 dispatch
    # ------------------------------------------------------------------

    # @param update [Telegram::Bot::Types::Update]
    # @return [Object, nil] handler 的返回值（无 handler 时 nil）
    def call(update)
      dispatch(update)
    end
    alias dispatch call

    # 主流程：先分流按钮回调 → 取消息 → 跳服务/非文本 → 解析轨 → 命中则分发。
    #
    # **按钮回调必须先于 extract_message**（T3.1）：extract_message 显式跳过
    # CallbackQuery 形状（否则按一次「公开」会被当成「原消息被重发」二次路由，
    # 原消息文本若恰好是骰式就会白掷一次骰，见 extract_message 的注释）。回调
    # 分支从 update 上直接取 CallbackQuery 本体，不经过那条守卫。
    def dispatch(update)
      return dispatch_callback_query(update) if callback_query_shaped?(update)

      message = extract_message(update)
      return nil if message.nil?

      # --- 群升级迁移消息：交给 migration handler（T2.5）---
      # migrate_to_chat_id / migrate_from_chat_id 是群「普通群 ↔ 超级群」升级的
      # 服务消息（§0.2.4）。两侧各发一条（旧群侧带 migrate_to、新群侧带
      # migrate_from），handler 对两个方向做的事完全相同，故幂等（§12 R5）。
      #
      # 本层**不持有 DB**：handler 由 main.rb 注入、测试注入假身。未注入时
      # 保持 T2.3 的行为（安静跳过）——缺依赖不该让 bot 崩，但也别静默丢
      # 迁移（故打 warn，运维能看见）。
      return handle_migration(message) if migration_message?(message)

      chat = message.chat
      return nil if chat.nil? || chat.id.nil?

      # chat_id 一律按 64 位整型处理（§0.2.4：chat_id 可超 32 位有效位）。
      chat_id = chat.id.to_i
      thread_id = message.message_thread_id&.to_i
      text = message.text
      return nil if text.nil? || text.empty?

      # --- 主轨 slash ---
      if text.start_with?("/")
        return handle_slash(text, chat_id: chat_id, thread_id: thread_id,
                                       message: message, chat_type: chat_type_of(chat))
      end

      # --- 辅助轨裸 ASCII 骰式 ---
      handle_aux(text, chat_id: chat_id, thread_id: thread_id,
                          message: message, chat_type: chat_type_of(chat))
    end

    # ------------------------------------------------------------------
    # 按钮回调路由（T3.1，计划 §8 T3.1 前置注记）
    # ------------------------------------------------------------------

    # CallbackQuery → 交给 :callback_query handler，并在 context 里备好**幂等**的
    # 应答闭包（先答后干活，见 bot/handlers/secret_dice.rb 的纪律 2）。
    #
    # 三条硬要求（缺一即返工）：
    #   1. **必须调 answerCallbackQuery**，否则用户客户端一直转圈；
    #   2. **先答后干活**：应答是一次网络往返，而 handler 要落库 + 发消息，
    #      慢得多；先答能把客户端的等待压到最短；
    #   3. **兜底也要答**：handler 抛异常被 rescue 吞掉时（run_handler 的既有
    #      纪律：不杀循环），客户端不会永远转圈——此处补一次兜底应答。
    #
    # 「未注册 :callback_query handler」不静默：warn 一次/条（缺依赖要可见），
    # 并**照答**（否则用户对着一个不转圈的按钮毫无反馈）。
    #
    # @return [Object, nil] handler 的返回值；无 handler 时 nil
    def dispatch_callback_query(update)
      query_id = query_id_of(update)
      data = update.respond_to?(:data) ? update.data : nil
      answered = false
      answer = lambda do |text = nil, alert: false|
        next if answered

        answered = true
        answer_callback_query(query_id, text, alert: alert)
      end

      handler = @handlers[:callback_query]
      if handler.nil?
        warn_line("[router] 未注册 :callback_query handler，按钮回调被忽略" \
                  "（构造 Router 时应注册，data=#{data.inspect}）")
        answer.call
        return nil
      end

      run_handler(:callback_query, handler, command: nil,
                                      chat_id: nil, thread_id: nil,
                                      message: nil, chat_type: nil,
                                      callback_query: update, answer_callback_query: answer)
    ensure
      # handler 抛异常 → run_handler 已 rescue 并 warn；此处补答，让客户端收手
      answer_callback_query(query_id, nil) unless answered
    end

    # 真的发 answerCallbackQuery（默认走注入的 api；可被 answer_callback: 替换）
    #
    # **只在 query_id 存在时发**：gem 的 CallbackQuery#id 是必填，但测试假身与
    # 未来形态可能缺——没有 id 的应答会被服务端以 400 拒，发了只是徒增噪音。
    # 失败只 warn 不抛：应答失败不该让整条回调路径炸掉。
    def answer_callback_query(query_id, text = nil, alert: false)
      return nil if query_id.nil? || query_id.to_s.empty?

      @answer_callback.call(query_id, text, alert: alert)
      nil
    rescue StandardError => e
      warn_line("[router] answerCallbackQuery 失败：#{e.class}")
      nil
    end

    # ------------------------------------------------------------------
    # 群升级迁移（T2.5）
    # ------------------------------------------------------------------

    # 把迁移消息交给注入的 handler。**不回复任何消息**——升级服务消息对
    # 群里其他 bot 与用户都不该有回声。
    #
    # 三条硬纪律：
    #   - 迁移消息**绝不走普通消息路径**（不进 slash/aux 判定）：服务消息的
    #     text 是系统生成的「群已升级为超级群」，不掷骰、不回话。
    #   - handler 抛异常 → warn（只记 class + id，不含正文）后继续，**不杀循环**
    #     （与 run_handler 同一纪律；DB 故障不该让 bot 停止掷骰）。
    #   - 未注入 handler → 安静跳过 + warn（缺依赖可见，不静默丢迁移）。
    #
    # @return [Object, nil] handler 的返回值
    def handle_migration(message)
      return nil if @migration.nil?

      chat_id = message.respond_to?(:chat) ? message.chat&.id : nil
      migrate_to = message.migrate_to_chat_id if message.respond_to?(:migrate_to_chat_id)
      migrate_from = message.migrate_from_chat_id if message.respond_to?(:migrate_from_chat_id)

      @migration.call(chat_id: chat_id, migrate_to: migrate_to, migrate_from: migrate_from)
    rescue StandardError => e
      warn_line("[router] 群迁移 re-key 失败（chat_id=#{chat_id}）：#{e.class}")
      nil
    ensure
      # 缺依赖也要留痕：静默丢弃迁移 = 群升级后账本无声消失，
      # 而这类故障没有任何用户可见症状（迁移消息本就不该回话）。
      warn_line("[router] 未注入 migration handler，群升级 re-key 被跳过" \
                "（构造 Router 时应传 migration:）") if @migration.nil?
    end

    # ------------------------------------------------------------------
    # 主轨：slash 命令
    # ------------------------------------------------------------------

    # 解析 `/cmd`、`/cmd args`、`/cmd@BotName args`，落到已注册 handler。
    #
    # **未注册 → 静默**（群里别的 bot 可能注册了同名命令；我们无权抢）。
    def handle_slash(text, chat_id:, thread_id:, message: nil, chat_type: nil)
      cmd = parse_slash(text)
      return nil if cmd.nil? || cmd.name.empty?

      handler = @handlers[cmd.name.to_sym]
      return nil if handler.nil? # 未知命令 → 静默

      run_handler(:slash, handler, command: cmd,
                                 chat_id: chat_id, thread_id: thread_id,
                                 message: message, chat_type: chat_type)
    end

    # slash 解析（纯函数，无副作用）
    #
    # 规则：
    #   - 必须以 `/` 开头；`//foo` 的命令名是 `/foo`（非法）→ nil
    #   - `/cmd@BotName args`：**只有 @本 bot 的 username** 才算发给本 bot；
    #     别的 bot 的命令静默（§6 群里多 bot 共存）
    #   - 命令名**不做小写化**（未注册即静默，不给大小写变体开后门）
    #
    # @return [SlashCommand, nil] 不合法时 nil
    def parse_slash(text)
      body = text.to_s[1..].to_s # 去掉前导 /
      head, args = body.split(/\s+/, 2)
      head = head.to_s
      args = args.to_s.strip

      name, at_bot = split_at_bot(head)
      return nil if name.nil? || name.empty?
      return nil if at_bot && !bot_matched?(at_bot)

      SlashCommand.new(name: name, args: args, raw_text: text)
    end

    # ------------------------------------------------------------------
    # 辅助轨：裸 ASCII 骰式
    # ------------------------------------------------------------------

    # 整条消息匹配骰式语法才路由；不命中 → 静默。
    def handle_aux(text, chat_id:, thread_id:, message: nil, chat_type: nil)
      return nil unless aux_match?(text)
      return nil unless aux_track_enabled?(chat_id, thread_id)

      handler = @handlers[:aux]
      return nil if handler.nil?

      run_handler(:aux, handler, command: nil,
                              chat_id: chat_id, thread_id: thread_id,
                              message: message, chat_type: chat_type,
                              text: text)
    end

    # 辅助轨语法判定（纯函数）
    def aux_match?(text)
      s = text.to_s.strip
      # 纯 ASCII 定案（§13 第 2 项）：含非 ASCII 直接不命中——中文/日文闲聊
      # 语法上不可能命中，日文一律不响应。
      return false if s.empty?
      return false unless s.ascii_only?

      @aux_pattern.match?(s)
    end

    # 辅助轨开关（可注入查询接口，持久化归 T2.4+）
    #
    # 开关查询自身抛异常时按**关**处理（fail-closed）：宁可漏掷一次，
    # 也不要在用户已关掉辅助轨的群里继续抢话。
    def aux_track_enabled?(chat_id, thread_id)
      @aux_enabled.call(chat_id, thread_id) ? true : false
    rescue StandardError => e
      warn_line("[router] 辅助轨开关查询失败，按关闭处理：#{e.class}")
      false
    end

    # ------------------------------------------------------------------
    # 分发 + 回发
    # ------------------------------------------------------------------

    # 跑 handler 并把结果回发（结果为 String 时由 router 代发）。
    #
    # 错误兜底：handler 抛异常 → warn + 继续（不杀循环）。日志**只记结构性
    # 信息**（轨/命令/chat_id/异常类），**绝不记用户正文**。
    def run_handler(kind, handler, command:, chat_id:, thread_id:, message:,
                    text: nil, chat_type: nil, callback_query: nil,
                    answer_callback_query: nil)
      context = {
        router: self,
        api: @api,
        kind: kind,
        command: command,
        name: command&.name,
        args: command&.args,
        text: text,
        chat_id: chat_id,
        thread_id: thread_id,
        user_id: user_id_of(message) || user_id_of(callback_query),
        chat_type: chat_type,
        message: message,
        callback_query: callback_query,
        # 回调数据单独摊平到 context（handler 不必自己去摸 callback_query 对象的
        # 字段——测试假身/gem 形态差别就集中在这一个入口上）
        data: callback_query.respond_to?(:data) ? callback_query.data : nil,
        answer_callback_query: answer_callback_query,
      }

      result = handler.call(context)

      # handler 直接返回文本 → 由 router 代发（带 thread 透传）
      if result.is_a?(String) && !result.empty?
        send(chat_id, result, thread_id: thread_id)
      end

      result
    rescue StandardError => e
      warn_line("[router] handler 异常已忽略（轨=#{kind} 命令=#{command&.name.inspect} " \
                "chat_id=#{chat_id}）：#{e.class}")
      nil
    end

    # 发送：thread_id 非 nil 时透传（forum 不掉话题，§3 决6）。
    #
    # 发送失败**只记不抛**——一条发不出去的消息不该让 router 崩掉整轮。
    def send(chat_id, text, thread_id: nil, **extra)
      return [] if text.to_s.empty?

      @api.send_text(chat_id, text, thread_id: thread_id, **extra)
    rescue StandardError => e
      warn_line("[router] 发送失败（chat_id=#{chat_id}）：#{e.class}")
      []
    end

    # ------------------------------------------------------------------
    # 工具
    # ------------------------------------------------------------------

    # @return [Boolean] @后缀是否指向本 bot
    #
    # **fail-closed**（kimi T2.3 评审）：username 未知（getMe 失败/未注入）时
    # **拒答一切带 @后缀**的命令——宁可不答，也不冒抢答别的 bot 命令的风险
    # （多 bot 群里 `/start@OtherBot` 被我们应答 = 静默策略破防）。
    def bot_matched?(at_bot)
      return false if @bot_username.nil?

      at_bot.to_s.casecmp?(@bot_username.to_s.delete_prefix("@"))
    end

    # 从 update 里取消息对象
    #
    # **gem 2.8.1 接缝实测**（T2.6 真机验收踩坑留档）：`Client#listen` yield 的
    # 是 **Message**——`handle_update` 返回 `update.current_message`
    # （gem client.rb:41-47），不是 Update。只认 Update 形态会让全量消息在
    # 此静默归零（症状：bot 在线、无任何回复、无报错日志）。
    # 故本方法**两种形态都收**：Update 取其 current_message；Message 直接用。
    #
    # **current_message 的另两类真实形状**（2026-10-12 Phase 2 验收期实证，
    # gem update.rb 的 current_message = 第一个非 nil 属性）：
    #   - **callback_query** update → yield **CallbackQuery 本体**（不是 nil！
    #     本文件与 telegram_api.rb 早先注释「会被 yield nil」是错的，已更正）。
    #     CallbackQuery 带 `message` 属性指向按钮所附的原消息——不加守卫，
    #     按一次按钮会被误当成「原消息被重发」而二次路由（原消息文本若恰好
    #     过闸门就会白掷一次骰）。故显式跳过；T3.1 的暗骰「公开」按钮应在
    #     dispatch 前加正式的 callback 路由分支（需要 query.id 与 data）。
    #   - **edited_message** update → yield 编辑后的 Message（`edit_date`
    #     非 nil 是唯一与新消息的区分点）。骰子 bot 对编辑重掷会产生两个
    #     不同的随机结果（「哪次算数」混乱）且是刷骰向量 → 一律跳过，
    #     打错了请重发一条。注意 Message 形态接缝无法区分「编辑」与「新发」，
    #     只能靠 Message 自带的 edit_date 字段判别。
    def extract_message(update)
      return nil if update.nil?

      # 按钮回调不是消息（见方法头注释）；T3.1 接正式 callback 路由
      return nil if callback_query_shaped?(update)

      # Message 形态直通（respond_to? chat+text 且不响应 current_message）
      if !update.respond_to?(:current_message) &&
         update.respond_to?(:chat) && update.respond_to?(:text)
        return nil if edited_message?(update)

        return update
      end

      message =
        if update.respond_to?(:current_message) && !update.current_message.nil?
          update.current_message
        elsif update.respond_to?(:message)
          update.message
        end

      return nil if callback_query_shaped?(message)
      return nil unless message.respond_to?(:text)
      return nil if edited_message?(message)

      message
    end

    # 群升级迁移服务消息？（§0.2.4 / §12 R5；处理归 T2.5）
    def migration_message?(message)
      return false unless message.respond_to?(:migrate_to_chat_id)

      !message.migrate_to_chat_id.nil? || !message.migrate_from_chat_id.nil?
    end

    # CallbackQuery 形状判别（extract_message 的守卫，见该方法头注释）。
    # `chat_instance` 是 CallbackQuery 在所有 update 负载类型中独有的属性
    # （gem 2.8.1 types/callback_query.rb），配上 `data` 双判据防误判。
    # 测试假身/未来 Types 新增类型只要不同时带这两个属性就不受影响。
    def callback_query_shaped?(obj)
      !obj.nil? && obj.respond_to?(:chat_instance) && obj.respond_to?(:data)
    end

    # 编辑过的消息？（gem 的 Message 恒响应 edit_date，新消息为 nil；
    # 测试假身不响应 edit_date 时视为新消息——与既有测试语料兼容）
    def edited_message?(message)
      message.respond_to?(:edit_date) && !message.edit_date.nil?
    end

    def user_id_of(message)
      from = message.respond_to?(:from) ? message.from : nil
      from&.id&.to_i
    end

    # CallbackQuery 的 id（answerCallbackQuery 必填；gem 形态是 String）
    #
    # 不响应 id 的对象一律 nil → answer_callback_query 短路不发（见该方法注释）
    def query_id_of(obj)
      return nil unless obj.respond_to?(:id)

      value = obj.id
      value.nil? || value.to_s.empty? ? nil : value
    end

    # 默认的 answerCallbackQuery 通道：走注入的 TelegramApi。
    #
    # 本层**不发消息、只答回调**，故不经过 send_text 的切段/配速/thread 逻辑
    # （那些对一条 toast 是纯开销；而配速限流是按消息计的，answerCallbackQuery
    # 不计入群消息速率）。
    def default_answer_callback(query_id, text = nil, alert: false)
      params = { callback_query_id: query_id }
      params[:text] = text if text && !text.to_s.empty?
      params[:show_alert] = true if alert

      @api.answer_callback_query(**params)
    end

    # 入站 chat.type 原值（T2.6：handler 判「私聊豁免 / 群里要管理员」）。
    #
    # **拿不到就返回 nil**（不是猜测值）：nil 必须被下游当作「群」处理——
    # 未知不等于豁免。chat 不认 type（测试假身）时同样 nil。
    def chat_type_of(chat)
      chat.respond_to?(:type) ? chat.type&.to_s : nil
    end

    private

    def normalize_key(key)
      key.to_s.downcase.to_sym
    end

    # `cmd@BotName` → ["cmd", "BotName"]；`@` 在首位 → [nil, nil]（非法）
    def split_at_bot(head)
      if head.start_with?("@")
        [nil, nil]
      elsif head.include?("@")
        head.split("@", 2)
      else
        [head, nil]
      end
    end

    # 只记结构性信息，绝不记用户正文（正文可能含群内私密内容）
    def warn_line(message)
      @logger.warn(message)
    rescue StandardError
      nil # logger 自身坏了也不能影响路由
    end
  end
end