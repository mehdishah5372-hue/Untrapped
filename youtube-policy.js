(() => {
  "use strict";

  const RULES_URL = chrome.runtime.getURL("youtube-allowlist.json");
  let allowedVideoIds = new Set();
  let rulesLoaded = false;
  const YOUTUBE_HOSTS = new Set(["youtube.com", "www.youtube.com", "m.youtube.com"]);

  function isYouTubeHost(host) {
    const h = String(host || "").toLowerCase().replace(/\.$/, "");
    return YOUTUBE_HOSTS.has(h) || h.endsWith(".youtube.com");
  }

  function getVideoId(url) {
    try {
      const u = new URL(url);
      if (!isYouTubeHost(u.hostname) || u.pathname !== "/watch") return null;
      const ids = u.searchParams.getAll("v");
      if (!rulesLoaded || ids.length !== 1 || !allowedVideoIds.has(ids[0])) return null;
      return ids[0];
    } catch (_) {
      return null;
    }
  }

  function isAllowedYouTubeUrl(url) {
    try {
      const u = new URL(url);
      return u.protocol === "https:" && isYouTubeHost(u.hostname) && getVideoId(u.href) !== null;
    } catch (_) {
      return false;
    }
  }

  function canonicalAllowedUrl(url) {
    return isAllowedYouTubeUrl(url)
      ? "https://www.youtube.com/watch?v=" + ALLOWED_VIDEO_ID
      : null;
  }

  async function loadRules() { const r = await fetch(RULES_URL, {cache: "no-store"}); if (!r.ok) throw new Error("youtube-allowlist.json unavailable"); const rules = await r.json(); if (rules.version !== 1) throw new Error("Unsupported allowlist version"); const entries = Array.isArray(rules.allowedYouTubeUrls) ? rules.allowedYouTubeUrls : []; allowedVideoIds = new Set(entries.map(e => { const u = new URL(e.url); if (u.protocol !== "https:" || !isYouTubeHost(u.hostname) || u.pathname !== "/watch" || u.searchParams.getAll("v").length !== 1) throw new Error("Invalid allowlist entry"); return u.searchParams.get("v"); })); rulesLoaded = true; return rules; }\n\n  window.UntrappedYouTubePolicy = Object.freeze({
    ALLOWED_VIDEO_ID: null,
    isYouTubeHost,
    getVideoId,
    isAllowedYouTubeUrl,
    canonicalAllowedUrl
  });
})();
