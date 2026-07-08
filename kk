#!/usr/bin/env bash
set -uo pipefail

SCRIPT_NAME="${0##*/}"
KUBECTL_BIN="${KUBECTL:-kubectl}"
KTCTL_BIN="${KTCTL:-ktctl}"
DEFAULT_KUBECONFIG=""
if [[ -n "${HOME:-}" ]]; then
  DEFAULT_KUBECONFIG="$HOME/.kube/config"
fi
KT_KUBECONFIG="${KT_KUBECONFIG:-${KUBECONFIG:-$DEFAULT_KUBECONFIG}}"
KT_CONNECT_SUDO="${KT_CONNECT_SUDO:-1}"
KT_CONNECT_STATE_DIR="${KT_CONNECT_STATE_DIR:-/tmp}"
FZF_BIN="${FZF:-fzf}"
PRINT_ONLY=0
SKIP_PAUSE=0
BACK_CHOICE=".. back"
BACK_STATUS=10
KT_CONNECT_CMD=()

usage() {
  cat <<'EOF'
kk - interactive kubectl helper

Usage:
  kk
  kk --print
  kk --help

Options:
  --print   Build a kubectl/ktctl command interactively and print it without running it.
  --help    Show this help text.

Environment:
  KUBECTL   kubectl executable to use. Defaults to kubectl.
  KTCTL     ktctl executable to use. Defaults to ktctl.
  KT_KUBECONFIG
            kubeconfig passed to ktctl --kubeconfig.
            Defaults to KUBECONFIG or $HOME/.kube/config.
  KT_CONNECT_SUDO
            use sudo for ktctl connect. Defaults to 1.
  KT_CONNECT_STATE_DIR
            directory for ktctl connect pid/log files. Defaults to /tmp.
  FZF       fzf executable to use. Defaults to fzf.

Examples:
  kk
  kk --print
  KUBECTL=/usr/local/bin/kubectl kk
  KTCTL=/usr/local/bin/ktctl kk
  KT_CONNECT_SUDO=0 kk
EOF
}

die() {
  printf 'kk: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

require_interactive_tty() {
  [[ -t 0 && -t 1 ]] || die "interactive terminal required; use '$SCRIPT_NAME --help' for usage"
}

quote_cmd() {
  local quoted=()
  local arg

  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    quoted+=("$arg")
  done

  printf '%s\n' "${quoted[*]}"
}

pause_if_interactive() {
  [[ -t 0 && -t 1 ]] || return 0
  printf '\n'
  read -r -p "Press Enter to continue..." _
}

run_command() {
  local _risk="$1"
  local status
  shift

  printf '\nCommand:\n  '
  quote_cmd "$@"
  printf '\n'

  if (( PRINT_ONLY )); then
    return 0
  fi

  "$@"
  status=$?
  if (( status != 0 )); then
    printf '\nCommand exited with status %d.\n' "$status" >&2
  fi
  return "$status"
}

run_log_page() {
  local status
  local quoted
  local -a statuses

  printf '\nEntering log page. Press Ctrl+C to stop following, q to quit.\n'
  printf '\nCommand:\n  '
  quoted=$(quote_cmd "$@")
  printf '%s' "$quoted"
  if command -v less >/dev/null 2>&1; then
    printf ' | less -R +F\n'
  else
    printf '\n'
  fi

  if (( PRINT_ONLY )); then
    return 0
  fi

  if command -v less >/dev/null 2>&1; then
    "$@" 2>&1 | less -R +F
    statuses=("${PIPESTATUS[@]}")
    status="${statuses[0]}"
    SKIP_PAUSE=1
  else
    "$@"
    status=$?
  fi

  case "$status" in
    0|130|141|143) return 0 ;;
  esac

  if (( status != 0 )); then
    printf '\nCommand exited with status %d.\n' "$status" >&2
  fi
  return "$status"
}

