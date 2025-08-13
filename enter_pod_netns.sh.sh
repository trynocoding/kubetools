#!/bin/bash

# 简化版 Pod 网络命名空间进入脚本 (已修复 containerd PID 获取)
# 使用 kubectl 直接获取容器 ID，然后通过容器运行时获取 PID
# 使用方法: ./enter-pod-netns-simple-fixed.sh <pod-name> [namespace] [options]

set -euo pipefail

# 默认值
DEFAULT_NAMESPACE="default"
VERBOSE=false
CONTAINER_INDEX=0
CONTAINER_RUNTIME="auto"

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
  $0 my-pod default -v                # 详细模式

EOF
}

# 解析命令行参数
parse_args() {
    # 检查帮助选项
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
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 检测容器运行时
detect_runtime() {
    verbose_log "容器运行时设置: $CONTAINER_RUNTIME"
    
    if [[ "$CONTAINER_RUNTIME" == "auto" ]]; then
        verbose_log "自动检测容器运行时..."
        
        # 检查 containerd
        if command -v ctr >/dev/null 2>&1 && ctr version >/dev/null 2>&1; then
            CONTAINER_RUNTIME="containerd"
            verbose_log "自动检测到 containerd 运行时"
            return 0
        fi
        
        # 检查 docker
        if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
            CONTAINER_RUNTIME="docker"
            verbose_log "自动检测到 docker 运行时"
            return 0
        fi
        
        log_error "无法检测到支持的容器运行时 (containerd 或 docker)"
        exit 1
    fi
    
    # 验证指定的运行时
    case "$CONTAINER_RUNTIME" in
        containerd)
            if ! command -v ctr >/dev/null 2>&1; then
                log_error "containerd (ctr) 命令未找到"
                exit 1
            fi
            ;;
        docker)
            if ! command -v docker >/dev/null 2>&1; then
                log_error "docker 命令未找到"
                exit 1
            fi
            ;;
        *)
            log_error "不支持的容器运行时: $CONTAINER_RUNTIME"
            exit 1
            ;;
    esac
}

# 获取 Pod 信息和容器 ID
get_container_id_from_pod() {
    verbose_log "获取 Pod '$POD_NAME' 在命名空间 '$NAMESPACE' 中的容器信息..."
    
    # 检查 kubectl 是否可用
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl 命令未找到"
        exit 1
    fi
    
    # 获取 Pod 信息
    if ! POD_INFO=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o json 2>/dev/null); then
        log_error "无法获取 Pod '$POD_NAME' 在命名空间 '$NAMESPACE' 中的信息"
        log_error "请检查 Pod 名称和命名空间是否正确"
        exit 1
    fi
    
    # 检查 Pod 状态
    POD_PHASE=$(echo "$POD_INFO" | jq -r '.status.phase')
    if [[ "$POD_PHASE" != "Running" ]]; then
        log_error "Pod '$POD_NAME' 状态为 '$POD_PHASE'，不是 'Running'"
        exit 1
    fi
    
    # 获取容器状态列表
    local container_statuses
    container_statuses=$(echo "$POD_INFO" | jq -r '.status.containerStatuses')
    
    if [[ "$container_statuses" == "null" || -z "$container_statuses" ]]; then
        log_error "无法获取容器状态信息"
        exit 1
    fi
    
    # 获取容器数量
    local container_count
    container_count=$(echo "$container_statuses" | jq '. | length')
    
    verbose_log "Pod 中有 $container_count 个容器"
    
    # 验证容器索引
    if [[ $CONTAINER_INDEX -ge $container_count ]]; then
        log_error "容器索引 $CONTAINER_INDEX 超出范围 (0-$((container_count-1)))"
        
        # 显示可用的容器
        local container_names
        container_names=$(echo "$container_statuses" | jq -r '.[].name' | tr '\n' ' ')
        log_error "可用的容器: $container_names"
        exit 1
    fi
    
    # 获取指定索引的容器信息
    local target_container_status
    target_container_status=$(echo "$container_statuses" | jq ".[$CONTAINER_INDEX]")
    
    # 获取容器名称
    TARGET_CONTAINER=$(echo "$target_container_status" | jq -r '.name')
    
    # 检查容器是否运行中
    local container_ready
    container_ready=$(echo "$target_container_status" | jq -r '.ready')
    local container_state
    container_state=$(echo "$target_container_status" | jq -r '.state | keys[0]')
    
    if [[ "$container_ready" != "true" || "$container_state" != "running" ]]; then
        log_error "容器 '$TARGET_CONTAINER' 未运行 (ready: $container_ready, state: $container_state)"
        exit 1
    fi
    
    # 获取容器 ID
    CONTAINER_ID=$(echo "$target_container_status" | jq -r '.containerID')
    
    if [[ -z "$CONTAINER_ID" || "$CONTAINER_ID" == "null" ]]; then
        log_error "无法获取容器 '$TARGET_CONTAINER' 的容器 ID"
        exit 1
    fi
    
    # 处理容器 ID 格式 (去掉前缀，如 "containerd://")
    if [[ "$CONTAINER_ID" =~ ^[a-z]+:// ]]; then
        CONTAINER_ID="${CONTAINER_ID#*://}"
    fi
    
    verbose_log "目标容器: $TARGET_CONTAINER (索引: $CONTAINER_INDEX)"
    verbose_log "容器 ID: $CONTAINER_ID"
    
    log_info "Pod: $POD_NAME, 命名空间: $NAMESPACE, 容器: $TARGET_CONTAINER"
}

# 通过容器 ID 获取 PID
get_pid_from_container_id() {
    verbose_log "通过容器 ID '$CONTAINER_ID' 获取 PID..."
    
    case "$CONTAINER_RUNTIME" in
        containerd)
            get_pid_from_containerd
            ;;
        docker)
            get_pid_from_docker
            ;;
        *)
            log_error "不支持的容器运行时: $CONTAINER_RUNTIME"
            return 1
            ;;
    esac
}

