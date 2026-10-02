# DSA 部署与运维手册（fork 自用）

本手册对应 `cdwenwang/daily_stock_analysis` 这个 fork 在自有 ECS + 域名上的部署方式。
面向三个问题：**怎么部署**、**改了代码怎么上线**、**ECS 挂了怎么重建**。

> 上游官方文档 `docs/DEPLOY.md`、`docs/deploy-webui-cloud.md` 描述的是「在服务器上编译代码」的路线。
> 本 fork 走的是「CI 构建镜像 + ECS 只拉镜像」路线，因为要长期改代码，ECS 上不编译可以省掉 Node.js 环境、
> 大量内存占用和每次几分钟的构建等待，并且天然获得回滚能力。两者不冲突，本手册只描述后者。

---

## 1. 架构总览

```
本地 Mac                        GitHub                          ECS (Linux)
────────────────────────────────────────────────────────────────────────────
改代码                          fork: cdwenwang/...
git push ─────────────────────► PR → CI (ci.yml)
                                合并到 main
                                        │
                                        ▼
                                Actions: deploy-image.yml
                                构建镜像并推送
                                        │
                                        ▼
                                GHCR: ghcr.io/cdwenwang/
                                      daily_stock_analysis
                                      ├── :prod          ← 最新
                                      └── :sha-<commit>  ← 回滚锚点
                                        │
                                        │  docker compose pull
                                        ▼
                                /opt/stock-analyzer/
                                ├── .env           ← 唯一真源，已 gitignore
                                ├── data/          ← SQLite + runtime.env
                                ├── logs/ reports/ ← 可丢弃
                                └── deploy/docker-compose.prod.yml
                                        │
                                        ▼
                                容器: stock-server (--serve-only)
                                      ← 单容器同时承担 Web 与定时分析，见 §3.5
                                        │
                                        ▼
                                Nginx :80/:443 ──► 你的域名
```

核心原则：

- **ECS 上永远不编译代码**，只拉镜像。
- **代码和镜像不需要备份**（GitHub / GHCR 就是备份）。
- **只有 `.env` + `data/` 需要备份**，这决定了灾备恢复的速度。

---

## 2. 一次性设置

### 2.1 GitHub 侧

1. **开启 Actions 写权限**（fork 默认没有，不开会导致镜像推送失败）
   `Settings → Actions → General → Workflow permissions` → 选 **Read and write permissions** → Save

2. **确认 fork 里不需要的 workflow 已禁用**（可选但推荐，避免无用构建和失败噪音）
   `Actions` 页面里逐个选中后点 `Disable workflow`：
   - `auto-tag.yml`、`create-release.yml`、`desktop-release.yml`（官方发版用）
   - `ghcr-dockerhub.yml`（强依赖 Docker Hub secrets，没配必然失败）

   保留：`CI`（PR 时跑测试）、`00-daily-analysis.yml`（备用）、`Build Deploy Image`（本 fork 的部署构建）。

3. **首次构建后设置包可见性**
   触发一次构建（对 main 任意 push，或 Actions 页面手动 `Run workflow`），然后到
   `https://github.com/users/cdwenwang/packages/container/daily_stock_analysis/settings`
   把可见性设为 **Public**。
   不想公开也可以，那样 ECS 上需要 `docker login ghcr.io`（见 3.4）。

### 2.2 ECS 侧规格

| 项 | 建议 |
| --- | --- |
| 配置 | 2C2G 起步；只跑单个服务 1G 也可，同时跑 analyzer + server 建议 2G+ |
| 磁盘 | 20G+（镜像约 1G，加数据/日志/报告） |
| 系统 | Ubuntu 22.04 / 24.04 |
| 安全组 | **只放行 22 / 80 / 443**，不要放行 8000 |

---

## 3. 首次部署

