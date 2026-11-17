#!/bin/sh
# 容器启动：拉起 Xvfb → 拉起微信 → 启动服务
#
# 重要：本容器必须带 --cap-add=SYS_PTRACE --security-opt seccomp=unconfined，
# 否则 hooksession 无法 ptrace，表现为一直报权限错误拿不到 session。
set -eu

DISPLAY="${DISPLAY:-:99}"
export DISPLAY

log() { echo "[entrypoint] $*"; }

# 运行时用户：默认 uid/gid 1000（与宿主 bind mount 属主一致）
RUNTIME_UID="${PUID:-1000}"
RUNTIME_GID="${PGID:-1000}"

# 数据目录属主对齐：宿主 bind mount 是 1000，容器内也用 1000
if [ -d /root/.xwechat ]; then
    if [ "$(stat -c %u /root/.xwechat 2>/dev/null)" != "$RUNTIME_UID" ]; then
        log "fixing ownership of /root/.xwechat to $RUNTIME_UID:$RUNTIME_GID"
        chown -R "$RUNTIME_UID:$RUNTIME_GID" /root/.xwechat 2>/dev/null || true
    fi
fi
mkdir -p /var/log/zsc
chown "$RUNTIME_UID:$RUNTIME_GID" /var/log/zsc 2>/dev/null || true

# 1) Xvfb
#
# 注意清理残留锁：容器被 docker stop 再 start 时，/tmp/.X99-lock 会留下，
# Xvfb 直接报 "Server is already active for display 99" 起不来。
# 只有在确认没有进程响应该 display 时才清锁，避免误删正在用的锁。
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    lock="/tmp/.X${DISPLAY#:}-lock"
    sock="/tmp/.X11-unix/X${DISPLAY#:}"
    if [ -e "$lock" ]; then
        log "removing stale X lock $lock"
        rm -f "$lock" "$sock" 2>/dev/null || true
    fi
    log "starting Xvfb on $DISPLAY as uid $RUNTIME_UID"
    # Xvfb 必须与微信同 uid 运行。
    #
    # 实测：容器里 Xvfb 以 root 跑、微信以 uid 1000 跑时，X 的 MIT-SHM
    # （X 共享内存扩展）在跨用户场景下不可用，Chromium 的 webview 会卡在
    # "二维码图案已画出但被半透明遮罩盖住 + 转圈"的状态，永远不出码。
    # 宿主上 Xvfb 和微信都是 uid 1000，所以没有这个问题。
    #
    # 这也是社区 dolphinv/x11docker 等方案强调 X server 与应用同 uid 的原因。
    setpriv --reuid="$RUNTIME_UID" --regid="$RUNTIME_GID" --clear-groups \
        Xvfb "$DISPLAY" -screen 0 "${XVFB_SCREEN:-1920x1200x24}" \
        -nolisten tcp -ac +extension GLX +extension RENDER -noreset &
    for _ in $(seq 1 50); do
        xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
        sleep 0.2
    done
fi
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || { log "Xvfb failed to start"; exit 1; }
log "X display ready: $DISPLAY"

# 1.5) dbus session：微信启动会连 session bus，缺了会直接崩
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    if command -v dbus-launch >/dev/null 2>&1; then
        log "starting dbus session"
        eval "$(dbus-launch --sh-syntax)"
        export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
    elif command -v dbus-daemon >/dev/null 2>&1; then
        log "starting dbus-daemon"
        mkdir -p /run/dbus
        dbus-daemon --session --fork --print-address > /tmp/dbus.addr 2>/dev/null || true
        if [ -s /tmp/dbus.addr ]; then
            DBUS_SESSION_BUS_ADDRESS=$(cat /tmp/dbus.addr)
            export DBUS_SESSION_BUS_ADDRESS
        fi
    fi
fi

