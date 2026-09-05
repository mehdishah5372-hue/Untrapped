// Runtime URL policy is sourced from youtube-allowlist.json.
async function installYouTubeAllowRules() {
  const response = await fetch(chrome.runtime.getURL('youtube-allowlist.json'), {cache: 'no-store'});
  if (!response.ok) throw new Error('youtube-allowlist.json unavailable');
  const rules = await response.json();
  if (rules.version !== 1 || !rules.policy?.allowOnlyListedWatchVideos) throw new Error('Unsupported YouTube policy');
  const entries = Array.isArray(rules.allowedYouTubeUrls) ? rules.allowedYouTubeUrls : [];
  const addRules = entries.map((entry, index) => {
    const u = new URL(entry.url);
    if (u.protocol !== 'https:' || !/^(?:www\.|m\.)?youtube\.com$/.test(u.hostname) || u.pathname !== '/watch') throw new Error('Invalid allowed YouTube URL: ' + entry.url);
    const id = u.searchParams.get('v');
    if (!id || u.searchParams.getAll('v').length !== 1 || !/^[A-Za-z0-9_-]{11}$/.test(id)) throw new Error('Invalid allowed YouTube video ID: ' + entry.url);
    const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const regexFilter = '^https://(?:www\\.|m\\.)?youtube\\.com/watch\\?(?:(?!v=)[^&#=]+=[^&#]*&)*v=' + escaped + '(?:&(?!v=)[^&#=]+=[^&#]*)*(?:#.*)?$';
    return {id: 1000 + index, priority: 100, action: {type: 'allow'}, condition: {regexFilter, resourceTypes: ['main_frame','sub_frame']}};
  });
  await chrome.declarativeNetRequest.updateDynamicRules({removeRuleIds: Array.from({length: 1000}, (_, i) => 1000 + i), addRules});
}
installYouTubeAllowRules().catch(error => console.error('Untrapped YouTube policy:', error));