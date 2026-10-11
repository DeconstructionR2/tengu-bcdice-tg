# frozen_string_literal: true

require "logger"

# ============================================================================
# bot/migration.rb — 群升级 re-key 处理器（T2.5）
#
# 计划 §3 决5 / §4.1 / §4.2（迁移 re-key 事务）/ §8 T2.5 / §12 R5 / §0.2.4
#
# ── 为什么需要 ──────────────────────────────────────────────────────────────
#   Telegram 群「普通群 → 超级群」升级时 chat_id 会变（本项目测试群「示例迁移群」
#   真发生过：-1234567890 → -1009876543210），并向两侧各发一条服务消息：
#     - 旧群侧消息：chat.id = 旧 id，migrate_to_chat_id = 新 id
#     - 新群侧消息：chat.id = 新 id，migrate_from_chat_id = 旧 id
#   本 bot 的**全部** DB 行都挂 chat_id（设置/账本/CT/暗骰/log 录制），
#   不 re-key 就等于群升级后账本与设置全丢——这是超级群支持的必需件。
#
# ── 事务定案（§4.2）────────────────────────────────────────────────────────
#   BEGIN → 对**含 chat_id 的 5 张表**逐一 UPDATE … SET chat_id=? WHERE chat_id=?
#        → 写 chat_id_aliases(old→new + 时间戳) → COMMIT
#   log_entries **不动**：它没有 chat_id 列，靠 log_id 外键关联 session_logs，
#   父行的 chat_id 一变，级联归属自动跟着走（外键本身不受影响）。
#
# ── 幂等（§12 R5，三条硬要求）─────────────────────────────────────────────
#   1. 同一迁移消息重复收到 → 第二次 UPDATE 命中 0 行（行已在 new 侧），
#      **不产生二次变更**；aliases 用 INSERT OR IGNORE（主键 old_chat_id）。
#   2. 只见到一侧消息（只有 migrate_to 或只有 migrate_from）也能正确工作
#      —— 两个方向都归一到同一对 (old, new)。
#   3. 两侧消息以任意顺序到达都幂等（两条消息做的事完全相同）。
#   另：迁移期间在新群侧新建的行**绝不会被误改**（WHERE 只匹配 old 侧）。
#
# ── 失败语义（刻意选择）────────────────────────────────────────────────────
#   若目标 id 侧已存在同键行（如 chat_settings 的 PK (chat_id, thread_id)），
#   UPDATE 会触发 UNIQUE 冲突 → **异常原样抛出、整个事务回滚**。
#   宁可整体不动（数据仍在旧 id 下、可从 chat_id_aliases 排查），也不做
#   「逐表部分迁移」留下半拉子账本。router 侧兜住异常（只 warn，不杀循环）。
#
# ── 依赖注入（router 不持有 DB）────────────────────────────────────────────
#   Router 通过 `migration:` 关键字拿到本对象，**自己 require 不本文件**——
#   路由层保持零 DB 依赖（main.rb 注入真身，测试注入假身，见 bot/router.rb）。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require_relative "../db/connection"

