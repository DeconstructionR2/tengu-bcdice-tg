# OPERATIONS.md — tengu-bcdice-tg 运维手册（部署 / 升级 / 备份恢复 / 监控 / 紧急处置）

> 依据：计划 §9「部署与运维」定案 + T4.1/T4.2 实证报告（`docs/t4.1-report.md`、
> `docs/t4.2-report.md`）。本手册的每条命令与路径均可在仓库或 `/opt` 现场找到出处；
> 未经实跑核对的条目一律显式标注状态。
>
> 环境：本机 = 部署主机；Docker 29.1.3
> （legacy builder，无 buildx）。
>
> **第一红线（违反会把生产打挂）**：任何时刻同一 bot token 只允许**一个**
> 轮询实例（getUpdates 消费者）。症状与互斥操作法见 §5。

---

## 0. 现场布局速查

| 对象 | 路径 / 名称 | 说明 |
|---|---|---|
| 源码仓库（唯一真相） | `~/projects/tengu-bcdice-tg` | 本地 git，不推远端；开发在这里 |
| 构建上下文 | `/opt/<project>/src` | rsync 镜像（生产不做开发，计划 §9） |
| 数据卷（宿主侧） | `/opt/<project>/data` | 容器挂载为 `/app/data`：`tengu.db*` + `.env` |
| 备份目录 | `/opt/backups/<project>/` | `tengu-YYYYMMDD.db` ×7；属主 <deploy-user>、mode 700 |
| 备份互斥锁 | `/opt/<project>/.backup.lock` | `scripts/backup.sh` 的 flock 自互斥（env `TENGU_BACKUP_LOCK` 可覆盖） |
| 备份日志 | `/opt/<project>/backup.log` | cron 追加重定向（脚本自身不投递，见 §4.1） |
| 镜像 | `tengu-bcdice-tg:latest`（+ 历史 tag） | 88.3MB content；tag 纪律见 §1.4 |
| 容器名 | `tengu-bcdice-tg` | T4.5 上线后存在；**当前（上线前）无容器在跑** |
| 证据目录 | `/opt/<project>/t4.1-evidence/`、`t4.2-evidence/` | 构建/冒烟/备份验证日志（机器本地，不入库） |
| 健康监控脚本 | `<agent-home>/scripts/server-health-check.sh` | 检查项 7 = 备份新鲜度（T4.2 登记，§4.1） |

只读红线（贯穿一切运维动作）：`vendor/bundle/**` 与 `references/src/**` 绝不修改——
这是「`bundle update` 零冲突升级」的根基（计划 §0.3 钉版纪律，台账 `docs/REFERENCES.md`）。

---

## 1. 部署（首次 / 换版）

### 1.1 构建链路：rsync → docker build

生产镜像只从 `/opt/<project>/src` 构建。推送源码（在 repo 根执行；命令出自
T4.1 报告 §2，已实施）：

```bash
rsync -a --delete \
  --exclude='/.git/' --exclude='/.env' --exclude='/.bundle/' --exclude='/vendor/' \
  --exclude='/references/src/' --exclude='/data/' --exclude='/tmp/' \
  --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.log' \
  ~/projects/tengu-bcdice-tg/ /opt/<project>/src/
```

构建（构建上下文必须是 `/opt/<project>/src`）：

```bash
cd /opt/<project>/src && sudo docker build -t tengu-bcdice-tg:latest .
# 想要不借缓存的全量重建（首次 / 排障时）：
cd /opt/<project>/src && sudo docker build --no-cache -t tengu-bcdice-tg:latest .
```

**构建闸门（计划 §9 原样获得）**：builder 阶段跑 `bundle exec rake verify`
（spike 19 项 + 引擎层 785 + bot/db 796）——**任何一段红 = `RAKE` non-zero =
构建失败、新镜像不产出**，旧容器全程不动。（T4.1 实测：三段全绿才
`Successfully built`，证据 `/opt/<project>/t4.1-evidence/t4.1-build.log`。）

**两个实测坑（已修，防复发）**：
- rsync 与 `.dockerignore` 的「裸名字模式」（如 `data/`）都会匹配**任意深度**的
  同名目录——曾把 `test/data/`（toml 夹具）滤掉、构建闸门当场红（`No target found!`）。
  两侧一律用 `/` 锚定根目录模式（写法见上），别改回裸名。
