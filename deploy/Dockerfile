# 开箱即用镜像：微信 + zsc 水电服务 + Xvfb
#
# 构建上下文需要两个东西：
#   1) 编译好的二进制（CI 里由 build 阶段产出，拷到 deploy/bin/）
#   2) wechat_<版本>.deb —— 微信 4.1.13.26 的安装包
#
# 为什么必须是 .deb 快照、不能在镜像里 apt 装：
#   hooksession 的 RVA 与函数语义绑死 4.1.13.26。apt 装到新版本会直接
#   触发 ErrVersionMismatch（拒绝注入），届时现象是"服务起来了但永远拿不到
#   session"。快照进镜像才能保证可重现。
#
# 运行时必须有 ptrace 权限（Docker 默认 seccomp 会拦截）：
#   docker run --cap-add=SYS_PTRACE --security-opt seccomp=unconfined ...

# ── 运行时镜像 ──────────────────────────────────────────────────
# 基础镜像前缀可切换：本地网络受限时用镜像加速，CI 用官方源
#   docker build --build-arg BASE_IMAGE=docker.m.daocloud.io/library/debian:bookworm-slim ...
ARG BASE_IMAGE=debian:bookworm-slim
FROM ${BASE_IMAGE}

ARG WECHAT_VERSION=4.1.13.26
LABEL org.opencontainers.image.title="zsc-water-and-electricity" \
      org.opencontainers.image.description="微信 + 宿舍水电数据服务（纯 Go 原生 ptrace 取 session）" \
      org.opencontainers.image.version="${WECHAT_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    HOME=/root \
    LANG=C.UTF-8 \
    TZ=Asia/Shanghai

# apt 源可切换：国内构建走清华镜像，CI 用官方源。
#
# registry-mirrors 只影响拉 Docker 镜像，管不到容器内的 apt-get，
# 所以这两件事必须分别处理。
#
# 必须用 http 前缀：bookworm-slim 预装里没有 ca-certificates，
# 用 https 会 "Certificate verification failed"，索引拉不到，
# 后续所有包都会报"不可用"，非常难看出真正原因。
ARG APT_MIRROR=""
RUN if [ -n "$APT_MIRROR" ]; then \
        case "$APT_MIRROR" in http://*|https://*) ;; *) APT_MIRROR="http://$APT_MIRROR";; esac; \
        # https 在没有 ca-certificates 的 slim 镜像里必然失败，降级到 http
        APT_MIRROR=$(echo "$APT_MIRROR" | sed 's|^https://|http://|'); \
        if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
            sed -i "s|http://deb.debian.org/debian|$APT_MIRROR/debian|g; \
                    s|http://deb.debian.org/debian-security|$APT_MIRROR/debian-security|g" \
                /etc/apt/sources.list.d/debian.sources; \
        elif [ -f /etc/apt/sources.list ]; then \
            sed -i "s|http://deb.debian.org/debian|$APT_MIRROR/debian|g; \
                    s|http://deb.debian.org/debian-security|$APT_MIRROR/debian-security|g" \
                /etc/apt/sources.list; \
        fi; \
        echo "apt mirror: $APT_MIRROR"; \
    else \
        echo "apt mirror: official"; \
    fi

