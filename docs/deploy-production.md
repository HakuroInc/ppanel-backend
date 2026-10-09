# 生产部署（production 分支 → 140.83.81.248）

推送到 `production` 分支即自动上线，流程见 `.github/workflows/deploy-production.yml`：

1. **verify**：复用 `checks.yml`（构建、测试、race、govulncheck、lint），不过不发布。
2. **build**：在原生 arm64 runner 上构建镜像，推送
   `ghcr.io/as207299/ppanel-backend:<commit sha>` 和 `:production`。
3. **deploy**：用专用部署密钥 SSH 到主机，执行 `/opt/ppanel/deploy.sh <sha>`，
   本次运行的短期 GHCR token 走 stdin，主机上不留任何凭据。

同一时间只有一个部署在跑，后来的推送会排队，不会打断进行中的部署。

## 主机端（/opt/ppanel）

本目录 `deploy/production/` 是主机文件的源：

| 文件 | 主机位置 | 说明 |
|---|---|---|
| `compose.yaml` | `/opt/ppanel/compose.yaml` | ppanel + redis，ppanel 只监听 `127.0.0.1:8080`（给 Cloudflare Tunnel） |
| `deploy.sh` | `/opt/ppanel/deploy.sh`（root:root 755） | 拉取镜像、切换版本、健康检查、失败回滚、清理旧镜像 |
| `env.example` | `/opt/ppanel/.env`（root:root 600） | `PPANEL_TAG` 由部署脚本改写，其余手动维护 |

运行时目录：`etc/ppanel.yaml`、`logs/`、`cache/` 归 65532:65532（容器内非 root 用户），
`redis/` 为 redis 数据。

部署密钥在 `~ubuntu/.ssh/authorized_keys` 中被限制为只能执行部署脚本：

```
restrict,command="sudo -n /opt/ppanel/deploy.sh \"$SSH_ORIGINAL_COMMAND\"" ssh-ed25519 ... gha-deploy@AS207299/ppanel-backend
```

`deploy.sh` 只接受 40 位小写十六进制的 commit sha。

## GitHub 配置

Environment `production`（仅允许 `production` 分支使用）中的 secrets：

- `PROD_SSH_KEY`：部署私钥
- `PROD_SSH_HOST`：`ubuntu@140.83.81.248`
- `PROD_SSH_KNOWN_HOSTS`：主机 ed25519 公钥（`SHA256:B7tdgZ0c0yiGqIM+OKSGl3mGk2vFu3OKAh7uBhgM+IU`）

## 接入数据库后

1. 在 `/opt/ppanel/.env` 填 `PPANEL_DB`（Azure 需要 TLS，如
   `user:pass@tcp(host:3306)/ppanel?tls=true`）。只在 `etc/ppanel.yaml` 还没有
   `JwtAuth.AccessSecret` 时读取，首次启动后会写回配置文件。
2. `cd /opt/ppanel && sudo docker compose up -d`，确认 `docker ps` 显示 healthy。
3. 把 `.env` 里的 `DEPLOY_REQUIRE_HEALTHY` 改成 `1`：此后新版本在
   `DEPLOY_HEALTH_TIMEOUT` 秒内不健康就自动回滚到上一个版本，CI 标红。

未接数据库时服务会停在安装向导（健康检查为 unhealthy），这是预期的；
`DEPLOY_REQUIRE_HEALTHY=0` 时部署照常完成，只打印警告。

## 手动操作

- 重新部署当前 production：Actions → Deploy production → Run workflow（选 production 分支）。
- 回滚到某个版本：在主机上 `sudo /opt/ppanel/deploy.sh <旧 sha>`（镜像需仍在 GHCR）。
