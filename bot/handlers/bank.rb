# frozen_string_literal: true

# ============================================================================
# bot/handlers/bank.rb — 天狗银行 /bank（T3.2，计划 §5 / §6 / §8 T3.2）
#
# slash 主轨，纯文本、无按钮（§13 第 7 项），handler **返回 String 由 router 代发**
# （契约见 bot/router.rb run_handler）——与 /secret 相反：银行是公开账本，
# 结果本来就该全群可见，没有「绝不经 router 代发」的命门。
#
# ── 子命令映射（全部从 tengu_bank/record.js 的操作集推导，纯 ASCII）──────────
#
#   天狗 `/tb <操作>`（discord_command/tb.js 只是把 option 透传给
#   `Record.receiveResponce`，操作集与语义全在 record.js 的 switch 里）：
#
#   | 本项目 /bank 子命令       | record.js 操作 | 天狗写法        |
#   |---------------------------|----------------|-----------------|
#   | deposit  <金额>            | `m+N` → recordMoney | `m+100`   |
#   | withdraw <金额>            | `m-N` → recordMoney | `m-50`    |
#   | item add <道具名>          | `i+名字` → recordItem(isItemAdd=true)  | `i+茶` |
#   | item del <道具名>          | `i-名字` → recordItem(isItemAdd=false) | `i-茶` |
#   | balance                   | `check` → getRecord            | `check`   |
#   | statement                 | `result`/`end` → getRecordResult | `result` |
#   | reset                     | `reset`/`delete` → deleteRecord | `reset`  |
#   | help                      | （天狗无；usage 落到 default 错误分支）| —        |
#
#   天狗的 `reset` 与 `delete`、`result` 与 `end` 是**同义别名**（两个 case
#   落到同一个函数）。本项目**只留一个**（reset / statement）：同义别名在纯
#   ASCII 命令表里是维护负担（改一处忘另一处），而 Telegram 菜单只有一条
#   /bank 描述，用户按 /help 的指路写得出正确形式。
#
#   天狗没有、本项目补的一个入口：**无参 /bank → 用法表**（Telegram 只有一条
#   /bank 菜单描述，用户没有 fnd 说明书可查；不给用法表就是「用户打了没反应」，
#   正是 T2.6 真机验收踩过的坑）。其余不加别名：`check`↔`balance`、
#   `result`↔`statement` 已是一一对应，再加第三个名字只会增加歧义——
#   而 record.js 的 `check`（查账**不动**账）与 `result`（出流水并**清零**）
#   是两个语义不同的动作，名字必须能把它们区分开，故 balance/statement 都留。
#
# ── 金额解析（逐字忠实 record.js splitRequest）─────────────────────────────
#   天狗用正则 `/^m\+(\d+)$/`、`/^m-\d+$/`：**只收无符号纯数字**（`+`/`-`
#   是操作符、不是金额的符号），`parseInt` 后再进 saveRecord。故本项目：
#     - 只接受 `\d+`（ASCII 数字串）；符号**只由动词** deposit/withdraw 决定；
#     - 带符号金额 / 小数 / 千分位 / 全角数字 / 十六进制一律**输入错误**
#       （天狗的正则同样不匹配，落 default 分支）；
#     - 0（`deposit 0` / `withdraw 0`）→ 输入错误：JS 的 `if (!array[1])`
#       把 0 当 falsy 拦掉，这是天狗的原样行为，不是本项目的额外校验。
#     - 超 int64 → 输入错误（天狗后端 Firestore int64 会拒绝，回 null → 同一文案）。
#     - **透支允许**：`withdraw 9999` 余额 100 → 余额 -9899（schema 注释即如此）。
#
# ── 893 彩蛋（record.js change893）─────────────────────────────────────
#   天狗：`String(money).indexOf("893") !== -1` → 金额两侧包上 `:japanese_goblin:`。
#   注意它判的是**字符串包含**，不是数值等于 893：余额 1893 / 8930 / -893 都命中。
#   本项目保留字符串语义（`sum_money.to_s.include?("893")`），但**装饰字符换成
#   纯文本标记**（§13 第 7 项：本项目第一版纯文本、不做富格式转换，而 Discord
#   的 `:japanese_goblin:` 自定义 emoji 语法在 Telegram 里不会被渲染成图案）。
#   → 用「👺」包住金额。天狗的自定义 emoji 在 Discord 里**会**渲染成小怪图案，
#   本项目用 Unicode 同义字符保留「金额两侧出现小怪」的观感。
#   文案逐条对照：
#     天狗 迁出前 : 万札を更新しました。現万札：**N**  アイテム：…
#     本项目      : 已更新万札。现万札：N  道具：…
#
# ── 作用域 ────────────────────────────────────────────────────────────────
#   (chat_id, thread_id) 话题级（§13 第 8 项），归一规则复用 db/settings.rb
#   （E4：0/1/负数 → 群级）。回发时 thread_id 由 router 透传入站原值——
#   本 handler **不**自己发消息，故不碰 thread_id 归一（与 T3.1 的 0→nil
#   守卫同源，但那是「自己发消息」才有的坑；代发路径的 thread 透传在 router 里）。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require_relative "../../db/bank"

