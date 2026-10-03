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
                                构建镜像并推送（一份构建，推两个 registry）
                                        │
                          ┌─────────────┴──────────────┐
                          ▼                            ▼
                 阿里云 ACR（ECS 从这里拉）      GHCR（仅留后路）
                 crpi-u3rv49hccjew63jz          ghcr.io/cdwenwang/
                   -vpc.cn-beijing.personal        daily_stock_analysis
                   .cr.aliyuncs.com                 国内拉不动，勿用
                   /default-is/stock-analysis
                     ├── :prod          ← 最新
                     └── :sha-<commit>  ← 回滚锚点
                          │
                          │  docker compose pull（走 VPC 内网，所以快）
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
- **代码和镜像不需要备份**（GitHub 存代码、阿里云 ACR 存镜像，本身就是备份）。
- **只有 `.env` + `data/` 需要备份**，这决定了灾备恢复的速度。
- **镜像必须走 ACR，不能走 GHCR**：GHCR 的 blob 托管在 `*.githubusercontent.com`，
  国内 ECS 能建立 TCP 连接但收不到任何字节，`docker pull` 会永久挂起（实测确认）。

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

3. **添加 ACR 凭据到 Repository secrets**（构建时推送镜像到阿里云 ACR 用）
   `Settings → Secrets and variables → Actions` → New repository secret：

   | Name | 值 |
   | --- | --- |
   | `ACR_USERNAME` | 阿里云账号全名，如 `1179574672@qq.com` |
   | `ACR_PASSWORD` | ACR 控制台「访问凭证」页设置的固定密码 |

   registry 地址和镜像路径不是机密，直接写在 `deploy-image.yml` 里，
   这样即使 fork 被改动也不会把镜像推到别处去。

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

### 3.4 登录阿里云 ACR（私有仓库，必须做一次）

ACR 上的 `default-is/stock-analysis` 是私有仓库，ECS 拉取前必须登录：

```bash
# 用户名是阿里云账号全名，密码是 ACR 控制台「访问凭证」页设置的固定密码
echo '<ACR固定密码>' | docker login \
  --username '1179574672@qq.com' --password-stdin \
  crpi-u3rv49hccjew63jz-vpc.cn-beijing.personal.cr.aliyuncs.com
```

注意用 **VPC 端点**（带 `-vpc`）——它解析到 `100.x.x.x` 的内网地址，走阿里云内网，
不消耗你那 3 Mbps 公网带宽。

登录信息存在 `~/.docker/config.json`，**这个文件要纳入备份**，否则重建后又要重新登录一次。

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

PR 合并到 main 后，`Build Deploy Image` 自动构建并推送镜像到 GHCR + 阿里云 ACR
（约 5-15 分钟；ACR 那一份是跨境推送，比 GHCR 慢）。构建完成后再上线：

```bash
ssh dsa          # 或 ssh root@10.0.0.1（走 WireGuard 隧道）
dsa-up           # 约 30 秒，含自动健康检查
```

三个预装好的辅助命令：

| 命令 | 用途 |
| --- | --- |
| `dsa-up` | 拉取 + 部署 + 健康检查（默认只管理 `server` 服务） |
| `dsa-logs` | 实时日志，`dsa-logs 200` 看最近 200 行 |
| `dsa-status` | 一眼看容器 / 后端 / 内存 / 磁盘 / WireGuard |

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

### 4.4 改配置（通知渠道、密钥、自选股）

**两个必须记住的点：**

**① 用 `dsa-up`，不要用 `docker compose restart`**

`restart` 只是重启现有容器，**容器环境变量在创建时就固定了**，改 `.env` 不会生效。只有 `up -d`（`dsa-up` 内部就是这个）会重建容器并重新读取 `env_file`。

这个坑实际踩过一次：把通知渠道从企业微信改成钉钉后执行 `restart`，诊断仍显示「已配置渠道: 2 个 / 企业微信, 钉钉」——旧渠道的环境变量还留在容器里。改用 `dsa-up` 后正常。

**② 配置有两份，都要改**

| 文件 | 作用 | 改动何时生效 |
| --- | --- | --- |
| `.env` | compose 通过 `env_file` 注入容器环境变量 | 需要 `dsa-up` 重建容器 |
| `data/runtime.env` | 应用运行时读取的活跃配置（`ENV_FILE` 指向它），WebUI 保存也写这里 | 重启进程即可 |

两份不一致时，`.env` 的环境变量优先（少数键除外，见 `src/config.py` 的 `_WEBUI_RUNTIME_ENV_FILE_PRIORITY_KEYS`）。所以**改配置时两份一起改**。

**改完验证：**

```bash
dsa-up
docker compose -f docker/docker-compose.yml -f deploy/docker-compose.prod.yml \
  exec -T -u dsa server python main.py --check-notify
```

> 注意 `exec` 后面跟的是**服务名** `server`，不是容器名 `stock-server`——写容器名会报 `service "stock-server" is not running`。

通知相关键（`DINGTALK_WEBHOOK_URL`、`WECHAT_WEBHOOK_URL`、`FEISHU_WEBHOOK_URL` 等）见 `docs/notifications.md`。

---

## 5. 备份

### 5.1 备份什么

| 内容 | 位置 | 需要备份 |
| --- | --- | --- |
| 代码 | GitHub | 否 |
| 镜像 | 阿里云 ACR | 否 |
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
#    注意：GitHub 的 git 协议在国内被拒（Empty reply from server），必须走 codeload tarball
sudo mkdir -p /opt/stock-analyzer && sudo chown "$USER" /opt/stock-analyzer
curl -fsSL -o /tmp/dsa.tar.gz \
  https://codeload.github.com/cdwenwang/daily_stock_analysis/tar.gz/refs/heads/main
mkdir -p /tmp/dsa-src && tar xzf /tmp/dsa.tar.gz -C /tmp/dsa-src
cd /tmp/dsa-src/daily_stock_analysis-main && tar cf - . | (cd /opt/stock-analyzer && tar xf -)
cd /opt/stock-analyzer && chmod +x deploy/*.sh

# ③ 取回备份（1 分钟）—— 从 rclone / 对象存储控制台下载最新归档
rclone copy oss:my-bucket/dsa-backup/dsa-<最新>.tar.gz /var/backups/dsa/

# ④ 登录阿里云 ACR（30 秒）
echo '<ACR固定密码>' | docker login --username '1179574672@qq.com' --password-stdin \
  crpi-u3rv49hccjew63jz-vpc.cn-beijing.personal.cr.aliyuncs.com

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
