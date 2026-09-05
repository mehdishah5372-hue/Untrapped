(() => {
  "use strict";
  const YOUTUBE_HOSTS = new Set(["youtube.com", "www.youtube.com", "m.youtube.com"]);
  const VIDEO_ID_RE = /^[A-Za-z0-9_-]{11}$/;
  function decodeComponent(value) { if (/%(?![0-9A-Fa-f]{2})/.test(value)) throw new Error("malformed percent encoding"); return decodeURIComponent(value.replace(/\+/g, " ")); }
  function parseQuery(raw) { if (!raw) return []; return raw.split("&").map((part) => { const i=part.indexOf("="); const rawKey=i<0?part:part.slice(0,i); const rawValue=i<0?"":part.slice(i+1); return {rawKey,rawValue,key:decodeComponent(rawKey),value:decodeComponent(rawValue)}; }); }
  function normaliseConfig(config) { const ids=Array.isArray(config?.allowedYouTubeVideoIds)?config.allowedYouTubeVideoIds.map(String):[]; return {allowAdditionalQueryParameters:config?.youtubePolicy?.allowAdditionalQueryParameters!==false,allowedIds:new Set(ids.filter((id)=>VIDEO_ID_RE.test(id)))}; }
  function decideYouTubeUrl(input,config) {
    const result={decision:"BLOCK",reason:"default-deny",url:String(input??"")}; let url; try{url=new URL(String(input));}catch(_){return {...result,reason:"invalid-url"};}
    if(url.protocol!=="https:")return {...result,reason:"scheme-not-https"}; const host=url.hostname.toLowerCase().replace(/\.$/,""); if(!YOUTUBE_HOSTS.has(host))return {...result,reason:"host-not-allowlisted"}; if(url.port&&url.port!=="443")return {...result,reason:"non-default-port"}; if(url.username||url.password)return {...result,reason:"credentials-present"}; if(url.pathname!=="/watch")return {...result,reason:"path-not-watch"}; if(url.hash)return {...result,reason:"fragment-present"};
    let pairs; try{pairs=parseQuery(url.search.slice(1));}catch(_){return {...result,reason:"malformed-query"};}
    const encodedIdentity=pairs.filter((p)=>p.key.toLowerCase()==="v"&&p.rawKey!=="v"); if(encodedIdentity.length>0)return {...result,reason:"encoded-parameter-name"};
    const v=pairs.filter((p)=>p.key==="v"); if(v.length!==1)return {...result,reason:v.length===0?"missing-lowercase-v":"duplicate-v"}; if(!VIDEO_ID_RE.test(v[0].rawValue))return {...result,reason:"encoded-or-invalid-video-id"}; if(!VIDEO_ID_RE.test(v[0].value))return {...result,reason:"invalid-video-id"};
    const policy=normaliseConfig(config); if(!policy.allowAdditionalQueryParameters&&pairs.length!==1)return {...result,reason:"additional-query-parameters"}; if(!policy.allowedIds.has(v[0].value))return {...result,reason:"video-not-allowlisted"}; return {decision:"ALLOW",reason:"explicit-video-allowlist",host,path:url.pathname,videoId:v[0].value,url:String(input)};
  }
  const api={decideYouTubeUrl,parseQuery,normaliseConfig}; if(typeof module!=="undefined"&&module.exports)module.exports=api; globalThis.UntrappedPolicy=api;
})();