fzf_select() {
  local prompt="$1"
  local selection
  local item display
  local max_key_len="${#BACK_CHOICE}"
  local -a rows=()
  shift

  if (($# == 0)); then
    return 1
  fi

  for item in "$@"; do
    ((${#item} > max_key_len)) && max_key_len="${#item}"
  done

  printf -v display "%-${max_key_len}s  %s" "$BACK_CHOICE" "返回上一级菜单"
  rows+=("$BACK_CHOICE"$'\t'"$display")
  for item in "$@"; do
    rows+=("$item"$'\t'"$item")
  done

  selection=$(printf '%s\n' "${rows[@]}" | "$FZF_BIN" \
    --height="${KK_FZF_HEIGHT:-70%}" \
    --layout=reverse \
    --border \
    --cycle \
    --delimiter=$'\t' \
    --with-nth=2 \
    --prompt="$prompt> ") || return 1

  selection="${selection%%$'\t'*}"
  if [[ "$selection" == "$BACK_CHOICE" ]]; then
    return "$BACK_STATUS"
  fi

  printf '%s\n' "$selection"
}

fzf_select_described() {
  local prompt="$1"
  local selection
  local item key desc display
  local max_key_len=0
  local back_row=""
  local -a rows=()
  shift

  if (($# == 0)); then
    return 1
  fi

  for item in "$@"; do
    key="${item%%$'\t'*}"
    ((${#key} > max_key_len)) && max_key_len="${#key}"
  done

  for item in "$@"; do
    key="${item%%$'\t'*}"
    if [[ "$item" == *$'\t'* ]]; then
      desc="${item#*$'\t'}"
    else
      desc=""
    fi
    printf -v display "%-${max_key_len}s  %s" "$key" "$desc"
    if [[ "$key" == "$BACK_CHOICE" ]]; then
      back_row="$key"$'\t'"$display"
    else
      rows+=("$key"$'\t'"$display")
    fi
  done

  if [[ -n "$back_row" ]]; then
    rows=("$back_row" "${rows[@]}")
  fi

  selection=$(printf '%s\n' "${rows[@]}" | "$FZF_BIN" \
    --height="${KK_FZF_HEIGHT:-70%}" \
    --layout=reverse \
    --border \
    --cycle \
    --delimiter=$'\t' \
    --with-nth=2 \
    --prompt="$prompt> ") || return 1

  selection="${selection%%$'\t'*}"
  if [[ "$selection" == "$BACK_CHOICE" ]]; then
    return "$BACK_STATUS"
  fi

  printf '%s\n' "$selection"
}

non_empty_lines() {
  sed '/^[[:space:]]*$/d'
}

kubectl_output() {
  local output

  if ! output=$("$KUBECTL_BIN" "$@" 2>&1); then
    printf 'kubectl failed:\n%s\n' "$output" >&2
    return 1
  fi

  printf '%s\n' "$output"
}

choose_namespace() {
  local current output selection namespace
  local namespaces=()

  current=$("$KUBECTL_BIN" config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)
  [[ -n "$current" ]] || current="default"

  if output=$(kubectl_output get ns -o name); then
    while IFS= read -r namespace; do
      namespaces+=("$namespace")
    done < <(printf '%s\n' "$output" | sed 's#^namespace/##' | non_empty_lines)
  fi

  if ((${#namespaces[@]} == 0)); then
    namespaces=("$current")
  fi

  selection=$(fzf_select "namespace" "${namespaces[@]}") || return $?
  printf '%s\n' "$selection"
}

choose_context() {
  local output selection context
  local contexts=()

  output=$(kubectl_output config get-contexts -o name) || return 1
  while IFS= read -r context; do
    contexts+=("$context")
  done < <(printf '%s\n' "$output" | non_empty_lines)

  if ((${#contexts[@]} == 0)); then
    printf 'No kubectl contexts found.\n' >&2
    return 1
  fi

  selection=$(fzf_select "context" "${contexts[@]}") || return $?
  printf '%s\n' "$selection"
}

choose_resource_type() {
  fzf_select_described "resource" \
    $'pods\t查看 Pod 运行状态和节点分布' \
    $'deployments\t查看 Deployment 副本和发布状态' \
    $'services\t查看 Service 暴露方式和端口' \
    $'ingress\t查看 Ingress 路由规则' \
    $'configmaps\t查看 ConfigMap 配置' \
    $'secrets\t查看 Secret 资源名称' \
    $'events\t查看集群事件并按时间排序' \
    "${BACK_CHOICE}"$'\t返回上一级菜单'
}

choose_yaml_resource_type() {
  fzf_select_described "resource" \
    $'pods\t导出 Pod YAML' \
    $'deployments\t导出 Deployment YAML' \
    $'services\t导出 Service YAML' \
    $'ingress\t导出 Ingress YAML' \
    $'configmaps\t导出 ConfigMap YAML' \
    $'secrets\t导出 Secret YAML' \
    "${BACK_CHOICE}"$'\t返回上一级菜单'
}

choose_named_resource() {
  local namespace="$1"
  local resource="$2"
  local output selection item
  local items=()

  output=$(kubectl_output get "$resource" -n "$namespace" -o name) || return 1
  while IFS= read -r item; do
    items+=("$item")
  done < <(printf '%s\n' "$output" | non_empty_lines)

  if ((${#items[@]} == 0)); then
    printf 'No %s found in namespace %s.\n' "$resource" "$namespace" >&2
    return 1
  fi

  selection=$(fzf_select "$resource" "${items[@]}") || return $?
  printf '%s\n' "$selection"
}

choose_container() {
  local namespace="$1"
  local pod="$2"
  local pod_name output selection container
  local containers=()

  pod_name="${pod#pod/}"
  output=$(kubectl_output get pod "$pod_name" -n "$namespace" \
    -o 'jsonpath={.spec.initContainers[*].name} {.spec.containers[*].name}') || return 1
  while IFS= read -r container; do
    containers+=("$container")
  done < <(printf '%s\n' "$output" | tr '[:space:]' '\n' | non_empty_lines)

  case "${#containers[@]}" in
    0) return 0 ;;
    1)
      printf '%s\n' "${containers[0]}"
      ;;
    *)
      selection=$(fzf_select "container" "${containers[@]}") || return $?
      printf '%s\n' "$selection"
      ;;
  esac
}

prompt_text() {
  local prompt="$1"
  local value

  read -r -p "$prompt: " value
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

prompt_replicas() {
  local value

  while true; do
    read -r -p "Replicas: " value
    [[ -n "$value" ]] || return 1
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    printf 'Replicas must be a non-negative integer.\n' >&2
  done
}

prompt_backable_text() {
  local prompt="$1"
  local value

  read -r -p "$prompt (empty or '.. back' to go back): " value
  if [[ -z "$value" || "$value" == "$BACK_CHOICE" ]]; then
    return "$BACK_STATUS"
  fi
  printf '%s\n' "$value"
}

prompt_port() {
  local value

  while true; do
    value=$(prompt_backable_text "Service port") || return $?
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    printf 'Service port must be a positive integer.\n' >&2
  done
}

choose_kt_namespace() {
  local output namespace selection
  local seen="|"
  local -a options=()

  for namespace in creams-rc creams-staging creams-dp-finance; do
    options+=("$namespace"$'\t'"快捷 namespace")
    seen+="$namespace|"
  done

  if output=$(kubectl_output get ns -o name); then
    while IFS= read -r namespace; do
      namespace="${namespace#namespace/}"
      [[ -n "$namespace" ]] || continue
      case "$seen" in
        *"|$namespace|"*) ;;
        *)
          options+=("$namespace"$'\t'"集群 namespace")
          seen+="$namespace|"
          ;;
      esac
    done < <(printf '%s\n' "$output" | non_empty_lines)
  fi

  selection=$(fzf_select_described "kt namespace" "${options[@]}" "${BACK_CHOICE}"$'\t返回上一级菜单') || return $?
  printf '%s\n' "$selection"
}

choose_kt_mode() {
  fzf_select_described "kt mode" \
    $'connect\t后台启动网络隧道，启动后打印日志' \
    $'connect foreground\t前台启动网络隧道，占用当前终端' \
    $'show connect log\t查看后台 connect 日志快照，按 q 返回' \
    $'stop connect\t停止后台 connect 进程' \
    $'exchange\t将 Service 全量流量转发到本地' \
    $'mesh\t按 versionMark/header 将标记流量转发到本地' \
    $'preview\t将本地服务暴露给集群访问' \
    "${BACK_CHOICE}"$'\t返回上一级菜单'
}

choose_service() {
  local namespace="$1"
  local output selection service
  local services=()

  output=$(kubectl_output get services -n "$namespace" -o name) || return 1
  while IFS= read -r service; do
    services+=("$service")
  done < <(printf '%s\n' "$output" | sed 's#^service/##' | non_empty_lines)

  if ((${#services[@]} == 0)); then
    printf 'No services found in namespace %s.\n' "$namespace" >&2
    return 1
  fi

  selection=$(fzf_select "service" "${services[@]}") || return $?
  printf '%s\n' "$selection"
}

choose_service_port() {
  local namespace="$1"
  local service="$2"
  local output port choice
  local -a options=()

  if output=$(kubectl_output get service "$service" -n "$namespace" -o 'jsonpath={.spec.ports[*].port}'); then
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      options+=("$port"$'\t'"Service 端口")
    done < <(printf '%s\n' "$output" | tr '[:space:]' '\n' | non_empty_lines)
  fi

  options+=("custom"$'\t手动输入端口')
  choice=$(fzf_select_described "service port" "${options[@]}" "${BACK_CHOICE}"$'\t返回上一级菜单') || return $?

  if [[ "$choice" == "custom" ]]; then
    prompt_port
  else
    printf '%s\n' "$choice"
  fi
}

run_kt_command() {
  local namespace="$1"
  local -a cmd
  shift

  if (( ! PRINT_ONLY )); then
    require_cmd "$KTCTL_BIN"
  fi

  cmd=("$KTCTL_BIN" -n "$namespace")
  if [[ -n "$KT_KUBECONFIG" ]]; then
    cmd+=("--kubeconfig" "$KT_KUBECONFIG")
  fi
  cmd+=("$@")

  run_command high "${cmd[@]}"
}

kt_connect_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

kt_connect_pid_file() {
  printf '%s/kk-kt-connect-%s.pid\n' "$KT_CONNECT_STATE_DIR" "$(kt_connect_id "$1")"
}

kt_connect_log_file() {
  printf '%s/kk-kt-connect-%s.log\n' "$KT_CONNECT_STATE_DIR" "$(kt_connect_id "$1")"
}

build_kt_connect_cmd() {
  local namespace="$1"
  local sudo_mode="${2:-foreground}"

  KT_CONNECT_CMD=()
  if [[ "$KT_CONNECT_SUDO" != "0" && "$sudo_mode" == "background" ]]; then
    KT_CONNECT_CMD=(sudo -n "$KTCTL_BIN" -n "$namespace")
  elif [[ "$KT_CONNECT_SUDO" != "0" ]]; then
    KT_CONNECT_CMD=(sudo "$KTCTL_BIN" -n "$namespace")
  else
    KT_CONNECT_CMD=("$KTCTL_BIN" -n "$namespace")
  fi

  if [[ -n "$KT_KUBECONFIG" ]]; then
    KT_CONNECT_CMD+=("--kubeconfig" "$KT_KUBECONFIG")
  fi
  KT_CONNECT_CMD+=(connect)
}

run_kt_connect_foreground() {
  local namespace="$1"
  local -a cmd

  if (( ! PRINT_ONLY )); then
    require_cmd "$KTCTL_BIN"
    [[ "$KT_CONNECT_SUDO" == "0" ]] || require_cmd sudo
  fi

  build_kt_connect_cmd "$namespace" foreground
  cmd=("${KT_CONNECT_CMD[@]}")
  run_command high "${cmd[@]}"
}

run_kt_connect_background() {
  local namespace="$1"
  local pid_file log_file pid
  local -a cmd

  pid_file=$(kt_connect_pid_file "$namespace")
  log_file=$(kt_connect_log_file "$namespace")
  build_kt_connect_cmd "$namespace" background
  cmd=("${KT_CONNECT_CMD[@]}")

  printf '\nBackground command:\n  '
  quote_cmd "${cmd[@]}"
  printf '\nLog:\n  %s\nPID file:\n  %s\n' "$log_file" "$pid_file"

  if (( PRINT_ONLY )); then
    return 0
  fi

  require_cmd "$KTCTL_BIN"
  require_cmd nohup
  if [[ "$KT_CONNECT_SUDO" != "0" ]]; then
    require_cmd sudo
    printf '\nRefreshing sudo credentials for background ktctl connect...\n'
    sudo -v || return $?
  fi

  if [[ -f "$pid_file" ]]; then
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      printf 'ktctl connect already running for namespace %s, pid %s.\n' "$namespace" "$pid"
      printf 'Log: %s\n' "$log_file"
      return 0
    fi
  fi

  # Keep background ktctl out of this terminal's Ctrl+C signal path.
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "${cmd[@]}" >"$log_file" 2>&1 < /dev/null &
  else
    (
      trap '' INT HUP
      exec nohup "${cmd[@]}" >"$log_file" 2>&1 < /dev/null
    ) &
  fi
  pid=$!
  printf '%s\n' "$pid" >"$pid_file"
  disown "$pid" 2>/dev/null || true

  printf 'Started ktctl connect in background, pid %s.\n' "$pid"
  printf 'Log: %s\n' "$log_file"
}

show_kt_connect_log() {
  local namespace="$1"
  local log_file

  log_file=$(kt_connect_log_file "$namespace")
  if [[ ! -f "$log_file" ]]; then
    printf 'No ktctl connect log found for namespace %s.\n' "$namespace" >&2
    printf 'Expected log: %s\n' "$log_file" >&2
    return 1
  fi

  if command -v less >/dev/null 2>&1; then
    less -R "$log_file"
  else
    tail -n 200 "$log_file"
  fi
}

print_kt_connect_log() {
  local namespace="$1"
  local log_file attempt

  log_file=$(kt_connect_log_file "$namespace")
  for attempt in {1..10}; do
    [[ -s "$log_file" ]] && break
    sleep 0.2
  done

  printf '\nktctl connect log snapshot:\n  %s\n\n' "$log_file"
  if [[ ! -f "$log_file" ]]; then
    printf 'No ktctl connect log found for namespace %s.\n' "$namespace" >&2
    return 1
  fi
  if [[ ! -s "$log_file" ]]; then
    printf '(log is empty; ktctl may still be starting)\n'
    return 0
  fi

  tail -n 200 "$log_file"
}

stop_kt_connect() {
  local namespace="$1"
  local pid_file log_file pid

  pid_file=$(kt_connect_pid_file "$namespace")
  log_file=$(kt_connect_log_file "$namespace")

  if [[ ! -f "$pid_file" ]]; then
    printf 'No ktctl connect pid file found for namespace %s.\n' "$namespace" >&2
    return 1
  fi

  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    printf 'Invalid pid file: %s\n' "$pid_file" >&2
    return 1
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'ktctl connect pid %s is not running. Removing stale pid file.\n' "$pid"
    rm -f "$pid_file"
    return 0
  fi

  printf '\nCommand:\n  kill -TERM -%s 2>/dev/null || kill -TERM %s\n' "$pid" "$pid"
  if (( PRINT_ONLY )); then
    return 0
  fi

  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid"
  rm -f "$pid_file"
  printf 'Stopped ktctl connect pid %s for namespace %s.\n' "$pid" "$namespace"
  printf 'Log kept at: %s\n' "$log_file"
}

switch_context() {
  local context

  context=$(choose_context) || return $?
  run_command normal "$KUBECTL_BIN" config use-context "$context"
}

switch_namespace() {
  local namespace

  namespace=$(choose_namespace) || return $?
  run_command normal "$KUBECTL_BIN" config set-context --current --namespace "$namespace"
}

view_resources() {
  local namespace resource
  local cmd
  local status

  while true; do
    namespace=$(choose_namespace) || return $?
    while true; do
      resource=$(choose_resource_type)
      status=$?
      (( status == BACK_STATUS )) && break
      (( status != 0 )) && return "$status"

      cmd=("$KUBECTL_BIN" get "$resource" -n "$namespace")
      if [[ "$resource" == "pods" ]]; then
        cmd+=("-o" "wide")
      elif [[ "$resource" == "events" ]]; then
        cmd+=("--sort-by=.lastTimestamp")
      fi

      run_command normal "${cmd[@]}"
      return $?
    done
  done
}

describe_pod() {
  local namespace pod
  local status

  while true; do
    namespace=$(choose_namespace) || return $?
    while true; do
      pod=$(choose_named_resource "$namespace" pods)
      status=$?
      (( status == BACK_STATUS )) && break
      (( status != 0 )) && return "$status"

      run_command normal "$KUBECTL_BIN" describe "$pod" -n "$namespace"
      return $?
    done
  done
}

logs_for_pod() {
  local previous="$1"
  local namespace pod container
  local cmd
  local status

  while true; do
    namespace=$(choose_namespace) || return $?
    while true; do
      pod=$(choose_named_resource "$namespace" pods)
      status=$?
      (( status == BACK_STATUS )) && break
      (( status != 0 )) && return "$status"

      while true; do
        container=$(choose_container "$namespace" "$pod")
        status=$?
        (( status == BACK_STATUS )) && break
        (( status != 0 )) && return "$status"

        cmd=("$KUBECTL_BIN" logs "$pod" -n "$namespace")
        [[ -n "${container:-}" ]] && cmd+=("-c" "$container")
        if [[ "$previous" == "previous" ]]; then
          cmd+=("--previous")
          run_command normal "${cmd[@]}"
        else
          cmd+=("--tail=200" "-f")
          run_log_page "${cmd[@]}"
        fi
        return $?
      done
    done
  done
}

exec_shell() {
  local namespace pod container shell
  local cmd
  local status

  while true; do
    namespace=$(choose_namespace) || return $?
    while true; do
      pod=$(choose_named_resource "$namespace" pods)
      status=$?
      (( status == BACK_STATUS )) && break
      (( status != 0 )) && return "$status"

      while true; do
        container=$(choose_container "$namespace" "$pod")
        status=$?
        (( status == BACK_STATUS )) && break
        (( status != 0 )) && return "$status"

        while true; do
          shell=$(fzf_select_described "shell" \
            $'sh\t通用 POSIX shell，容器里最常见' \
            $'bash\t功能更完整，镜像里不一定安装' \
            $'ash\tAlpine/busybox 常见 shell' \
            "${BACK_CHOICE}"$'\t返回上一级菜单')
          status=$?
          (( status == BACK_STATUS )) && break
          (( status != 0 )) && return "$status"

          cmd=("$KUBECTL_BIN" exec -it "$pod" -n "$namespace")
          [[ -n "${container:-}" ]] && cmd+=("-c" "$container")
          cmd+=("--" "$shell")

          run_command high "${cmd[@]}"
          return $?
        done
      done
    done
  done
}

get_yaml() {
  local namespace resource item
  local status

  while true; do
    namespace=$(choose_namespace) || return $?
    while true; do
      resource=$(choose_yaml_resource_type)
      status=$?
      (( status == BACK_STATUS )) && break
      (( status != 0 )) && return "$status"

      while true; do
        item=$(choose_named_resource "$namespace" "$resource")
        status=$?
        (( status == BACK_STATUS )) && break
        (( status != 0 )) && return "$status"

        run_command normal "$KUBECTL_BIN" get "$item" -n "$namespace" -o yaml
        return $?
      done
    done
  done
}

watch_pods() {
  local namespace

  namespace=$(choose_namespace) || return $?
  run_command normal "$KUBECTL_BIN" get pods -n "$namespace" -w
}

top_resources() {
  local choice namespace
  local status

  while true; do
    choice=$(fzf_select_described "top" \
      $'pods\t查看当前 namespace 的 Pod 资源使用' \
      $'nodes\t查看节点资源使用' \
      "${BACK_CHOICE}"$'\t返回上一级菜单') || return $?

    status=0
    if [[ "$choice" == "nodes" ]]; then
      run_command normal "$KUBECTL_BIN" top nodes
      status=$?
    else
      namespace=$(choose_namespace) || status=$?
      if (( status == 0 )); then
        run_command normal "$KUBECTL_BIN" top pods -n "$namespace"
        status=$?
      fi
    fi

    (( status == BACK_STATUS )) && continue
    return "$status"
  done
}

troubleshooting_menu() {
  local choice
  local status

  while true; do
    choice=$(fzf_select_described "troubleshoot" \
      $'describe pod\t查看 Pod 事件、调度和容器状态' \
      $'logs\t进入 Pod 实时日志页面' \
      $'previous logs\t查看上一次崩溃容器日志' \
      $'exec shell\t进入容器 shell' \
      $'get yaml\t导出资源 YAML 便于排查字段' \
      $'watch pods\t持续观察 Pod 状态变化' \
      $'top pods/nodes\t查看资源使用情况' \
      "${BACK_CHOICE}"$'\t返回上一级菜单') || return $?

    case "$choice" in
      "describe pod") describe_pod; status=$? ;;
      "logs") logs_for_pod current; status=$? ;;
      "previous logs") logs_for_pod previous; status=$? ;;
      "exec shell") exec_shell; status=$? ;;
      "get yaml") get_yaml; status=$? ;;
      "watch pods") watch_pods; status=$? ;;
      "top pods/nodes") top_resources; status=$? ;;
    esac

    (( status == BACK_STATUS )) && continue
    return "$status"
  done
}

explain_resource() {
  local topic

  topic=$(prompt_text "Resource or field, e.g. deployment.spec.template.spec.containers") || return 1
  run_command normal "$KUBECTL_BIN" explain "$topic"
}

learning_menu() {
  local choice
  local status

  while true; do
    choice=$(fzf_select_described "learn" \
      $'kubectl explain\t查询资源字段含义和 YAML 写法' \
      $'kubectl api-resources\t列出集群支持的资源类型和短名称' \
      $'kubectl version\t查看本机 kubectl 客户端版本' \
      "${BACK_CHOICE}"$'\t返回上一级菜单') || return $?

    case "$choice" in
      "kubectl explain") explain_resource; status=$? ;;
      "kubectl api-resources") run_command normal "$KUBECTL_BIN" api-resources; status=$? ;;
      "kubectl version") run_command normal "$KUBECTL_BIN" version --client; status=$? ;;
    esac

    (( status == BACK_STATUS )) && continue
    return "$status"
  done
}

apply_manifest() {
  local namespace path

  namespace=$(choose_namespace) || return $?
  path=$(prompt_text "Manifest file or directory") || return 1
  run_command high "$KUBECTL_BIN" apply -n "$namespace" -f "$path"
}

delete_resource() {
  local namespace resource item
  local status

  while true; do
    namespace=$(choose_namespace) || return $?
    while true; do
      resource=$(choose_resource_type)
      status=$?
      (( status == BACK_STATUS )) && break
      (( status != 0 )) && return "$status"

      while true; do
        item=$(choose_named_resource "$namespace" "$resource")
        status=$?
        (( status == BACK_STATUS )) && break
        (( status != 0 )) && return "$status"

        run_command high "$KUBECTL_BIN" delete "$item" -n "$namespace"
        return $?
      done
    done
  done
}

rollout_restart() {
  local namespace deploy
  local status

  while true; do
    namespace=$(choose_namespace) || return $?
    while true; do
      deploy=$(choose_named_resource "$namespace" deployments)
      status=$?
      (( status == BACK_STATUS )) && break
      (( status != 0 )) && return "$status"

      run_command high "$KUBECTL_BIN" rollout restart "$deploy" -n "$namespace"
      return $?
    done
  done
}

scale_deployment() {
  local namespace deploy replicas
  local status

  while true; do
    namespace=$(choose_namespace) || return $?
    while true; do
      deploy=$(choose_named_resource "$namespace" deployments)
      status=$?
      (( status == BACK_STATUS )) && break
      (( status != 0 )) && return "$status"

      replicas=$(prompt_replicas) || return 1
      run_command high "$KUBECTL_BIN" scale "$deploy" -n "$namespace" --replicas "$replicas"
      return $?
    done
  done
}

change_menu() {
  local choice
  local status

  while true; do
    choice=$(fzf_select_described "change" \
      $'apply manifest\t应用 YAML 文件或目录' \
      $'delete resource\t删除选中的资源' \
      $'rollout restart deployment\t重启 Deployment 触发滚动发布' \
      $'scale deployment\t调整 Deployment 副本数' \
      "${BACK_CHOICE}"$'\t返回上一级菜单') || return $?

    case "$choice" in
      "apply manifest") apply_manifest; status=$? ;;
      "delete resource") delete_resource; status=$? ;;
      "rollout restart deployment") rollout_restart; status=$? ;;
      "scale deployment") scale_deployment; status=$? ;;
    esac

    (( status == BACK_STATUS )) && continue
    return "$status"
  done
}

kt_connect_menu() {
  local namespace mode service port header
  local status

  while true; do
    namespace=$(choose_kt_namespace) || return $?
    while true; do
      mode=$(choose_kt_mode)
      status=$?
      (( status == BACK_STATUS )) && break
      (( status != 0 )) && return "$status"

      case "$mode" in
        "connect")
          run_kt_connect_background "$namespace"
          status=$?
          (( PRINT_ONLY )) && return "$status"
          if (( status == 0 )); then
            print_kt_connect_log "$namespace"
            status=$?
            if (( status == 0 )); then
              pause_if_interactive
              continue
            fi
          fi
          return "$status"
          ;;
        "connect foreground")
          run_kt_connect_foreground "$namespace"
          return $?
          ;;
        "show connect log")
          show_kt_connect_log "$namespace"
          status=$?
          (( PRINT_ONLY )) && return "$status"
          (( status == 0 )) && continue
          return "$status"
          ;;
        "stop connect")
          stop_kt_connect "$namespace"
          status=$?
          (( PRINT_ONLY )) && return "$status"
          (( status == 0 )) && continue
          return "$status"
          ;;
        "exchange"|"mesh"|"preview")
          while true; do
            service=$(choose_service "$namespace")
            status=$?
            (( status == BACK_STATUS )) && break
            (( status != 0 )) && return "$status"

            while true; do
              port=$(choose_service_port "$namespace" "$service")
              status=$?
              (( status == BACK_STATUS )) && break
              (( status != 0 )) && return "$status"

              if [[ "$mode" == "mesh" ]]; then
                header=$(prompt_backable_text "Version mark / header") || status=$?
                (( status == BACK_STATUS )) && continue
                (( status != 0 )) && return "$status"
                run_kt_command "$namespace" mesh "$service" --expose "$port" --versionMark "$header"
              elif [[ "$mode" == "exchange" ]]; then
                run_kt_command "$namespace" exchange "$service" --expose "$port"
              else
                run_kt_command "$namespace" preview "$service" --expose "$port"
              fi
              return $?
            done
          done
          ;;
      esac
    done
  done
}

