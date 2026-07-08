# kt-tools

个人 Kubernetes 命令行辅助工具。

## kk

`kk` 是一个交互式 `kubectl` 辅助脚本，适合不想记大量 Kubernetes
命令的人使用。它通过 `fzf` 菜单选择操作、namespace、资源、Pod 和
container，然后执行对应的 `kubectl` 命令。

## 依赖

- `bash`
- `kubectl`
- `ktctl` 可选；只有使用 `kt connect` 菜单时需要
- `fzf`
- `less` 可选，但推荐安装，用于日志页面

macOS 可以用 Homebrew 安装常用依赖：

```bash
brew install kubectl fzf
```

如果需要使用 `kt connect` 菜单，还需要额外安装 `ktctl`。

## 安装

可以在仓库目录里直接运行：

```bash
./kk
```

也可以把当前目录加入 `PATH`：

```bash
export PATH="$(pwd):$PATH"
```

之后直接运行：

```bash
kk
```

## 用法

```bash
kk          # 打开交互菜单
kk --print  # 生成并打印命令，不执行
kk --help   # 查看帮助
```

可以通过环境变量指定可执行文件：

```bash
KUBECTL=/usr/local/bin/kubectl kk
KTCTL=/usr/local/bin/ktctl kk
KT_KUBECONFIG="$HOME/.kube/config" kk
KT_CONNECT_SUDO=0 kk
FZF=/usr/bin/fzf kk
```

## 菜单

除主菜单外，子菜单和资源选择菜单都提供：

- `.. back`：返回上一级菜单

在多级选择中，`.. back` 只返回当前上一级。例如从 Pod 选择返回到
namespace 选择，从 container 选择返回到 Pod 选择。

主菜单：

- `switch context`：切换当前 kubectl context
- `switch namespace`：切换当前 context 的默认 namespace
- `view resources`：查看常用 Kubernetes 资源
- `troubleshooting`：查看日志、describe、exec 和排障信息
- `learn / discover`：查询 kubectl 字段、资源类型和版本
- `kt connect`：本地联调、流量转发和预览
- `change resources`：执行 apply、delete、restart、scale 等变更

资源查看支持 pods、deployments、services、ingress、configmaps、secrets
和 events。

排障菜单：

- `describe pod`：查看 Pod 事件、调度和容器状态
- `logs`：进入 Pod 实时日志页面
- `previous logs`：查看上一次崩溃容器日志
- `exec shell`：进入容器 shell
- `get yaml`：导出资源 YAML 便于排查字段
- `watch pods`：持续观察 Pod 状态变化
- `top pods/nodes`：查看资源使用情况

学习和反查菜单：

- `kubectl explain`：查询资源字段含义和 YAML 写法
- `kubectl api-resources`：列出集群支持的资源类型和短名称
- `kubectl version --client`：查看本机 kubectl 客户端版本

变更操作菜单：

- `apply manifest`：应用 YAML 文件或目录
- `delete resource`：删除选中的资源
- `rollout restart deployment`：重启 Deployment 触发滚动发布
- `scale deployment`：调整 Deployment 副本数

kt connect 菜单：

- `connect`：后台启动本地到集群的网络隧道，启动后默认打印日志
- `connect foreground`：前台启动网络隧道，占用当前终端
- `show connect log`：查看后台 connect 日志快照，按 `q` 返回
- `stop connect`：停止后台 connect 进程
- `exchange`：将 Service 全量流量转发到本地
- `mesh`：按 versionMark/header 将标记流量转发到本地
- `preview`：将本地服务暴露给集群访问

`kt connect` 的 namespace 会优先显示常用快捷项：

- `creams-rc`
- `creams-staging`
- `creams-dp-finance`

执行 `ktctl` 时会显式追加 `--kubeconfig`。默认使用 `KUBECONFIG`；
如果未设置，则使用 `$HOME/.kube/config`，避免 `sudo ktctl connect`
时丢失普通用户的 kubeconfig。

`ktctl connect` 通常需要配置本机网络路由，默认会以 `sudo ktctl ... connect`
后台执行，并把 PID 和日志放在 `/tmp`。启动后会默认打印最近 200 行 connect
日志快照；按 Enter 后，可以继续在同一个 `kk` 菜单里选择 `exchange` 或 `mesh`。
后台进程会尽量用独立会话启动，避免你在日志页按 `Ctrl+C` 时误停掉 connect。

如果你明确不需要 sudo，可以设置：

```bash
KT_CONNECT_SUDO=0 kk
```

后台 connect 的状态目录默认为 `/tmp`，可通过 `KT_CONNECT_STATE_DIR` 覆盖。
`show connect log` 不会跟随日志，按 `q` 返回；即使误按 `Ctrl+C`，也不应影响
后台 connect 进程。

## 日志

`troubleshooting -> logs` 会打开持续跟随的日志页面：

```bash
kubectl logs pod/<name> -n <namespace> -c <container> --tail=200 -f | less -R +F
```

日志页面里：

- `Ctrl+C` 停止继续跟随新日志
- `q` 退出日志页面

`troubleshooting -> previous logs` 只执行一次 `kubectl logs --previous`，
不会持续跟随日志。

## 安全行为

`kk` 会在执行前打印生成的命令，但不会再次询问确认。选择操作后，命令会
直接执行，除非使用 `--print`。

`kt connect` 里的 `exchange`、`mesh`、`preview` 会创建 ktctl 资源或影响
Service 流量。首次使用建议先通过 `kk --print` 检查生成的命令。

如果只想检查生成的命令、不希望访问或修改集群，使用：

```bash
kk --print
```
