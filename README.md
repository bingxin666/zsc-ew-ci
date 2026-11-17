# zsc-ew-ci

只做一件事：把 [zsc-water-and-electricity](https://git.haori.ink/bingxin/zsc-water-and-electricity)
构建成 Docker 镜像，推到 `ghcr.io/bingxin666/zsc-ew-ci`。

## 为什么不放在 GitLab 跑

GitLab 实例的 Runner **没有 privileged**，两条官方路径都被底层挡住：

| 方案 | 失败原因 |
|---|---|
| `docker:dind` | `alias "docker" is already in use by another service`，dind 起不来（2375/2376 都连不上）|
| `buildah` | `Error during unshare(CLONE_NEWUSER): Operation not permitted` |

诊断证据：容器 capability = `a80425fb`（Docker 默认集，不含 `SYS_ADMIN`），
而 privileged 容器会是 `000001ffffffffff`。

GitHub 的 `ubuntu-latest` runner 原生带 docker，构建这条路通畅。

## 这个仓库里有什么

```
.github/workflows/build-image.yml   构建流程
deploy/Dockerfile                   镜像定义（与上游同步）
deploy/entrypoint.sh                容器启动脚本（与上游同步）
deploy/zscwd.env.example            环境变量模板
```

**源码不在这里**，构建时从 GitLab clone。

Dockerfile 和 entrypoint 放在本仓库（而不是用上游的），是为了改构建逻辑时
不用动上游代码。上游的改动只要不涉及这两个文件，不需要同步。

## 一次性配置

### 1. 建 GitLab Personal Access Token

访问 <https://git.haori.ink/-/user_settings/personal_access_tokens>，新建：

| 字段 | 值 |
|---|---|
| Name | `github-ci-read`（随便） |
| Expiration | 按需，**建议长一点**（例如 1 年），过期后 CI 会失败 |
| Scopes | 只勾 **`read_repository`** |

复制生成的 token（`glpat-` 开头）。

### 2. 存到 GitHub Secrets

访问 <https://github.com/bingxin666/zsc-ew-ci/settings/secrets/actions>，
新增 Repository secret：

| Name | Value |
|---|---|
| `GITLAB_TOKEN` | 刚才复制的 `glpat-...` |

可选（不设则默认用户名 `bingxin`）：

| Name | Value |
|---|---|
| `GITLAB_USER` | 你的 GitLab 用户名 |

### 3. 确认 package 可写

`GITHUB_TOKEN` 需要 `packages: write`，workflow 里已声明：

```yaml
permissions:
  contents: read
  packages: write
```

如果推送时报 `denied: permission_denied`，去
<https://github.com/settings/tokens> 检查，或确认仓库
`Settings → Actions → General → Workflow permissions` 不是
「Read repository contents permission」的限制模式。

## 怎么跑

### 手动触发（最常用）

```bash
gh workflow run build-image -R bingxin666/zsc-ew-ci -f source_ref=main
```

带额外 tag：

```bash
gh workflow run build-image -R bingxin666/zsc-ew-ci \
  -f source_ref=v1.0.0 -f image_tag=v1.0.0
```

看进度：

```bash
gh run list -R bingxin666/zsc-ew-ci --limit 5
gh run watch -R bingxin666/zsc-ew-ci
```

### 没有自动触发

**只有手动 `workflow_dispatch`，没有 push / schedule 自动触发。**

原因：镜像约 2.5GB，一次构建要拉 222MB deb + docker build + 推 2.5GB，
很耗 Actions 额度和带宽；定时触发还会在没人看的时候白跑。

代价是本仓库自己的改动（`deploy/Dockerfile` 等）也不会自动验证，改完记得
手动跑一次。上游 GitLab 有新提交同样不会触发。

### 产出的 tag

| tag | 含义 |
|---|---|
| `latest` | 只在默认分支构建时打 |
| `<short-sha>` | 本仓库 commit sha |
| `src-<short-sha>` | **上游源码**的 commit sha，追代码版本用这个 |
| `<image_tag>` | 手动指定的额外 tag |

## 拉取并使用

ghcr 的包默认是 **private**，拉之前要登录：

```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u bingxin666 --password-stdin
docker pull ghcr.io/bingxin666/zsc-ew-ci:latest
```

或者把 package 设为 public：`Packages → 包详情 → Package settings → Change visibility`。

运行（三个必需项，见主仓库文档）：

```bash
docker run -d --name zsc \
  --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined \
  -e API_TOKEN="$(openssl rand -hex 32)" \
  -p 8080:8080 \
  --shm-size=2g \
  -v zsc-wechat:/root/.xwechat \
  --restart unless-stopped \
  ghcr.io/bingxin666/zsc-ew-ci:latest
```

完整部署说明见主仓库 `docs/deploy.md`。

## 同步上游的 Dockerfile

如果上游改了 `deploy/Dockerfile` 或 `entrypoint.sh`，需要同步过来：

```bash
# 在本地主仓库
cp deploy/Dockerfile deploy/entrypoint.sh deploy/zscwd.env.example ../zsc-ew-ci/deploy/
cd ../zsc-ew-ci && git add -A && git commit -m "sync build files from upstream" && git push
```

改完后手动跑一次 workflow 验证。

## 构建耗时参考

| 阶段 | 时间 |
|---|---|
| clone 上游 + 拉 LFS（222MB deb） | 1~2 min |
| Go 编译（带缓存） | ~30s |
| docker build（层缓存命中时） | 1~2 min |
| 推送 2.5GB 到 ghcr | 2~4 min |

首次构建没有缓存，会慢一些（docker build 那步要装微信依赖，约 5~8 min）。

## 实测耗时（首次有缓存）

第一次真实构建：clone + LFS 约 **520 秒**，docker build 约 **160 秒**。
主要是 222MB deb 的跨境传输慢（约 0.4~0.5 MB/s）。后续构建有 gha 缓存，
docker build 会快些，但 LFS 每次都要重拉（GitHub Actions 之间不共享工作区）。

## 踩过的坑

### 1. clone 阶段直接失败（RPC failed / early EOF）

```
git lfs install          ← 这一行在 clone 之前
git clone --depth 1 ...
```

`git lfs install` 会让后续 clone 顺带拉 LFS 对象，于是 clone 阶段就要传
222MB，跨境链路直接断：

```
error: RPC failed; curl 92 HTTP/2 stream 7 was not closed cleanly
error: 49947 bytes of body are still expected
fatal: early EOF
fatal: fetch-pack: invalid index-pack output
```

**修法**：clone 前 `export GIT_LFS_SKIP_SMUDGE=1`，clone 只拿 pointer
（几秒完成），再单独 `git lfs pull` 并重试。

### 2. attestation 步骤失败

```
Error: Failed to persist attestation:
Feature not available for user-owned private repositories.
```

GitHub 的 `attest-build-provenance` 只对公开仓库或**组织**拥有的私有仓库
可用。用户私有仓库用不了。它只是可选的 SLSA 溯源签名，不影响镜像，
已从 workflow 里移除。

### 3. 本地 `gh` 查不到 package

```
gh: You need at least read:packages scope to get a package's versions.
```

本地 `gh` token 只有 `repo` / `workflow` 等 scope。想用 API 查包信息需要
额外加 `read:packages`。不影响 CI 推送（CI 用内置 GITHUB_TOKEN）。

## 已知限制

- **上游更新不自动触发**：需要手动 dispatch，或在本仓库加个定时任务探测
  上游 commit（会消耗 Actions 额度）。
- **deb 每次都要从 GitLab LFS 拉**：222MB。如果 GitLab 那边网络慢，
  clone 步骤会拖时间。仓库无缓存机制。
- **镜像约 2.5GB**，ghcr 存储按账号配额算。
