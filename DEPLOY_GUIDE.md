# GitHub 仓库与 Cloudflare Workers 部署说明

本指南说明如何配合 `sci.zdxq.xyz` 与个人 GitHub 仓库实现一键脚本托管。

---

## 1. 提交至 GitHub 仓库

在本地或 VPS 的仓库目录中提交更新：

```bash
git add install.sh uninstall.sh README.md DEPLOY_GUIDE.md
git commit -m "fix: acme 120s timeout, unified fallback insecure params, safe execution"
git push origin main
```

---

## 2. Cloudflare Workers 路由分发代码

在绑定的 `sci.zdxq.xyz` Worker 中，使用以下完整代码支持安装与卸载：

```javascript
export default {
  async fetch(request) {
    const url = new URL(request.url);
    // 替换为你的真实 GitHub 用户名和仓库名称
    const REPO_BASE = "https://raw.githubusercontent.com/<你的用户名>/<你的仓库名>/main";
    
    let targetFile = "install.sh";
    if (url.pathname === "/uninstall" || url.pathname === "/un") {
      targetFile = "uninstall.sh";
    }

    const githubUrl = `${REPO_BASE}/${targetFile}`;
    const response = await fetch(githubUrl);

    if (!response.ok) {
      return new Response(`Error fetching ${targetFile} from GitHub: ${response.statusText}`, {
        status: response.status
      });
    }

    return new Response(response.body, {
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "cache-control": "no-cache"
      }
    });
  }
};
```
