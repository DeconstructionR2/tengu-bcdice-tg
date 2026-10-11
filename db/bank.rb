# frozen_string_literal: true

require "logger"

# ============================================================================
# db/bank.rb — 天狗银行（存钱/取钱 + 存道具/删道具 + 查账 + 清零，T3.2）
#
# 语义母本（**只读**，逐行对照移植）：
#   references/src/TenguDiceBot/TenguDiceBot/tengu_bank/tb_db_wrapper.js
#   references/src/TenguDiceBot/TenguDiceBot/tengu_bank/record.js
# 计划依据：§13 第 4 项（全量忠实移植）、§13 第 8 项（话题级作用域）、
# §4.1（bank_record schema）、§4.2（16 操作验收单中的 4 条银行行）。
#
# ── 天狗原义与本项目映射 ──────────────────────────────────────────────────
#   天狗：`collection 'tengu-bank'` **每 Discord 频道一份文档**（整文档读改写）。
#   本项目：§13 第 8 项拍板**话题级**——(chat_id, thread_id) 复合键即「一本账」
#   （forum 群的话题 ≈ Discord 的频道；forum 外的普通群/超级群 ≈ 群级 thread_id=0）。
#   thread 归一**复用** Settings.normalize_thread_id（E4：0/1/负数 → 群级 0），
#   不在本文件另抄一份——两处抄本必然漂移（与 router.rb 对命令集合的同款纪律）。
#
# ── 与天狗的三处**刻意**语义差异（其余逐条忠实）─────────────────────────────
#
#   ① 流水存 **JSON 数组**而非天狗的「、」分隔字符串（§4.1 定案）。
#      天狗读回时靠 `replace(/、/g, " + ").replace(/\s\+\s-/g, " - ")` 拼成
#      算式；本项目把该字符串拼装还原为 `money_flow_text`（同一份观感），
#      落库形态则是结构化数组，可断言、可按元素访问。
#   ② 删道具**元素级**：天狗是 `String(item_record).replace(item, '')`（record.js
#      之外的 tb_db_wrapper.js:38）——它删的是**首个同名子串**，故账本里
#      「ポット改、ポット」删「ポット」会连「ポット改」一起削掉（quirk）。
#      §4.1 注记要求修复：改为「删掉第一个**完全相等**的元素」。
#   ③ 金额上限：SQLite 的 `INTEGER` 列是**动态类型**（超 int64 的值会被静默
#      存成 REAL），而天狗后端是 Firestore 的 int64 字段——写超界值会被拒绝
#      → saveRecord 返回 null → 玩家看到「入力エラー」。故本文件显式做 int64
#      范围校验并回 :error（**不**让 REAL 污染 sum_money，那会让后续每次
#      `sum += money` 都变成浮点运算、且「893」彩蛋的字符串判定失真）。
#      校验点在**累加之后**（sum 才是真正要落库的值）。
#
# ── 天狗忠实保留（含「看起来像 bug 的部分」）──────────────────────────────
#   - **无透支校验**：sum_money 可为负（schema 注释即如此）。
#   - `m+0` / `m-0` → 天狗 `if (!array[1]) return error`（0 在 JS 里是 falsy）
#     → 玩家看到输入错误。本文件 `amount.zero? → :error` 同款。
#   - **首次只存道具也会开账**：天狗 saveRecord 在「无数据」分支无条件建档，
#     money=0 → money_record="0"。故「空账上第一次删道具」不会报「没有该道具」，
#     而是开出一个空账（天狗行为，本文件同样保留，见 CHANGELOG 注记）。
#   - **先删了整体输出**：天狗 getRecordResult 里 DELETE 失败会把**整条**回复
#     换成错误文案（不是追加一行）。本文件 `statement` 用同一个返回值形状复现。
#   - 未知子命令 → 天狗固定错误文案（error.replyErrorMessage，本项目中文版）。
#
# ── 纪律 ────────────────────────────────────────────────────────────────────
#   - **值一律绑定**（db/connection.rb 同款）：道具名来自用户输入。
#   - **整行读改写在事务内**（:immediate 立即取写锁，防「读→改→写」竞态；
#     sqlite 事务不可嵌套，Connection#transaction 已在事务中时直接复用外层）。
#     事务块内**只做 DB 读写**，不做日志、不做网络。
#   - 判断删没删到读 Connection#changes（execute 返回的是结果集不是行数）。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require "json"
require_relative "connection"
require_relative "settings"