- 本机 legacy builder 无 `--progress`/buildx；取证用 `--no-cache` + 日志重定向。
  换版构建后回收中间层：`sudo docker image prune -f`（T4.1 实测回收 393.5MB，R10）。

### 1.2 docker run 参数全家福（正式容器）

前置：`.env` 已在数据卷就位（§1.3），否则**先填再起**。

```bash
sudo docker run -d \
  --name tengu-bcdice-tg \
  --restart unless-stopped \
  --log-opt max-size=10m --log-opt max-file=3 \
  -v /opt/<project>/data:/app/data \
  tengu-bcdice-tg:latest
```

逐个解释（均有 T4.1 实证）：

| 参数 | 作用 | 实证依据 |
|---|---|---|
| `--restart unless-stopped` | 主进程崩溃自动拉起；`docker stop/kill` 为手动停止**不**自动拉起 | t4.1 §5.3 三分表 |
| `--log-opt max-size=10m --log-opt max-file=3` | 逐容器 json-file 轮转（上限 ≈30MB）；不动 daemon.json（本机同跑 4 个无关服务，blast radius 不值） | t4.1 §6 |
| `-v /opt/<project>/data:/app/data` | 数据卷：SQLite + `.env`；重建镜像/换容器不丢数据 | 计划 §9 |
| （无端口映射） | 长轮询 `getUpdates`，零入境端口，免 SSL 证书 | 计划 §3 决7 |

容器内进程以 uid/gid 1000（`tengu`）运行，与宿主 `<deploy-user>`(1000) 对齐——卷内文件
直接可读，实测容器写的 `tengu.db*` 属主 `<deploy-user>`（t4.1 §4）。

### 1.3 .env 卷内自填纪律

- 生产 `.env` 路径：**`/opt/<project>/data/.env`**（数据卷内）。镜像里
  **没有** `.env`（`.dockerignore` 排除）；`config.rb` 默认找 `/app/.env` 不存在，
  由镜像 ENV `TELEGRAM_ENV_FILE=/app/data/.env` 指向数据卷（`bot/config.rb`
  `load_dotenv!` / Dockerfile 注释）。
- 模板 = 仓库 `.env.example`（键位清单：`TELEGRAM_BOT_TOKEN`、`TELEGRAM_BOT_TOKEN_TEST`、
  `TENGU_ENV`、`LOG_ROLLS`、`LOGGING_ENABLED`、`DB_PATH`）。**值由用户本人填写，
  agent 不代写**；建议 `chmod 600`。容器内 `DB_PATH` 用默认 `/app/data/tengu.db` 即可。
- 缺 token 时 bot 会**清晰报错 exit 1**（只报键名不报值）；但此时 `--restart` 会把
  「反复退出」当崩溃——空转重启刷日志（不损坏数据）。所以：**先填 .env 再 docker run**。

### 1.4 镜像 tag 纪律与现状

换版前先给现役镜像留回滚锚点（`latest` 马上会被新构建覆盖）：

```bash
sudo docker tag tengu-bcdice-tg:latest tengu-bcdice-tg:rollback-$(date +%Y%m%d)
```

当前保存的 tag（2026-10-12 实测 `sudo docker images`，会随版本演进）：
`tengu-bcdice-tg:t4.1-20261012`（首版）、`tengu-bcdice-tg:t4.1-20261012-fixes`
（T4.1-review 修订版，`latest` 当前指向它）。二者指向不同镜像 ID，均保留供 T4.5 使用。

### 1.5 部署后验证（T4.5 上线时执行）

```bash
sudo docker ps                       # State=running
sudo docker logs --tail 50 tengu-bcdice-tg
# 期待启动序列（T4.1 冒烟实录，t4.1-report §5.2）：
#   [T3.1] 天狗骰子 bot 启动中…（token_key=…，值不打印）
#   [T3.1] 主轨菜单已注册：/start /help /settings /roll /nd /system /secret /bank /ct /log
#   [T3.1] @username="…"；路由=slash 主轨 + 裸 ASCII 辅助轨 + 按钮回调分支
```

随后在测试话题先打一条 `/roll SB` 验证容器内端到端掷骰（I18n→表求值→切段→发送
四段在容器形态的首跑，登记为 T4.5 验收项，t4.1-review 评审提案 #1），再开正式群。

---

## 2. 升级 BCDice gem

### 2.1 前提（零冲突升级的根，勿破坏）

