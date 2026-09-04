(() => {
  "use strict";

  const STYLE_ID = "untrapped-focus-mode";

  // Network rules stop normal navigations before the page loads. This guard covers
  // YouTube's SPA history navigations, which do not necessarily create a new request.
  function enforceYouTubeUrl() {
    const policy = window.UntrappedYouTubePolicy;
    if (!policy || !policy.isYouTubeHost(location.hostname)) return;
    if (!policy.isAllowedYouTubeUrl(location.href)) {
      window.stop();
      location.replace(chrome.runtime.getURL("blocked.html"));
    }
  }

  function installNavigationGuard() {
    enforceYouTubeUrl();
    const originalPushState = history.pushState;
    const originalReplaceState = history.replaceState;
    history.pushState = function (...args) {
      const result = originalPushState.apply(this, args);
      queueMicrotask(enforceYouTubeUrl);
      return result;
    };
    history.replaceState = function (...args) {
      const result = originalReplaceState.apply(this, args);
      queueMicrotask(enforceYouTubeUrl);
      return result;
    };
    window.addEventListener("popstate", enforceYouTubeUrl);
    window.addEventListener("hashchange", enforceYouTubeUrl);
    window.addEventListener("yt-navigate-start", enforceYouTubeUrl);
    window.addEventListener("yt-navigate-finish", enforceYouTubeUrl);
  }

  installNavigationGuard();


  // YouTube is a single-page app and frequently replaces DOM nodes. The old
  // implementation hid a handful of elements once, so YouTube could simply
  // recreate them after navigation. Focus mode uses persistent CSS selectors
  // plus a MutationObserver so the rules survive SPA navigation and lazy load.
  const FOCUS_CSS = `
    /* Recommendations and discovery feeds */
    #related,
    #secondary ytd-watch-next-secondary-results-renderer,
    ytd-watch-next-secondary-results-renderer,
    ytd-compact-video-renderer,
    ytd-video-with-context-renderer,
    ytd-reel-shelf-renderer,
    ytd-rich-shelf-renderer,
    ytd-horizontal-card-list-renderer,
    ytd-shelf-renderer[is-shorts],
    ytd-shorts,
    ytd-shorts-shelf-renderer,
    ytd-rich-section-renderer:has(ytd-reel-shelf-renderer),
    ytd-browse[page-subtype="home"] ytd-rich-grid-renderer,
    ytd-browse[page-subtype="trending"] ytd-rich-grid-renderer,

    /* Home / discovery / social navigation */
    ytd-browse[page-subtype="home"] #primary,
    ytd-browse[page-subtype="trending"] #primary,
    ytd-guide-entry-renderer[role="tab"][href^="/feed/explore"],
    ytd-guide-entry-renderer[role="tab"][href^="/feed/trending"],
    ytd-guide-entry-renderer[role="tab"][href^="/shorts"],
    ytd-guide-entry-renderer[role="tab"][href^="/feed/subscriptions"],
    ytd-mini-guide-entry-renderer[aria-label="Shorts"],
    ytd-mini-guide-entry-renderer[aria-label="Trending"],
    ytd-mini-guide-entry-renderer[aria-label="Subscriptions"],

    /* Comments and live interaction */
    #comments,
    #chat,
    ytd-comments,
    ytd-live-chat-frame,
    ytd-live-chat-renderer,

    /* End-screen / in-player recommendations */
    .ytp-endscreen-content,
    .ytp-ce-element,
    .ytp-ce-video,
    .ytp-autonav-endscreen-upnext-container,
    .ytp-autonav-endscreen-upnext-header,
    .ytp-suggestion-set,

    /* Engagement prompts */
    ytd-subscribe-button-renderer,
    ytd-video-owner-renderer #subscribe-button,
    #notification-preference-toggle-button,

    /* Shorts injected dynamically */
    a[href^="/shorts/"],
    ytd-reel-item-renderer,

    /* Ads / promotional distractions */
    #masthead-ad,
    ytd-ad-slot-renderer,
    ytd-display-ad-renderer,
    ytd-promoted-sparkles-web-renderer,
    ytd-in-feed-ad-layout-renderer,
    ytd-action-companion-ad-renderer,
    .ytp-ad-module,
    .ytp-ad-overlay-container,
    .ytp-ad-text-overlay,
    #player-ads,

    /* Autoplay UI */
    .ytp-autonav-toggle-button-container,
    ytd-compact-autoplay-renderer {
      display: none !important;
      visibility: hidden !important;
    }

    /* On watch pages remove the recommendation column completely. */
    ytd-watch-flexy[is-two-columns_] #secondary {
      display: none !important;
    }

    ytd-watch-flexy[is-two-columns_] #primary {
      width: 100% !important;
      max-width: 100% !important;
    }
  `;

  function installFocusStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = FOCUS_CSS;
    (document.head || document.documentElement).appendChild(style);
  }

  function disableAutoplay() {
    // YouTube exposes autoplay state on the player toggle. Only click when
    // autoplay is currently enabled, so we never toggle it back on.
    const button = document.querySelector(
      ".ytp-autonav-toggle-button[aria-checked='true'], " +
      ".ytp-autonav-toggle-button[aria-pressed='true']"
    );
    if (button) {
      try {
        button.click();
      } catch (_) {
        // Ignore player lifecycle races.
      }
    }
  }

  function markTransientNodes() {
    const selectors = [
      "#related",
      "#comments",
      "#chat",
      "#masthead-ad",
      ".ytp-endscreen-content",
      ".ytp-ce-element",
      ".ytp-autonav-endscreen-upnext-container",
    ];

    for (const selector of selectors) {
      document.querySelectorAll(selector).forEach((node) => {
        node.setAttribute("data-untrapped-hidden", "true");
      });
    }

    disableAutoplay();
  }

  function start() {
    installFocusStyle();
    markTransientNodes();

    // YouTube navigates without full page reloads. Batch mutations so this
    // stays lightweight while still catching newly inserted recommendation UI.
    let scheduled = false;
    const observer = new MutationObserver(() => {
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(() => {
        scheduled = false;
        installFocusStyle();
        markTransientNodes();
      });
    });

    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
    });

    window.addEventListener("yt-navigate-finish", markTransientNodes);
    window.addEventListener("popstate", markTransientNodes);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
