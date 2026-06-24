# 南京晓庄学院镜像站安装与使用手册

本文档描述一套完整部署方式：`web` 与 `index` 使用容器运行，`yuki` 保持在宿主机通过 systemd 运行。这样可以保留 yuki 对 Docker 同步容器和宿主机大容量目录的直接管理能力，同时让 Web 和首页生成器便于升级。

## 1. 架构

默认组件：

- `web`：`nginx:1.27-alpine` 容器，提供 HTTP 静态服务、目录浏览、`/status/json` 反向代理。
- `index`：本项目 Python 容器，定时生成 `/srv/mirror/www/index.html` 和 `/srv/mirror/www/mirrorz.json`。
- `yukid`：宿主机 systemd 服务，读取 `/etc/yuki/repos/*.yaml`，定时启动 `ustcmirror/*` 同步容器。
- `ustcmirror/rsync:latest`：由 yuki 按需拉起，用 rsync 同步实际仓库数据。
- `/srv/mirror/www`：镜像站 Web 根目录，Nginx、index、yuki 共同使用。

默认端口：

- HTTP：`80`
- yuki 本机 API：`127.0.0.1:9999`

`deploy/compose.yaml` 使用 `network_mode: host`，所以容器可以访问宿主机的 `127.0.0.1:9999`。不要把 yuki 监听地址改成 `0.0.0.0`，除非你已经做好防火墙和访问控制。

## 2. 系统要求

推荐：

- Debian 12 或 Ubuntu 22.04/24.04
- root 权限
- 公网或教育网可访问的服务器
- 可用磁盘空间按镜像仓库规划，建议单独挂载到 `/srv/mirror`
- DNS 指向服务器，例如 `mirrors.njxzu.cn`

安装脚本会安装：

- `docker.io`
- `docker-compose-plugin`
- `git`
- `rsync`
- `curl`
- `sqlite3`

## 3. 一键安装

克隆代码：

```bash
git clone --recursive <this-repo> /tmp/njxzu-mirrors-index
cd /tmp/njxzu-mirrors-index
```

执行完整安装：

```bash
sudo deploy/install.sh \
  --domain mirrors.njxzu.cn \
  --email mirror@openatom.njxzu.cn \
  --web-root /srv/mirror/www
```

这个脚本会：

- 写入 `/etc/njxzu-mirrors-container.env`
- 写入 `/etc/njxzu-mirrors.env`
- 安装 Docker 和 Compose 插件
- 安装 Web/index 容器
- 安装宿主机 yuki
- 设置 yuki post-sync hook
- 创建共享 Web 根目录 `/srv/mirror/www`

如果只安装 Web/index 容器，不安装 yuki：

```bash
sudo deploy/install.sh --skip-yuki
```

如果只安装 yuki，不安装 Web/index 容器：

```bash
sudo deploy/install.sh --skip-web
```

## 4. 配置文件

主要配置：

- `/etc/njxzu-mirrors-container.env`：容器部署配置。
- `/etc/njxzu-mirrors.env`：宿主机 yuki、post-sync 和传统脚本配置。
- `/etc/yuki/daemon.toml`：yuki 服务配置。
- `/etc/yuki/repos/*.yaml`：每个镜像仓库的同步配置。
- `/opt/njxzu-mirrors-index/deploy/compose.yaml`：Web/index 容器编排。

重要变量：

```ini
MIRROR_DOMAIN=mirrors.njxzu.cn
MIRROR_BASE_URL=https://mirrors.njxzu.cn
MIRROR_WEB_ROOT=/srv/mirror/www
YUKI_PROXY_URL=http://127.0.0.1:9999
MIRROR_YUKI_URL=http://127.0.0.1:9999/api/v1/metas
MIRROR_INDEX_INTERVAL=600
```

修改环境文件后重启容器：

```bash
sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml up -d --build
```

修改 yuki 配置后重启：

```bash
sudo systemctl restart yukid
```

## 5. 启动和检查

查看容器：

```bash
sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml ps
```

查看 index 生成日志：

