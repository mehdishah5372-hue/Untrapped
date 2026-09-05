const fs = require("fs");
const vm = require("vm");

const source = fs.readFileSync("youtube-policy.js", "utf8");
const fsRules = fs.readFileSync("youtube-allowlist.json", "utf8");
const context = { URL, Set, chrome: { runtime: { getURL: () => "youtube-allowlist.json" } }, fetch: async () => ({ ok: true, json: async () => JSON.parse(fsRules) }) };
vm.createContext(context);
vm.runInContext(source, context);
const P = context.UntrappedYouTubePolicy;


function assert(condition, message) {
  if (!condition) throw new Error(message);
}

(async () => { await P.loadRules();

const allowed = [
  "https://m.youtube.com/watch?v=2wgg7KtzTrU&vl=en",
  "https://www.youtube.com/watch?vl=en&v=2wgg7KtzTrU&utm_source=x",
  "https://youtube.com/watch?v=2wgg7KtzTrU#fragment",
  "https://www.youtube.com/watch?utm_campaign=x&v=2wgg7KtzTrU&t=90"
];

for (const url of allowed) assert(P.isAllowedYouTubeUrl(url), "should allow: " + url);

const blocked = [
  "https://www.youtube.com/watch?v=OTHER_VIDEO",
  "https://www.youtube.com/watch?v=2wgg7KtzTrU&v=OTHER_VIDEO",
  "https://www.youtube.com/shorts/2wgg7KtzTrU",
  "https://www.youtube.com/results?search_query=2wgg7KtzTrU",
  "https://www.youtube.com/channel/UC123",
  "https://www.youtube.com/@somechannel",
  "https://youtu.be/2wgg7KtzTrU",
  "http://www.youtube.com/watch?v=2wgg7KtzTrU"
];

for (const url of blocked) assert(!P.isAllowedYouTubeUrl(url), "should block: " + url);

console.log("YOUTUBE POLICY PASS: allowlist/denylist corpus passed."); })().catch(err => { console.error(err); process.exit(1); });