- `vendor/bundle/**` 与 `references/src/**` **只读**；扩展类在 `game_systems/`
  继承注册（上游零修改）——升级风险仅剩 R1「超类内部方法签名变化」，由
  `test/engine_structure_test.rb` 结构断言守卫（红了先看它）。
- `Gemfile.lock` 入库；镜像构建 `BUNDLE_FROZEN=true`（Gemfile 与 lock 漂移 =
  构建失败，fail-closed，R9）；bundler 钉 `4.0.22`（= lock 的 `BUNDLED WITH`）。
- 升级时需手动 diff 上游三处核心机制（我们在扩展/ Runner 里复制或覆写过其语义，
  见 `Gemfile` 头注释）：`base.rb` 的 `prefixes_pattern` / `dice_command`
  （secret 捕获语义）、`NinjaSlayer2.rb` 的 `proc_dice_2nd`（`proc_ex_diceroll`
  复制其骨架）。

### 2.2 升级步骤

```bash
# ① 本机 repo：改 Gemfile 钉版（例：gem "bcdice", "X.Y.Z"），然后
bundle update bcdice
bundle exec rake verify            # 必须全绿才继续（红 = 停手排查，别抱侥幸）
git add Gemfile Gemfile.lock       # lock 一并入库
git -c user.name='DeconstructionR2' -c user.email='129867793+DeconstructionR2@users.noreply.github.com' commit -m '…'

# ② 留回滚锚点 → rsync（在 repo 根执行，命令与 §1.1 完全一致）→ 构建
sudo docker tag tengu-bcdice-tg:latest tengu-bcdice-tg:rollback-$(date +%Y%m%d)
cd /opt/<project>/src && sudo docker build -t tengu-bcdice-tg:latest .

# ③ 换容器（数据卷不动）
sudo docker stop tengu-bcdice-tg && sudo docker rm tengu-bcdice-tg
sudo docker run -d \
  --name tengu-bcdice-tg \
  --restart unless-stopped \
  --log-opt max-size=10m --log-opt max-file=3 \
  -v /opt/<project>/data:/app/data \
  tengu-bcdice-tg:latest
```

### 2.3 回滚（旧镜像 tag 换回）

```bash
sudo docker stop tengu-bcdice-tg && sudo docker rm tengu-bcdice-tg
# docker run 与 §1.2 同一条命令，仅镜像标签换成回滚锚点：
sudo docker run -d \
  --name tengu-bcdice-tg \
  --restart unless-stopped \
  --log-opt max-size=10m --log-opt max-file=3 \
  -v /opt/<project>/data:/app/data \
  tengu-bcdice-tg:rollback-YYYYMMDD
```

换容器只换代码；账目/自定义表/log 全在数据卷，不受升级与回滚影响（计划 §9）。

### 2.4 上游源码快照升级（另一件事）

只有在需要重跑数据 diff / 对照时才重取 `references/src/` 快照；流程 = 重克隆 →
`docs/REFERENCES.md` 登记新旧 commit hash → 重跑数据 diff 报告
（`docs/REFERENCES.md` 顶部「升级快照流程」原文）。gem 升级与快照重取互相独立。

---

## 3. 备份与恢复

### 3.1 日备机制（T4.2 已落地）

- cron（<deploy-user> 用户，`crontab -l` 第 3 行实测）：

```
30 4 * * * <repo-path>/scripts/backup.sh >> /opt/<project>/backup.log 2>&1
```

- **cron 直调 repo 路径**（不另拷 `/opt`）：脚本随 repo 版本管理，单一真相；
  repo 若迁移/删除 cron 静默失效 → 由 §4.1 的 36h 新鲜度检查兜底告警。
- 备份落 `/opt/backups/<project>/tengu-YYYYMMDD.db`，保留 7 份（T4.2 报告 §3）。

### 3.2 备份脚本行为表（`scripts/backup.sh`，按当前代码口径）

| 场景 | 行为 | 退出码 |
|---|---|---|
| 并发双跑 | flock 自互斥（先抢锁再干活）；另一实例在跑 → stderr 结构性 ERROR、本次退出 | 1 |
| 路径含单引号 | 提前明确拒绝（`.backup` 点命令无法承载单引号路径，失败安全） | 1 |
| DB 不存在（未上线 / 尚未生成） | stdout 一行说明，不建备份目录 | 0 |
| DB 存在 | 写 `tengu-YYYYMMDD.db.tmp-$$` → `sqlite3 ".backup ..."`（**在线一致备份**，免停容器；WAL 下裸 `cp` 非严格一致——E3 实证）→ `PRAGMA integrity_check` 自检 → `mv -f` **原子顶替** | 0 |
| 同日重跑 | 同上一行的 tmp→验→mv 路径；旧同日档在新档验完前**不动**，失败不丢既有备份 | 0 |
| 保留 | 只清理严格形态 `tengu-[0-9]{8}.db` 超龄者（其他文件绝不误删） | 0 |
| 失败（sqlite3 非零 / 目录不可写 / 完整性不过） | tmp 半成品当场删（防「假新鲜」骗过监控）+ stderr 结构性 ERROR | 1 |