module TenguDB
  # --------------------------------------------------------------------------
  # 异常类（handler 只读类名做分支，不读消息——消息可能带用户输入）
  # --------------------------------------------------------------------------

  # 金额/累加结果超出 int64（对齐天狗后端 Firestore int64 字段的拒绝行为）
  class AmountOutOfRange < StandardError; end

  # 入参不合法（chat_id=0、空道具名……）：不是「用户输错命令」而是「程序传错」
  class InvalidArgument < StandardError; end

  # --------------------------------------------------------------------------
  # BankRecord：读出来的一本账（数组字段已解析，不是 JSON 字符串）
  # --------------------------------------------------------------------------
  class BankRecord
    attr_reader :chat_id, :thread_id, :sum_money, :money_record, :item_record, :updated_at

    # @param money_record [Array<Integer>] 金额流水（天狗的「、」分隔字符串，JSON 化）
    # @param item_record  [Array<String>] 道具清单（天狗的「、」分隔字符串，JSON 化）
    def initialize(chat_id:, thread_id:, sum_money:, money_record:, item_record:, updated_at: nil)
      @chat_id = chat_id.to_i
      @thread_id = thread_id.to_i
      @sum_money = sum_money.to_i
      # dup + freeze：值对象对外不可变，调用方手滑改了也不会污染后续读
      @money_record = money_record.map { |v| v.to_i }.freeze
      @item_record = item_record.map(&:to_s).freeze
      @updated_at = updated_at.to_s
      freeze
    end

    # 天狗的 `item_record ? "**"+item+"**" : "なし"`：空账显示「无」
    def items_label(empty: "无")
      item_record.empty? ? empty : item_record.join("、")
    end

    # 天狗的流水算式：money_record.replace(/、/g, " + ").replace(/\s\+\s-/g, " - ")
    #
    # 负数连排时 `100 + -50` 会变成 `100 - 50`（天狗的观感），本方法同一结果。
    #
    # @return [String, nil] nil = 无流水（天狗 `if (result.money_record)` 的假值分支，
    #   对应「空字符串/空数组」）
    def money_flow_text
      return nil if money_record.empty?

      money_record.map(&:to_s).join(" + ").gsub(/\s\+\s-/, " - ")
    end

    # 天狗 `deleteRecord` 的文案按作用域（天狗只有「チャンネル内」一种）
    def scope_label
      thread_id > Settings::GENERAL_THREAD_ID ? "本话题" : "本群"
    end

    def to_h
      { chat_id: chat_id, thread_id: thread_id, sum_money: sum_money,
        money_record: money_record, item_record: item_record, updated_at: updated_at }
    end
  end

  # --------------------------------------------------------------------------
  # SaveResult：save_record 的三态返回值（不抛异常给 handler 分支用）
  # --------------------------------------------------------------------------
  class SaveResult
    OK = :ok
    ITEM_MISSING = :item_missing  # 删道具时账上没有这一件（天狗 saveRecord → null）
    ERROR = :error                # 入参/范围/存储层失败（天狗同样回 null）

    attr_reader :record, :error

    def initialize(status, record: nil, error: nil)
      @status = status
      @record = record
      @error = error
      freeze
    end

    def self.ok(record)
      new(OK, record: record)
    end

    # 天狗 record.js `if (!result) return "そのアイテムの記録はありません。"`
    def self.item_missing
      new(ITEM_MISSING)
    end

    def self.error(error_class)
      new(ERROR, error: error_class)
    end

    def status
      @status
    end

    def ok?
      @status == OK
    end

    def item_missing?
      @status == ITEM_MISSING
    end

    def error?
      @status == ERROR
    end

    def to_h
      { status: @status, record: record&.to_h, error: @error }
    end
  end

  # --------------------------------------------------------------------------
  # Bank：bank_record 的存取（天狗 4 操作）
  # --------------------------------------------------------------------------
  class Bank
    # int64 上界/下界（Firestore 的整数字段边界；SQLite INTEGER 列同理）
    INT64_MAX = 9_223_372_036_854_775_807
    INT64_MIN = -9_223_372_036_854_775_808

    COLUMNS = "chat_id, thread_id, sum_money, money_record, item_record, updated_at"

    # @param connection [TenguDB::Connection, nil] nil = DB 层单连接
    # @param logger [#warn, nil] 只记结构性信息（异常类名），绝不记用户输入
    def initialize(connection = nil, logger: ::Logger.new($stderr))
      @conn = connection || Connection.instance
      @logger = logger
    end

    # 群级作用域的 thread_id（E4：forum General 话题恒为 1，与群级 0 同义）
    GROUP_THREAD_ID = Settings::GROUP_THREAD_ID

    # thread 归一（**唯一实现在 Settings**，此处只做转发——见文件头部①）
    def self.normalize_thread_id(thread_id)
      Settings.normalize_thread_id(thread_id)
    end

    # ------------------------------------------------------------------
    # 天狗 4 操作
    # ------------------------------------------------------------------

    # 查账（天狗 getRecord）
    #
    # @return [BankRecord, nil]
    def fetch(chat_id:, thread_id: nil)
      chat = normalize_chat_id(chat_id)
      return nil if chat.nil?

      row = conn.get_first_hash(
        "SELECT #{COLUMNS} FROM bank_record WHERE chat_id = ? AND thread_id = ?",
        [chat, self.class.normalize_thread_id(thread_id)]
      )
      return nil if row.nil?

      to_record(row)
    end

    # 存钱 / 取钱（天狗 recordMoney → saveRecord{money}）
    #
    # @param amount [Integer] **已带符号**：正 = 存入，负 = 取出
    # @return [SaveResult]
    def save_money(chat_id:, thread_id: nil, amount:)
      save_record(chat_id: chat_id, thread_id: thread_id, money: amount.to_i)
    end

    # 存道具（天狗 recordItem → saveRecord{item, isItemAdd: true}）
    def add_item(chat_id:, thread_id: nil, name:)
      save_record(chat_id: chat_id, thread_id: thread_id, item: name, add_item: true)
    end

    # 删道具（天狗 recordItem → saveRecord{item, isItemAdd: false}）
    def remove_item(chat_id:, thread_id: nil, name:)
      save_record(chat_id: chat_id, thread_id: thread_id, item: name, add_item: false)
    end

    # 清零（天狗 delete / deleteRecord）
    #
    # **返回值语义**：天狗 deleteChannel 分「成功/失败」两态，文案二选一
    # （`チャンネル内の記録をリセットしました。` / `…チャンネルの削除に失敗しました。`），
    # 而 Firestore 删除**不存在**的文档也算成功。本项目对齐该语义：
    # 「删掉了一行」与「本来就没有行」**都是成功**（均回 true，玩家看到
    # 「已重置」——对一个空账说「重置成功」不构成误导）。
    # 真正的 DB 故障**抛异常**（不返回 false）：这样它经 router 的兜底留下
    # 结构化日志，而不是变成一句没人看的 false。handler 里的失败分支据此
    # 真实可达（注入假 bank 即可触发，见 test_bank_handler_test.rb）。
    #
    # @return [true] 恒 true；DB 故障时抛异常而非返回 false
    def clear(chat_id:, thread_id: nil)
      chat = normalize_chat_id(chat_id)
      raise InvalidArgument, "chat_id" if chat.nil?

      conn.execute(
        "DELETE FROM bank_record WHERE chat_id = ? AND thread_id = ?",
        [chat, self.class.normalize_thread_id(thread_id)]
      )
      true
    end

    # 结算：查账出流水 **并立即清零**（天狗 getRecordResult，result/end 两入口共用）
    #
    # 天狗的顺序是「先读 → 出报表 → 再删」，且账本不存在时**直接早退不删**。
    # 删除失败时整条输出退化为错误文案（也在返回值里体现：deleted=false）。
    #
    # @return [Array(BankRecord, Boolean, Boolean)] [账本(nil=查无此账), 是否查到了账, 是否查不到=false 时不必看]
    def statement(chat_id:, thread_id: nil)
      chat = normalize_chat_id(chat_id)
      raise InvalidArgument, "chat_id" if chat.nil?

      # 读→删同样必须在事务内（kimi T3.2 评审提案 #1）：否则并发下 fetch 与
      # DELETE 之间落入的存款会被静默清掉、且不出现在报表里。单线程轮询虽
      # 不触发，但本文件头部自立「整行读改写在事务内」的纪律要对 statement 成立。
      # 块内不 return（sqlite3 transaction 的 ensure commit 陷阱），赋值出块。
      outcome = nil
      conn.transaction(:immediate) do
        record = fetch(chat_id: chat, thread_id: thread_id)
        if record.nil?
          outcome = [nil, false, false] # 天狗：查无记录 → 早退，不做删除
        else
          # 真删；DB 故障在这里抛异常（handler/router 兜底），不吞
          conn.execute(
            "DELETE FROM bank_record WHERE chat_id = ? AND thread_id = ?",
            [chat, self.class.normalize_thread_id(thread_id)]
          )
          outcome = [record, true, true]
        end
      end
      outcome
    end

    # ------------------------------------------------------------------
    # 天狗 saveRecord 的逐行移植（上面四个操作的共同底座）
    # ------------------------------------------------------------------
    #
    # 天狗（tb_db_wrapper.js:11-53）：
    #   无数据 → 建档 {sum_money: money, money_record: String(money), item_record: item||""}
    #   有数据 → sum += money；money != 0 时追加流水；
    #             isItemAdd → 追加道具；否则按「首个子串」删除（quirk，见头部②）
    #
    # @param money    [Integer] 金额增量（0 = 只动道具）
    # @param item     [String, nil] 道具名（nil = 只动钱）
    # @param add_item [Boolean] true = 存入道具，false = 删道具
    # @return [SaveResult]
    def save_record(chat_id:, thread_id: nil, money: 0, item: nil, add_item: true)
      chat = normalize_chat_id(chat_id)
      return SaveResult.error(InvalidArgument) if chat.nil?

      thread = self.class.normalize_thread_id(thread_id)
      amount = money.to_i
      # 天狗的入参在 record.js 层就被 `if (!array[1]) return error` 拦掉 0 与空；
      # 本层只拦「int64 越界」（0 留给 handler 按天狗语义拒绝，那里有文案）。
      return SaveResult.error(AmountOutOfRange) unless within_int64?(amount)

      item_name = normalize_item(item)
      # 删道具必须给得出名字（空名 = 无从删起）；存道具可以不给（nil = 只动钱）
      return SaveResult.error(InvalidArgument) if !add_item && item_name.nil?

      # ⚠️ 事务块内**绝不 return**：sqlite3 的 transaction 是
      # 「BEGIN → yield → ensure 里 commit/rollback」，块内 return 走的是
      # **正常**路径（ensure 里 commit）→ 半截改动被提交。故块内只赋值
      # outcome，出块后再 return。
      outcome = nil
      # kimi T3.2 评审提案 #4：返回值用事务内**已算好的**字段直接构造，
      # 不做提交后的二次 fetch——省一次 SELECT，也消掉「并发下 fetch 得 nil →
      # SaveResult.ok(nil) → handler NoMethodError」的面。
      saved = nil
      begin
        conn.transaction(:immediate) do
          row = conn.get_first_hash(
            "SELECT #{COLUMNS} FROM bank_record WHERE chat_id = ? AND thread_id = ?",
            [chat, thread]
          )

          if row.nil?
            # 天狗「データなし、新規作成」分支：**无条件建档**（连只删道具也开账）
            initial_items = item_name ? [item_name] : []
            insert_row(chat, thread, amount, [amount], initial_items)
            saved = BankRecord.new(chat_id: chat, thread_id: thread, sum_money: amount,
                                   money_record: [amount], item_record: initial_items)
            outcome = SaveResult::OK
          else
            current = to_record(row)
            sum = current.sum_money + amount
            outcome = SaveResult::ERROR unless within_int64?(sum)

            if outcome.nil?
              flow = current.money_record.dup
              flow << amount unless amount.zero? # 天狗 `if (money != 0)`

              items = current.item_record.dup
              if add_item
                items << item_name unless item_name.nil?
              else
                # 天狗 checkRecSplit：账上没有**完全相等**的元素就不删（回 null）
                idx = items.index(item_name)
                if idx.nil?
                  outcome = SaveResult::ITEM_MISSING
                else
                  # 天狗这里是 `String(item_record).replace(item, '')`：删首个**子串**，
                  # 故「ポット改、ポット」删「ポット」会削掉「ポット改」——quirk。
                  # §4.1 定案：元素级删除，只摘掉那一个元素（头部②）。
                  items.delete_at(idx)
                end
              end

              if outcome.nil?
                update_row(chat, thread, sum, flow, items)
                saved = BankRecord.new(chat_id: chat, thread_id: thread, sum_money: sum,
                                       money_record: flow, item_record: items)
              end
            end
            outcome ||= SaveResult::OK
          end
        end
      rescue SQLite3::Exception => e
        # 天狗 saveRecord 的 .catch(() => null) → 玩家看到输入错误。
        # 异常穿出 transaction 时 sqlite3 已在 ensure 里回滚整笔（我们没写过
        # 半截：两个早退分支都在写之前就定了 outcome）。
        # kimi T3.2 评审提案 #5：锁竞争（BusyException）被译成「输入有误」会误导
        # 排障——单独留一条结构性 warn（只有异常类名，不含任何用户输入）。
        warn_line("[bank] 存储层锁竞争：#{e.class}") if e.is_a?(SQLite3::BusyException)
        return SaveResult.error(e.class)
      end

      return SaveResult.error(AmountOutOfRange) if outcome == SaveResult::ERROR
      return SaveResult.item_missing if outcome == SaveResult::ITEM_MISSING

      SaveResult.ok(saved)
    end

    # 该 (chat, thread) 名下的行数（诊断/测试用）
    def count_for(chat_id:, thread_id: nil)
      conn.get_first_value(
        "SELECT count(*) FROM bank_record WHERE chat_id = ? AND thread_id = ?",
        [chat_id.to_i, self.class.normalize_thread_id(thread_id)]
      ).to_i
    end

    private

    attr_reader :conn

    # 天狗拿到的是 Firebase 的 Collection→Doc（频道 id 为键）；Telegram 的
    # chat_id 可超 32 位有效位（§0.2.4），故一律 to_i 且**拒绝 0**——
    # Ruby 里 0 是真值，不拦会把行写到 chat_id=0 这个黑洞里
    # （与 bot/migration.rb 的 0 守卫同款纪律）。
    def normalize_chat_id(chat_id)
      return nil if chat_id.nil?
      return nil if chat_id.is_a?(String) && chat_id.strip.empty?

      id = chat_id.to_i
      id.zero? ? nil : id
    end

    def within_int64?(value)
      value.between?(INT64_MIN, INT64_MAX)
    end

    # 天狗 `item ? String(item) : ""`：空串在 JS 里 falsy → 等价于「没有道具」。
    # 「删道具」路径下空名没有意义（会退化成删第一个元素），故交由调用方守卫。
    def normalize_item(item)
      return nil if item.nil?

      name = item.to_s
      name.empty? ? nil : name
    end

    def insert_row(chat, thread, sum, flow, items)
      conn.execute(
        "INSERT INTO bank_record (chat_id, thread_id, sum_money, money_record, item_record, " \
        "updated_at) VALUES (?, ?, ?, ?, ?, datetime('now'))",
        [chat, thread, sum, JSON.generate(flow), JSON.generate(items)]
      )
    end

    def update_row(chat, thread, sum, flow, items)
      conn.execute(
        "UPDATE bank_record SET sum_money = ?, money_record = ?, item_record = ?, " \
        "updated_at = datetime('now') WHERE chat_id = ? AND thread_id = ?",
        [sum, JSON.generate(flow), JSON.generate(items), chat, thread]
      )
    end

    def to_record(row)
      BankRecord.new(
        chat_id: row["chat_id"],
        thread_id: row["thread_id"],
        sum_money: row["sum_money"],
        money_record: parse_array(row["money_record"]),
        item_record: parse_array(row["item_record"]),
        updated_at: row["updated_at"]
      )
    end

    # JSON 列解析。**容错**：列是 TEXT，人工灌过库或旧版本写坏时不能让整本账
    # 读不出来（回退成空数组 = 那段流水当没有）。解析失败只 warn，不上抛——
    # 上抛会让「查账」变成「bot 报错」，而用户要的是看到现有余额。
    def parse_array(raw)
      text = raw.to_s
      return [] if text.empty?

      parsed = JSON.parse(text)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      warn_line("[bank] 流水列不是合法 JSON，按空数组处理")
      []
    end

    def warn_line(message)
      @logger.warn(message)
    rescue StandardError
      nil
    end
  end
end