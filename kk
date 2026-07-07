#!/usr/bin/env bash
set -uo pipefail

SCRIPT_NAME="${0##*/}"
KUBECTL_BIN="${KUBECTL:-kubectl}"
FZF_BIN="${FZF:-fzf}"
PRINT_ONLY=0
SKIP_PAUSE=0

usage() {
  cat <<'EOF'
kk - interactive kubectl helper

Usage:
  kk
  kk --print
  kk --help

Options:
  --print   Build a kubectl command interactively and print it without running it.
  --help    Show this help text.

Environment:
  KUBECTL   kubectl executable to use. Defaults to kubectl.
  FZF       fzf executable to use. Defaults to fzf.

Examples:
  kk
  kk --print
  KUBECTL=/usr/local/bin/kubectl kk
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
  shift

  if (($# == 0)); then
    return 1
  fi

  printf '%s\n' "$@" | "$FZF_BIN" \
    --height="${KK_FZF_HEIGHT:-70%}" \
    --layout=reverse \
    --border \
    --cycle \
    --prompt="$prompt> "
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
  local current output selection
  local namespaces=()

  current=$("$KUBECTL_BIN" config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)
  [[ -n "$current" ]] || current="default"

  if output=$(kubectl_output get ns -o name); then
    mapfile -t namespaces < <(printf '%s\n' "$output" | sed 's#^namespace/##' | non_empty_lines)
  fi

  if ((${#namespaces[@]} == 0)); then
    namespaces=("$current")
  fi

  selection=$(fzf_select "namespace" "${namespaces[@]}") || return 1
  printf '%s\n' "$selection"
}

choose_context() {
  local output selection
  local contexts=()

  output=$(kubectl_output config get-contexts -o name) || return 1
  mapfile -t contexts < <(printf '%s\n' "$output" | non_empty_lines)

  if ((${#contexts[@]} == 0)); then
    printf 'No kubectl contexts found.\n' >&2
    return 1
  fi

  selection=$(fzf_select "context" "${contexts[@]}") || return 1
  printf '%s\n' "$selection"
}

choose_resource_type() {
  fzf_select "resource" \
    "pods" \
    "deployments" \
    "services" \
    "ingress" \
    "configmaps" \
    "secrets" \
    "events"
}

choose_yaml_resource_type() {
  fzf_select "resource" \
    "pods" \
    "deployments" \
    "services" \
    "ingress" \
    "configmaps" \
    "secrets"
}

choose_named_resource() {
  local namespace="$1"
  local resource="$2"
  local output selection
  local items=()

  output=$(kubectl_output get "$resource" -n "$namespace" -o name) || return 1
  mapfile -t items < <(printf '%s\n' "$output" | non_empty_lines)

  if ((${#items[@]} == 0)); then
    printf 'No %s found in namespace %s.\n' "$resource" "$namespace" >&2
    return 1
  fi

  selection=$(fzf_select "$resource" "${items[@]}") || return 1
  printf '%s\n' "$selection"
}

choose_container() {
  local namespace="$1"
  local pod="$2"
  local pod_name output selection
  local containers=()

  pod_name="${pod#pod/}"
  output=$(kubectl_output get pod "$pod_name" -n "$namespace" \
    -o 'jsonpath={.spec.initContainers[*].name} {.spec.containers[*].name}') || return 1
  mapfile -t containers < <(printf '%s\n' "$output" | tr '[:space:]' '\n' | non_empty_lines)

  case "${#containers[@]}" in
    0) return 0 ;;
    1)
      printf '%s\n' "${containers[0]}"
      ;;
    *)
      selection=$(fzf_select "container" "${containers[@]}") || return 1
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

switch_context() {
  local context

  context=$(choose_context) || return 1
  run_command normal "$KUBECTL_BIN" config use-context "$context"
}

switch_namespace() {
  local namespace

  namespace=$(choose_namespace) || return 1
  run_command normal "$KUBECTL_BIN" config set-context --current --namespace "$namespace"
}

view_resources() {
  local namespace resource
  local cmd

  namespace=$(choose_namespace) || return 1
  resource=$(choose_resource_type) || return 1

  cmd=("$KUBECTL_BIN" get "$resource" -n "$namespace")
  if [[ "$resource" == "pods" ]]; then
    cmd+=("-o" "wide")
  elif [[ "$resource" == "events" ]]; then
    cmd+=("--sort-by=.lastTimestamp")
  fi

  run_command normal "${cmd[@]}"
}

describe_pod() {
  local namespace pod

  namespace=$(choose_namespace) || return 1
  pod=$(choose_named_resource "$namespace" pods) || return 1
  run_command normal "$KUBECTL_BIN" describe "$pod" -n "$namespace"
}

logs_for_pod() {
  local previous="$1"
  local namespace pod container
  local cmd

  namespace=$(choose_namespace) || return 1
  pod=$(choose_named_resource "$namespace" pods) || return 1
  container=$(choose_container "$namespace" "$pod") || return 1

  cmd=("$KUBECTL_BIN" logs "$pod" -n "$namespace")
  [[ -n "${container:-}" ]] && cmd+=("-c" "$container")
  if [[ "$previous" == "previous" ]]; then
    cmd+=("--previous")
    run_command normal "${cmd[@]}"
  else
    cmd+=("--tail=200" "-f")
    run_log_page "${cmd[@]}"
  fi
}

exec_shell() {
  local namespace pod container shell
  local cmd

  namespace=$(choose_namespace) || return 1
  pod=$(choose_named_resource "$namespace" pods) || return 1
  container=$(choose_container "$namespace" "$pod") || return 1
  shell=$(fzf_select "shell" "sh" "bash" "ash") || return 1

  cmd=("$KUBECTL_BIN" exec -it "$pod" -n "$namespace")
  [[ -n "${container:-}" ]] && cmd+=("-c" "$container")
  cmd+=("--" "$shell")

  run_command high "${cmd[@]}"
}

get_yaml() {
  local namespace resource item

  namespace=$(choose_namespace) || return 1
  resource=$(choose_yaml_resource_type) || return 1
  item=$(choose_named_resource "$namespace" "$resource") || return 1
  run_command normal "$KUBECTL_BIN" get "$item" -n "$namespace" -o yaml
}

watch_pods() {
  local namespace

  namespace=$(choose_namespace) || return 1
  run_command normal "$KUBECTL_BIN" get pods -n "$namespace" -w
}

top_resources() {
  local choice namespace

  choice=$(fzf_select "top" "pods" "nodes") || return 1
  if [[ "$choice" == "nodes" ]]; then
    run_command normal "$KUBECTL_BIN" top nodes
  else
    namespace=$(choose_namespace) || return 1
    run_command normal "$KUBECTL_BIN" top pods -n "$namespace"
  fi
}

troubleshooting_menu() {
  local choice

  choice=$(fzf_select "troubleshoot" \
    "describe pod" \
    "logs" \
    "previous logs" \
    "exec shell" \
    "get yaml" \
    "watch pods" \
    "top pods/nodes") || return 1

  case "$choice" in
    "describe pod") describe_pod ;;
    "logs") logs_for_pod current ;;
    "previous logs") logs_for_pod previous ;;
    "exec shell") exec_shell ;;
    "get yaml") get_yaml ;;
    "watch pods") watch_pods ;;
    "top pods/nodes") top_resources ;;
  esac
}

explain_resource() {
  local topic

  topic=$(prompt_text "Resource or field, e.g. deployment.spec.template.spec.containers") || return 1
  run_command normal "$KUBECTL_BIN" explain "$topic"
}

learning_menu() {
  local choice

  choice=$(fzf_select "learn" \
    "kubectl explain" \
    "kubectl api-resources" \
    "kubectl version") || return 1

  case "$choice" in
    "kubectl explain") explain_resource ;;
    "kubectl api-resources") run_command normal "$KUBECTL_BIN" api-resources ;;
    "kubectl version") run_command normal "$KUBECTL_BIN" version --client ;;
  esac
}