main_menu() {
  fzf_select_described "kk" \
    $'switch context\t切换当前 kubectl context' \
    $'switch namespace\t切换当前 context 的默认 namespace' \
    $'view resources\t查看常用 Kubernetes 资源' \
    $'troubleshooting\t查看日志、describe、exec 和排障信息' \
    $'learn / discover\t查询 kubectl 字段、资源类型和版本' \
    $'kt connect\t本地联调、流量转发和预览' \
    $'change resources\t执行 apply、delete、restart、scale 等变更' \
    $'quit\t退出 kk'
}

main_loop() {
  local choice
  local status

  while true; do
    choice=$(main_menu) || exit 0
    status=0
    SKIP_PAUSE=0

    case "$choice" in
      "switch context") switch_context; status=$? ;;
      "switch namespace") switch_namespace; status=$? ;;
      "view resources") view_resources; status=$? ;;
      "troubleshooting") troubleshooting_menu; status=$? ;;
      "learn / discover") learning_menu; status=$? ;;
      "kt connect") kt_connect_menu; status=$? ;;
      "change resources") change_menu; status=$? ;;
      "quit") exit 0 ;;
    esac

    (( PRINT_ONLY && status != BACK_STATUS )) && exit 0
    if (( status != 0 && status != BACK_STATUS )); then
      printf '\nAction did not complete. Check the message above, or try another namespace/pod.\n' >&2
    fi
    if (( status != BACK_STATUS && (status != 0 || ! SKIP_PAUSE) )); then
      pause_if_interactive
    fi
  done
}

main() {
  local arg

  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        usage
        exit 0
        ;;
      --print)
        PRINT_ONLY=1
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done

  require_cmd "$KUBECTL_BIN"
  require_cmd "$FZF_BIN"
  require_interactive_tty
  main_loop
}

main "$@"
