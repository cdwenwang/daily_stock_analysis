#!/usr/bin/env bash
# ===================================
# DSA 恢复脚本（灾备重建用）
# ===================================
#
# 在按 deploy/RUNBOOK.md 完成「装 Docker + clone 仓库」之后执行，把备份归档里的
# .env / data / nginx 配置还原回去并拉起服务。
#
# 用法：
#   ./deploy/restore.sh /var/backups/dsa/dsa-20261002-031700.tar.gz
#   ./deploy/restore.sh /var/backups/dsa/dsa-20261002-031700.tar.gz --no-start

set -euo pipefail

APP_DIR="${APP_DIR:-/opt/stock-analyzer}"
NGINX_CONF_DST="${NGINX_CONF_DST:-/etc/nginx/conf.d/dsa.conf}"

archive="${1:-}"
start_services=1
[ "${2:-}" = "--no-start" ] && start_services=0

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

[ -n "$archive" ] || die "用法：$0 <备份归档路径> [--no-start]"
[ -f "$archive" ] || die "归档不存在：$archive"
[ -d "$APP_DIR" ] || die "APP_DIR 不存在：${APP_DIR}（请先按 RUNBOOK 完成 git clone）"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

tar xzf "$archive" -C "$work"
[ -f "$work/.env" ] || die "归档里没有 .env，拒绝继续（请确认归档是否完整）"

COMPOSE_ARGS=(-f "$APP_DIR/docker/docker-compose.yml" -f "$APP_DIR/deploy/docker-compose.prod.yml")

# 1. 停服务，避免恢复过程中有进程写数据库
if docker compose "${COMPOSE_ARGS[@]}" ps -q 2>/dev/null | grep -q .; then
    log "停止现有服务"
    docker compose "${COMPOSE_ARGS[@]}" down
fi

# 2. 旧 data/ 改名保留，避免新旧数据混杂（确认无误后可自行删除）
if [ -d "$APP_DIR/data" ]; then
    mv "$APP_DIR/data" "$APP_DIR/data.pre-restore.$(date +%Y%m%d-%H%M%S)"
    log "原 data/ 已改名为 data.pre-restore.*"
fi

# 3. 还原 .env 与 data/
log "恢复 .env 与 data/"
cp -a "$work/.env" "$APP_DIR/.env"
mkdir -p "$APP_DIR/data"
[ -d "$work/data" ] && cp -a "$work/data/." "$APP_DIR/data/"

# 4. 还原 nginx 配置
if [ -f "$work/dsa-nginx.conf" ]; then
    if [ "$(id -u)" = "0" ] || [ -w "$(dirname "$NGINX_CONF_DST")" ]; then
        cp -a "$work/dsa-nginx.conf" "$NGINX_CONF_DST"
        log "已恢复 nginx 配置到 $NGINX_CONF_DST"
    else
        cp -a "$work/dsa-nginx.conf" "$APP_DIR/dsa-nginx.conf.restored"
        log "无权限写 ${NGINX_CONF_DST}，已存到 $APP_DIR/dsa-nginx.conf.restored，请手动安装"
    fi
fi

# 5. 拉起服务
if [ "$start_services" = "1" ]; then
    log "拉起服务（需要已 docker login ghcr.io，见 RUNBOOK）"
    docker compose "${COMPOSE_ARGS[@]}" up -d --no-build
    sleep 5
    docker compose "${COMPOSE_ARGS[@]}" ps
    if curl -fsS http://127.0.0.1:8000/api/health >/dev/null 2>&1; then
        log "健康检查通过"
    else
        log "警告：健康检查未通过，执行 docker compose ${COMPOSE_ARGS[*]} logs --tail=100 排查"
    fi
fi

log "恢复完成。如新机器尚未配置证书：sudo certbot --nginx -d <你的域名>"