# 从 containerd 获取 PID (已根据您的建议修正)
get_pid_from_containerd() {
    verbose_log "使用 containerd 获取容器 PID..."
    
    # 通过 task list 获取 PID
    local task_line
    # 使用 grep 和 head -n 1 确保只匹配一行
    if ! task_line=$(ctr -n k8s.io task list | grep "$CONTAINER_ID" | head -n 1); then
        log_error "在 containerd 任务列表中找不到容器 '$CONTAINER_ID'"
        return 1
    fi

    if [[ -z "$task_line" ]]; then
        log_error "在 containerd 任务列表中找不到容器 '$CONTAINER_ID'"
        return 1
    fi
    
    # 提取 PID (第二列)
    CONTAINER_PID=$(echo "$task_line" | awk '{print $2}')
    
    if [[ -z "$CONTAINER_PID" || "$CONTAINER_PID" == "0" ]]; then
        log_error "无法从任务列表中获取有效的容器 PID"
        return 1
    fi
    
    verbose_log "容器 PID: $CONTAINER_PID"
    return 0
}

# 从 docker 获取 PID
get_pid_from_docker() {
    verbose_log "使用 docker 获取容器 PID..."
    
    # 直接通过容器 ID 获取 PID
    if ! CONTAINER_PID=$(docker inspect --format "{{.State.Pid}}" "$CONTAINER_ID" 2>/dev/null); then
        log_error "无法获取容器 '$CONTAINER_ID' 的 PID"
        return 1
    fi
    
    if [[ -z "$CONTAINER_PID" || "$CONTAINER_PID" == "0" ]]; then
        log_error "容器 PID 无效: $CONTAINER_PID"
        return 1
    fi
    
    verbose_log "容器 PID: $CONTAINER_PID"
    return 0
}

# 进入网络命名空间
enter_netns() {
    if [[ -z "$CONTAINER_PID" ]]; then
        log_error "容器 PID 未设置"
        exit 1
    fi
    
    local netns_path="/proc/$CONTAINER_PID/ns/net"
    
    if [[ ! -e "$netns_path" ]]; then
        log_error "网络命名空间路径不存在: $netns_path"
        exit 1
    fi
    
    log_success "进入容器网络命名空间 (PID: $CONTAINER_PID)"
    log_info "您现在处于 Pod '$POD_NAME' 容器 '$TARGET_CONTAINER' 的网络命名空间中"
    log_info "使用 'exit' 退出网络命名空间"
    
    # 进入网络命名空间并启动 shell
    exec nsenter -t "$CONTAINER_PID" -n -p bash --rcfile <(echo "PS1='[netns:$POD_NAME/$TARGET_CONTAINER] \u@\h:\w\$ '")
}

# 主函数
main() {
    parse_args "$@"
    detect_runtime
    get_container_id_from_pod
    
    if ! get_pid_from_container_id; then
        log_error "获取容器 PID 失败"
        exit 1
    fi
    
    enter_netns
}

# 检查是否以 root 权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        log_info "请使用: sudo $0 $*"
        exit 1
    fi
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_root "$@"
    main "$@"
fi