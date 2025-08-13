#!/bin/bash

# 增强版 Pod 网络命名空间进入脚本 - 支持 containerd 和 Docker
# 使用方法: ./enter-pod-netns.sh <pod-name> [namespace] [options]

set -euo pipefail

# 默认值
DEFAULT_NAMESPACE="default"
VERBOSE=false
CONTAINER_INDEX=0
SHOW_HELP=false
CONTAINER_RUNTIME="auto"  # 新增：默认自动检测

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

verbose_log() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 <pod-name> [namespace] [options]

参数:
  pod-name              Pod 名称 (必需)
  namespace             Kubernetes 命名空间 (默认: default)

选项:
  -c, --container INDEX 指定容器索引 (默认: 0，即第一个容器)
  -r, --runtime RUNTIME 指定容器运行时 (containerd|docker|auto，默认: auto)
  -v, --verbose         详细模式
  -h, --help           显示此帮助信息

示例:
  $0 my-pod                           # 进入 default 命名空间中 my-pod 的第一个容器网络命名空间
  $0 my-pod kube-system               # 进入 kube-system 命名空间中的 my-pod
  $0 my-pod default -c 1              # 进入第二个容器的网络命名空间
  $0 my-pod default -r docker         # 强制使用 Docker 运行时
  $0 my-pod default -r containerd     # 强制使用 containerd 运行时
  $0 my-pod default -v                # 详细模式

支持的容器运行时:
  - containerd (通过 ctr)
  - docker (通过 docker)
  - auto (自动检测，优先 containerd)

EOF
}

# 解析命令行参数
parse_args() {
    # 首先检查是否有帮助选项
    for arg in "$@"; do
        case $arg in
            -h|--help)
                show_help
                exit 0
                ;;
        esac
    done

    if [[ $# -eq 0 ]]; then
        log_error "缺少必需的参数"
        show_help
        exit 1
    fi

    POD_NAME="$1"
    shift

    # 检查第二个参数是否为选项
    if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
        NAMESPACE="$1"
        shift
    else
        NAMESPACE="$DEFAULT_NAMESPACE"
    fi

    # 解析选项
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--container)
                if [[ $# -lt 2 ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                CONTAINER_INDEX="$2"
                shift 2
                ;;
            -r|--runtime)
                if [[ $# -lt 2 ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                CONTAINER_RUNTIME="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 验证容器索引
    if ! [[ "$CONTAINER_INDEX" =~ ^[0-9]+$ ]]; then
        log_error "容器索引必须是非负整数"
        exit 1
    fi

    # 验证容器运行时参数
    case "$CONTAINER_RUNTIME" in
        auto|containerd|docker)
            ;; # 有效值
        *)
            log_error "无效的容器运行时: $CONTAINER_RUNTIME"
            log_error "支持的值: auto, containerd, docker"
            exit 1
            ;;
    esac
}

# 检测或设置容器运行时
detect_container_runtime() {
    verbose_log "容器运行时设置: $CONTAINER_RUNTIME"

    if [[ "$CONTAINER_RUNTIME" != "auto" ]]; then
        # 用户手动指定了运行时，验证其可用性
        case "$CONTAINER_RUNTIME" in
            containerd)
                if ! command -v ctr >/dev/null 2>&1; then
                    log_error "指定了 containerd 运行时，但 ctr 命令不可用"
                    exit 1
                fi
                if ! ctr -n k8s.io containers list >/dev/null 2>&1; then
                    log_error "ctr 命令可用，但无法访问 k8s.io 命名空间"
                    log_error "请检查 containerd 是否正在运行以及权限设置"
                    exit 1
                fi
                verbose_log "使用指定的 containerd 运行时"
                ;;
            docker)
                if ! command -v docker >/dev/null 2>&1; then
                    log_error "指定了 docker 运行时，但 docker 命令不可用"
                    exit 1
                fi
                if ! docker ps >/dev/null 2>&1; then
                    log_error "docker 命令可用，但无法连接到 Docker 守护进程"
                    log_error "请检查 Docker 是否正在运行以及权限设置"
                    exit 1
                fi
                verbose_log "使用指定的 Docker 运行时"
                ;;
        esac
        return 0
    fi

    # 自动检测模式
    verbose_log "自动检测容器运行时..."

    # 优先检查 containerd
    if command -v ctr >/dev/null 2>&1; then
        if ctr -n k8s.io containers list >/dev/null 2>&1; then
            CONTAINER_RUNTIME="containerd"
            verbose_log "自动检测到 containerd 运行时"
            return 0
        fi
    fi

    # 检查 docker
    if command -v docker >/dev/null 2>&1; then
        if docker ps >/dev/null 2>&1; then
            CONTAINER_RUNTIME="docker"
            verbose_log "自动检测到 Docker 运行时"
            return 0
        fi
    fi

    log_error "未检测到可用的容器运行时"
    log_error "请确保以下条件之一满足:"
    log_error "  1. ctr 已安装且可访问 containerd (k8s.io 命名空间)"
    log_error "  2. docker 已安装且 Docker 守护进程正在运行"
    log_error "或者使用 -r 参数手动指定容器运行时"
    exit 1
}

