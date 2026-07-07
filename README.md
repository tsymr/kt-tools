# kt-tools

个人 Kubernetes 命令行辅助工具。

## kk

`kk` 是一个交互式 `kubectl` 辅助脚本，适合不想记大量 Kubernetes
命令的人使用。它通过 `fzf` 菜单选择操作、namespace、资源、Pod 和
container，然后执行对应的 `kubectl` 命令。

## 依赖

- `bash`
- `kubectl`
- `fzf`
- `less` 可选，但推荐安装，用于日志页面

## 安装

可以在仓库目录里直接运行：

```bash
./kk
```

也可以把当前目录加入 `PATH`：

```bash
export PATH="/home/ts/projects/tools/kt-tools:$PATH"
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

如果只想检查生成的命令、不希望访问或修改集群，使用：

```bash
kk --print
```