# 依赖：一次批量安装（快），失败才退回逐包定位（可诊断）。
#
# 之前写成"每个包单独 apt-get install"，50 多个包每个都要重新解析依赖，
# 光这一步就要 3~5 分钟，纯属自找麻烦。正确做法是先批量装，只有真失败时
# 才降级为逐包尝试，把具体哪个包不可用打印出来。
#
# 注意 Debian 各版本会改名（libasound2 -> libasound2t64、libglib2.0-0 -> libglib2.0-0t64），
# 所以 t64 变体单独兜底安装，不影响主线。
RUN apt-get update && \
    PKGS="libglib2.0-0 libudev1 libfontconfig1 libdbus-1-3 \
        libnss3 libpcre2-8-0 libcap2 libatomic1 libgcc-s1 \
        libx11-6 libxcb1 libxkbcommon0 libxdamage1 libxext6 \
        libxfixes3 libxrandr2 libxrender1 libxtst6 libxi6 libsm6 \
        libxcomposite1 libxcb-shm0 libxcb-util1 libxcb-keysyms1 \
        libxcb-image0 libxcb-icccm4 libxcb-render-util0 libxcb-xfixes0 \
        libxcb-shape0 libxcb-sync1 libxcb-randr0 libxcb-xinerama0 \
        libxcb-cursor0 libxkbcommon-x11-0 \
        libdrm2 libgbm1 libasound2 libpulse0 libcups2 libgl1-mesa-dri \
        # GL/Vulkan/Wayland：缺这两个时 RadiumWMPF 的 GPU 进程初始化失败
        #  [viz_main_impl "Exiting GPU process due to errors during initialization"]
        # 结果是登录二维码渲染不出来（界面只有 "Scan to log in" 文字，图是空白）。
        # 宿主有这两个库所以正常；容器里默认不带，必须显式安装。
        libvulkan1 libwayland-egl1 libwayland-client0 libwayland-server0 \
        # AppEx(Chromium) 在容器里缺这三个：atk/atspi 无障碍桥
        libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 \
        # EGL/GLES 与 wayland（Chromium 探测用，缺失只是告警，但装上更稳）
        libegl1 libgles2 libwayland-client0 libwayland-server0 \
        # dbus：微信启动会连 session bus，缺了会崩
        dbus dbus-x11 \
        fonts-noto-cjk fonts-noto-color-emoji \
        xvfb x11-utils x11-xserver-utils x11-apps xdotool xauth \
        imagemagick tesseract-ocr tesseract-ocr-chi-sim tesseract-ocr-eng \
        ca-certificates tzdata procps iproute2 tini util-linux" && \
    if apt-get install -y --no-install-recommends $PKGS; then \
        echo "batch install: OK"; \
    else \
        echo "批量安装失败，逐包定位"; \
        for p in $PKGS; do \
            apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \
                || echo "  不可用: $p"; \
        done; \
    fi && \
    for p in libasound2t64 libglib2.0-0t64; do \
        apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 || true; \
    done && \
    rm -rf /var/lib/apt/lists/*

# 硬依赖校验：这几个缺了服务肯定跑不起来，直接让构建失败
RUN for bin in Xvfb xdpyinfo xdotool convert tesseract xprop xwd pgrep; do \
        command -v "$bin" >/dev/null || { echo "缺少必要命令: $bin"; exit 1; }; \
    done && \
    echo "runtime tools: OK"

# ImageMagick 默认策略会拦截 png 读写，必须放开（否则 convert 直接失败）
RUN if [ -f /etc/ImageMagick-6/policy.xml ]; then \
        sed -i 's|<policy domain="coder" rights="none" pattern="PNG" />|<policy domain="coder" rights="read\|write" pattern="PNG" />|g' \
            /etc/ImageMagick-6/policy.xml; \
    fi

# 建一个 uid=1000 的普通用户，微信以它运行。
#
# 为什么不用 root：社区方案（linuxserver/weixin 等）都用 PUID/PGID=1000，
# 让实际服务降权运行。实测在容器里以 root 跑微信时，RadiumWMPF 派生的
# AppEx 全部立刻退出（exit=1）并留下僵尸，hooksession 永远报
# "appex never appeared"；而宿主上以 uid 1000 跑就正常。
# mmkv（AppEx 的存储层）对文件属主敏感，root 与 bind mount 的 1000 不一致
# 会导致它判定数据库损坏并反复删除。
RUN groupadd -g 1000 wechat 2>/dev/null || true && \
    useradd -u 1000 -g 1000 -M -s /bin/bash -d /home/wechat wechat 2>/dev/null || true && \
    mkdir -p /home/wechat && chown 1000:1000 /home/wechat && \
    id wechat

# 微信本体：从 .deb 快照安装
ARG WECHAT_DEB=wechat_4.1.13.26_amd64.deb
COPY ${WECHAT_DEB} /tmp/wechat.deb
RUN dpkg -i /tmp/wechat.deb || apt-get -f install -y --no-install-recommends \
    && rm -f /tmp/wechat.deb \
    && test -x /opt/wechat/wechat \
    && echo "wechat installed: $(ls -lh /opt/wechat/wechat | awk '{print $5}')"