apply_manifest() {
  local namespace path

  namespace=$(choose_namespace) || return 1
  path=$(prompt_text "Manifest file or directory") || return 1
  run_command high "$KUBECTL_BIN" apply -n "$namespace" -f "$path"
}

delete_resource() {
  local namespace resource item

  namespace=$(choose_namespace) || return 1
  resource=$(choose_resource_type) || return 1
  item=$(choose_named_resource "$namespace" "$resource") || return 1
  run_command high "$KUBECTL_BIN" delete "$item" -n "$namespace"
}

rollout_restart() {
  local namespace deploy

  namespace=$(choose_namespace) || return 1
  deploy=$(choose_named_resource "$namespace" deployments) || return 1
  run_command high "$KUBECTL_BIN" rollout restart "$deploy" -n "$namespace"
}

scale_deployment() {
  local namespace deploy replicas

  namespace=$(choose_namespace) || return 1
  deploy=$(choose_named_resource "$namespace" deployments) || return 1
  replicas=$(prompt_replicas) || return 1
  run_command high "$KUBECTL_BIN" scale "$deploy" -n "$namespace" --replicas "$replicas"
}

change_menu() {
  local choice

  choice=$(fzf_select "change" \
    "apply manifest" \
    "delete resource" \
    "rollout restart deployment" \
    "scale deployment") || return 1

  case "$choice" in
    "apply manifest") apply_manifest ;;
    "delete resource") delete_resource ;;
    "rollout restart deployment") rollout_restart ;;
    "scale deployment") scale_deployment ;;
  esac
}

main_menu() {
  fzf_select "kk" \
    "switch context" \
    "switch namespace" \
    "view resources" \
    "troubleshooting" \
    "learn / discover" \
    "change resources" \
    "quit"
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
      "change resources") change_menu; status=$? ;;
      "quit") exit 0 ;;
    esac

    (( PRINT_ONLY )) && exit 0
    if (( status != 0 )); then
      printf '\nAction did not complete. Check the message above, or try another namespace/pod.\n' >&2
    fi
    if (( status != 0 || ! SKIP_PAUSE )); then
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
