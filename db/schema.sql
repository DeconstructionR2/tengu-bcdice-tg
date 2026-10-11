-- ============================================================================
-- db/schema.sql — 全量 schema（计划 §4.1 逐字落地，T2.4）
--
-- 七张表一次建全（chat_settings / bank_record / custom_tables / secrets /
-- chat_id_aliases / session_logs / log_entries）——表结构是**静态资产**，
-- 后续任务（T3.x 银行/CT/暗骰、T3.5 log 录制、T2.5 迁移）直接用，
-- 不做「用到再建」的增量迁移（本服务单文件 SQLite，无多实例升级路径，
-- 每次启动跑一遍幂等 DDL 的成本可忽略）。
--
-- 幂等契约：全部 CREATE TABLE/INDEX 带 IF NOT EXISTS → 可重复执行。
-- 连接层（db/connection.rb）首次连接自动执行本文件。
--
-- 执行方式：db.execute_batch（sqlite3 gem 的多语句入口）。
-- ⚠️ 不用 `db.execute`：它走 prepare/step 单语句路径，本文件的分号分隔多语句
--   会被当成 SQL 片段报错。
-- ============================================================================

PRAGMA journal_mode=WAL;

-- 每群（每话题）设置：规则系统 ID。查找顺序 话题→群→全局默认
-- （§3 决6 / §13 第 5 项）。thread_id=0 即群级（forum 的 General 话题
-- 恒为 1，E4 定案：0 与 1 都归群级作用域，见 db/settings.rb）。
CREATE TABLE IF NOT EXISTS chat_settings (
  chat_id      INTEGER NOT NULL,      -- 64位, 群/超级群 id
  thread_id    INTEGER NOT NULL DEFAULT 0,  -- 0=群级默认; >0=forum 话题(§13第5项: 话题级切换第一版即含)
  game_system  TEXT NOT NULL DEFAULT 'NinjaSlayer2Ex',
  updated_at   TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (chat_id, thread_id)
);

-- 天狗语义: 每频道一本共享账(≈Telegram 话题级, §13第8项定案)
CREATE TABLE IF NOT EXISTS bank_record (
  chat_id      INTEGER NOT NULL,      -- 天狗语义: 每频道一本共享账(≈Telegram 话题级, §13第8项定案)
  thread_id    INTEGER NOT NULL DEFAULT 0,  -- 0=群级默认; >0=forum 话题
  sum_money    INTEGER NOT NULL DEFAULT 0,  -- 可为负(忠实保留: 无透支校验)
  money_record TEXT NOT NULL DEFAULT '[]',  -- JSON 数组流水(替代天狗「、」分隔字符串)
  item_record  TEXT NOT NULL DEFAULT '[]',  -- JSON 数组(元素级增删, 修复天狗字符串替换误伤 quirk)
  updated_at   TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (chat_id, thread_id)
);

CREATE TABLE IF NOT EXISTS custom_tables (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  scope        TEXT NOT NULL CHECK(scope IN ('private','public')),
  chat_id      INTEGER NOT NULL DEFAULT 0,  -- 0=public; >0=private 所属群(占位避免 NULL 使 UNIQUE 失效——SQLite 中 NULL 互不相等)
  name         TEXT NOT NULL,
  spec         TEXT NOT NULL,         -- JSON: {dice:{a:..,b:..}, data:{..}}
  permissions  TEXT NOT NULL DEFAULT '[]',  -- JSON: user_id 数组
  datarange    TEXT NOT NULL DEFAULT '{}',  -- JSON: {isUse,max,min}
  author_id    INTEGER NOT NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(scope, chat_id, name)
);

CREATE TABLE IF NOT EXISTS secrets (
  id           TEXT PRIMARY KEY,      -- 短随机 id(按钮 callback_data 64B 限制)
  chat_id      INTEGER NOT NULL,
  thread_id    INTEGER NOT NULL DEFAULT 0,  -- 公开按钮回发话题定位
  user_id      INTEGER NOT NULL,      -- 只有本人可看/可公开
  command      TEXT NOT NULL,
  result_text  TEXT NOT NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS chat_id_aliases (   -- 群升级迁移映射(审计+幂等)
  old_chat_id  INTEGER PRIMARY KEY,
  new_chat_id  INTEGER NOT NULL,
  migrated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

-- §13 第 6 项定案: 跑团 log 录制(对标海豹 .log 工作流)
CREATE TABLE IF NOT EXISTS session_logs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id      INTEGER NOT NULL,
  thread_id    INTEGER NOT NULL DEFAULT 0,   -- 与 chat_settings 同尺度: 话题级
  name         TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'recording' CHECK(status IN ('recording','paused','ended')),
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  ended_at     TEXT
);

CREATE TABLE IF NOT EXISTS log_entries (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  log_id       INTEGER NOT NULL REFERENCES session_logs(id),
  seq          INTEGER NOT NULL,            -- 日志内序号(导出排序依据)
  sender_name  TEXT NOT NULL,               -- 显示名(导出文本直接可用)
  user_id      INTEGER,                     -- bot 消息为 NULL
  is_bot       INTEGER NOT NULL DEFAULT 0,  -- 1=bot 的掷骰结果等(导出时可标色)
  msg_kind     TEXT NOT NULL DEFAULT 'text',-- text/photo/sticker/... 非文本记占位符
  content      TEXT NOT NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_log_entries_log ON log_entries(log_id, seq);

-- ============================================================================
-- 索引（除 log_entries 那条外，按 T2.4 的实际访问模式补）
--
-- 为什么不逐表补索引而只在必要处补：
--   - chat_settings / bank_record：主键 (chat_id, thread_id) 前缀已覆盖
--     「按群/话题查」这一唯一热路径 → 再加索引是纯写放大；
--   - secrets：按「公开按钮回调 id」查（主键）+ 按 chat 清理（T3.1），
--     后者非热路径，暂不建；
--   - session_logs：T3.5 的「列出本群 log」按 chat_id 查，
--     属低频（每人每天几次）→ 等 T3.5 有实测访问模式再定，避免过早优化。
--   后续任务加索引时，请在此处写明**为什么现在需要**（同上的纪律）。
-- ============================================================================