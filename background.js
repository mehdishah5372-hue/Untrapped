// YouTube is a single-page app. The content script is injected at document_end,
// but this listener also asks it to re-apply focus mode after full navigations.
// The content script itself handles SPA navigation and DOM mutations.
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === "complete" && tab.url?.includes("youtube.com")) {
    chrome.tabs.sendMessage(tabId, { text: "reapply-focus-mode" }).catch(() => {});
  }
});
