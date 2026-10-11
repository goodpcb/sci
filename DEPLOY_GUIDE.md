# GitHub 部署与自定义域名极简调用指南

通过本指南，你可以将加固脚本发布到个人 GitHub 仓库，并通过 Cloudflare 实现免长链接的极简一键调用。

---

## 1. 推送到 GitHub 仓库

1. 在 GitHub 上新建一个 **Public** 仓库（例如 `singbox-suite`）。
2. 在解压后的目录中执行以下命令提交并推送：

```bash
git init
git add install.sh uninstall.sh README.md DEPLOY_GUIDE.md
git commit -m "feat: secure singbox caddy multi-protocol installer"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<你的仓库名>.git
git push -u origin main
```

推送后，即可通过原始链接在任何新 VPS 上运行：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/<你的仓库名>/main/install.sh)
```

---

## 2. 进阶：使用 Cloudflare Workers 绑定自己的短域名

无需记住冗长的 GitHub Raw 链接，在 Cloudflare 创建一个免费 Worker 并绑定你的二级域名（例如 `sh.yourdomain.com`）：

1. 进入 Cloudflare 控制台 -> **Workers & Pages** -> **Create application** -> **Create Worker**。
2. 编辑代码，粘贴以下内容：
```javascript
export default {
  async fetch(request) {
    const GITHUB_RAW_URL = "https://raw.githubusercontent.com/<你的用户名>/<你的仓库名>/main/install.sh";
    const response = await fetch(GITHUB_RAW_URL);
    return new Response(response.body, {
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "cache-control": "no-cache"
      }
    });
  }
};
```
3. 在该 Worker 的 **Settings** -> **Domains & Routes** 中绑定你的自定义域名（例如 `sh.yourdomain.com`）。
4. 今后在任意新机器上只需执行极简命令：
```bash
bash <(curl -fsSL https://sh.yourdomain.com)
```
