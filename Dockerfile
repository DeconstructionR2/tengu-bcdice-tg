# ============================================================================
# Dockerfile — T4.1 生产镜像（multi-stage）
#
# 设计依据：计划 §9「部署与运维」+ §8 T4.1 + §12 R9（Docker 依赖解析漂移）。
#
# 三个阶段：
#   1. builder  —— 全量依赖（含 :test 组）+ 源码，跑 `bundle exec rake verify`
#                  作为**构建闸门**：测试失败 = 镜像不产出（计划 §9 升级流程）。
#   2. gems     —— 只装生产组（不装 :test）的 bundle，供 runtime 单独摘取。
#   3. runtime  —— 精简运行镜像：不带编译工具链、不带测试套件与参考资料，
#                  非 root 运行，入口 `ruby bot/main.rb`。
#
# 依赖解析纪律（R9）：全程只用 Gemfile.lock（BUNDLE_FROZEN=true —
# Gemfile 与 lock 漂移直接构建失败，而不是静默重新解析拉新版）。
# bundler 版本钉死 = Gemfile.lock 的 BUNDLED WITH（4.0.22）。
#
# 构建（生产机 /opt/<project>/src 为构建上下文）：
#   sudo docker build -t tengu-bcdice-tg:latest .
#
# 运行（正式）：数据卷 /opt/<project>/data → /app/data；
#   卷内 .env 由用户自填（TELEGRAM_BOT_TOKEN）；token 绝不进镜像（.dockerignore）。
#   sudo docker run -d --name tengu-bcdice-tg --restart unless-stopped \
#     --log-opt max-size=10m --log-opt max-file=3 \
#     -v /opt/<project>/data:/app/data tengu-bcdice-tg:latest
# ============================================================================

# --- 阶段 1/3：builder（构建闸门）-------------------------------------------
FROM ruby:3.4-slim@sha256:c12225b6a73743f943530d9e610f4ae78e0dbcffdcf797b01522a55f7d25acb3 AS builder

# 原生扩展编译依赖（bigdecimal/racc 等；sqlite3 走 lock 内预编译平台版，
# libsqlite3-dev 只是保险——预编译版万一不可用时可回退源码编译）
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential pkg-config libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

# bundler 钉版 = Gemfile.lock 的 BUNDLED WITH（R9：构建不重新解析依赖）
RUN gem install bundler -v 4.0.22 --no-document

# 冻结模式：lock 与 Gemfile 不一致时**构建失败**（fail-closed，防漂移）
ENV BUNDLE_FROZEN=true

WORKDIR /app

# 依赖层先行：Gemfile.lock 不变 → 此层缓存命中，源码改动不触发重装
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

# 源码层（.dockerignore 已排除 .git/vendor/bundle/references/src/data/.env 等）
COPY . .

# 构建闸门（计划 §9：测试失败 = 构建失败）：
#   rake verify = spike + 引擎层 toml 全量 + bot/db 层 minitest（三段全绿才算过）
RUN bundle exec rake verify

# --- 阶段 2/3：gems（只装生产组）--------------------------------------------
FROM ruby:3.4-slim@sha256:c12225b6a73743f943530d9e610f4ae78e0dbcffdcf797b01522a55f7d25acb3 AS gems

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential pkg-config libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

RUN gem install bundler -v 4.0.22 --no-document

WORKDIR /app
COPY Gemfile Gemfile.lock ./
# BUNDLE_WITHOUT=test：runtime 不带测试框架（test-unit/tomlrb/minitest/rake）
RUN BUNDLE_WITHOUT=test BUNDLE_FROZEN=true bundle install --jobs 4 --retry 3

# --- 阶段 3/3：runtime（精简运行镜像）---------------------------------------
FROM ruby:3.4-slim@sha256:c12225b6a73743f943530d9e610f4ae78e0dbcffdcf797b01522a55f7d25acb3 AS runtime

# 运行期系统依赖：SQLite 共享库（预编译 gem 已静态带库，此处兜底可移植性）
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 \
 && rm -rf /var/lib/apt/lists/*

# 生产 bundle（含 bundler 4.0.22；不含 :test 组）。
# BUNDLE_WITHOUT=test 必须在运行期也生效——否则 `bundle exec` 会因
# lock 里 test 组 gem 未安装而 GemNotFound。
COPY --from=gems /usr/local/bundle /usr/local/bundle
ENV BUNDLE_WITHOUT=test \
    BUNDLE_FROZEN=true \
    BUNDLE_APP_CONFIG=/usr/local/bundle \
    LANG=C.UTF-8

# 非 root 运行（计划 §9 容器化纪律）。
# uid 1000 与宿主机部署账号（<deploy-user>）对齐——卷文件读写走 owner 位即可；
# 注意 gid 1000 在宿主侧是 netdev 组而非 <deploy-user> 组（无害，owner 位足够，
# kimi T4.1 评审提案 #4 订正此处注释口径）。
RUN groupadd --gid 1000 tengu \
 && useradd --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin tengu

WORKDIR /app

# 只带运行所需文件（test/、references/、scripts/、docs/ 不进运行镜像）。
# NOTICE.md/LICENSE 必须随镜像：运行镜像含 TenguDiceBot 派生表数据（MIT 要求
# 许可文本与实质性部分随行），本项目自身 MIT 许可同理。
COPY bot/ bot/
COPY db/ db/
COPY lib/ lib/
COPY game_systems/ game_systems/
COPY i18n/ i18n/
COPY Gemfile Gemfile.lock ./
COPY NOTICE.md LICENSE ./

# 数据卷：SQLite（默认 /app/data/tengu.db，bot/config.rb）+ .env（用户自填）。
# TELEGRAM_ENV_FILE 指向卷内 .env——镜像里没有 .env（.dockerignore 排除），
# 容器内 config.rb 的默认路径 /app/.env 不存在，必须由该变量指向数据卷。
ENV TELEGRAM_ENV_FILE=/app/data/.env
RUN mkdir -p /app/data && chown tengu:tengu /app/data
VOLUME ["/app/data"]

USER tengu

# 入口：stdout/stderr 同步在 bot/main.rb 顶部已显式开启（docker logs 实时可见）
CMD ["bundle", "exec", "ruby", "bot/main.rb"]