module TelegramBot
  # --------------------------------------------------------------------------
  # Migration
  # --------------------------------------------------------------------------
  class Migration
    # **含 chat_id 的 5 张表**（§4.2 定案的逐一 UPDATE 清单）。
    #
    # 顺序即执行顺序：先设置/账本（热数据）再 CT/暗骰/log（低频）。
    # 这不是语义依赖——任一张表失败整个事务都回滚——只影响「若人工看 SQL
    # 顺序时先看到什么」。写死常量而非反射 sqlite_master：新表由 schema
    # 显式决定，反射会把「忘了加进清单的表」变成静默漏迁移。
    #
    # ⚠️ 表名是**插值**进 SQL 的（值一律绑定）。安全前提：它来自本文件里的
    #   frozen 字面量常量，不含任何外部输入——与 db/connection.rb 的纪律
    #   （值绝不拼串）不冲突。
    TABLES = %w[
      chat_settings
      bank_record
      custom_tables
      secrets
      session_logs
    ].freeze

    # 随旧 id 一同改挂的「别名表」（不在 TABLES 里——它记录的是迁移本身，
    # 不是被迁移的业务数据）
    ALIAS_TABLE = "chat_id_aliases"

    # 单次 handle 的结果（值对象；测试与日志都靠它，不靠猜）
    class Result
      # @param old_chat_id [Integer] 迁移前的 id
      # @param new_chat_id [Integer] 迁移后的 id
      # @param direction [Symbol] :to（旧群侧消息）/ :from（新群侧消息）/ :both
      # @param rows [Hash{String=>Integer}] 每张表被 UPDATE 命中的行数
      # @param alias_recorded [Boolean] 本次是否**新写入**了 alias 行
      # @param alias_conflict [Boolean] 已存在 alias 但指向不同 new id
      attr_reader :old_chat_id, :new_chat_id, :direction, :rows, :alias_recorded,
                  :alias_conflict

      def initialize(old_chat_id:, new_chat_id:, direction:, rows:,
                     alias_recorded:, alias_conflict: false)
        @old_chat_id = old_chat_id
        @new_chat_id = new_chat_id
        @direction = direction
        @rows = rows.freeze
        @alias_recorded = alias_recorded
        @alias_conflict = alias_conflict
        freeze
      end

      # 本次真正改动了行吗？（重复消息 = false，这是幂等的可观测证据）
      def moved?
        moved_total.positive?
      end

      def moved_total
        @rows.values.sum
      end

      def to_h
        { old_chat_id: old_chat_id, new_chat_id: new_chat_id,
          direction: direction, rows: rows, alias_recorded: alias_recorded,
          alias_conflict: alias_conflict }
      end
    end

    # @param connection [TenguDB::Connection, nil] nil = DB 层单连接
    #   （测试注入 :memory: 库；生产由 main.rb 显式传 Connection.instance，
    #   与 Settings 共用同一连接——单连接纪律，§3 决9）
    # @param logger [#warn] 日志器（只记结构性信息，绝不记用户正文）
    def initialize(connection: nil, logger: ::Logger.new($stderr))
      @conn = connection
      @logger = logger
    end

    def connection
      @conn ||= TenguDB::Connection.instance
    end

    # ------------------------------------------------------------------
    # 入口
    # ------------------------------------------------------------------

    # 处理一条群升级迁移消息（两种方向统一入口）。
    #
    # @param chat_id [Integer] 入站消息所在群的 id
    # @param migrate_to [Integer, nil] Message#migrate_to_chat_id（旧群侧消息）
    # @param migrate_from [Integer, nil] Message#migrate_from_chat_id（新群侧消息）
    # @return [Result, nil] nil = 这不是迁移消息（两个字段都没有）
    #
    # 方向归一（这是「只见到一侧也能工作」的实现）：
    #   有 migrate_to        → (old=chat_id, new=migrate_to)
    #   有 migrate_from      → (old=migrate_from, new=chat_id)
    #   两个都有（Telegram 不会发，但防御）→ (old=migrate_from, new=migrate_to)
    #   都没有               → nil
    def handle(chat_id:, migrate_to: nil, migrate_from: nil)
      current = id_of(chat_id)
      to = id_of(migrate_to)
      from = id_of(migrate_from)

      old_id, new_id, direction =
        if to && from then [from, to, :both]
        elsif to then [current, to, :to]
        elsif from then [from, current, :from]
        else return nil
        end

      return nil if old_id.nil? || new_id.nil?

      # 0 守卫（kimi T2.5 评审）：Telegram 的 chat_id 永不为 0，但 Ruby 里 0 是
      # 真值、垃圾字符串 to_i 也得 0——不拦的话会把行迁到 chat_id 0 黑洞里。
      return nil if old_id.zero? || new_id.zero?

      # 同一 id（防御：Telegram 不会这么发，但自我 UPDATE 会「命中全部行」
      # 而让 moved? 误报为真变更，白白污染幂等判定的证据）
      return Result.new(old_chat_id: old_id, new_chat_id: new_id,
                        direction: direction,
                        rows: TABLES.to_h { |t| [t, 0] },
                        alias_recorded: false) if old_id == new_id

      run_rekey(old_id, new_id, direction)
    end

    # handler 注册表统一协议是 `#call(context)`（router 的 register / handlers
    # 全是这个形状），迁移 handler 走同一入口便于注入与替换。
    alias call handle

    # ------------------------------------------------------------------
    # 读
    # ------------------------------------------------------------------

    # 某 id 的迁移记录（无记录 = nil）；审计/诊断用
    def alias_for(old_chat_id)
      connection.get_first_hash(
        "SELECT old_chat_id, new_chat_id, migrated_at FROM #{ALIAS_TABLE} " \
        "WHERE old_chat_id = ?", [id_of(old_chat_id)]
      )
    end

    # 该 id 下**仍挂着行**的表（诊断「迁移到底动了哪些表」用）
    def counts_by_table(chat_id)
      id = id_of(chat_id)
      TABLES.each_with_object({}) do |table, acc|
        acc[table] = connection.get_first_value(
          "SELECT count(*) FROM #{table} WHERE chat_id = ?", [id]
        ).to_i
      end
    end

    private

    attr_reader :conn

    # 事务主体：5 张表逐一 UPDATE + 写 alias。
    def run_rekey(old_id, new_id, direction)
      moved = {}
      recorded = false
      conflict = false

      begin
        conn.transaction(:immediate) do
          TABLES.each do |table|
            conn.execute(
              "UPDATE #{table} SET chat_id = ? WHERE chat_id = ?", [new_id, old_id]
            )
            # 受影响行数读 Connection#changes（execute 的返回值是结果集，
            # 不是 change count——T2.4 D5 实测过这个坑）
            moved[table] = conn.changes
          end

          recorded, conflict = record_alias(old_id, new_id)
        end
      rescue SQLite3::ConstraintException => e
        # 冲突可观测性（kimi T2.5 评审）：异常抛给 router 后日志只剩类名，
        # 排查「哪张表哪个键撞了」零线索。此处先做结构化诊断再原样重抛。
        warn_conflict_keys(old_id, new_id, e)
        raise
      end

      warn_conflict(old_id, new_id) if conflict

      Result.new(old_chat_id: old_id, new_chat_id: new_id, direction: direction,
                 rows: moved, alias_recorded: recorded, alias_conflict: conflict)
    end

    # 写审计行：INSERT OR IGNORE（主键 old_chat_id）保证重复消息不产生二次行。
    #
    # @return [Array(Boolean, Boolean)] [是否本次新写入, 已存在记录是否与本次不符]
    def record_alias(old_id, new_id)
      existing = conn.get_first_value(
        "SELECT new_chat_id FROM #{ALIAS_TABLE} WHERE old_chat_id = ?", [old_id]
      )

      if existing.nil?
        conn.execute(
          "INSERT OR IGNORE INTO #{ALIAS_TABLE} (old_chat_id, new_chat_id, migrated_at) " \
          "VALUES (?, ?, datetime('now'))", [old_id, new_id]
        )
        [true, false]
      else
        # 同一 old 已有记录：保留**首次**映射（审计表不改写），
        # 但 re-key 仍以本次消息的 new 为准（最新消息是活的事实）。
        [false, existing.to_i != new_id]
      end
    end

    # 只记结构性信息（id / 方向），绝不记用户正文
    def warn_conflict(old_id, new_id)
      @logger.warn(
        "[migration] chat_id=#{old_id} 已有迁移记录且指向不同 id（本次=#{new_id}）：" \
        "以本次消息为准，审计行保留首次映射"
      )
    rescue StandardError
      nil # logger 坏了也不能让迁移失败
    end

    # UNIQUE 冲突诊断（kimi T2.5 评审）：冲突发生时逐表查出**具体撞键**，
    # 否则异常到 router 只剩一个类名，「永远迁不动」的死锁根本无法排查。
    #
    # re-key 的 UPDATE 只可能撞这三类约束：
    #   chat_settings / bank_record：PK (chat_id, thread_id)
    #   custom_tables：UNIQUE (scope, chat_id, name)
    # （secrets/session_logs 的 PK 与 chat_id 无关，结构上撞不了）
    # 只记结构性键（thread_id / scope+name），不记任何业务内容。
    CONFLICT_PROBES = {
      "chat_settings" =>
        "SELECT a.thread_id AS k FROM chat_settings a WHERE a.chat_id = ? AND EXISTS " \
        "(SELECT 1 FROM chat_settings b WHERE b.chat_id = ? AND b.thread_id = a.thread_id)",
      "bank_record" =>
        "SELECT a.thread_id AS k FROM bank_record a WHERE a.chat_id = ? AND EXISTS " \
        "(SELECT 1 FROM bank_record b WHERE b.chat_id = ? AND b.thread_id = a.thread_id)",
      "custom_tables" =>
        "SELECT a.scope || ':' || a.name AS k FROM custom_tables a WHERE a.chat_id = ? AND EXISTS " \
        "(SELECT 1 FROM custom_tables b WHERE b.chat_id = ? AND b.scope = a.scope AND b.name = a.name)",
    }.freeze

    def warn_conflict_keys(old_id, new_id, err)
      parts = CONFLICT_PROBES.filter_map do |table, sql|
        keys = conn.execute(sql, [old_id, new_id]).map { |row| row.is_a?(Hash) ? row["k"] : row[0] }
        next if keys.empty?

        "#{table} 冲突键=#{keys.first(5).inspect}#{keys.size > 5 ? "（共#{keys.size}个）" : ''}"
      end

      @logger.warn(
        "[migration] re-key 冲突（#{old_id} → #{new_id}）：#{err.class}；" \
        "#{parts.empty? ? '未定位到具体撞键表' : parts.join('；')}。" \
        "数据仍在旧 id 下（事务已回滚），排查后可手工重迁"
      )
    rescue StandardError
      nil # 诊断自身失败不得掩盖原始异常（调用方会重抛原异常）
    end

    # nil / 空串 → nil；其余一律 to_i（**统一 64 位口径**，§0.2.4：
    # chat_id 可超 32 位有效位，入站若给字符串也不能丢精度）
    def id_of(value)
      return nil if value.nil?
      return nil if value.is_a?(String) && value.strip.empty?

      value.to_i
    end
  end
end