# 1.8) 微信必需的运行时环境
#
# 这些都是实测出来的：缺少任何一个，微信在容器里会直接 Aborted（core dump），
# 而日志里只有无关的 wayland 告警，非常难定位。
# XDG_RUNTIME_DIR 必须归运行用户所有。
#
# 实测报错：XDG_RUNTIME_DIR (/tmp/runtime-root) is not owned by us (uid 1000),
# but by uid 0!  —— entrypoint 以 root 创建目录、微信以 1000 运行，属主不符。
# 后果是 PulseAudio/GPU 相关初始化失败，进而 webview 渲染不出二维码。
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
mkdir -p "$XDG_RUNTIME_DIR"
chown "$RUNTIME_UID:$RUNTIME_GID" "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$XDG_RUNTIME_DIR"
# 跨 uid 场景下禁用 MIT-SHM，避免 Chromium 走共享内存渲染（见上面 Xvfb 注释）
export QT_X11_NO_MITSHM=1
export J2D_USE_MITSHM=0
export LIBGL_ALWAYS_SOFTWARE=1
export QT_QPA_PLATFORM=xcb
export GDK_BACKEND=x11
# 没有 PulseAudio 服务时不指定，让 libpulse 自行降级
if [ -n "${PULSE_SERVER:-}" ]; then export PULSE_SERVER; fi

# 2) 微信（不阻塞；服务自己会探测它是否在跑）
if [ "${START_WECHAT:-1}" = "1" ]; then
    if ! pgrep -f '^/opt/wechat/wechat' >/dev/null 2>&1; then
        log "starting WeChat as uid $RUNTIME_UID"
        # 以普通用户身份运行（不是 root）。
        #
        # 实测：容器内以 root 跑微信时，RadiumWMPF 派生的 AppEx 全部立刻
        # 退出（exit=1）+ 留僵尸，hooksession 报 "appex never appeared"。
        # 宿主上以 uid 1000 跑就正常。mmkv（AppEx 存储层）对文件属主敏感，
        # root 与 bind mount 的 1000 不一致会让它判定数据库损坏并反复删除。
        setpriv --reuid="$RUNTIME_UID" --regid="$RUNTIME_GID" --clear-groups \
            /opt/wechat/wechat \
            --ozone-platform=x11 --disable-gpu --disable-gpu-compositing \
            --use-gl=swiftshader --in-process-gpu >/var/log/zsc/wechat.log 2>&1 &
        sleep 5
        if ! pgrep -f '^/opt/wechat/wechat' >/dev/null 2>&1; then
            log "WARNING: WeChat exited right after start; see /var/log/zsc/wechat.log"
        else
            log "WeChat is running"
        fi
    else
        log "WeChat already running"
    fi
fi

# 3) 环境变量桥接：.env 里的键可直接用容器环境变量给
if [ -z "${API_TOKEN:-}" ]; then
    log "ERROR: API_TOKEN is required (pass -e API_TOKEN=...)"
    exit 1
fi
cat > /app/.env.runtime <<ENVEOF
API_TOKEN=${API_TOKEN}
HTTP_ADDR=${HTTP_ADDR:-0.0.0.0:8080}
CHECK_INTERVAL=${CHECK_INTERVAL:-60s}
LOGIN_CHECK_INTERVAL=${LOGIN_CHECK_INTERVAL:-2s}
IGNITE_AFTER_LOGIN=${IGNITE_AFTER_LOGIN:-5s}
SESSION_REFRESH_INTERVAL=${SESSION_REFRESH_INTERVAL:-30m}
SESSION_TTL=${SESSION_TTL:-2h}
CLOSE_WEBVIEW_DELAY=${CLOSE_WEBVIEW_DELAY:-10s}
HOOK_ENABLE_GATE_PATCH=${HOOK_ENABLE_GATE_PATCH:-true}
AUTO_LOGIN_ENABLED=${AUTO_LOGIN_ENABLED:-true}
AUTO_RESTART=${AUTO_RESTART:-true}
AUTO_CLICK=${AUTO_CLICK:-true}
WECHAT_EXE=/opt/wechat/wechat
WECHAT_DISPLAY=${DISPLAY}
WECHAT_HOME=${HOME}
APPEX_EXECUTABLE=/opt/wechat/RadiumWMPF/runtime/WeChatAppEx
LOG_LEVEL=${LOG_LEVEL:-info}
ENVEOF
# 属主与权限：运行时用户要能读（chmod 600 属于 root 时降权后读不到）
chown "$RUNTIME_UID:$RUNTIME_GID" /app/.env.runtime 2>/dev/null || true
chmod 600 /app/.env.runtime

log "starting zscwd as uid $RUNTIME_UID"
# zscwd 也以同一用户运行：它要 ptrace 微信，同 uid 最简单（配合 cap_sys_ptrace）。
exec setpriv --reuid="$RUNTIME_UID" --regid="$RUNTIME_GID" --clear-groups \
    /usr/local/bin/zscwd -env /app/.env.runtime
