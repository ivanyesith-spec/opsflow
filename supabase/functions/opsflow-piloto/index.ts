// OpsFlow pilot web preview: serves a pinned, public test-only snapshot.
// No secrets, no database writes, no service-role operations.
const PROJECT_REF = "yxgilbgwuxmlbdrbfisi";
const PINNED_COMMIT = "8251ba2a3f93488135c25e9a0a651549067d84a8";
const SLUG = "opsflow-piloto";
const SOURCE = "https://raw.githubusercontent.com/ivanyesith-spec/opsflow/" + PINNED_COMMIT + "/";
const TYPES: Record<string,string> = {
  "index.html":"text/html; charset=utf-8",
  "icon-192.png":"image/png",
  "icon-512.png":"image/png",
};
function response(text: string, status: number): Response {
  return new Response(text, { status, headers: { "Content-Type":"text/plain; charset=utf-8", "Cache-Control":"no-store" } });
}
Deno.serve(async (request: Request) => {
  if (request.method !== "GET" && request.method !== "HEAD") return response("Method not allowed.",405);
  const envUrl = Deno.env.get("SUPABASE_URL") || "";
  if (envUrl !== "https://" + PROJECT_REF + ".supabase.co")
    return response("Preview disabled: wrong Supabase environment.",503);
  const parsed = new URL(request.url);
  // Supabase Edge Runtime puede entregar la ruta completa o solo /<slug>.
  const candidates = ["/functions/v1/" + SLUG, "/" + SLUG];
  const marker = candidates.find(x => parsed.pathname === x || parsed.pathname.startsWith(x + "/"));
  if (!marker) return response("Not found.",404);
  const suffix = parsed.pathname.slice(marker.length).replace(/^\/+/, "");
  const file = suffix || "index.html";
  if (!Object.hasOwn(TYPES,file)) return response("Not found.",404);
  try {
    const origin = await fetch(SOURCE + file, { redirect:"follow", cache:"no-store" });
    if (!origin.ok) return response("Preview source unavailable.",503);
    let body: string | ArrayBuffer;
    if (file === "index.html") {
      let html = await origin.text();
      if (!html.includes("const PILOT_PROJECT_REF = '" + PROJECT_REF + "'")
          || !html.includes("const PILOT_MODE = true;")
          || html.includes("zxsiantglodsqqvigndk")
          || !html.includes("PILOTO DE PRUEBAS")) {
        return response("Preview source failed environment verification.",503);
      }
      html = html.replace("<head>",'<head><base href="/functions/v1/'+SLUG+'/">');
      body = html;
    } else body = await origin.arrayBuffer();
    const headers = new Headers({
      "Content-Type": TYPES[file], "Cache-Control":"no-store",
      "X-Content-Type-Options":"nosniff",
      "Referrer-Policy":"no-referrer",
      "X-Robots-Tag":"noindex, nofollow, noarchive",
      "X-Frame-Options":"DENY",
      "Content-Security-Policy":
        "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; " +
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " +
        "font-src https://fonts.gstatic.com; img-src 'self' data: blob: https:; " +
        "connect-src 'self' https://" + PROJECT_REF + ".supabase.co wss://" + PROJECT_REF + ".supabase.co; " +
        "media-src blob:; worker-src 'none'; frame-ancestors 'none'",
    });
    return new Response(request.method==="HEAD" ? null : body,{status:200,headers});
  } catch (_) {
    return response("Preview source temporarily unreachable.",503);
  }
});