# 获取 Pod 信息
get_pod_info() {
    verbose_log "获取 Pod '$POD_NAME' 在命名空间 '$NAMESPACE' 中的信息..."

    if ! kubectl get pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        log_error "Pod '$POD_NAME' 在命名空间 '$NAMESPACE' 中不存在"
        exit 1
    fi

    # 获取 Pod 状态
    POD_STATUS=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    if [[ "$POD_STATUS" != "Running" ]]; then
        log_error "Pod '$POD_NAME' 状态为 '$POD_STATUS'，不是 Running"
        exit 1
    fi

    # 获取容器数量
    CONTAINER_COUNT=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' | wc -w)
    verbose_log "Pod 中有 $CONTAINER_COUNT 个容器"

    if [[ $CONTAINER_INDEX -ge $CONTAINER_COUNT ]]; then
        log_error "容器索引 $CONTAINER_INDEX 超出范围 (0-$((CONTAINER_COUNT-1)))"
        exit 1
    fi

    # 获取指定容器的名称
    CONTAINER_NAME=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.containers[$CONTAINER_INDEX].name}")
    verbose_log "目标容器: $CONTAINER_NAME (索引: $CONTAINER_INDEX)"

    log_info "Pod: $POD_NAME, 命名空间: $NAMESPACE, 容器: $CONTAINER_NAME"
}

# 获取容器 ID (containerd)
get_container_id_containerd() {
    verbose_log "使用 containerd 获取容器 ID..."

    # 构建标签过滤器
    local pod_label="io.kubernetes.pod.name=$POD_NAME"
    local namespace_label="io.kubernetes.pod.namespace=$NAMESPACE"
    local container_label="io.kubernetes.container.name=$CONTAINER_NAME"

    verbose_log "搜索标签: $pod_label, $namespace_label, $container_label"

    # 使用 ctr 获取容器 ID
    CONTAINER_ID=$(ctr -n k8s.io containers list -q | while read -r cid; do
        # 获取容器信息
        local info=$(ctr -n k8s.io containers info "$cid" 2>/dev/null || continue)
        
        # 检查标签是否匹配
        if echo "$info" | jq -r '.Labels["io.kubernetes.pod.name"]' 2>/dev/null | grep -q "^$POD_NAME$" && \
           echo "$info" | jq -r '.Labels["io.kubernetes.pod.namespace"]' 2>/dev/null | grep -q "^$NAMESPACE$" && \
           echo "$info" | jq -r '.Labels["io.kubernetes.container.name"]' 2>/dev/null | grep -q "^$CONTAINER_NAME$"; then
            echo "$cid"
            break
        fi
    done)

    if [[ -z "$CONTAINER_ID" ]]; then
        log_error "无法找到匹配的容器 ID"
        exit 1
    fi

    verbose_log "找到容器 ID: $CONTAINER_ID"
}

