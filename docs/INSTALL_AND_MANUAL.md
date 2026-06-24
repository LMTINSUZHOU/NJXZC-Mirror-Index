# 南京晓庄学院镜像站安装与使用手册

本文档描述一套完整部署方式：`web` 与 `index` 使用容器运行，`yuki` 保持在宿主机通过 systemd 运行。这样可以保留 yuki 对 Docker 同步容器和宿主机大容量目录的直接管理能力，同时让 Web 和首页生成器便于升级。

## 1. 架构

默认组件：

- `web`：`nginx:1.27-alpine` 容器，提供 HTTP 静态服务、目录浏览、`/status/json` 反向代理。
- `index`：本项目 Python 容器，定时生成 `/srv/mirror/www/index.html` 和 `/srv/mirror/www/mirrorz.json`。
- `admin`：本项目 Python/Flask 容器，提供内部管理页面，通过 `/admin/` 访问。
- `yukid`：宿主机 systemd 服务，读取 `/etc/yuki/repos/*.yaml`，定时启动 `ustcmirror/*` 同步容器。
- `ustcmirror/rsync:latest`：由 yuki 按需拉起，用 rsync 同步实际仓库数据。
- `/srv/mirror/www`：镜像站 Web 根目录，Nginx、index、yuki 共同使用。

默认端口：

- HTTP：`80`
- admin 本机监听：`127.0.0.1:18081`，由 Nginx 反代为 `/admin/`
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
- 安装内部管理页面容器
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
MIRROR_LOGO_URL=/static/img/nx-openatom-logo.jpg
MIRROR_WEB_ROOT=/srv/mirror/www
YUKI_PROXY_URL=http://127.0.0.1:9999
MIRROR_YUKI_URL=http://127.0.0.1:9999/api/v1/metas
MIRROR_INDEX_INTERVAL=600
ADMIN_PROXY_URL=http://127.0.0.1:18081
ADMIN_BIND=127.0.0.1:18081
ADMIN_USERNAME=admin
ADMIN_PASSWORD=<change-me>
ADMIN_SECRET_KEY=<random-secret>
ADMIN_ALLOW_CIDRS=127.0.0.1/32,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10
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
curl -I http://127.0.0.1/admin/
```

## 6. 内部管理页面

访问地址：

```text
http://mirrors.njxzu.cn/admin/
```

登录账号来自 `/etc/njxzu-mirrors-container.env`：

```ini
ADMIN_USERNAME=admin
ADMIN_PASSWORD=...
ADMIN_SECRET_KEY=...
```

建议首次部署后立即修改 `ADMIN_PASSWORD` 和 `ADMIN_SECRET_KEY`，然后重启容器：

```bash
sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml up -d --build
```

管理页面默认只允许本机和内网地址段访问。若需要限制到学校网段，可以把 `ADMIN_ALLOW_CIDRS` 改为实际网段，例如：

```ini
ADMIN_ALLOW_CIDRS=127.0.0.1/32,::1/128,10.11.0.0/16
```

页面支持：

- 刷新首页和 `mirrorz.json`。
- 查看启用仓库、停用仓库和内置示例。
- 修改仓库 cron 定时任务。
- 从示例导入仓库。
- 启用、停用仓库。
- 删除仓库配置；勾选“数据”后才会删除 `/srv/mirror/www/<repo>` 这类仓库目录。
- 触发 yuki reload 和单仓库同步。

注意：

- yuki 当前停用时，页面仍然可以修改 YAML 配置；启用、停用、reload、同步会显示 yuki 不可用提示。
- 删除默认只删 YAML 配置，不会删仓库数据。
- 管理页面容器通过挂载 `/etc/yuki` 管理仓库配置，yuki 仍然运行在宿主机。

## 7. rsync 同步配置

镜像仓库同步由 yuki 管理。每个仓库对应一个 YAML 文件，放在 `/etc/yuki/repos/`。

使用 USTC 上游时必须遵守 [科大源同步方法与注意事项](https://mirrors.ustc.edu.cn/help/rsync-guide.html)：

- 只使用 `rsync.mirrors.ustc.edu.cn`，不要用 `mirrors.ustc.edu.cn` 做 rsync。
- 不要用 HTTP/HTTPS 大规模同步仓库内容。
- 同步参数必须能增量同步，使用 `-a`，或至少 `-rlt`。`ustcmirror/rsync:latest` 默认命令满足这个要求。
- 不要使用 `-c` / `--checksum`。
- 普通仓库不超过每天一次；`ubuntu`、`ubuntu-releases` 等热门仓库最高每 6 小时一次。
- 单 IP 并发连接不要超过 5。多个仓库的 cron 要错开。

推荐使用脚本创建 rsync 仓库。脚本会拒绝 USTC 主站域名、`-c/--checksum`，并对 USTC 仓库的同步频率做保守校验：

```bash
sudo /opt/njxzu-mirrors-index/deploy/add-rsync-repo.sh \
  --name debian-security \
  --host rsync.mirrors.ustc.edu.cn \
  --path debian-security/ \
  --cron "47 3 * * *" \
  --max-delete 50000 \
  --reload