```bash
sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml logs -f index
```

查看 yuki：

```bash
sudo systemctl status yukid
sudo journalctl -u yukid -n 100
```

检查首页：

```bash
curl -I http://127.0.0.1/
curl http://127.0.0.1/status/json
```

## 6. rsync 同步配置

镜像仓库同步由 yuki 管理。每个仓库对应一个 YAML 文件，放在 `/etc/yuki/repos/`。

推荐使用脚本创建 rsync 仓库：

```bash
sudo /opt/njxzu-mirrors-index/deploy/add-rsync-repo.sh \
  --name alpine \
  --host rsync.alpinelinux.org \
  --path alpine/ \
  --cron "17 */4 * * *" \
  --max-delete 20000 \
  --reload \
  --sync
```

参数解释：

- `--name alpine`：本地仓库名，对应 URL `https://mirrors.njxzu.cn/alpine/`。
- `--host rsync.alpinelinux.org`：rsync 上游主机。
- `--path alpine/`：上游 rsync 模块或目录。
- `--cron "17 */4 * * *"`：每 4 小时第 17 分钟同步一次。
- `--max-delete 20000`：单次最多删除 20000 个文件，防止上游异常导致大规模误删。
- `--reload`：写入配置后执行 `yukictl reload`。
- `--sync`：立即执行一次同步。

脚本会生成：

```yaml
name: 'alpine'
cron: '17 */4 * * *'
storageDir: '/srv/mirror/www/alpine'
image: 'ustcmirror/rsync:latest'
logRotCycle: 5
retry: 1
envs:
  RSYNC_HOST: 'rsync.alpinelinux.org'
  RSYNC_PATH: 'alpine/'
  RSYNC_MAXDELETE: '20000'
  RSYNC_BW: '0'
  RSYNC_EXCLUDE: '--exclude=.~tmp~/'
  RSYNC_NO_DELETE: 'false'
  RSYNC_SSL: 'false'
  $UPSTREAM: 'rsync://rsync.alpinelinux.org/alpine/'
```

手动写配置也可以：

```bash
sudo editor /etc/yuki/repos/alpine.yaml
sudo install -d -o mirror -g mirror /srv/mirror/www/alpine
sudo yukictl reload
sudo yukictl sync alpine
```

## 7. 常用 rsync 示例

同步 Alpine：

```bash
sudo /opt/njxzu-mirrors-index/deploy/add-rsync-repo.sh \
  --name alpine \
  --host rsync.alpinelinux.org \
  --path alpine/ \
  --cron "17 */4 * * *" \
  --max-delete 20000 \
  --reload --sync
```

从 USTC 上游同步 Ubuntu releases：

```bash
sudo /opt/njxzu-mirrors-index/deploy/add-rsync-repo.sh \
  --name ubuntu-releases \
  --host rsync.mirrors.ustc.edu.cn \
  --path ubuntu-releases/ \
  --cron "37 */6 * * *" \
  --max-delete 10000 \
  --reload
```

限制带宽到 50 MiB/s：

```bash
sudo /opt/njxzu-mirrors-index/deploy/add-rsync-repo.sh \
  --name example \
  --host rsync.example.edu.cn \
  --path example/ \
  --bwlimit 51200 \
  --reload
```

只追加不删除，适合首次试跑：

```bash
sudo /opt/njxzu-mirrors-index/deploy/add-rsync-repo.sh \
  --name testrepo \
  --host rsync.example.edu.cn \
  --path testrepo/ \
  --no-delete \
  --reload --sync
```

使用 SSH rsync：

```bash
sudo /opt/njxzu-mirrors-index/deploy/add-rsync-repo.sh \
  --name private-repo \
  --host mirror-sync@example.edu.cn \
  --path /data/private-repo/ \
  --rsync-rsh "ssh -i /home/mirror/.ssh/id_rsa -o StrictHostKeyChecking=accept-new" \
  --upstream "mirror-sync@example.edu.cn:/data/private-repo/" \
  --reload
```

## 8. 查看同步状态

列出仓库：

