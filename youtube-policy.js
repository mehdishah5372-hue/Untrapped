(() => {
  "use strict";

  const RULES_URL = chrome.runtime.getURL("youtube-rules.json");
  const ALLOWED_VIDEO_ID = "2wgg7KtzTrU";
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
      if (ids.length !== 1 || ids[0] !== ALLOWED_VIDEO_ID) return null;
      return ids[0];
    } catch (_) {
      return null;
    }
  }

  function isAllowedYouTubeUrl(url) {
    try {
      const u = new URL(url);
      return u.protocol === "https:" &&
        isYouTubeHost(u.hostname) &&
        getVideoId(u.href) === ALLOWED_VIDEO_ID;
    } catch (_) {
      return false;
    }
  }

  function canonicalAllowedUrl(url) {
    return isAllowedYouTubeUrl(url)
      ? "https://www.youtube.com/watch?v=" + ALLOWED_VIDEO_ID
      : null;
  }

  async function loadRules() { const r = await fetch(RULES_URL, {cache: "no-store"}); if (!r.ok) throw new Error("youtube-rules.json unavailable"); return await r.json(); }\n\n  window.UntrappedYouTubePolicy = Object.freeze({
    ALLOWED_VIDEO_ID,
    isYouTubeHost,
    getVideoId,
    isAllowedYouTubeUrl,
    canonicalAllowedUrl
  });
})();