# Go 服务二进制
WORKDIR /app
COPY bin/zscwd     /usr/local/bin/zscwd
COPY bin/zsctool   /usr/local/bin/zsctool
COPY bin/hookprobe /usr/local/bin/hookprobe
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY zscwd.env.example /app/zscwd.env.example
RUN chmod +x /usr/local/bin/zscwd /usr/local/bin/zsctool \
             /usr/local/bin/hookprobe /usr/local/bin/entrypoint.sh

# ptrace 走文件 capability：仍需运行时 --cap-add=SYS_PTRACE，
# 但不加的话连 setcap 都省不掉，这里显式设上减少一次手工步骤。
# ptrace 能力：file capability 对任何用户执行都生效，
# 所以 uid 1000 跑 zscwd 也能 ptrace 同一 uid 的微信进程。
RUN setcap cap_sys_ptrace+ep /usr/local/bin/zscwd && \
    setcap cap_sys_ptrace+ep /usr/local/bin/hookprobe && \
    getcap /usr/local/bin/zscwd /usr/local/bin/hookprobe && \
    chmod 755 /usr/local/bin/zscwd /usr/local/bin/zsctool /usr/local/bin/hookprobe

# 微信数据目录：**必须挂 volume 持久化**。
#
# 澄清一个容易误解的点：Linux 版微信不支持自动登录，每次进程重启仍需扫码。
# 持久化的价值在于保存「设备身份」（key_info.dat 等）——微信据此认出这是
# 同一台已登录过的设备；不持久化则每次重启都像「新设备登录」，容易触发风控。
# 字体缓存目录必须对 uid 1000 可写。
#
# 实测报错：Fontconfig error: No writable cache directories
#   /var/cache/fontconfig /root/.cache/fontconfig /root/.fontconfig
# 降权后微信读不到字体缓存，二维码直接渲染成空白（界面只有 "Scan to log in"
# 文字，图是白的）。这类问题在 root 运行时不会出现，很容易被忽略。
RUN mkdir -p /var/cache/fontconfig /root/.cache/fontconfig && \
    chown -R 1000:1000 /var/cache/fontconfig /root/.cache/fontconfig && \
    chmod 755 /var/cache/fontconfig && chmod 755 /root/.cache

# 数据目录归 uid 1000 所有（容器内路径保持 /root/.xwechat 以兼容既有配置，
# 但所有权给 wechat 用户；也可以改成 /home/wechat/.xwechat）
RUN mkdir -p /root/.xwechat /var/log/zsc /run/xvfb && \
    chown -R 1000:1000 /root/.xwechat /var/log/zsc && \
    chmod 755 /root && chmod 700 /root/.xwechat
VOLUME ["/root/.xwechat"]

EXPOSE 8080
# 故意不加 HEALTHCHECK。
#
# 实测踩坑：加了 HEALTHCHECK 配合 --restart unless-stopped，会在启动初期
# （服务还没就绪、健康检查返回非 0）触发 Docker 重启容器，把用户刚扫码的
# 微信登录态一起干掉——表现为"登录后 40 秒服务自己重启了"。
#
# 编排层若需要健康检查，请自己用 /healthz 配置更宽的 start_period，
# 并且不要用会"重启容器"的策略，否则同样会打断登录。

# 用 tini 当 PID 1 回收僵尸进程。
#
# 实测问题：entrypoint 里用 `exec zscwd` 会让 zscwd 变成 PID 1，而它不 wait()
# 孤儿进程，于是微信派生的 AppEx 子进程死后全部变成 <defunct> 僵尸堆着。
# 更严重的是 AppEx 主进程一次都没能正常起来（僵尸残留让再派生失败），
# hooksession 直接报 "appex never appeared"，永远取不到 session。
#
# tini 作为 PID 1 会正确 reap，微信派生的子进程就能正常生灭。
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
