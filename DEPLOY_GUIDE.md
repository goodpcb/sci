# GitHub 仓库与 Cloudflare Worker 部署说明

本仓库通过 `sci.zdxq.xyz` 从 GitHub raw 分发脚本。仓库为 `goodpcb/sci`，分支为 `main`。

## 1. 使用更新包

更新包包含以下五个文件，解压后放到仓库根目录：

```text
install.sh
uninstall.sh
README.md
DEPLOY_GUIDE.md
worker.js
```

包中不包含 `.git`、服务器配置、节点凭证或私钥。覆盖的是项目源码与说明文档，不需要替换本地仓库的 Git 元数据。

已有本地仓库时先确认工作区状态，并处理自己尚未提交的改动，再更新 `main`：

```bash
git status --short
git switch main
git pull --ff-only origin main
```

没有本地仓库时：

```bash
git clone https://github.com/goodpcb/sci.git
cd sci
```

随后将更新包中的五个文件复制到当前仓库根目录，或在当前目录解压更新包。不要覆盖尚未保留的个人改动。

## 2. 检查、提交和推送

在仓库根目录执行：

```bash
bash -n install.sh
bash -n uninstall.sh
git diff --check
git diff --stat
git status --short
```

查看 `git diff`，确认更改符合预期后提交并推送：

```bash
git add install.sh uninstall.sh README.md DEPLOY_GUIDE.md worker.js
git commit -m "feat: add v5.2 deployment hardening and guarded uninstall"
git push origin main
```

这一步由仓库所有者执行；打包文件本身不会自动推送，也不会自动修改 Cloudflare Worker。

## 3. Worker 配置

你现有的 Worker 已指向以下 GitHub raw 根地址，可继续使用：

```text
https://raw.githubusercontent.com/goodpcb/sci/main
```

它已有的分发关系：

| Worker URL | 上游文件 |
| --- | --- |
| `https://sci.zdxq.xyz/` | `install.sh` |
| `https://sci.zdxq.xyz/uninstall` | `uninstall.sh` |
| `https://sci.zdxq.xyz/un` | `uninstall.sh` |

仅更新仓库中的两个脚本即可使用这些路由，不必为了新版安装器改动现有 Worker。

如希望使用改进版，将本仓库 [worker.js](worker.js) 的完整内容复制到 Cloudflare Worker 编辑器后部署，保留原有 `sci.zdxq.xyz` 域名绑定。把文件提交到 GitHub **不会自动部署 Worker**。

改进版增加：

- 明确允许 `/`、`/install`、`/install.sh`、`/uninstall`、`/un`、`/uninstall.sh`，其余路径返回 404。
- 仅接受 GET/HEAD；其他方法返回 405。
- GitHub HTTP 错误保留对应状态码；请求异常返回 502。
- 对上游请求设置超时，并对返回脚本设置 `Cache-Control: no-store`。

GitHub raw 仍可能存在上游缓存，不能把响应缓存头理解成所有更新都会立即生效。推送后先核对 Worker 返回的文件内容再执行。

## 4. 推送后核对下载

在测试 VPS 上先下载，不立即执行：

```bash
curl --proto '=https' --tlsv1.2 -fSL --retry 2 --max-time 180 https://sci.zdxq.xyz/ -o install.sh
curl --proto '=https' --tlsv1.2 -fSL --retry 2 --max-time 180 https://sci.zdxq.xyz/uninstall -o uninstall.sh
bash -n install.sh
bash -n uninstall.sh
bash install.sh --help
bash uninstall.sh --help
```

如果显示 404，检查 `main` 分支根目录是否有文件名完全一致的 `install.sh` 与 `uninstall.sh`。仓库必须能被 Worker 访问；当前 Worker 未配置访问私有仓库的认证。

若要确认是否为刚推送的版本，可分别在本地仓库和 VPS 执行 `sha256sum install.sh uninstall.sh`，比较结果。哈希不一致时先排查下载内容或缓存，不要执行未知版本。

## 5. 安装与卸载命令

安装 / 从原 v5.1 迁移：

```bash
curl --proto '=https' --tlsv1.2 -fSL --retry 2 --connect-timeout 15 --max-time 180 https://sci.zdxq.xyz/ -o install.sh && sudo bash install.sh install
```

卸载：

```bash
curl --proto '=https' --tlsv1.2 -fSL --retry 2 --connect-timeout 15 --max-time 180 https://sci.zdxq.xyz/uninstall -o uninstall.sh && sudo bash uninstall.sh
```

默认卸载需输入 `UNINSTALL`；只有明确希望跳过交互时才附加 `--yes`。卸载适用于可识别的 v5.2 部署，尚未迁移的 v5.1 不会被直接删除。

在 VPS 安装前完成 Python 3、DNS、端口放行与已有服务检查，详见 [README.md](README.md)。请先使用能恢复的测试 VPS 验证；当前版本尚未完成所有目标系统的实际安装或代理端到端连接测试。

## 6. 故障排查与恢复

安装后：

```bash
sudo sb-v52 health
sudo journalctl -u sing-box -u caddy -u sb-v52-cert-sync.service -n 80
```

`health` 通过后，仍需客户端分别测试 Reality、HY2 及启用的可选协议。常见检查项包括域名是否直指 VPS、错误的 AAAA 记录、TCP 80/443、HY2 UDP 端口及 Reality 握手目标是否可访问。

备份位于 `/var/backups/sb-v52/`，含节点凭证和私钥，不要上传到 GitHub。未卸载时可以用：

```bash
sudo sb-v52 rollback --backup /var/backups/sb-v52/实际备份目录
```

卸载后管理命令已经删除，使用下载的安装脚本恢复：

```bash
sudo bash install.sh rollback --backup /var/backups/sb-v52/实际备份目录
```

回滚恢复脚本管理的程序、文件与原服务状态，不卸载 APT 安装的软件包，也不删除新建账户。

## 7. 交互终端修复

已修复旧 v5.2 在首次提示前出现的 `File or stream is not seekable` 错误。原因是 Python 以 `r+` 模式打开不可寻址的 `/dev/tty`；新版分别打开读、写流。安装和卸载脚本都已修复，安装与卸载提示的普通输入、回车默认值及 UTF-8 输入已通过伪终端测试。该错误发生在创建备份、安装依赖及修改服务之前。请推送新版文件后重新下载运行。
