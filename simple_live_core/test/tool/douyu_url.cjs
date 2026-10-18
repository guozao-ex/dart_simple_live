#!/usr/bin/env node
// 开发辅助脚本：按 SimpleLive 的取流流程解析一条斗鱼 FLV 直链。
// 用法：node douyu_url.cjs <房间号> [cdn，默认 hw-h5]
// 只把直链写到 stdout，诊断信息走 stderr（不输出 wsAuth/token 等凭据内容）。
const fs = require('node:fs');
const path = require('node:path');

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43';
const DART_SIGN = path.join(__dirname, '..', '..', 'lib', 'src', 'scripts', 'douyu_sign.dart');
const DID = '10000000000000000000000000001501';

function loadCryptoJs() {
  const dart = fs.readFileSync(DART_SIGN, 'utf8');
  const start = dart.indexOf("r'''") + 4;
  const end = dart.indexOf("'''", start);
  return dart.slice(start, end);
}

async function sign(roomId) {
  const res = await fetch(
    'https://www.douyu.com/swf_api/homeH5Enc?rids=' + roomId,
    { headers: { referer: 'https://www.douyu.com/' + roomId, 'user-agent': UA } },
  );
  const json = await res.json();
  const html = json && json.data && json.data['room' + roomId];
  if (!html) {
    throw new Error('homeH5Enc 未返回脚本');
  }
  const tt = Math.floor(Date.now() / 1000);
  (0, eval)(loadCryptoJs());
  (0, eval)(html);
  return (0, eval)("ub98484234('" + roomId + "','" + DID + "'," + tt + ')');
}

// 房间号传 auto 时从推荐列表里挑一个正在直播的房间，避免写死的房间下播后失效。
async function resolveLiveRoomId() {
  const res = await fetch('https://www.douyu.com/japi/weblist/apinc/allpage/6/1', {
    headers: { referer: 'https://www.douyu.com/', 'user-agent': UA },
  });
  const json = await res.json();
  const items = ((json.data || {}).rl || []).filter((item) => item.type === 1);
  if (!items.length) {
    throw new Error('推荐列表里没有正在直播的房间');
  }
  const picked = items[0];
  console.error('[douyu_url] auto 选中房间 ' + picked.rid + '（在线 ' + picked.ol + '）');
  return String(picked.rid);
}

async function main() {
  let roomId = process.argv[2];
  const cdn = process.argv[3] || 'hw-h5';
  if (!roomId) {
    console.error('用法: node douyu_url.cjs <房间号|auto> [cdn]');
    process.exit(2);
  }
  if (roomId === 'auto') {
    roomId = await resolveLiveRoomId();
  }
  const data = await sign(roomId);
  const body =
    data + '&cdn=' + cdn + '&rate=-1&ver=Douyu_223061205&iar=1&ive=1&hevc=0&fa=0';
  const res = await fetch('https://www.douyu.com/lapi/live/getH5Play/' + roomId, {
    method: 'POST',
    headers: {
      referer: 'https://www.douyu.com/' + roomId,
      'user-agent': UA,
      'content-type': 'application/x-www-form-urlencoded',
    },
    body,
  });
  const json = await res.json();
  const payload = json && json.data;
  if (!payload || !payload.rtmp_live) {
    throw new Error('getH5Play 失败: ' + JSON.stringify({ error: json.error, msg: json.msg }));
  }
  let live = decodeURIComponent(String(payload.rtmp_live));
  if (!live.startsWith('http')) {
    const base = String(payload.rtmp_url).replace(/\/+$/, '');
    const tail = live.replace(/^\/+/, '');
    live = base + '/' + tail;
  }
  const uri = new URL(live);
  console.error(
    '[douyu_url] cdn=' + payload.rtmp_cdn + ' host=' + uri.host +
    ' expire=' + uri.searchParams.get('expire') + ' fcdn=' + uri.searchParams.get('fcdn'),
  );
  process.stdout.write(live);
}

main().catch((error) => {
  console.error('[douyu_url] ' + (error && error.message ? error.message : error));
  process.exit(1);
});
