#!/usr/bin/env bash
# 服务器侧部署脚本，由 .github/workflows/deploy.yml 通过 SSH 调用（也可手动跑）。
# 前提：代码已同步到 $APP_DIR（工作流负责 clone / reset），本机装有 docker compose。
#
# 做的事：读 .env → docker compose up -d --build → 健康检查。
# 不做的事：不碰 .env、不碰 data/（数据库与机密安全）。
#
# 技术栈无关：只要仓库根目录有 compose.yaml（或 docker-compose.yml）和对应 Dockerfile，
# Node / Python / Go 都是同一条路。第一次上线前需要：
#   1. 仓库里加 compose.yaml + Dockerfile，容器内监听 $PORT
#   2. 服务器上 cp .env.example /opt/agfp/.env 并填好机密（只做一次）
set -euo pipefail

APP_DIR="${APP_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$APP_DIR"
echo "==> 应用目录: $APP_DIR"

# 1) compose 文件必须存在，否则明确失败而不是“假成功”
COMPOSE=""
for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
  [ -f "$f" ] && { COMPOSE="$f"; break; }
done
if [ -z "$COMPOSE" ]; then
  echo "❌ 仓库根目录没有 compose.yaml —— 还没有可部署的应用。加上 compose.yaml + Dockerfile 后再合并。"
  exit 1
fi

# 2) .env：机密只在服务器，永不进 git
if [ ! -f .env ]; then
  if [ -f .env.example ]; then
    echo "⚠️ 未发现 .env，先用 .env.example 占位启动。请尽快 ssh 上来填好 /opt/agfp/.env 后重新部署。"
    cp .env.example .env && chmod 600 .env
  else
    echo "⚠️ 未发现 .env 也没有 .env.example，按无环境变量启动。"
    : > .env; chmod 600 .env
  fi
fi

# 3) 构建并滚动到新容器
HOST_PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2 || true)"; HOST_PORT="${HOST_PORT:-8789}"
HEALTH_PATH="$(grep -E '^HEALTH_PATH=' .env 2>/dev/null | cut -d= -f2 || true)"; HEALTH_PATH="${HEALTH_PATH:-/api/health}"
echo "==> docker compose -f $COMPOSE up -d --build"
docker compose -f "$COMPOSE" up -d --build --remove-orphans
docker image prune -f >/dev/null 2>&1 || true

# 4) 健康检查（只查本机端口；对外 https 由 nginx 反代，不在此脚本职责内）
echo "==> 等待 http://127.0.0.1:$HOST_PORT$HEALTH_PATH …"
ok=0
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$HOST_PORT$HEALTH_PATH" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [ "$ok" -eq 1 ]; then
  echo "✅ 部署成功：$(git log --oneline -1)"
else
  echo "❌ 健康检查未通过。最近日志："
  docker compose -f "$COMPOSE" logs --tail=50
  exit 1
fi