```

参数解释：

- `--name debian-security`：本地仓库名，对应 URL `https://mirrors.njxzu.cn/debian-security/`。
- `--host rsync.mirrors.ustc.edu.cn`：USTC rsync 专用主机。
- `--path debian-security/`：上游 rsync 模块或目录。
- `--cron "47 3 * * *"`：每天 03:47 同步一次。
- `--max-delete 50000`：单次最多删除 50000 个文件，防止上游异常导致大规模误删。
- `--reload`：写入配置后执行 `yukictl reload`。
- `--sync`：立即执行一次同步。

脚本会生成：

```yaml
name: 'debian-security'
cron: '47 3 * * *'
storageDir: '/srv/mirror/www/debian-security'
image: 'ustcmirror/rsync:latest'
logRotCycle: 5
retry: 1
envs:
  RSYNC_HOST: 'rsync.mirrors.ustc.edu.cn'
  RSYNC_PATH: 'debian-security/'
  RSYNC_MAXDELETE: '50000'
  RSYNC_BW: '0'
  RSYNC_EXCLUDE: '--exclude=.~tmp~/'
  RSYNC_NO_DELETE: 'false'
  RSYNC_SSL: 'false'
  $UPSTREAM: 'rsync://rsync.mirrors.ustc.edu.cn/debian-security/'
```

手动写配置也可以：

```bash
sudo editor /etc/yuki/repos/debian-security.yaml
sudo install -d -o mirror -g mirror /srv/mirror/www/debian-security
sudo yukictl reload
sudo yukictl sync debian-security
```

## 8. 常用同步示例

本项目内置了常用同步示例，默认是 `.yaml.example`，不会自动启用。可以先复制到禁用目录，确认清单后再移动到 `/etc/yuki/repos/`：

```bash
sudo mkdir -p /etc/yuki/repos.disabled
sudo cp /opt/njxzu-mirrors-index/deploy/yuki/repos/{ubuntu,ubuntu-releases,debian,debian-cd,debian-security,nodejs-release,llvm-apt,texlive-iso,eclipse-epp,msys2,obs-studio,ventoy}.yaml.example /etc/yuki/repos.disabled/
```

一期推荐清单：

| 仓库 | 用途 | 频率 | 估算体量 |
|---|---|---:|---:|
| `ubuntu` | Ubuntu APT 源 | 6 小时一次 | 约 4.5 TiB |
| `ubuntu-releases` | Ubuntu 安装镜像 | 6 小时一次 | 约 55 GiB |
| `debian` | Debian APT 源 | 每日一次 | 约 2.5 TiB |
| `debian-cd` | Debian 安装镜像 | 每日一次 | 约 236 GiB |
| `debian-security` | Debian 安全更新 | 每日一次 | 约 220 GiB |
| `nodejs-release` | Node.js 官方发布包 | 每日一次 | 约 480 GiB |
| `llvm-apt` | Clang/LLVM APT 源 | 每日一次 | 约 85 GiB |
| `texlive-iso` | TeX Live ISO 安装镜像，含 Windows/Linux 安装介质 | 每日一次 | 约 7 GiB |
| `eclipse-epp` | Eclipse IDE 打包发布目录 | 每日一次 | 随 release 变化 |
| `msys2` | MSYS2 与 MinGW-w64 软件包 | 每日一次 | 随上游增长 |
| `obs-studio` | OBS Studio GitHub Release 资产 | 每日一次 | 保留最近 3 个 release |
| `ventoy` | Ventoy GitHub Release 资产 | 每日一次 | 保留最近 5 个 release |

