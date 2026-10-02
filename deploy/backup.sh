#!/usr/bin/env bash
# ===================================
# DSA 备份脚本
# ===================================
#
# 只备份「无法从 GitHub / GHCR 重建」的东西：
#   .env                       全部密钥，丢了要重新申请
#   data/                      SQLite 数据库、历史记录、runtime.env、HMAC 密钥
#   /etc/nginx/conf.d/dsa.conf 域名反代配置
#
# 代码和镜像不需要备份（分别在 GitHub 和 GHCR）。
#
# 用法：
#   ./deploy/backup.sh                                    # 只留本地
#   RCLONE_REMOTE=oss:my-bucket/dsa ./deploy/backup.sh    # 同时上传对象存储
#
# 定时（每天 03:17，避开整点；用 root 执行以便写入 /var/backups）：
#   sudo crontab -e
#   17 3 * * * RCLONE_REMOTE=oss:my-bucket/dsa /opt/stock-analyzer/deploy/backup.sh >> /var/log/dsa-backup.log 2>&1

set -euo pipefail

APP_DIR="${APP_DIR:-/opt/stock-analyzer}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/dsa}"
KEEP_DAYS="${KEEP_DAYS:-14}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/dsa.conf}"

COMPOSE_ARGS=(-f "$APP_DIR/docker/docker-compose.yml" -f "$APP_DIR/deploy/docker-compose.prod.yml")
STAMP="$(date +%Y%m%d-%H%M%S)"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

[ -d "$APP_DIR" ] || die "APP_DIR 不存在：$APP_DIR"
[ -f "$APP_DIR/.env" ] || log "警告：$APP_DIR/.env 不存在，本次备份将不含密钥"

if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
    die "无法创建 ${BACKUP_DIR}，请用 root 运行，或设置 BACKUP_DIR=<可写目录>"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- 1. data/ 目录（SQLite 先在容器内取一致性快照）-------------------------
if [ -d "$APP_DIR/data" ]; then
    running="$(docker compose "${COMPOSE_ARGS[@]}" ps --status running --services 2>/dev/null | head -n1 || true)"

    if [ -n "$running" ] && [ -f "$APP_DIR/data/stock_analysis.db" ]; then
        log "服务 $running 运行中，用容器内 sqlite3 backup 取一致性快照"
        # 服务运行中直接 copy 数据库可能拿到写了一半的文件（WAL 未 checkpoint）
        if docker compose "${COMPOSE_ARGS[@]}" exec -T -u dsa "$running" python - <<'PY'
import sqlite3

src = sqlite3.connect('/app/data/stock_analysis.db')
dst = sqlite3.connect('/app/data/.dsa-backup.db')
src.backup(dst)
dst.close()
src.close()
PY
        then
            cp -a "$APP_DIR/data" "$work/data"
            mv -f "$APP_DIR/data/.dsa-backup.db" "$work/data/stock_analysis.db"
        else
            log "警告：容器内快照失败，退化为直接复制（归档可能不一致）"
            cp -a "$APP_DIR/data" "$work/data"
        fi
    else
        log "服务未运行，直接复制 data/"
        cp -a "$APP_DIR/data" "$work/data"
    fi
    rm -f "$APP_DIR/data/.dsa-backup.db"
fi

# --- 2. 密钥与反代配置 -----------------------------------------------------
[ -f "$APP_DIR/.env" ] && cp -a "$APP_DIR/.env" "$work/.env"
[ -f "$NGINX_CONF" ] && cp -a "$NGINX_CONF" "$work/dsa-nginx.conf"

# --- 3. 打包 ---------------------------------------------------------------
archive="$BACKUP_DIR/dsa-$STAMP.tar.gz"
tar czf "$archive" -C "$work" .
log "已生成 ${archive}（$(du -h "$archive" | cut -f1)）"

# --- 4. 上传对象存储（可选，失败不影响本地备份）----------------------------
if [ -n "$RCLONE_REMOTE" ]; then
    if command -v rclone >/dev/null 2>&1; then
        if rclone copy "$archive" "$RCLONE_REMOTE"; then
            log "已上传到 $RCLONE_REMOTE"
        else
            log "警告：上传 $RCLONE_REMOTE 失败，本地备份仍然可用"
        fi
    else
        log "警告：未安装 rclone，跳过上传（安装见 deploy/RUNBOOK.md）"
    fi
fi

# --- 5. 轮转 ---------------------------------------------------------------
find "$BACKUP_DIR" -name 'dsa-*.tar.gz' -mtime +"$KEEP_DAYS" -delete
log "完成，本地保留最近 $KEEP_DAYS 天"
