# frozen_string_literal: true

# ============================================================================
# db/connection.rb — SQLite 连接层（T2.4，计划 §4.1 / §15.5 E10）
#
# 四条硬要求（缺一即验收不过）：
#   1. **单连接**：进程内一个 DB 实例（`Connection.instance`），不每次操作重开。
#      计划 §3 决9：并发能力理论降级但与负载差 4 个数量级（群限额 20 条/分），
#      无实际影响；单连接还顺带免掉了「多连接 WAL 写锁竞争」的运维面。
#   2. **WAL**：`PRAGMA journal_mode=WAL`（读写不互斥；备份须用
#      `sqlite3 .backup`，裸 cp 有一致性瑕疵——计划 §15.2 E3 / T4.2）。
#   3. **`PRAGMA foreign_keys=ON`**：SQLite **默认关闭**外键强制，
#      不开则 schema 里的 `log_entries.log_id REFERENCES session_logs(id)`
#      形同虚设（实测：默认插入孤儿行不报错）。这是 §15.5 E10 的落地点。
#   4. **首次连接自动建表**：执行 db/schema.sql（幂等 CREATE IF NOT EXISTS）。
#   5. **首次连接自动补列**：`ensure_column` 对既有库执行 ALTER TABLE ADD COLUMN
#      （schema.sql 加不了列，见 apply_schema 与本文件下方 COLUMN_ADDITIONS）。
#
# 路径来源：`TelegramBot::Config.db_path`（.env 的 DB_PATH；容器
# /app/data/tengu.db，本机开发 ./data/tengu.db）。**不在本文件另抄一份**
# 默认值——两处抄本必然漂移（router.rb 对命令集合的同款纪律）。
#
# 测试用法：`Connection.open(path: ":memory:")` 开一次性内存库；
# 生产/集成用 `Connection.instance`（按路径 memo 的单连接）。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require "fileutils"
require "monitor"
require "sqlite3"
require_relative "../bot/config"

