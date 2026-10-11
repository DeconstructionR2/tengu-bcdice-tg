#!/bin/bash
# scripts/backup.sh — tengu-bcdice-tg 生产数据备份（宿主机 cron 日备）
#
# 设计（计划 §8 T4.2 + §9 备份节 + §15.2 E3）：
#   - 备份对象：生产数据卷内 SQLite 库（容器挂载 /app/data，宿主 /opt/<project>/data/tengu.db）。
#   - 用 `sqlite3 <db> ".backup ..."`（SQLite 在线备份 API，一致性快照）——WAL 模式裸 cp
#     非严格一致（§15.2 E3），本脚本与容器写入并发运行，无需停容器。
#   - DB 不存在（T4.5 上线前 / 尚未生成）→ 打一行说明、exit 0（不告警不报错）。
#   - 同日重复跑幂等：先删旧同名，再备；失败不留半成品。
#   - 保留最近 KEEP 份（默认 7），只清理 tengu-YYYYMMDD.db 严格形态（不误删目录里其他文件）。
#   - 失败（sqlite3 非零 / 目标不可写 / 备份完整性检查不过）→ stderr 结构性报错 + exit 非零。
#     脚本自身无投递能力：cron 重定向把 stderr 收进 backup.log；告警侧由
#     server-health-check.sh「备份新鲜度」检查兜底（备份超龄即告警）。
#   - 测试：TENGU_DB_PATH / TENGU_BACKUP_DIR 环境变量覆盖（干跑不碰生产路径）。
#
# 用法:
#   scripts/backup.sh
#   TENGU_DB_PATH=/tmp/x.db TENGU_BACKUP_DIR=/tmp/bk scripts/backup.sh
set -u

DB="${TENGU_DB_PATH:-/opt/<project>/data/tengu.db}"
BACKUP_DIR="${TENGU_BACKUP_DIR:-/opt/backups/<project>}"
KEEP=7

ts() { date '+%F %T'; }

# ---------- 未上线：DB 还不存在 → 一行说明，静默跳过 ----------
if [ ! -f "$DB" ]; then
  echo "$(ts) tengu-backup: 跳过——DB 不存在（$DB，未上线或尚未生成）"
  exit 0
fi

# ---------- 前置：sqlite3 可用 + 备份目录可写 ----------
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "tengu-backup: ERROR sqlite3 不在 PATH（PATH=$PATH）" >&2
  exit 1
fi
if ! mkdir -p "$BACKUP_DIR" 2>/dev/null || [ ! -w "$BACKUP_DIR" ]; then
  echo "tengu-backup: ERROR 备份目录不可写：$BACKUP_DIR" >&2
  exit 1
fi
chmod 700 "$BACKUP_DIR" 2>/dev/null || true   # 备份含群聊数据，收紧到属主（失败不致命）

# ---------- 在线一致备份（同日重复跑：先删旧同名，幂等） ----------
TARGET="$BACKUP_DIR/tengu-$(date +%Y%m%d).db"
rm -f "$TARGET"
if ! sqlite3 "$DB" ".backup '$TARGET'"; then
  rm -f "$TARGET"   # 不留半成品：坏文件会让「最新备份」假新鲜，反而掩盖告警
  echo "tengu-backup: ERROR sqlite3 .backup 失败：$DB -> $TARGET（sqlite3 报错见上一行）" >&2
  exit 1
fi

# ---------- 备份自检（小库毫秒级；坏副本当场暴露，而不是等恢复时） ----------
CHECK=$(sqlite3 "$TARGET" "PRAGMA integrity_check;" 2>&1)
if [ "$CHECK" != "ok" ]; then
  rm -f "$TARGET"
  echo "tengu-backup: ERROR 备份完整性检查未过：$TARGET（integrity_check=$CHECK）" >&2
  exit 1
fi

# ---------- 保留最近 KEEP 份（文件名字典序=时间序；严格形态防误删） ----------
OLD=$(cd "$BACKUP_DIR" && ls -1 tengu-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].db 2>/dev/null | sort | head -n -"$KEEP")
if [ -n "$OLD" ]; then
  while IFS= read -r f; do
    rm -f "$BACKUP_DIR/$f" && echo "$(ts) tengu-backup: 清理超龄备份 $f"
  done <<< "$OLD"
fi

echo "$(ts) tengu-backup: OK $TARGET（$(du -h "$TARGET" | cut -f1)，保留最近 $KEEP 份）"
exit 0