### 3.1 装 Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# 退出 SSH 重新登录，让 docker 组生效
```

### 3.2 拉代码

```bash
sudo mkdir -p /opt/stock-analyzer && sudo chown "$USER" /opt/stock-analyzer
git clone https://github.com/cdwenwang/daily_stock_analysis.git /opt/stock-analyzer
cd /opt/stock-analyzer
chmod +x deploy/*.sh
```

### 3.3 配置 .env

```bash
cp deploy/env.template .env
vim .env          # 按模板注释填写：自选股 + 至少一个模型 key + 至少一个通知渠道
```

`.env` 已经在仓库 `.gitignore`（第 2 行）里，不会被 `git pull` 覆盖或误提交。

### 3.4 登录镜像仓库（仅当包设为 private 时需要）

```bash
# 在 GitHub 生成 PAT，勾选 read:packages
echo '<你的PAT>' | docker login ghcr.io -u cdwenwang --password-stdin
```

登录信息存在 `~/.docker/config.json`，**这个文件已包含在备份脚本的考虑范围内**（见第 6 节说明），
重建时若忘了密码可直接重新登录。

### 3.5 选择容器拓扑（重要，先看这段）

compose 里定义了两个服务，**不要无脑全起**：

| 服务 | 启动命令 | 作用 |
| --- | --- | --- |
| `analyzer` | `main.py --schedule` | 纯 CLI 调度循环 |
| `server` | `main.py --serve-only` | FastAPI + Web 界面；`SCHEDULE_ENABLED=true` 时**同时**接管定时分析 |

两个调度器之间**没有跨进程互斥**：`src/services/runtime_scheduler.py` 用的运行锁
`_RUNTIME_ANALYSIS_LOCK` 是进程内的线程锁，而 `main.py` 判断是否启动运行时调度器的
条件是 `args.schedule or config.schedule_enabled`（即受 `.env` 里的 `SCHEDULE_ENABLED` 影响）。
所以：

| 配置 | 结果 |
| --- | --- |
| `SCHEDULE_ENABLED=false`（上游默认）+ 两个服务同起 | ✅ analyzer 调度，server 只做 Web |
| **`SCHEDULE_ENABLED=true` + 两个服务同起** | ❌ **到点分析两次、推送两遍** |
| `SCHEDULE_ENABLED=true` + **只起 `server`** | ✅ 一个进程同时管 Web 和调度 |

**推荐只起 `server`**：少一个容器、内存占用减半，且不会重复推送。
只有把 `SCHEDULE_ENABLED` 保持为 `false` 时才有必要单独起 `analyzer`。

### 3.6 设置上线命令别名

```bash
sudo tee /usr/local/bin/dsa-up >/dev/null <<'SH'
#!/usr/bin/env bash
# 默认只管理 server；需要操作别的服务时：dsa-up analyzer
set -euo pipefail
cd /opt/stock-analyzer
COMPOSE=(-f docker/docker-compose.yml -f deploy/docker-compose.prod.yml)
SERVICES=("$@")
[ ${#SERVICES[@]} -eq 0 ] && SERVICES=(server)
docker compose "${COMPOSE[@]}" pull "${SERVICES[@]}"
docker compose "${COMPOSE[@]}" up -d --no-build "${SERVICES[@]}"
docker compose "${COMPOSE[@]}" ps
SH
sudo chmod +x /usr/local/bin/dsa-up
```

### 3.7 启动

```bash
dsa-up                                  # 只起 server（Web + 定时分析）
curl -fsS http://127.0.0.1:8000/api/health && echo OK
```

### 3.8 Nginx + 域名 + HTTPS

```bash
sudo apt update && sudo apt install -y nginx certbot python3-certbot-nginx
sudo cp deploy/nginx.conf /etc/nginx/conf.d/dsa.conf
sudo sed -i 's/dsa.example.com/你的域名/' /etc/nginx/conf.d/dsa.conf
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d 你的域名        # 自动申请证书 + 配置自动续期
```

DNS 记得提前把域名的 A 记录指向 ECS 公网 IP，证书签发才能通过校验。

### 3.9 验证清单

- [ ] `curl http://127.0.0.1:8000/api/health` 返回正常
- [ ] 浏览器打开 `https://你的域名`，出现登录/初始化密码页面
- [ ] 首次访问设置管理密码（`ADMIN_AUTH_ENABLED=true` 生效）
- [ ] 手动跑一次分析，确认通知能收到：
      `docker compose -f docker/docker-compose.yml -f deploy/docker-compose.prod.yml exec -u dsa stock-server python main.py --no-notify`
- [ ] 去掉 `--no-notify` 再跑一次，确认飞书/企业微信收到推送

---

## 4. 日常上线

### 4.1 标准流程

```bash
# 本地
git checkout -b feat/xxx
# ... 改代码 ...
./scripts/ci_gate.sh                    # 本地先过一遍
python -m pytest -m "not network"
git push origin feat/xxx
# 在 GitHub 上开 PR 到自己的 main
```

> `ci.yml` 只在 **pull_request** 时触发，直接 push 到 main 不会跑测试。
> 所以务必走 PR，哪怕是在自己的 fork 里。

PR 合并到 main 后，`Build Deploy Image` 自动构建并推送镜像（约 5-10 分钟，有 gha 缓存会更快）。
构建完成后再上线：

```bash
ssh <你的ECS>
dsa-up                                  # 约 30 秒
docker compose -f docker/docker-compose.yml -f deploy/docker-compose.prod.yml logs -f --tail=100
```

### 4.2 回滚

每个 commit 都推了 `:sha-<commit>` tag，回滚就是把镜像 tag 钉到旧版本：

```bash
cd /opt/stock-analyzer
# 找到要回的版本（也可以在 GitHub Actions 的 Summary 里看）
vim deploy/docker-compose.prod.yml      # 把 :prod 改成 :sha-<旧commit>
dsa-up
```

回滚是**幂等且即时**的，不需要重新构建，这是这套架构相对「ECS 本地 build」最大的价值。

### 4.3 同步上游更新

```bash
git fetch upstream
git merge upstream/main
git push origin main                    # 触发构建 → dsa-up
```

建议每月一次，不要攒太久（攒久了冲突量会爆炸）。

**降低冲突的做法**：尽量不改 upstream 跟踪的文件。
- 配置类需求 → 加环境变量 / 用 `.env`
- 部署类需求 → 放 `deploy/`（本 fork 独有目录）
- 新功能 → 新增文件而不是改现有文件

---

## 5. 备份

### 5.1 备份什么

| 内容 | 位置 | 需要备份 |
| --- | --- | --- |
| 代码 | GitHub | 否 |
| 镜像 | GHCR | 否 |
| **`.env`** | ECS | **必须**（丢了要重新申请所有 key） |
| **`data/`** | ECS | **必须**（数据库、历史记录、WebUI 保存的配置） |
| **nginx 配置** | ECS | **必须**（重建时省 3 分钟） |
| `reports/` | ECS | 可选（能重新生成） |
| `logs/` | ECS | 否 |

### 5.2 配置自动备份

```bash
# 1. 测试跑一次
cd /opt/stock-analyzer
sudo ./deploy/backup.sh

# 2. 配置对象存储上传（可选但强烈建议）
#    rclone 同时支持阿里云 OSS / 腾讯云 COS / S3，装一次就够
curl https://rclone.org/install.sh | sudo bash
rclone config          # 新建 remote，名字填 oss（阿里云选 "Alibaba Cloud (Aliyun) Object Storage System"，
                       # 腾讯云选 "Tencent Cloud Object Storage (COS)"）

# 3. 加定时任务
sudo crontab -e
17 3 * * * RCLONE_REMOTE=oss:my-bucket/dsa-backup /opt/stock-analyzer/deploy/backup.sh >> /var/log/dsa-backup.log 2>&1
```

备份脚本的两个要点：
- **SQLite 用 `.backup()` API 取快照**，不直接复制文件（服务运行中直接 copy 可能拿到 WAL 未 checkpoint 的半成品）。
- 上传失败**不会**影响本地备份，本地归档默认保留 14 天。

### 5.3 再加一层：云厂商自动快照

阿里云 / 腾讯云都可以给系统盘配置「自动快照策略」（每天一次、保留 7 天），成本极低。
这一层能覆盖「整机报废」的极端情况，且恢复时无需重新装环境。

---

## 6. 灾备重建（ECS 挂了）

### 6.1 先分清是哪种「挂了」

| 情况 | 处理 |
| --- | --- |
| 容器崩溃 / 进程退出 | **自动恢复**。compose 配置了 `restart: unless-stopped`，无需人工干预 |
| 机器重启 | **自动恢复**。Docker 服务自启，容器跟着起 |
| 磁盘损坏 / 机器报废 / 误删数据 | 按下文重建 |
| 误删 `.env` | 从最近备份里取回单个文件即可 |

### 6.2 重建清单（目标 10 分钟）

```bash
# ① 装 Docker（1 分钟）
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && exec su -l $USER

# ② 拉代码（30 秒）
sudo mkdir -p /opt/stock-analyzer && sudo chown "$USER" /opt/stock-analyzer
git clone https://github.com/cdwenwang/daily_stock_analysis.git /opt/stock-analyzer
cd /opt/stock-analyzer && chmod +x deploy/*.sh

# ③ 取回备份（1 分钟）—— 从 rclone / 对象存储控制台下载最新归档
rclone copy oss:my-bucket/dsa-backup/dsa-<最新>.tar.gz /var/backups/dsa/

# ④ 登录镜像仓库（仅 private 包需要，30 秒）
echo '<你的PAT>' | docker login ghcr.io -u cdwenwang --password-stdin

# ⑤ 恢复并拉起（1 分钟）
./deploy/restore.sh /var/backups/dsa/dsa-<最新>.tar.gz

# ⑥ Nginx + 证书（3 分钟）
sudo apt update && sudo apt install -y nginx certbot python3-certbot-nginx
sudo cp deploy/nginx.conf /etc/nginx/conf.d/dsa.conf   # restore.sh 也可能已经还原过
sudo sed -i 's/dsa.example.com/你的域名/' /etc/nginx/conf.d/dsa.conf
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d 你的域名

# ⑦ 重建上线别名
sudo tee /usr/local/bin/dsa-up >/dev/null <<'SH'
#!/usr/bin/env bash
# 默认只管理 server；需要操作别的服务时：dsa-up analyzer
set -euo pipefail
cd /opt/stock-analyzer
COMPOSE=(-f docker/docker-compose.yml -f deploy/docker-compose.prod.yml)
SERVICES=("$@")
[ ${#SERVICES[@]} -eq 0 ] && SERVICES=(server)
docker compose "${COMPOSE[@]}" pull "${SERVICES[@]}"
docker compose "${COMPOSE[@]}" up -d --no-build "${SERVICES[@]}"
docker compose "${COMPOSE[@]}" ps
SH
sudo chmod +x /usr/local/bin/dsa-up

# ⑧ 验证
curl -fsS http://127.0.0.1:8000/api/health && echo OK
```

只需改 DNS 指向新 IP（如果是换机器），HTTPS 证书重新签发一次即可，之后 certbot 自动续期。

### 6.3 别忘了恢复的部分

- [ ] DNS A 记录指向新 IP
- [ ] 云安全组放行 22 / 80 / 443
- [ ] `sudo crontab -e` 重新加回备份定时任务
- [ ] 对象存储的 rclone 配置（`~/.config/rclone/rclone.conf`）—— 建议同时纳入备份或单独存好

---

## 7. 排障速查

```bash
# 服务状态 / 日志
dsa-up
docker compose -f docker/docker-compose.yml -f deploy/docker-compose.prod.yml logs -f --tail=100

# 进容器（只跑 server 时容器名是 stock-server；跑 analyzer 时才是 stock-analyzer）
docker compose -f docker/docker-compose.yml -f deploy/docker-compose.prod.yml exec -u dsa stock-server bash

# 手动跑一次分析（不发通知）
docker compose -f docker/docker-compose.yml -f deploy/docker-compose.prod.yml exec -u dsa stock-server python main.py --no-notify

# 忘记 Web 管理密码
docker compose -f docker/docker-compose.yml -f deploy/docker-compose.prod.yml exec -u dsa stock-server python -m src.auth reset_password

# 页面能打开但样式错乱（静态资源 404）
# → 镜像里前端没打包好，重新触发 Actions 构建，然后 dsa-up
```

| 症状 | 排查方向 |
| --- | --- |
| 域名打不开 | 安全组 80/443 是否放行 → `sudo nginx -t` → `curl 127.0.0.1:8000/api/health` |
| 8000 本地通、域名不通 | Nginx 配置或证书问题，看 `/var/log/nginx/error.log` |
| 收不到推送 | 容器日志里找通知渠道报错；确认 `.env` 里渠道 key 没写错 |
| 分析任务没按点跑 | `SCHEDULE_ENABLED=true` 是否生效；`docker compose logs` 看调度输出 |
| 内存不足 / 容器被杀 | 提高 compose 里的 `limits.memory`；设 `MAX_WORKERS=1`；避免同时跑 analyzer + server |
| 数据库被锁 | 停服后删 `data/*.lock` |
| 图片上传失败 | Nginx `client_max_body_size` 是否放宽（本仓库的 nginx.conf 已设为 10m） |
| Agent 对话页不可用 | Nginx 是否透传 WebSocket（本仓库的 nginx.conf 已配置） |

---

## 8. 相关文档

- `docs/DEPLOY.md` —— 官方部署指南（覆盖 Docker / 直接部署 / systemd / GitHub Actions 四条路线）
- `docs/deploy-webui-cloud.md` —— 云服务器访问与 Nginx 反代细节
- `docs/intelligence-sources.md` —— 资讯源（含雪球热门）配置与 NewsNow 部署要求
- `docs/full-guide.md` —— 完整功能与配置说明
