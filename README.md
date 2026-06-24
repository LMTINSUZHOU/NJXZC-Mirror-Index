# 南晓开放原子社开源软件镜像站

本项目基于 [USTC mirrors-index](https://git.lug.ustc.edu.cn/mirrors/mirrors-index) 定制，用于生成南晓开放原子社开源软件镜像站首页、状态页和 MirrorZ 元数据。同步调度参考 [ustclug/yuki](https://github.com/ustclug/yuki)，同步容器参考 [ustclug/ustcmirror-images](https://github.com/ustclug/ustcmirror-images)，页面体验参考 <https://mirrors.ustc.edu.cn/>。

完整安装、rsync 同步配置和运维手册见 [docs/INSTALL_AND_MANUAL.md](docs/INSTALL_AND_MANUAL.md)。

## 组件

- `mirrors-index`：扫描镜像目录，生成 `index.html`、`mirrorz.json`、`/status/` 静态页面。
- `yuki`：可选的镜像同步调度器，提供 `/api/v1/metas` 状态 JSON。
- `ustcmirror-images`：可选的同步容器集合，例如 `ustcmirror/rsync:latest`、`ustcmirror/apt-sync:latest`。
- `nginx`：对外提供静态文件、仓库目录浏览，并把 `/status/json` 反代到 yuki。

## 容器化部署

推荐部署形态是：`yuki` 继续运行在宿主机，`web` 与 `index` 使用容器运行。这样 yuki 仍可直接管理 Docker 同步容器和宿主机目录，Web 层也更容易升级和回滚。

目标系统建议 Debian 12 或 Ubuntu 22.04/24.04。

```bash
git clone --recursive <this-repo> /tmp/njxzu-mirrors-index
cd /tmp/njxzu-mirrors-index
sudo deploy/install.sh \
  --domain mirrors.njxzu.cn \
  --email mirror@openatom.njxzu.cn \
  --web-root /srv/mirror/www
```

容器化部署会启动两个服务：

- `web`：官方 `nginx:1.27-alpine`，读取 `/srv/mirror/www` 并对外监听 80。
- `index`：本项目构建的 Python 镜像，默认每 10 分钟生成一次 `index.html` 和 `mirrorz.json`。

`deploy/compose.yaml` 默认使用 `network_mode: host`。原因是宿主机 yuki 默认只监听 `127.0.0.1:9999`，host 网络可以让容器访问这个本地接口，同时不需要把 yuki 暴露到外网。

安装脚本会部署 Web/index 容器并安装宿主机 yuki。启用仓库同步后，yuki 的 post-sync hook 会在容器模式下执行 `docker compose exec index /app/scripts/generate-index.sh`，同步完成后立即刷新首页。

常用命令：

```bash
sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml ps

sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml logs -f index
```

## 传统部署

目标系统建议 Debian 12 或 Ubuntu 22.04/24.04。

```bash
git clone --recursive <this-repo> /tmp/njxzu-mirrors-index
cd /tmp/njxzu-mirrors-index
sudo cp deploy/mirror.env.example /etc/njxzu-mirrors.env
sudo editor /etc/njxzu-mirrors.env
sudo deploy/quick-deploy.sh
```

默认路径：

- 源码目录：`/opt/njxzu-mirrors-index`
- Web 根目录：`/srv/mirror/www`
- 环境文件：`/etc/njxzu-mirrors.env`
- 站点域名：`mirrors.njxzu.cn`

部署后访问 `http://mirrors.njxzu.cn/`。如果还没有 DNS，可以先在本机 `/etc/hosts` 指向服务器 IP。

## 启用 yuki

首页可以只依赖目录扫描工作；如果需要同步调度和状态页，继续安装 yuki：

```bash
sudo /opt/njxzu-mirrors-index/deploy/setup-yuki.sh
```

示例仓库配置会安装到 `/etc/yuki/repos/*.yaml.example`，默认不会启用。USTC 上游同步请遵守 <https://mirrors.ustc.edu.cn/help/rsync-guide.html>：使用 `rsync.mirrors.ustc.edu.cn`，不要使用 HTTP/HTTPS 大规模抓取，不要使用 `-c/--checksum`，普通仓库每日一次，Ubuntu 等热门仓库最高每 6 小时一次。

启用 Ubuntu releases 示例：

```bash
sudo /opt/njxzu-mirrors-index/deploy/add-rsync-repo.sh \
  --name ubuntu-releases \
  --host rsync.mirrors.ustc.edu.cn \
  --path ubuntu-releases/ \
  --cron "37 */6 * * *" \
  --reload
```

yuki 同步完成后会触发首页重新生成。传统部署会启动 `mirrors-index.service`，容器化部署会触发 `index` 容器内的生成脚本。状态页读取 `/status/json`，Nginx 会把它反代到 `http://127.0.0.1:9999/api/v1/metas`。

## 本地开发

```bash
make init
make gen
make serve
```

然后访问 <http://127.0.0.1:8000/>。`make gen` 会使用 `DEBUG_WITH_REPOLIST=1` 根据 `examples/repolist.txt` 创建测试目录。

## 配置入口

- `config/gencontent.json`：站点文案、链接、域名、帮助链接、yuki 状态接口。
- `config/genmirrorz.json`：MirrorZ 元数据、endpoint、站点信息。
- `config/revproxy.json`：反向代理列表。默认空数组。
- `deploy/mirror.env.example`：生产部署环境变量，可覆盖域名、路径、联系邮箱。
- `deploy/container.env.example`：容器化部署环境变量。
- `deploy/compose.yaml`：Web/index 容器编排，yuki 不在该 Compose 内。
- `deploy/yuki/repos/*.yaml.example`：yuki 仓库同步样例。

## 常用运维命令

```bash
sudo systemctl status mirrors-index.timer
sudo systemctl start mirrors-index.service
sudo journalctl -u mirrors-index.service -n 100

sudo systemctl status yukid
sudo yukictl repo ls
sudo yukictl meta ls

sudo docker compose --env-file /etc/njxzu-mirrors-container.env \
  -f /opt/njxzu-mirrors-index/deploy/compose.yaml ps
```

## 版权

上游 mirrors-index 代码遵循 GPL-2.0。USTC LUG 原始版权声明见 `LICENSE`。