# 获取容器 ID (Docker)
get_container_id_docker() {
    verbose_log "使用 Docker 获取容器 ID..."

    # 构建标签过滤器
    local pod_label="io.kubernetes.pod.name=$POD_NAME"
    local namespace_label="io.kubernetes.pod.namespace=$NAMESPACE"
    local container_label="io.kubernetes.container.name=$CONTAINER_NAME"

    verbose_log "搜索标签: $pod_label, $namespace_label, $container_label"

    # 使用 docker 获取容器 ID
    CONTAINER_ID=$(docker ps --filter "label=$pod_label" \
                              --filter "label=$namespace_label" \
                              --filter "label=$container_label" \
                              --format "{{.ID}}" | head -n1)

    if [[ -z "$CONTAINER_ID" ]]; then
        log_error "无法找到匹配的容器 ID"
        exit 1
    fi

    verbose_log "找到容器 ID: $CONTAINER_ID"
}

# 获取容器 PID (containerd)
get_container_pid_containerd() {
    verbose_log "使用 containerd 获取容器 PID..."

    # 首先尝试 ctr task list
    CONTAINER_PID=$(ctr -n k8s.io task list | grep "^$CONTAINER_ID" | awk '{print $2}' 2>/dev/null || true)
    
    if [[ -z "$CONTAINER_PID" || "$CONTAINER_PID" == "-" ]]; then
        # 备用方案：使用 ctr task info
        verbose_log "task list 未返回 PID，尝试 task info..."
        CONTAINER_PID=$(ctr -n k8s.io task info "$CONTAINER_ID" 2>/dev/null | jq -r '.Pid // empty' 2>/dev/null || true)
    fi

    if [[ -z "$CONTAINER_PID" || "$CONTAINER_PID" == "null" || "$CONTAINER_PID" == "-" ]]; then
        log_error "无法获取容器 PID"
        log_error "容器可能未运行或处于异常状态"
        exit 1
    fi

    verbose_log "找到容器 PID: $CONTAINER_PID"
}

# 获取容器 PID (Docker)
get_container_pid_docker() {
    verbose_log "使用 Docker 获取容器 PID..."

    CONTAINER_PID=$(docker inspect "$CONTAINER_ID" --format '{{.State.Pid}}')

    if [[ -z "$CONTAINER_PID" || "$CONTAINER_PID" == "0" ]]; then
        log_error "无法获取容器 PID"
        log_error "容器可能未运行或处于异常状态"
        exit 1
    fi

    verbose_log "找到容器 PID: $CONTAINER_PID"
}

# 进入网络命名空间
enter_netns() {
    verbose_log "准备进入网络命名空间..."

    # 检查 nsenter 命令
    if ! command -v nsenter >/dev/null 2>&1; then
        log_error "nsenter 命令不可用"
        exit 1
    fi

    # 检查网络命名空间文件是否存在
    local netns_path="/proc/$CONTAINER_PID/ns/net"
    if [[ ! -e "$netns_path" ]]; then
        log_error "网络命名空间文件不存在: $netns_path"
        exit 1
    fi

    log_success "成功找到容器网络命名空间"
    log_info "容器运行时: $CONTAINER_RUNTIME"
    log_info "容器 ID: $CONTAINER_ID"
    log_info "容器 PID: $CONTAINER_PID"
    log_info "网络命名空间: $netns_path"
    echo
    log_info "正在进入容器网络命名空间..."
    log_info "使用 'exit' 命令退出"
    echo

    # 进入网络命名空间并启动 shell
    exec nsenter -t "$CONTAINER_PID" -n bash
}

# 主函数
main() {
    parse_args "$@"
    detect_container_runtime
    get_pod_info

    case "$CONTAINER_RUNTIME" in
        containerd)
            get_container_id_containerd
            get_container_pid_containerd
            ;;
        docker)
            get_container_id_docker
            get_container_pid_docker
            ;;
        *)
            log_error "未知的容器运行时: $CONTAINER_RUNTIME"
            exit 1
            ;;
    esac

    enter_netns
}

# 执行主函数
main "$@"