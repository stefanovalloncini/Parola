import type { APIRoute } from "astro";

export const GET: APIRoute = ({ site }) => {
  if (process.env.NOINDEX === "1") {
    return new Response("User-agent: *\nDisallow: /\n", {
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }
  const lines = ["User-agent: *", "Disallow: /og-card", "Disallow: /it/og-card"];
  if (site) lines.push(`Sitemap: ${new URL("sitemap-index.xml", site).href}`);
  return new Response(`${lines.join("\n")}\n`, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
};