```bash
sudo yukictl repo ls
```

查看元数据：

```bash
sudo yukictl meta ls
sudo yukictl meta ls alpine
```

手动同步：

```bash
sudo yukictl sync alpine
```

查看日志：

```bash
sudo ls -la /var/log/yuki/alpine
sudo tail -f /var/log/yuki/alpine/result.log
```

状态页：

```text
https://mirrors.njxzu.cn/status/
https://mirrors.njxzu.cn/status/json
```

## 9. 首页刷新

index 容器默认每 10 分钟刷新一次首页。yuki 同步完成后也会通过 post-sync hook 立即刷新。

手动刷新：

```bash
sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml \
  exec -T index /app/scripts/generate-index.sh
```

如果使用传统 systemd 版：

```bash
sudo systemctl start mirrors-index.service
```

## 10. 新增仓库流程

标准流程：

1. 确认上游 rsync 地址。
2. 估算容量和同步周期。
3. 使用 `add-rsync-repo.sh` 生成 yuki 配置。
4. 首次同步建议先加 `--no-delete` 试跑。
5. 查看日志确认无异常。
6. 去掉 `--no-delete`，重新写配置并 reload。
7. 等首页刷新后确认文件列表中出现仓库。

查看上游 rsync 模块：

```bash
rsync rsync://rsync.alpinelinux.org/
rsync rsync://rsync.mirrors.ustc.edu.cn/
```

试探单个目录：

```bash
rsync --dry-run -av rsync://rsync.alpinelinux.org/alpine/ /tmp/alpine-test/
```

## 11. 升级

拉取新代码：

```bash
cd /opt/njxzu-mirrors-index
sudo git pull
sudo git submodule update --init --recursive
```

重建容器：

```bash
sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml up -d --build
```

升级 yuki：

```bash
sudo /opt/njxzu-mirrors-index/deploy/setup-yuki.sh
```

## 12. 备份

必须备份：

- `/etc/njxzu-mirrors-container.env`
- `/etc/njxzu-mirrors.env`
- `/etc/yuki/daemon.toml`
- `/etc/yuki/repos/`
- `/var/lib/yuki/yukid.db`

镜像数据 `/srv/mirror/www` 通常很大，可以按磁盘策略快照或重新同步。

## 13. 排障

首页 404 或空白：

```bash
sudo ls -la /srv/mirror/www/index.html
sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml logs index
```

`/status/json` 失败：

```bash
curl http://127.0.0.1:9999/api/v1/metas
sudo systemctl status yukid
```

同步失败：

```bash
sudo yukictl meta ls <repo>
sudo tail -n 200 /var/log/yuki/<repo>/result.log
```

常见 rsync 退出码：

- `12`：rsync 协议或网络数据流错误，先重试并检查上游。
- `23`：部分文件失败，通常是上游文件变化或权限问题。
- `24`：同步过程中上游文件消失，常见且通常可忽略。
- `25`：超过 `RSYNC_MAXDELETE`，需要确认上游是否大规模删除，再调高 `--max-delete`。
- `30`：网络超时，可调大 `RSYNC_TIMEOUT` 或换上游。

容器无法访问 yuki：

- 确认 `deploy/compose.yaml` 仍使用 `network_mode: host`。
- 确认 yuki 监听 `127.0.0.1:9999`。
- 执行 `curl http://127.0.0.1:9999/api/v1/metas`。

## 14. 安全建议

- yuki 只监听 `127.0.0.1:9999`。
- 不对公网开放 Docker API。
- 不把 `/var/run/docker.sock` 挂给 Web 容器。
- rsync 首次同步建议使用 `--no-delete` 试跑。
- 对大仓库设置合理 `RSYNC_MAXDELETE`。
- 定期备份 `/etc/yuki/repos/` 和 yuki SQLite 数据库。

## 15. 卸载

停止容器：

```bash
sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml down
```

停止 yuki：

```bash
sudo systemctl disable --now yukid
```

保留数据时不要删除 `/srv/mirror/www`。完全清理前请确认已经备份。