module TelegramBot
  module Handlers
    # ----------------------------------------------------------------------
    # BankHandler
    # ----------------------------------------------------------------------
    class BankHandler
      # 无参 /bank 的用法表（含每个子命令→天狗操作的对照，注释即文档）
      USAGE = <<~USAGE.chomp
        天狗银行（每个话题一本账，话题之间互不相通）
        /bank deposit <金额> — 存钱，例：/bank deposit 100
        /bank withdraw <金额> — 取钱，例：/bank withdraw 50（可透支，余额可为负）
        /bank item add <道具名> — 存道具，例：/bank item add 茶
        /bank item del <道具名> — 取出道具，例：/bank item del 茶
        /bank balance — 查账（余额+道具+出入金流水，不动账）
        /bank statement — 出结算（出入金流水算式），**出完即清零**
        /bank reset — 清空本话题的账（余额、道具、流水全部清空）
      USAGE

      # 天狗 error.replyErrorMessage() 的中文版（未知子命令/金额非法共用一条）
      BAD_INPUT = "输入有误，请按 /bank help 的用法重新输入。"

      # 余额/道具的固定呈现（天狗 `現万札：**N**  アイテム：…` 的中文版）
      #   N 会过 893 彩蛋（可能变成 👺  -893  👺）
      def self.balance_line(record)
        "现万札：#{change893(record.sum_money)}  道具：#{record.item_record.empty? ? '无' : record.item_record.join('、')}"
      end

      # 天狗 change893：金额串**含** "893" 就被小怪包起来（含 1893/8930/-893）。
      # 装饰用 👺（Telegram 里 :japanese_goblin: 不渲染，纯文本 Unicode 更保真）。
      def self.change893(money)
        text = money.to_i.to_s
        return text unless text.include?("893")

        "👺  #{text}  👺"
      end

      # @param bank [TenguDB::Bank, nil] nil = DB 层单连接
      # @param logger [#warn, nil] 只记结构性信息，绝不记用户正文（道具名是用户输入）
      def initialize(bank: nil, logger: $stderr)
        @bank = bank
        @logger = logger
      end

      # 懒加载：注入了假 bank 的用例完全不碰 SQLite
      def bank
        @bank ||= TenguDB::Bank.new
      end

      # router 的 handler 注册表接口
      def self.registry(handler = new)
        { bank: handler }
      end

      # ------------------------------------------------------------------
      # 统一入口（返回 String = 由 router 代发；nil = 静默）
      # ------------------------------------------------------------------
      def call(context)
        return nil unless context[:name].to_s == "bank"

        args = context[:args].to_s.strip
        return USAGE if args.empty?

        chat_id = context[:chat_id].to_i
        # 拿不到 chat_id → 归不到任何一本账；静默（不该发生：入站消息必有 chat）
        return nil if chat_id.zero?

        thread_id = context[:thread_id]
        verb, rest = split_verb(args)

        case verb
        when "deposit" then handle_money(chat_id, thread_id, rest, +1)
        when "withdraw" then handle_money(chat_id, thread_id, rest, -1)
        when "item" then handle_item(chat_id, thread_id, rest)
        when "balance" then handle_balance(chat_id, thread_id)
        when "statement" then handle_statement(chat_id, thread_id)
        when "reset" then handle_reset(chat_id, thread_id)
        when "help" then USAGE
        else BAD_INPUT
        end
      end

      private

      # 天狗 receiveResponce 先 `content.replace(/\s+/g, "")` 去掉全部空白，
      # 再按正则匹配操作。本项目等价做法：切出动词后**只取第一个参数 token**，
      # 其余部分留给道具名（道具名可含空格——天狗的 `i+.+` 也允许）。
      def split_verb(args)
        verb, rest = args.split(/\s+/, 2)
        [verb.to_s.downcase, rest.to_s.strip]
      end

      # ------------------------------------------------------------------
      # 存钱 / 取钱（天狗 recordMoney → m+N / m-N）
      # ------------------------------------------------------------------
      #
      # 符号**只由动词决定**：天狗的正则 `/^m\+(\d+)$/` 与 `/^m-\d+$/` 里，
      # `+`/`-` 是操作的一部分，金额本身只能是**无符号**数字串。故
      # `deposit -50` / `withdraw -50` 都不匹配天狗的任一正则 → 落到 default
      # 分支回输入错误；`withdraw -50` 尤其不能被当成「存 50」而偷偷反向入账。
      def handle_money(chat_id, thread_id, rest, sign)
        amount = parse_amount(rest)
        return BAD_INPUT if amount.nil? || amount.zero? # 0 = 天狗的 falsy 分支

        result = bank.save_money(chat_id: chat_id, thread_id: thread_id,
                                 amount: amount * sign)
        return render_save_result(result) unless result.ok?

        "已更新万札。#{self.class.balance_line(result.record)}"
      end

      # ------------------------------------------------------------------
      # 存道具 / 删道具（天狗 recordItem → i+名字 / i-名字）
      # ------------------------------------------------------------------
      def handle_item(chat_id, thread_id, rest)
        action, name = rest.split(/\s+/, 2)
        name = name.to_s.strip
        return BAD_INPUT if name.empty?

        result =
          case action.to_s.downcase
          when "add" then bank.add_item(chat_id: chat_id, thread_id: thread_id, name: name)
          when "del", "delete", "remove" then bank.remove_item(chat_id: chat_id, thread_id: thread_id, name: name)
          else return BAD_INPUT
          end

        return render_save_result(result) unless result.ok?

        "道具已更新。#{self.class.balance_line(result.record)}"
      end

      # ------------------------------------------------------------------
      # 查账（天狗 getRecord ← `check`）：**不动账**
      # ------------------------------------------------------------------
      def handle_balance(chat_id, thread_id)
        record = bank.fetch(chat_id: chat_id, thread_id: thread_id)
        return "本#{record_scope(thread_id)}内没有找到银行的记录。" if record.nil?

        text = +"当前状况…… #{self.class.balance_line(record)}"
        flow = record.money_flow_text
        text << "\n出入金记录：#{flow} = #{self.class.change893(record.sum_money)}" unless flow.nil?
        text
      end

      # ------------------------------------------------------------------
      # 结算（天狗 getRecordResult ← `result`/`end`）：出流水后**清零**
      # ------------------------------------------------------------------
      def handle_statement(chat_id, thread_id)
        record, attempted, deleted = bank.statement(chat_id: chat_id, thread_id: thread_id)

        unless attempted
          return "本#{record_scope(thread_id)}内没有找到银行的记录。"
        end

        # 天狗：DELETE 失败时把**整条**输出换成错误文案，不是追加一行。
        # 真 DB 故障时 db/bank.rb 走的是**抛异常**（router 兜底 + 结构化日志），
        # 所以这里的 false 只在注入了会失败的 bank 时出现（测试可达）。保留
        # 分支而不是让它恒真：一旦日后 DB 层改成「返回 false」表达故障，handler
        # 已备好用户可见的失败文案，不会把「没清掉」静默说成「已重置」。
        unless deleted
          warn_line("[bank] 结算清零失败（chat_id=#{chat_id}）")
          return "清零失败，账目未被重置。请稍后再试。"
        end

        text = +"结果…… #{self.class.balance_line(record)}"
        flow = record.money_flow_text
        text << "\n出入金记录：#{flow} = #{self.class.change893(record.sum_money)}" unless flow.nil?
        text << "\n\n#{reset_notice(record_scope(thread_id))}"
        text
      end

      # ------------------------------------------------------------------
      # 清零（天狗 deleteRecord ← `reset`/`delete`）
      # ------------------------------------------------------------------
      def handle_reset(chat_id, thread_id)
        bank.clear(chat_id: chat_id, thread_id: thread_id)
        reset_notice(record_scope(thread_id))
      end

      # 天狗 deleteRecord 的「チャンネル内の記録をリセットしました。」中文版
      def reset_notice(scope)
        "已重置#{scope}内的记录。"
      end

      def record_scope(thread_id)
        TenguDB::Bank.normalize_thread_id(thread_id) > TenguDB::Settings::GENERAL_THREAD_ID ? "本话题" : "本群"
      end

      # 天狗 saveRecord 的两态回显（recordMoney / recordItem 的头部判断）
      def render_save_result(result)
        return "账上没有这件道具的记录。" if result.item_missing?

        BAD_INPUT
      end

      # 金额解析（逐字忠实 record.js 的 /^m[+-]\d+$/ + parseInt）
      #
      # 只接受**无符号**数字串：\d+（天狗的两条正则里 `+`/`-` 是操作符，
      # 金额本身没有符号；`deposit -50` 在天狗那里落 default → 输入错误）。
      # 小数 / 千分位 / 「1e5」/ 全角数字 / 前后缀一律 nil（天狗正则同样不匹配）。
      def parse_amount(text)
        s = text.to_s.strip
        return nil unless /\A\d+\z/.match?(s)

        s.to_i
      end

      def warn_line(message)
        @logger.warn(message)
      rescue StandardError
        nil
      end
    end
  end
end