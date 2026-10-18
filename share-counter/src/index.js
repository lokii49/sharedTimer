// Anonymous share counter for Timer.
//
// POST /api/timer/share adds 1 to today's (UTC) count. Nothing about the request is
// stored: no IP, no user agent, no timer data, no identifiers of any kind. The body is
// ignored. Read the totals with `npm run counts`.

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname !== "/api/timer/share") {
      return new Response("Not found", { status: 404 });
    }
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
    }
    const day = new Date().toISOString().slice(0, 10);
    await env.DB.prepare(
      "INSERT INTO share_counts (day, n) VALUES (?1, 1) ON CONFLICT(day) DO UPDATE SET n = n + 1"
    ).bind(day).run();
    return new Response(null, { status: 204 });
  },
};