module TenguDB
  # --------------------------------------------------------------------------
  # 单连接封装
  # --------------------------------------------------------------------------
  class Connection
    SCHEMA_PATH = File.expand_path("schema.sql", __dir__)

    # 内存库哨兵（测试用）。sqlite3 gem 对该串特殊处理，不落盘。
    MEMORY = ":memory:"

    # ==========================================================================
    # schema 演进登记处（T2.6 确立的**首例**，此后加列一律同此办理）
    # ==========================================================================
    #
    # 背景：`CREATE TABLE IF NOT EXISTS` 在表已存在时**整条跳过**，故在
    # schema.sql 里加一列只对**新库**生效；部署前就建好的库会永远缺这一列，
    # 直到某条 SQL 真的碰到它才报 `no such column: xxx`——而那一刻已经在生产。
    #
    # 故每次给表加列必须**同时**改两处（schema.sql 保证新库、这里保证旧库）。
    # 缺任一条的症状：
    #   - 漏 schema.sql → 全新部署直接建不出该列，一启动就炸；
    #   - 漏本清单       → 旧部署一直好着，升级后才炸（最难查的一种）。
    #
    # 元素形态：[表名, 列名, "完整 ADD COLUMN 的列定义子句"]，例：
    #   ["chat_settings", "aux_enabled", "INTEGER NOT NULL DEFAULT 1"]
    # ALTER TABLE 不支持 IF NOT EXISTS（SQLite 至今没有），故靠**先探后加**
    # 保证幂等（ensure_column）。加 NOT NULL 列时**必须**带 DEFAULT：
    # 没有默认值的 ADD COLUMN 在有数据的表上会直接失败。
    COLUMN_ADDITIONS = [
      # T2.6：辅助轨开关（每群一份，只走群级行 thread_id=0）。
      # 与 schema.sql 的列定义逐字一致——两处漂移会让新库旧库行为不同。
      ["chat_settings", "aux_enabled", "INTEGER NOT NULL DEFAULT 1"]
    ].freeze

    # 进程内连接登记表：{绝对路径或 MEMORY => Connection}。
    # 按**路径**分键而非全局单例——测试要能同时开多份内存库互不干扰。
    @instances = {}
    @registry_lock = Monitor.new

    class << self
      # 打开一个新连接（应用 PRAGMA + 建表）。**不登记**到单连接表。
      #
      # @param path [String] 数据库文件路径；":memory:" 为内存库
      # @return [TenguDB::Connection]
      def open(path: nil)
        new(path || default_path)
      end

      # 进程内单连接（同一路径重复调用返回同一实例）。
      #
      # @param path [String, nil] nil = Config.db_path
      # @return [TenguDB::Connection]
      def instance(path: nil)
        key = normalize_path(path || default_path)
        @registry_lock.synchronize do
          @instances[key] ||= new(key)
        end
      end

      # 清空登记表（**仅测试用**：让每个用例能拿到干净的单连接）
      def reset!
        @registry_lock.synchronize do
          @instances.each_value { |c| c.close rescue nil } # rubocop:disable Style/RescueModifier
          @instances = {}
        end
      end

      # 数据库路径的唯一真相来源
      def default_path
        TelegramBot::Config.db_path
      end

      def normalize_path(path)
        p = path.to_s
        p == MEMORY ? MEMORY : File.expand_path(p)
      end
    end

    attr_reader :path

    def initialize(path)
      @path = self.class.normalize_path(path)
      @monitor = Monitor.new

      # 建库目录（容器 /app/data 由数据卷挂载时通常已存在，但本地开发
      # ./data/ 可能没建过；mkdir_p 幂等）
      FileUtils.mkdir_p(File.dirname(@path)) unless memory?

      @db = SQLite3::Database.new(@path)
      apply_pragmas
      apply_schema
      apply_column_additions
    end

    # -- 基础操作 ------------------------------------------------------------

    # 非查询语句（INSERT/UPDATE/DELETE/DDL）
    #
    # @param sql [String]
    # @param params [Array] 绑定参数（**一律绑定，绝不拼串**——game_system
    #   来自用户输入，拼串即注入面）
    def execute(sql, params = [])
      @monitor.synchronize { @db.execute(sql, params) }
    end

    # 取单行单值（`SELECT count(*) …` 之类）
    def get_first_value(sql, params = [])
      @monitor.synchronize { @db.get_first_value(sql, params) }
    end

    # 取单行为 **Hash**（列名 → 值）。显式走 `query` + 临时 results_as_hash，
    # 不改连接的全局模式——全局模式是**连接级**状态，测试若改了不还原，
    # 后续用例会拿到数组行而在 `row["game_system"]` 上炸（难以定位的串味）。
    #
    # @return [Hash, nil] 无匹配行时 nil
    def get_first_hash(sql, params = [])
      @monitor.synchronize do
        previous = @db.results_as_hash
        @db.results_as_hash = true
        begin
          @db.get_first_row(sql, params)
        ensure
          @db.results_as_hash = previous
        end
      end
    end

    # 取多行（数组的数组；列序与 SQL 一致）
    def execute_query(sql, params = [])
      @monitor.synchronize { @db.execute(sql, params) }
    end

    # 受影响行数（UPDATE/DELETE）。**不能**用 execute 的返回值——它返回
    # 结果集（DDL/DELETE 都是空数组），不是 change count（实测 sqlite3 2.9）。
    #
    # ⚠️ 与 execute 是**两次独立加锁**（各自 synchronize），「先 execute 再读
    # changes」不构成原子对——调用方（settings/secrets/custom_tables）依赖的
    # 隐含前提是**单线程串行**（当前实现如此；Monitor 只是防未来）。若将来
    # 引入第二个线程共享连接，此处会读到被夹入语句覆盖的 changes 值
    # （2026-10-13 审核登记；届时应改为同锁内返回 [result, changes] 的合体助手）。
    def changes
      @monitor.synchronize { @db.changes }
    end

    # 事务助手。块抛异常 → 回滚并**原样**重抛（调用方自行 rescue）。
    #
    # 默认 :immediate：SQLite 的 deferred 事务在**首次写**时才取写锁，
    # 事务中途才发现冲突会直接 SQLITE_BUSY 失败（无法回退重试）；
    # immediate 在 BEGIN 处即取锁，语义更可预期（计划 §4.2 的多表读改写
    # 全走这条路径）。
    #
    # **已在一个事务里时直接 yield**（不嵌套）：sqlite3 gem 明确不支持嵌套，
    # 嵌套会抛 "cannot start a transaction within a transaction"。
    # 让内层复用外层事务，是 savepoint 之外的正确做法（外层失败全回滚）。
    def transaction(mode = :immediate)
      @monitor.synchronize do
        if @db.transaction_active?
          yield self
        else
          @db.transaction(mode) { yield self }
        end
      end
    end

    def transaction_active?
      @monitor.synchronize { @db.transaction_active? }
    end

    def closed?
      @monitor.synchronize { @db.closed? }
    end

    def close
      @monitor.synchronize { @db.close unless @db.closed? }
    end

    # 供测试断言连接层契约（journal_mode / foreign_keys）
    def pragma(name)
      get_first_value("PRAGMA #{name}")
    end

    # ----------------------------------------------------------------------
    # schema 演进的公开面（测试与诊断用）
    # ----------------------------------------------------------------------

    # 某表的列名数组（按建表顺序）
    #
    # 走 `pragma_table_info(?)` **表值函数**而非 `PRAGMA table_info(x)` 语句：
    # 前者接受绑定参数，故**表名不需要拼进 SQL 字符串**（与「值一律绑定」
    # 的纪律同源）。PRAGMA 语句形式不接受绑定参数，只能拼串。
    #
    # @return [Array<String>] 表不存在时返回 []（不是异常——调用方多在探测）
    def column_names(table)
      row = get_first_value(
        "SELECT group_concat(name) FROM pragma_table_info(?)", [table.to_s]
      )
      row.to_s.split(",").reject(&:empty?)
    end

    # 该表是否有这一列
    def column?(table, column)
      column_names(table).include?(column.to_s)
    end

    # 补一列（幂等：已在则什么也不做）
    #
    # 顺序要紧：先探**表**在不在（否则 ALTER 一个不存在的表会炸成
    # "no such table"，掩盖真实问题），再探**列**在不在（已存在 → 直接
    # no-op 返回 false，这正是幂等性的来源）。
    #
    # ⚠️ **表名/列定义是插值进 SQL 的**（值一律绑定）。安全前提同
    #   Migration::TABLES：它们来自本文件 frozen 的 COLUMN_ADDITIONS 常量，
    #   不含任何外部输入。**不要**把这个方法开放给用户输入。
    #
    # @param definition [String] ADD COLUMN 的列定义子句（不含列名）
    # @return [Boolean] 本次是否**真的执行了**加列（false = 已存在或表不存在）
    def ensure_column(table, column, definition)
      return false unless table_exists?(table)
      return false if column?(table, column)

      execute("ALTER TABLE #{table} ADD COLUMN #{column} #{definition}")
      true
    end

    def table_exists?(table)
      get_first_value(
        "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table.to_s]
      ).to_i.positive?
    end

    def memory?
      @path == self.class::MEMORY
    end

    private

    # PRAGMA 顺序有讲究：journal_mode 必须在任何写事务之前设，
    # foreign_keys 必须在**连接建立后、任何写之前**设（SQLite 不允许在
    # 事务中途切换 foreign_keys，会被静默忽略）。
    def apply_pragmas
      execute("PRAGMA journal_mode=WAL")
      execute("PRAGMA foreign_keys=ON")
      # 单进程 + WAL 已足够；busy_timeout 只防「未来有人加第二个连接」时
      # 的瞬时锁等待，不替代单连接纪律。
      execute("PRAGMA busy_timeout=5000")
    end

    # 首次连接自动建表（schema 全是 IF NOT EXISTS → 幂等，可重复执行）。
    #
    # 用 execute_batch（多语句入口）而非 execute：后者走 prepare/step 单语句
    # 路径，本文件的分号分隔语句会被当成 SQL 片段报错。
    #
    # ⚠️ 本文件**只负责新库的完整结构**；既有库的加列走 apply_column_additions
    #（`CREATE TABLE IF NOT EXISTS` 对已存在的表整条跳过，加进去的新列不会生效）。
    def apply_schema
      sql = File.read(SCHEMA_PATH)
      @monitor.synchronize { @db.execute_batch(sql) }
    end

    # 首次连接自动补列（T2.6 schema 演进的唯一起点）。
    #
    # 必须排在 apply_schema **之后**：新库此时已含全部列，全部 no-op；
    # 旧库缺的列在这里补上。顺序反过来会给尚未建表的库补列失败。
    #
    # 单条失败**不让连接建立失败**：数据库能被打开、其余表可用，比启动即
    # 崩掉更有用（§9 的「部署期故障越早炸越好」针对 DB_PATH/权限这类
    # 根本用不了的情况；缺列是可用性问题，且被记进日志可被看见）。
    # 注意这里**不**把表名/列名打进 warn 正文之外的地方——它们是常量不是输入。
    def apply_column_additions
      COLUMN_ADDITIONS.each do |table, column, definition|
        added = ensure_column(table, column, definition)
        warn_line("[db] 表 #{table} 已补列 #{column}（schema 演进，见 COLUMN_ADDITIONS）") if added
      rescue StandardError => e
        warn_line("[db] 补列失败（表=#{table} 列=#{column}）：#{e.class}（消息不打印）")
      end
    end

    def warn_line(message)
      warn(message)
    rescue StandardError
      nil # 日志器坏了也不能让建库失败
    end
  end
end