手动跑 / 干跑（干跑不碰生产路径；锁路径可用 `TENGU_BACKUP_LOCK` 覆盖）：

```bash
scripts/backup.sh
TENGU_DB_PATH=/tmp/x.db TENGU_BACKUP_DIR=/tmp/bk scripts/backup.sh
```

（并发互斥与 tmp+mv 原子顶替为 T4.2-review 落地——原「先删旧同名」实现已被推翻，
以代码为准。）

### 3.3 查看与自检

```bash
ls -lt /opt/backups/<project>/
sqlite3 /opt/backups/<project>/tengu-YYYYMMDD.db "PRAGMA integrity_check;"
tail -5 /opt/<project>/backup.log        # 日备行为转录
```

### 3.4 恢复演练步骤（T4.5 验收项；按计划 §8 Phase 4 验收执行一次）

前置：备份文件已按「可直接开库」验证过（integrity ok，t4.2 §5）；恢复前**先在群里
记录预期状态**（`/bank balance`、`/ct list`、`/log list` 的输出），恢复后逐条对照。

```bash
# 0) 停容器（手动停止；unless-stopped 不会自动拉起）
sudo docker stop tengu-bcdice-tg

# 1) 隔离坏库（保留现场，事后可分析）
cd /opt/<project>/data
mv tengu.db tengu.db.broken-$(date +%Y%m%d)
#    关键：旧库的 -wal/-shm 挂件一并清掉——SQLite 打开新主文件时会把残留 WAL
#    当恢复日志处理，必须删除（备份文件是 .backup 产出、内容自洽，不需要 WAL）。
rm -f tengu.db-wal tengu.db-shm

# 2) 放回备份（以 <deploy-user> 身份复制，属主即 uid1000，与容器内 tengu 同 uid）
cp /opt/backups/<project>/tengu-YYYYMMDD.db tengu.db

# 3) 起容器（容器还在用 start；已删则用 §1.2 的 docker run 全家福）
sudo docker start tengu-bcdice-tg
sudo docker logs --tail 50 tengu-bcdice-tg     # 启动序列正常

# 4) 群里核对：/bank balance、/ct list、/log list 与步骤 0 记录一致
```

注意：
- **`.env` 不在备份范围**（凭据纪律，t4.2 R-c）——它长住数据卷，别在恢复中被覆盖掉；
- 恢复演练全程遵守 §5 单实例红线（停容器后再动库文件）；
- 机器级容灾（整机快照）由部署主机既有云厂商镜像快照体系覆盖，本项目不重复建设
  （计划 §9 分工）。

---

## 4. 监控与告警

### 4.1 服务器健康监控（备份新鲜度项，T4.2 登记）

`<agent-home>/scripts/server-health-check.sh` 检查项 7（由主机监控 cron 驱动投递；
本手册只管其语义与自检）：

- 变量（脚本顶部）：`TENGU_DB=/opt/<project>/data/tengu.db`、
  `TENGU_BACKUP_DIR=/opt/backups/<project>`、`BACKUP_WARN_H=36`。
- 语义：**仅当生产库存在（=已上线）才查**；最新 `tengu-[0-9]{8}.db`（严格 8 位日期
  glob，与 backup.sh 清理口径一致；畸形名不遮蔽陈旧）超过 36h 未更新 → 告警；
  库存活但零备份 → 也告警（「从未更新（∞）」）；stat 竞态守卫（取最新与读 mtime
  之间文件消失 → 本轮静默跳过，零噪音）；未上线 → 静默；脚本恒 `exit 0`
  （告警只进 `ALERTS` 字符串，不影响退出码）。
- 手动自检：`bash <agent-home>/scripts/server-health-check.sh`——绿 = 零输出 exit 0
  （2026-10-12 实测通过；未上线态下 tengu 项静默）。
