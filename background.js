importScripts('policy.js');

chrome.webNavigation.onBeforeNavigate.addListener((details) => {
  if (details.frameId !== 0) return;
  const url = details.url || '';
  if (!/^https:\/\/([^/]+\.)?youtube\.com\//i.test(url)) return;

  chrome.storage.local.get(['untrappedPolicy'], (stored) => {
    const config = stored.untrappedPolicy || {};
    let decision;
    try {
      decision = globalThis.UntrappedPolicy.decideYouTubeUrl(url, config);
    } catch (_) {
      decision = { decision: 'BLOCK', reason: 'policy-evaluation-error' };
    }
    if (decision.decision !== 'ALLOW') {
      const blocked = chrome.runtime.getURL('blocked.html') + '?reason=' + encodeURIComponent(decision.reason || 'blocked');
      chrome.tabs.update(details.tabId, { url: blocked }).catch(() => {});
    }
  });
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'complete' && tab.url?.includes('youtube.com')) {
    chrome.tabs.sendMessage(tabId, { text: 'reapply-focus-mode' }).catch(() => {});
  }
});
