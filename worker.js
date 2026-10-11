// Repository: goodpcb/sci, branch: main. Optional replacement for the existing Worker.
export default {
  async fetch(request) {
    const headers = {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    };
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", {
        status: 405, headers: { ...headers, allow: "GET, HEAD" }
      });
    }
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const routes = {
      "/": "install.sh",
      "/install": "install.sh",
      "/install.sh": "install.sh",
      "/uninstall": "uninstall.sh",
      "/un": "uninstall.sh",
      "/uninstall.sh": "uninstall.sh"
    };
    // Prevent unexpected paths (e.g. favicon.ico or a typo) from serving an installer.
    const targetFile = Object.hasOwn(routes, path) ? routes[path] : undefined;
    if (!targetFile) {
      return new Response("Not found", { status: 404, headers });
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 30000);
    try {
      const githubUrl = `https://raw.githubusercontent.com/goodpcb/sci/main/${targetFile}`;
      const upstream = await fetch(githubUrl, {
        method: request.method,
        signal: controller.signal,
        headers: { "cache-control": "no-cache" }
      });
      if (!upstream.ok) {
        return new Response(`Error fetching ${targetFile}: HTTP ${upstream.status}`, {
          status: upstream.status, headers
        });
      }
      return new Response(request.method === "HEAD" ? null : upstream.body, {
        status: 200, headers
      });
    } catch (error) {
      return new Response("GitHub upstream unavailable; please retry later", {
        status: 502, headers
      });
    } finally {
      clearTimeout(timer);
    }
  }
};