- 已知窗口：上线首日 DB 出现后、首次日备前（最长到次日 04:30）会报一次
  「无任何备份」，属预期；上线当天手动跑一次 `scripts/backup.sh` 即消除（t4.2 R-d）。

### 4.2 容器侧日常查看

```bash
sudo docker ps                                   # 状态与运行时长
sudo docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' tengu-bcdice-tg
sudo docker logs --tail 200 tengu-bcdice-tg      # 或 -f 跟随；json-file 轮转上限 ≈30MB
```

运营日志（stdout/stderr → docker json-file）与跑团 log（显式 `/log` 录制、落 SQLite）
是两套东西：跑团 log 不受 docker 日志轮转影响。

### 4.3 restart 策略语义（`unless-stopped` 三分，t4.1 §5.3 实测）

| 场景 | 行为 |
|---|---|
| 主进程死亡（如 OOM/异常退出） | 自动拉起，`RestartCount` +1 |
| `docker stop` / `docker kill`（手动停止） | 保持停止，**不**自动拉起；`docker start` 手动恢复 |
| 进程非零退出循环（如缺 token 的崩溃循环） | 策略接管，`RestartCount` 持续上涨（查 logs 修因） |

排障小抄：容器内对 **PID1** 发信号（含 `SIGKILL`）会被内核丢弃（实测 `rc=0` 而进程
存活）——模拟「主进程死亡」要从**宿主侧** kill；`docker stop` 已由 `bot/main.rb` 的
`Signal.trap("TERM"){ exit 0 }` 保证干净退出（T4.1-review）。

### 4.4 磁盘纪律（R10）

```bash
df -h /                              # 根盘水位
du -sh /opt/backups/<project> /opt/<project>/data
sudo docker system df                # 镜像/容器/卷占用
sudo docker image prune -f           # 换版构建后回收中间层（T4.1 实测回收 393.5MB）
```

### 4.5 常见故障排查表

| 症状 | 排查/处置 | 出处 |
|---|---|---|
| 群里零反应，容器 `running` | `docker logs --tail 200`：有启动序列行吗？无 → 容器在崩溃循环（看 `ps -a` 状态与 `RestartCount`，排 §4.3）；有 → 查 409（§5）与 DB 锁 | t4.1 §5 |
| **菜单没注册上**（客户端菜单缺命令/点了没反应） | 启动日志应含「[T3.1] 主轨菜单已注册：…」；缺它 = `register_main_commands` 失败 → 启动**裸退 exit 1**（不会带病长轮询）。日志看「[T2.4] 注册主轨菜单失败」行，常见=token 无效/属于另一个 bot/网络不通；核对 `.env` 的 `token_key` 分支（`TENGU_ENV`）后重启 | `bot/main.rb` L113-126、`bot/config.rb` |
| **409 双轮询** | 见 §5 红线：同 token 出现了第二个 getUpdates 消费者。症状 = 容器 `RestartCount` 持续上涨 / dev 进程突然死亡；日志异常类 `Telegram::Bot::Exceptions::ResponseError` | t4.1 §5.1（gem 409 崩溃链源码实证） |
| **ephemeral 消失**（暗骰结果/按钮不见了） | 已知行为：ephemeral 消息约 25 分钟后消失（T2.2 客户端实测）。补救：本人打 `/secret last` 重取（复用原行、本人限定）；要留痕就用「公开」按钮走常规消息 | t2.2 报告、t3.1 报告 |
| **导出失败**（`/log end` 回执报发送失败） | 回执措辞「导出文件发送失败——录制数据已保留」时数据都在库里（`/log list` 可见）；查 logs 里 `SendError`（网络抖动/请求被 400）。重发入口未实现（backlog `/log export`），目前只能人工从 DB 导 | t3.5 报告 §4 决策 11、§6.3 |
| **DB 锁**（`BusyException` 结构性 warn） | 设计口径 = 单进程单连接（`db/connection.rb`）。确认没有第二个进程连同一库：`pgrep -af 'bot/main.rb'`；`sudo lsof /opt/<project>/data/tengu.db`。典型来源 = dev 进程与容器共用同一 data 目录 | `db/connection.rb` 注释、t3.2 评审 |
| 库损坏（`integrity_check` 不过） | 停容器 → §3.4 恢复演练步骤 | t4.2 §2 |
| token 类启动报错 | bot 只报键名不报值：核对 `/opt/<project>/data/.env` 是否就位、`TENGU_ENV` 分支是否与 token 匹配、token 是否被吊销 | `bot/config.rb` |