Ubuntu APT 与 Debian APT 不建议用普通 rsync 只同步发行版目录，因为 `pool/` 是共享目录，简单裁剪可能导致 `Packages` 引用缺文件。若要严格只保留 Ubuntu 20.04+、Debian 10+，需要改用 APT 专用镜像工具做 suite/architecture 闭包同步；普通 rsync 示例按 USTC 模块完整同步。

软件类补充说明：

- `texlive-iso`、`eclipse-epp`、`msys2` 使用 TUNA 已验证可访问的 rsync 上游。若未来切换到 USTC，仍要使用 `rsync.mirrors.ustc.edu.cn` 并遵守 USTC rsync 频率限制。
- `obs-studio`、`ventoy` 使用 `ustcmirror/github-release:latest`，通过 GitHub API 下载 release 资产，不属于 USTC rsync 同步。若遇到 GitHub API 速率限制，可以在 YAML 的 `envs` 中加入 `GITHUB_TOKEN`。
- 暂未加入 7-Zip；当前没有确认到适合 yuki 直接维护的稳定 rsync 示例。

启用 Ubuntu releases：

```bash
sudo /opt/njxzu-mirrors-index/deploy/add-rsync-repo.sh \
  --name ubuntu-releases \
  --host rsync.mirrors.ustc.edu.cn \
  --path ubuntu-releases/ \
  --cron "37 */6 * * *" \
  --max-delete 10000 \
  --reload
```

启用 Debian security：

```bash
sudo /opt/njxzu-mirrors-index/deploy/add-rsync-repo.sh \
  --name debian-security \
  --host rsync.mirrors.ustc.edu.cn \
  --path debian-security/ \
  --cron "47 3 * * *" \
  --max-delete 50000 \
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

## 9. 查看同步状态

列出仓库：

```bash
sudo yukictl repo ls
```

查看元数据：

```bash
sudo yukictl meta ls
sudo yukictl meta ls ubuntu-releases
```

手动同步：

```bash
sudo yukictl sync ubuntu-releases
```

查看日志：

```bash
sudo ls -la /var/log/yuki/ubuntu-releases
sudo tail -f /var/log/yuki/ubuntu-releases/result.log
```

状态页：

```text
https://mirrors.njxzu.cn/status/
https://mirrors.njxzu.cn/status/json
```

## 10. 首页刷新

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

## 11. 新增仓库流程

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
rsync rsync://rsync.mirrors.ustc.edu.cn/
```

试探单个目录：

```bash
rsync --dry-run -avH rsync://rsync.mirrors.ustc.edu.cn/ubuntu-releases/ /tmp/ubuntu-releases-test/
```

## 12. 升级

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

## 13. 备份

必须备份：

- `/etc/njxzu-mirrors-container.env`
- `/etc/njxzu-mirrors.env`
- `/etc/yuki/daemon.toml`
- `/etc/yuki/repos/`
- `/var/lib/yuki/yukid.db`

镜像数据 `/srv/mirror/www` 通常很大，可以按磁盘策略快照或重新同步。

## 14. 排障

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

## 15. 安全建议

- yuki 只监听 `127.0.0.1:9999`。
- 不对公网开放 Docker API。
- 不把 `/var/run/docker.sock` 挂给 Web 容器。
- rsync 首次同步建议使用 `--no-delete` 试跑。
- 对大仓库设置合理 `RSYNC_MAXDELETE`。
- 定期备份 `/etc/yuki/repos/` 和 yuki SQLite 数据库。

## 16. 卸载

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
