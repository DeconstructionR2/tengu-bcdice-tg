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
#   - **迁移消息与非文本消息安静跳过**（迁移处理归 T2.5，留钩子注释）。
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

    attr_reader :api, :aux_enabled, :handlers, :aux_pattern
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
    # @param logger [#warn] 日志器（只记结构性信息）
    def initialize(api:,
                   handlers: {},
                   aux_enabled: nil,
                   bot_username: nil,
                   aux_systems: nil,
                   logger: $stderr)
      @api = api
      @handlers = handlers.dup
      @aux_enabled = aux_enabled || ->(_chat_id, _thread_id) { true }
      @bot_username = bot_username
      @logger = logger
      @aux_systems = aux_systems
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
    #      thread_id:, user_id:, message: }`
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

    # 主流程：取消息 → 跳服务/非文本 → 解析轨 → 命中则分发。
    def dispatch(update)
      message = extract_message(update)
      return nil if message.nil?

      # --- 群升级迁移消息：安静跳过 ---
      # migrate_to_chat_id / migrate_from_chat_id 是群「普通群 ↔ 超级群」升级的
      # 服务消息（§0.2.4）。真正的事务性 re-key 归 T2.5 migration.rb，本层
      # 只保证**不把它当普通消息处理**。
      # ↓↓↓ T2.5 钩子：在此处按 migrate_from_chat_id → migrate_to_chat_id
      #     调 Migration.handle(chat_id:, migrate_to:)（幂等，§12 R5）。
      return nil if migration_message?(message)

      chat = message.chat
      return nil if chat.nil? || chat.id.nil?

      # chat_id 一律按 64 位整型处理（§0.2.4：chat_id 可超 32 位有效位）。
      chat_id = chat.id.to_i
      thread_id = message.message_thread_id&.to_i
      text = message.text
      return nil if text.nil? || text.empty?

      # --- 主轨 slash ---
      if text.start_with?("/")
        return handle_slash(text, chat_id: chat_id, thread_id: thread_id, message: message)
      end

      # --- 辅助轨裸 ASCII 骰式 ---
      handle_aux(text, chat_id: chat_id, thread_id: thread_id, message: message)
    end

    # ------------------------------------------------------------------
    # 主轨：slash 命令
    # ------------------------------------------------------------------

    # 解析 `/cmd`、`/cmd args`、`/cmd@BotName args`，落到已注册 handler。
    #
    # **未注册 → 静默**（群里别的 bot 可能注册了同名命令；我们无权抢）。
    def handle_slash(text, chat_id:, thread_id:, message: nil)
      cmd = parse_slash(text)
      return nil if cmd.nil? || cmd.name.empty?

      handler = @handlers[cmd.name.to_sym]
      return nil if handler.nil? # 未知命令 → 静默

      run_handler(:slash, handler, command: cmd,
                                 chat_id: chat_id, thread_id: thread_id,
                                 message: message)
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
    def handle_aux(text, chat_id:, thread_id:, message: nil)
      return nil unless aux_match?(text)
      return nil unless aux_track_enabled?(chat_id, thread_id)

      handler = @handlers[:aux]
      return nil if handler.nil?

      run_handler(:aux, handler, command: nil,
                              chat_id: chat_id, thread_id: thread_id,
                              message: message,
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
    def run_handler(kind, handler, command:, chat_id:, thread_id:, message:, text: nil)
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
        user_id: user_id_of(message),
        message: message,
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
    # 只认**原始消息类**（message / edited_message / channel_post /
    # edited_channel_post / business_message / guest_message，经
    # Update#current_message 统一取出）。其余 update 类型
    # （callback_query / inline_query / my_chat_member / message_reaction …）
    # 本层**不处理**——回调查询归 T3.x 的按钮 handler。
    def extract_message(update)
      return nil if update.nil?

      message =
        if update.respond_to?(:current_message) && !update.current_message.nil?
          update.current_message
        elsif update.respond_to?(:message)
          update.message
        end

      return nil unless message.respond_to?(:text)

      message
    end

    # 群升级迁移服务消息？（§0.2.4 / §12 R5；处理归 T2.5）
    def migration_message?(message)
      return false unless message.respond_to?(:migrate_to_chat_id)

      !message.migrate_to_chat_id.nil? || !message.migrate_from_chat_id.nil?
    end

    def user_id_of(message)
      from = message.respond_to?(:from) ? message.from : nil
      from&.id&.to_i
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