(() => {
  "use strict";

  const STYLE_ID = "untrapped-focus-mode";
  const DEFAULTS = {
    homeFeed: true,
    recommendedVideos: true,
    shorts: true,
    commentSection: true,
    liveChat: true,
    ad: true,
  };

  const SELECTORS = {
    homeFeed: [
      "ytd-browse[page-subtype='home'] ytd-rich-grid-renderer",
      "ytd-browse[page-subtype='home'] #primary",
    ],
    recommendedVideos: [
      "#related",
      "ytd-watch-next-secondary-results-renderer",
      "#secondary ytd-compact-video-renderer",
      "#secondary ytd-video-with-context-renderer",
      "ytd-watch-flexy #secondary",
      ".ytp-endscreen-content",
      ".ytp-ce-element",
      ".ytp-ce-video",
      ".ytp-autonav-endscreen-upnext-container",
      ".ytp-autonav-endscreen-upnext-header",
      ".ytp-suggestion-set",
    ],
    shorts: [
      "ytd-reel-shelf-renderer",
      "ytd-shorts-shelf-renderer",
      "ytd-shelf-renderer[is-shorts]",
      "ytd-shorts",
      "ytd-reel-item-renderer",
      "a[href^='/shorts/']",
      "ytd-guide-entry-renderer[role='tab'][href^='/shorts']",
      "ytd-mini-guide-entry-renderer[aria-label='Shorts']",
    ],
    commentSection: ["#comments", "ytd-comments"],
    liveChat: ["#chat", "ytd-live-chat-frame", "ytd-live-chat-renderer"],
    ad: [
      "#masthead-ad",
      "#player-ads",
      "ytd-ad-slot-renderer",
      "ytd-display-ad-renderer",
      "ytd-promoted-sparkles-web-renderer",
      "ytd-in-feed-ad-layout-renderer",
      "ytd-action-companion-ad-renderer",
      ".ytp-ad-module",
      ".ytp-ad-overlay-container",
      ".ytp-ad-text-overlay",
    ],
  };

  const AUTOPLAY_SELECTORS = [
    ".ytp-autonav-toggle-button[aria-checked='true']",
    ".ytp-autonav-toggle-button[aria-pressed='true']",
  ];

  function getSettings() {
    return new Promise((resolve) => {
      chrome.storage.sync.get(DEFAULTS, (stored) => {
        resolve({ ...DEFAULTS, ...stored });
      });
    });
  }

  function enabledSelectors(settings) {
    const selectors = [];
    for (const key of Object.keys(SELECTORS)) {
      if (settings[key]) selectors.push(...SELECTORS[key]);
    }
    return [...new Set(selectors)];
  }

  function installStyle(settings) {
    let style = document.getElementById(STYLE_ID);
    if (!style) {
      style = document.createElement("style");
      style.id = STYLE_ID;
      (document.head || document.documentElement).appendChild(style);
    }

    const selectors = enabledSelectors(settings);
    const rules = selectors.length
      ? `${selectors.join(",\n")} { display: none !important; visibility: hidden !important; }`
      : "";

    const layoutRule = settings.recommendedVideos
      ? "ytd-watch-flexy[is-two-columns_] #primary { width: 100% !important; max-width: 100% !important; }"
      : "";

    style.textContent = `${rules}\n${layoutRule}`;
  }

  function disableAutoplay() {
    for (const selector of AUTOPLAY_SELECTORS) {
      const button = document.querySelector(selector);
      if (!button) continue;
      try {
        button.click();
      } catch (_) {}
      break;
    }
  }

  function hideMatchingNodes(settings) {
    for (const selector of enabledSelectors(settings)) {
      document.querySelectorAll(selector).forEach((node) => {
        node.setAttribute("data-untrapped-hidden", "true");
      });
    }
    if (settings.recommendedVideos) disableAutoplay();
  }

  async function apply() {
    const settings = await getSettings();
    installStyle(settings);
    hideMatchingNodes(settings);
  }

  // popup.js sends these messages when a preference changes.
  chrome.runtime.onMessage.addListener((message) => {
    if (!message?.text) return;

    const map = {
      hideHomeFeed: ["homeFeed", true],
      showHomeFeed: ["homeFeed", false],
      hideRecommendedVideos: ["recommendedVideos", true],
      showRecommendedVideos: ["recommendedVideos", false],
      hideShorts: ["shorts", true],
      showShorts: ["shorts", false],
      hideCommentSection: ["commentSection", true],
      showCommentSection: ["commentSection", false],
      hideLiveChat: ["liveChat", true],
      showLiveChat: ["liveChat", false],
      hideAd: ["ad", true],
      showAd: ["ad", false],
      "reapply-focus-mode": null,
    };

    const change = map[message.text];
    if (change) {
      chrome.storage.sync.set({ [change[0]]: change[1] }, apply);
      return;
    }

    if (message.text === "reapply-focus-mode") apply();
  });

  let scheduled = false;
  function scheduleApply() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      apply();
    });
  }

  function start() {
    apply();

    const observer = new MutationObserver(scheduleApply);
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
    });

    window.addEventListener("yt-navigate-finish", scheduleApply);
    window.addEventListener("yt-page-data-fetched", scheduleApply);
    window.addEventListener("popstate", scheduleApply);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
