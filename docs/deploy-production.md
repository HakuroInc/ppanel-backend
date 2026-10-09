# 生产部署（production 分支 → 140.83.81.248）

推送到 `production` 分支即自动上线，流程见 `.github/workflows/deploy-production.yml`，不跑测试：

1. GitHub 托管 runner（`ubuntu-latest`，公开仓库免费）检出代码，交叉编译 linux/arm64 二进制
   （与仓库 Dockerfile 相同的 ldflags，`VERSION=production-<sha8>`，`CHANNEL=stable`）。
2. 用专用部署密钥 SSH 到生产机，二进制走 stdin，commit sha 作为命令参数；
   主机执行 `/opt/ppanel/deploy.sh <sha>`：校验是 arm64 ELF，套上 `Dockerfile.runtime`
   构建本地镜像 `ppanel-backend:<sha>`，切换版本，健康检查，必要时回滚，清理旧镜像。

同一时间只有一个部署在跑，后来的推送排队。

## 主机端（/opt/ppanel）

本目录 `deploy/production/` 是主机文件的源，更新时手动复制过去：

| 文件 | 主机位置 | 说明 |
|---|---|---|
| `compose.yaml` | `/opt/ppanel/compose.yaml` | ppanel + redis，ppanel 只监听 `127.0.0.1:8080`（给 Cloudflare Tunnel） |
| `deploy.sh` | `/opt/ppanel/deploy.sh`（root:root 755） | 部署入口 |
| `Dockerfile.runtime` | `/opt/ppanel/Dockerfile.runtime`（root:root 644） | 运行时镜像，最终层与仓库 Dockerfile 一致 |
| `env.example` | `/opt/ppanel/.env`（root:root 600） | `PPANEL_TAG` 由部署脚本改写，其余手动维护 |

运行时目录：`etc/ppanel.yaml`、`logs/`、`cache/` 归 65532:65532（容器内非 root 用户），`redis/` 为 redis 数据。

部署密钥在 `~ubuntu/.ssh/authorized_keys` 中被限制为只能执行部署脚本：

```
restrict,command="sudo -n /opt/ppanel/deploy.sh \"$SSH_ORIGINAL_COMMAND\"" ssh-ed25519 ... gha-deploy@AS207299/ppanel-backend
```

## GitHub 配置

- Environment `production`（仅允许 `production` 分支）中的 secrets：
  `PROD_SSH_KEY`（部署私钥）、`PROD_SSH_HOST`（`ubuntu@140.83.81.248`）、
  `PROD_SSH_KNOWN_HOSTS`（主机 ed25519 公钥，`SHA256:B7tdgZ0c0yiGqIM+OKSGl3mGk2vFu3OKAh7uBhgM+IU`）。
- 外部贡献者的 fork PR 工作流需要人工批准（仓库设置 `all_external_contributors`）。

## 接入数据库后

1. 在 `/opt/ppanel/.env` 填 `PPANEL_DB`（Azure 需要 TLS，如
   `user:pass@tcp(host:3306)/ppanel?tls=true`）。只在 `etc/ppanel.yaml` 还没有
   `JwtAuth.AccessSecret` 时读取，首次启动后会写回配置文件。
2. `cd /opt/ppanel && sudo docker compose up -d`，确认 `docker ps` 显示 healthy。
3. 把 `.env` 里的 `DEPLOY_REQUIRE_HEALTHY` 改成 `1`：此后新版本在
   `DEPLOY_HEALTH_TIMEOUT` 秒内不健康就自动回滚到上一个版本，CI 标红。

未接数据库时服务停在安装向导（健康检查为 unhealthy），这是预期的；部署照常完成，只打印警告。

## 手动操作

- 重新部署：Actions → Deploy production → Run workflow（选 production 分支）。
- 回滚：主机上保留当前与上一个版本的镜像，
  `sudo sed -i 's/^PPANEL_TAG=.*/PPANEL_TAG=<旧 sha>/' /opt/ppanel/.env && cd /opt/ppanel && sudo docker compose up -d`。
