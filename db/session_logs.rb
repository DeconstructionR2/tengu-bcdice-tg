# frozen_string_literal: true

require "logger"

# ============================================================================
# db/session_logs.rb — 跑团 log 录制（T3.5，计划 §4.1 / §13 第 6 项 / §12 R8）
#
# 两张表（schema.sql 已建，本文件不碰 DDL）：
#   session_logs   一次录制（chat_id, thread_id, name, status, created_at, ended_at）
#   log_entries    一条条目（log_id, seq, sender_name, user_id, is_bot, msg_kind,
#                  content, created_at）
#
# ── 作用域与状态机 ──────────────────────────────────────────────────────────
#   作用域 = (chat_id, thread_id) 话题级——与 chat_settings / bank_record 同尺度。
#   thread 归一**复用 Settings.normalize_thread_id**（E4：0/1/负数 → 群级 0），
#   不在本文件另抄一份——两处抄本必然漂移（同 bank.rb 纪律）。
#
#   状态机（schema 的 CHECK 约束）：
#       （无）──start──▶ recording ──pause──▶ paused ──resume──▶ recording
#                            │                 │
#                            └──── finish ─────┘──▶ ended（终态）
#   「进行中」= recording | paused（active）。**同一作用域同时只允许一个进行中**：
#   start 遇到进行中的录制回 :already_active（不静默覆盖——用户要求「多团并行」
#   时先 /log end 旧的，语义显式；也保证录制挂钩「找到唯一在录的」无歧义）。
#   ended 是终态：finish 之后 start 开新的，旧记录留在库里供 /log list 查。
#
# ── seq（导出排序依据）──────────────────────────────────────────────────────
#   seq 是**日志内序号**，append_entry 在 :immediate 事务内
#   `COALESCE(MAX(seq),0)+1` 现算。单连接 + Monitor（db/connection.rb）本已串行，
#   事务是第二道保险（同 T3.2「整行读改写在事务内」纪律：防将来有人并发调用）。
#
# ── 群升级 re-key ───────────────────────────────────────────────────────────
#   session_logs 含 chat_id，**已在 bot/migration.rb 的 Migration::TABLES 内**
#   （T2.5 建清单时就全量登记过；test_migration_test.rb 有反射守卫钉住）。群升级
#   后本表行随新 chat_id 走；log_entries 没有 chat_id 列，靠 log_id 外键挂在
#   session_logs 上，天然跟着走、不需要 UPDATE。
#
# ── 纪律 ────────────────────────────────────────────────────────────────────
#   - **值一律绑定**：sender_name / content 都是用户输入。
#   - 事务块内**绝不 return**（sqlite3 的 transaction 是 BEGIN→yield→ensure 里
#     commit——块内 return 走正常路径会被**提交**）：一律赋值出块（同 bank.rb）。
#   - 判断「有没有行」看查询结果，不用 execute 的返回值。
#   - log_entries.log_id 的 REFERENCES 由连接层的 `PRAGMA foreign_keys=ON`
#     强制（§15.5 E10）；append 到不存在的 log 会抛 ConstraintException——
#     调用方（recorder/router）自行兜底，本层不吞。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require_relative "connection"
require_relative "settings"