---

## 5. 双轮询 409 红线（dev 进程 ↔ 容器互斥操作法）

**事实（T4.1 实证，源码级）**：Telegram 每个 bot 只允许一个 `getUpdates` 消费者；
后到的请求会**终止**先到者的长轮询（409）。本仓库栈对 409 是**未捕获崩溃链**——
gem `api.rb` 非 200 即 raise；`client.rb#fetch_updates` 只 rescue
Timeout/ConnectionFailed；`bot/main.rb` 对 `listen` 无兜底 → **进程直接死**。
容器里表现为「重启循环」，dev 进程表现为「突然消失」。

**规则**：同 token 的消费者全集 =（dev 进程，`TENGU_ENV=test` 用测试 token）+
（该 token 对应容器）。**任何时刻只许一个活。** 本机现有一个 dev 测试进程在跑
（示例：`pid <pid>`，自 2026-10-12 01:11 起）——起任何用同 token 的容器前，
必须按下面的互斥时序处理，**不许 kill 它**：

```bash
PGREP_PID=$(pgrep -f 'bot/main.rb')   # ① 找到 dev 进程（pid 会变，别写死）
kill -STOP "$PGREP_PID"               # ② 冻结（SIGSTOP，不是 kill）
sleep 35                              # ③ 等在途长轮询租约到期（gem 内 timeout=20s，
                                      #    此后 Telegram 侧消费者数 = 0）
# ④ 起容器（独占轮询）→ 验证 → 删容器 → 确认无消费者
kill -CONT "$PGREP_PID"               # ⑤ 恢复（读掉缓冲空响应、立即重新轮询）
```

- 这套时序是 T4.1 冒烟实证过的操作法（两次执行，dev bot 全程同 pid 存活，
  `Ssl` 状态往返）；脚本化时**必须加 trap 兜底**：任何失败路径先删容器再 CONT。
- 冒烟/临时容器用完即 `docker rm -f`，别留第二个消费者。
- 正式上线后：正式 token 的消费者只有唯一容器；测试 token 的消费者归 dev 进程
  或测试用途容器——两个 token 可以各自有一个实例，同 token 内永远单实例。
- `docker stop`/`docker kill` 属「手动停止」语义（§4.3）：停了不会被策略拉起，
  这正好用于「换容器」与「恢复演练」期间保证零消费者。

---

## 6. 紧急处置（bot 无响应时的排查顺序）

1. `sudo docker ps -a` —— 容器活着吗？`RestartCount` 在涨吗？（涨 = 崩溃循环）
2. `sudo docker logs --tail 200 tengu-bcdice-tg` —— 找出启动序列行与异常类名
   （日志只记结构性信息、不含 token 值）。
3. `pgrep -af 'bot/main.rb'` —— 有没有第二个轮询实例（409 红线，§5）？
4. `sudo lsof /opt/<project>/data/tengu.db` —— 库被谁占着（DB 锁）？
5. token 链核验：`/opt/<project>/data/.env` 在不在、启动日志的
   `token_key=…` 分支对不对（**只看键名，绝不回显值**）。
6. 以上都对 → `sudo docker restart tengu-bcdice-tg`；仍无解 → 停容器保留现场
   （日志、镜像 tag 先别删），走 §3.4 从最近备份恢复。
7. 全程纪律：排查「无反应」时不要盲目连发真消息轰炸（限流 20 条/分/群）；
   先看日志再动手。

---

## 7. 相关文档索引

| 文档 | 内容 |
|---|---|
| `docs/t4.1-report.md` | Docker 化交付：三阶段镜像、构建闸门、冒烟、restart/日志轮转实证 |
| `docs/t4.2-report.md` | 备份落地：cron、脚本行为表、WAL 对照实证、监控登记 |
| `docs/t3.5-report.md` | 跑团 log 录制/导出（文件上传 FilePart 必修实证） |
| `docs/t3.1-report.md` | 暗骰 /secret：ephemeral 25 分钟实证、按钮回调接线 |
| `docs/REFERENCES.md` | 上游钉版台账（升级快照流程） |
| `docs/EXTENDING.md` | 四条扩展轴的扩展开发指南 |
| 计划 `<agent-home>/plans/2026-10-11_122428-tengu-bcdice-telegram-dicebot.md` | 唯一权威需求源（§9 本手册底稿） |