module TenguDB
  # --------------------------------------------------------------------------
  # 值对象：一次录制
  # --------------------------------------------------------------------------
  class SessionLog
    STATUS_LABELS = {
      "recording" => "录制中",
      "paused" => "已暂停",
      "ended" => "已结束"
    }.freeze

    attr_reader :id, :chat_id, :thread_id, :name, :status, :created_at, :ended_at, :entry_count

    # @param entry_count [Integer, nil] 条目数（list 查询带出；其余路径为 nil）
    def initialize(id:, chat_id:, thread_id:, name:, status:, created_at: nil,
                   ended_at: nil, entry_count: nil)
      @id = id.to_i
      @chat_id = chat_id.to_i
      @thread_id = thread_id.to_i
      @name = name.to_s
      @status = status.to_s
      @created_at = created_at.to_s
      @ended_at = ended_at.nil? ? nil : ended_at.to_s
      @entry_count = entry_count.nil? ? nil : entry_count.to_i
      freeze
    end

    def recording?
      status == SessionLogs::STATUS_RECORDING
    end

    def paused?
      status == SessionLogs::STATUS_PAUSED
    end

    def ended?
      status == SessionLogs::STATUS_ENDED
    end

    # 进行中（录制中或已暂停）——start 的互斥判据、状态机操作的目标集合
    def active?
      recording? || paused?
    end

    def status_label
      STATUS_LABELS.fetch(status, status)
    end

    # 作用域显示词（回给用户的文案用；与 bank.rb 同款判据）
    def scope_label
      thread_id > Settings::GENERAL_THREAD_ID ? "本话题" : "本群"
    end

    def to_h
      { id: id, chat_id: chat_id, thread_id: thread_id, name: name, status: status,
        created_at: created_at, ended_at: ended_at, entry_count: entry_count }
    end
  end

  # --------------------------------------------------------------------------
  # 值对象：一条条目
  # --------------------------------------------------------------------------
  class LogEntry
    attr_reader :id, :log_id, :seq, :sender_name, :user_id, :is_bot, :msg_kind,
                :content, :created_at

    def initialize(id: nil, log_id: nil, seq:, sender_name:, user_id: nil,
                   is_bot: 0, msg_kind: "text", content:, created_at: nil)
      @id = id.nil? ? nil : id.to_i
      @log_id = log_id.nil? ? nil : log_id.to_i
      @seq = seq.to_i
      @sender_name = sender_name.to_s
      @user_id = user_id.nil? ? nil : user_id.to_i
      @is_bot = is_bot.to_i
      @msg_kind = msg_kind.to_s
      @content = content.to_s
      @created_at = created_at.to_s
      freeze
    end

    def bot?
      @is_bot == 1
    end

    def to_h
      { seq: seq, sender_name: sender_name, user_id: user_id, is_bot: bot?,
        msg_kind: msg_kind, content: content, created_at: created_at }
    end
  end

  # --------------------------------------------------------------------------
  # LogResult：状态机操作的返回值（不抛异常给调用方分支用）
  # --------------------------------------------------------------------------
  class LogResult
    OK = :ok
    NO_ACTIVE = :no_active            # 该作用域没有进行中的录制
    ALREADY_ACTIVE = :already_active  # start 时已有进行中录制（log 带出那一条）
    ALREADY_PAUSED = :already_paused
    ALREADY_RECORDING = :already_recording
    INVALID_NAME = :invalid_name      # 名字为空/过长/含控制字符
    INVALID_ARGUMENT = :invalid_argument

    attr_reader :status, :log

    def initialize(status, log: nil)
      @status = status
      @log = log
      freeze
    end

    def self.ok(log)
      new(OK, log: log)
    end

    def self.no_active
      new(NO_ACTIVE)
    end

    def self.already_active(log)
      new(ALREADY_ACTIVE, log: log)
    end

    def self.already_paused(log)
      new(ALREADY_PAUSED, log: log)
    end

    def self.already_recording(log)
      new(ALREADY_RECORDING, log: log)
    end

    def self.invalid_name
      new(INVALID_NAME)
    end

    def self.invalid_argument
      new(INVALID_ARGUMENT)
    end

    def ok?
      @status == OK
    end

    def to_h
      { status: @status, log: log&.to_h }
    end
  end

  # --------------------------------------------------------------------------
  # SessionLogs：两张表的存取
  # --------------------------------------------------------------------------
  class SessionLogs
    STATUS_RECORDING = "recording"
    STATUS_PAUSED = "paused"
    STATUS_ENDED = "ended"
    ACTIVE_STATUSES = [STATUS_RECORDING, STATUS_PAUSED].freeze

    # 名字上限（实现级决策）：名字会进回显文案与导出文件头部，不设上限等于
    # 允许几千字的标题刷屏；100 字符对「第一次跑团/XX战役#3」绰绰有余。
    MAX_NAME_LENGTH = 100

    # int64 上下界（SQLite INTEGER 列是动态类型，超界值会被静默存成 REAL、精度
    # 损失——同 db/custom_tables.rb / db/bank.rb 的守卫口径。界含 INT64_MIN：
    # 它是合法 int64、SQLite 存得住，2026-10-12 三审统一四文件口径）
    INT64_MAX = 9_223_372_036_854_775_807
    INT64_MIN = -9_223_372_036_854_775_808

    # 单个 log 的条目上限（2026-10-18 审核：此前既无保留期也无上限，
    # `/log new` 后忘记 end 就会每条群消息永久入库，导出时全量读入内存）。
    # 取 seq 现算值做判据（seq 单调递增且不删除），不额外查 count。
    # 20000 条 ≈ 一个长期战役数周的量；超出时录制停写并 warn 一次。
    MAX_ENTRIES = 20_000

    LOG_COLUMNS = "id, chat_id, thread_id, name, status, created_at, ended_at"
    # list 是 JOIN 式查询（session_logs + 条目数子查询），列必须带表前缀
    LOG_COLUMNS_QUALIFIED = "l.id, l.chat_id, l.thread_id, l.name, l.status, " \
                            "l.created_at, l.ended_at"
    ENTRY_COLUMNS = "id, log_id, seq, sender_name, user_id, is_bot, msg_kind, content, created_at"

    # @param connection [TenguDB::Connection, nil] nil = DB 层单连接
    # @param logger [#warn, nil] 只记结构性信息（异常类名），绝不记用户正文
    def initialize(connection = nil, logger: ::Logger.new($stderr))
      @conn = connection || Connection.instance
      @logger = logger
      @cap_warned = {}
    end

    # thread 归一（**唯一实现在 Settings**，此处只做转发——同 bank.rb）
    def self.normalize_thread_id(thread_id)
      Settings.normalize_thread_id(thread_id)
    end

    # ------------------------------------------------------------------
    # 读
    # ------------------------------------------------------------------

    # 按 id 取一条（含已结束的）
    def find(id)
      row = conn.get_first_hash(
        "SELECT #{LOG_COLUMNS} FROM session_logs WHERE id = ?", [id.to_i]
      )
      row.nil? ? nil : to_log(row)
    end

    # 该作用域**进行中**的录制（recording 或 paused）；多条时取最新一条
    # （start 的互斥保证最多一条，ORDER BY LIMIT 1 是防御性写法）
    def active(chat_id:, thread_id: nil)
      chat = normalize_chat_id(chat_id)
      return nil if chat.nil?

      row = conn.get_first_hash(
        "SELECT #{LOG_COLUMNS} FROM session_logs " \
        "WHERE chat_id = ? AND thread_id = ? AND status IN (?, ?) " \
        "ORDER BY id DESC LIMIT 1",
        [chat, self.class.normalize_thread_id(thread_id),
         STATUS_RECORDING, STATUS_PAUSED]
      )
      row.nil? ? nil : to_log(row)
    end

    # 该作用域**正在录**的那条（录制挂钩用；paused/ended 都不算）
    def recording_for(chat_id:, thread_id: nil)
      chat = normalize_chat_id(chat_id)
      return nil if chat.nil?

      row = conn.get_first_hash(
        "SELECT #{LOG_COLUMNS} FROM session_logs " \
        "WHERE chat_id = ? AND thread_id = ? AND status = ? " \
        "ORDER BY id DESC LIMIT 1",
        [chat, self.class.normalize_thread_id(thread_id), STATUS_RECORDING]
      )
      row.nil? ? nil : to_log(row)
    end

    # 该作用域的录制清单（最新在前），带条目数（/log list 用）
    #
    # @param limit [Integer, nil] nil = 不限
    # @return [Array<SessionLog>]
    def list(chat_id:, thread_id: nil, limit: nil)
      chat = normalize_chat_id(chat_id)
      return [] if chat.nil?

      sql = "SELECT #{LOG_COLUMNS_QUALIFIED}, " \
            "(SELECT count(*) FROM log_entries e WHERE e.log_id = l.id) AS entry_count " \
            "FROM session_logs l WHERE l.chat_id = ? AND l.thread_id = ? " \
            "ORDER BY l.id DESC"
      params = [chat, self.class.normalize_thread_id(thread_id)]
      unless limit.nil?
        sql = "#{sql} LIMIT ?"
        params << limit.to_i
      end
      conn.execute_query(sql, params).map { |row| to_log_from_array(row) }
    end

    # 一次录制的全部条目（seq 升序——导出排序依据）
    #
    # @return [Array<LogEntry>]
    def entries(log_id)
      conn.execute_query(
        "SELECT #{ENTRY_COLUMNS} FROM log_entries WHERE log_id = ? ORDER BY seq ASC",
        [log_id.to_i]
      ).map { |row| to_entry_from_array(row) }
    end

    def count_entries(log_id)
      conn.get_first_value(
        "SELECT count(*) FROM log_entries WHERE log_id = ?", [log_id.to_i]
      ).to_i
    end

    # ------------------------------------------------------------------
    # 状态机
    # ------------------------------------------------------------------

    # 开录（/log new）。同作用域已有进行中的录制 → :already_active（log 带出那条）。
    #
    # @return [LogResult]
    def start(chat_id:, thread_id: nil, name:)
      chat = normalize_chat_id(chat_id)
      return LogResult.invalid_argument if chat.nil?

      clean_name = normalize_name(name)
      return LogResult.invalid_name if clean_name.nil?

      thread = self.class.normalize_thread_id(thread_id)
      result = nil
      conn.transaction(:immediate) do
        existing = active(chat_id: chat, thread_id: thread)
        if existing
          result = LogResult.already_active(existing)
        else
          conn.execute(
            "INSERT INTO session_logs (chat_id, thread_id, name, status, created_at) " \
            "VALUES (?, ?, ?, ?, datetime('now'))",
            [chat, thread, clean_name, STATUS_RECORDING]
          )
          new_id = conn.get_first_value("SELECT last_insert_rowid()")
          result = LogResult.ok(find(new_id))
        end
      end
      result
    end

    # 暂停（/log off）：recording → paused
    def pause(chat_id:, thread_id: nil)
      transition(chat_id: chat_id, thread_id: thread_id,
                 target: STATUS_PAUSED, unchanged: :already_paused)
    end

    # 继续（/log on）：paused → recording
    def resume(chat_id:, thread_id: nil)
      transition(chat_id: chat_id, thread_id: thread_id,
                 target: STATUS_RECORDING, unchanged: :already_recording)
    end

    # 结束（/log end；方法名不叫 end —— 那是 Ruby 关键字）：active 任一状态 → ended
    #
    # 语义决策：**paused 状态也能直接 finish**（用户暂停到一半想收工是常态；
    # 不要求先 /log on 再 end）。ended_at 在此写入（schema 的 ended_at 只在这里用）。
    def finish(chat_id:, thread_id: nil)
      transition(chat_id: chat_id, thread_id: thread_id,
                 target: STATUS_ENDED, unchanged: nil)
    end

    # ------------------------------------------------------------------
    # 写：条目
    # ------------------------------------------------------------------

    # 追加一条录制条目（seq 在事务内现算）。
    #
    # @param user_id [Integer, nil] bot 条目为 nil（schema 注释）
    # @param is_bot [Boolean, Integer] 1 = bot 自己的输出（掷骰结果等）
    # @param msg_kind [String] "text" / "photo" / "sticker" / …（非文本占位）
    # @return [LogEntry, nil]
    def append_entry(log_id:, sender_name:, user_id: nil, is_bot: 0, msg_kind: "text", content:)
      # 入参守卫（2026-10-13 审核：此前只有 chat_id 走 int64 守卫，本方法
      # 裸用 to_i——超界值会被 SQLite 静默存成 REAL）。log_id 必填，非法
      # 属调用方 bug（同 secrets.create 的 ArgumentError 口径）；user_id
      # 可空，超界归一为 NULL（bot 消息同席位）。
      log = log_id.to_i
      raise ArgumentError, "log_id 不合法" if log.zero? || !log.between?(INT64_MIN, INT64_MAX)

      uid = user_id.nil? ? nil : user_id.to_i
      uid = nil if uid && !uid.between?(INT64_MIN, INT64_MAX)

      entry = nil
      conn.transaction(:immediate) do
        seq = conn.get_first_value(
          "SELECT COALESCE(MAX(seq), 0) + 1 FROM log_entries WHERE log_id = ?",
          [log]
        ).to_i
        if seq > MAX_ENTRIES
          # 到达上限：不再写入（不静默丢最旧的——导出仍与库里一致），
          # 每个 log 只 warn 一次，避免热路径刷日志。
          warn_entry_cap(log)
          next
        end

        conn.execute(
          "INSERT INTO log_entries (log_id, seq, sender_name, user_id, is_bot, " \
          "msg_kind, content, created_at) " \
          "VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))",
          [log, seq, sender_name.to_s, uid,
           truthy_flag?(is_bot) ? 1 : 0, msg_kind.to_s, content.to_s]
        )
        row = conn.get_first_hash(
          "SELECT #{ENTRY_COLUMNS} FROM log_entries WHERE log_id = ? AND seq = ?",
          [log, seq]
        )
        entry = row.nil? ? nil : to_entry(row)
      end
      entry
    end

    private

    attr_reader :conn

    # 条目上限告警（每个 log 一次；只记结构性信息）
    def warn_entry_cap(log_id)
      return if @cap_warned[log_id]

      @cap_warned[log_id] = true
      @logger.warn("[session_logs] log #{log_id} 已达条目上限 #{MAX_ENTRIES}，后续消息不再录制")
    rescue StandardError
      nil
    end

    # 状态机共同底座：找 active 行（无 → :no_active）→ 目标态已于当前态
    # → 原样返回 + unchanged 码 → 否则 UPDATE（ended 时同时写 ended_at）。
    def transition(chat_id:, thread_id:, target:, unchanged:)
      chat = normalize_chat_id(chat_id)
      return LogResult.invalid_argument if chat.nil?

      thread = self.class.normalize_thread_id(thread_id)
      result = nil
      conn.transaction(:immediate) do
        current = active(chat_id: chat, thread_id: thread)
        if current.nil?
          result = LogResult.no_active
        elsif current.status == target
          result =
            case unchanged
            when :already_paused then LogResult.already_paused(current)
            when :already_recording then LogResult.already_recording(current)
            else LogResult.ok(current) # finish 的 unchanged 为 nil：不可能走到（ended 不是 active），防御性兜底
            end
        else
          if target == STATUS_ENDED
            conn.execute(
              "UPDATE session_logs SET status = ?, ended_at = datetime('now') WHERE id = ?",
              [target, current.id]
            )
          else
            conn.execute(
              "UPDATE session_logs SET status = ? WHERE id = ?",
              [target, current.id]
            )
          end
          result = LogResult.ok(find(current.id))
        end
      end
      result
    end

    # chat_id 归一：nil / 空串 / 0 一律拒绝（0 在 Ruby 里是真值，不拦会把行
    # 写进 chat_id=0 黑洞；同 bank.rb / migration.rb 的 0 守卫纪律）；
    # 超 int64 界同样拒绝（SQLite 动态类型会静默存成 REAL；含 INT64_MIN 的
    # 闭区间口径与 bank.rb 一致，2026-10-12 三审统一）
    def normalize_chat_id(chat_id)
      return nil if chat_id.nil?
      return nil if chat_id.is_a?(String) && chat_id.strip.empty?

      id = chat_id.to_i
      return nil if id.zero?
      return nil unless id.between?(INT64_MIN, INT64_MAX)

      id
    end

    # 名字归一：strip 后必须非空、≤ MAX_NAME_LENGTH、不含控制字符（\n 会拆坏
    # 回显文案与导出头部；控制字符没有任何正当用途）
    def normalize_name(name)
      return nil if name.nil?

      s = name.to_s.strip
      return nil if s.empty?
      return nil if s.length > MAX_NAME_LENGTH
      return nil if s.match?(/[\x00-\x1f\x7f]/)

      s
    end

    # SQLite 无 BOOLEAN：0/1 整数。取值侧吃布尔/整数/字符串（同 settings.rb）
    def truthy_flag?(value)
      case value
      when true then true
      when false, nil then false
      when String then !%w[0 false off no].include?(value.strip.downcase)
      when Numeric then !value.zero?
      else true
      end
    end

    def to_log(row)
      SessionLog.new(
        id: row["id"], chat_id: row["chat_id"], thread_id: row["thread_id"],
        name: row["name"], status: row["status"], created_at: row["created_at"],
        ended_at: row["ended_at"],
        entry_count: row.key?("entry_count") ? row["entry_count"] : nil
      )
    end

    # list 走 execute_query（数组行）：列序 = LOG_COLUMNS 展开 + entry_count
    def to_log_from_array(row)
      id, chat, thread, name, status, created, ended, count = row
      SessionLog.new(id: id, chat_id: chat, thread_id: thread, name: name,
                     status: status, created_at: created, ended_at: ended,
                     entry_count: count)
    end

    def to_entry(row)
      LogEntry.new(
        id: row["id"], log_id: row["log_id"], seq: row["seq"],
        sender_name: row["sender_name"], user_id: row["user_id"],
        is_bot: row["is_bot"], msg_kind: row["msg_kind"],
        content: row["content"], created_at: row["created_at"]
      )
    end

    def to_entry_from_array(row)
      id, log_id, seq, sender_name, user_id, is_bot, msg_kind, content, created = row
      LogEntry.new(id: id, log_id: log_id, seq: seq, sender_name: sender_name,
                   user_id: user_id, is_bot: is_bot, msg_kind: msg_kind,
                   content: content, created_at: created)
    end

    def warn_line(message)
      @logger.warn(message)
    rescue StandardError
      nil
    end
  end
end
