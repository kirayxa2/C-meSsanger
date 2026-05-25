// Quick end-to-end smoke test:
// 1) WebSocket relay between two browser-style clients
// 2) HTTP polling (the protocol the UE4SS Lua mod will use)
// 3) Mixed: WebSocket client and HTTP client in the same lobby see each other
import WebSocket from 'ws';

const BASE = process.env.BASE ?? 'http://localhost:9090';
const WSBASE = BASE.replace(/^http/, 'ws');

const log = (tag, ...args) => console.log(`[${tag}]`, ...args);

function connect(code, name) {
  const ws = new WebSocket(`${WSBASE}/ws?code=${code}&name=${encodeURIComponent(name)}`);
  ws.received = [];
  ws.on('message', (raw) => {
    const m = JSON.parse(raw.toString());
    ws.received.push(m);
    log(name + ' <-', m.type, m.type === 'state' ? m.data : '');
  });
  return new Promise((resolve, reject) => {
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function postJson(url, body) {
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: r.status, body: await r.json().catch(() => null) };
}

async function getJson(url) {
  const r = await fetch(url);
  return { status: r.status, body: await r.json().catch(() => null) };
}

async function testWebSocketRelay() {
  console.log('\n=== Test 1: WebSocket relay ===');
  const r = await fetch(`${BASE}/api/lobby`, { method: 'POST' });
  const { code } = await r.json();
  log('main', 'created lobby', code);

  const a = await connect(code, 'Alice');
  await sleep(50);
  const b = await connect(code, 'Bob');
  await sleep(150);

  a.send(JSON.stringify({ type: 'start' }));
  await sleep(100);
  a.send(JSON.stringify({ type: 'state', data: { x: 1, y: 2, z: 3, yaw: 90 } }));
  await sleep(100);
  b.send(JSON.stringify({ type: 'event', name: 'door_open', data: { id: 'door_42' } }));
  await sleep(100);
  b.send(JSON.stringify({ type: 'start' }));
  await sleep(100);

  a.close();
  await sleep(150);
  b.close();
  await sleep(100);

  return [
    ['Alice gets "joined" with isHost=true', a.received.find((m) => m.type === 'joined')?.you?.isHost === true],
    ['Bob gets "joined" with isHost=false', b.received.find((m) => m.type === 'joined')?.you?.isHost === false],
    ['Alice sees Bob join', !!a.received.find((m) => m.type === 'player_joined' && m.player.name === 'Bob')],
    ['Bob receives "started" from host', !!b.received.find((m) => m.type === 'started')],
    ['Bob receives Alice state relay', !!b.received.find((m) => m.type === 'state' && m.data.x === 1)],
    ['Alice receives Bob event relay', !!a.received.find((m) => m.type === 'event' && m.name === 'door_open')],
    ['Non-host start was ignored', b.received.filter((m) => m.type === 'started').length === 1],
  ];
}

async function testHttpPolling() {
  console.log('\n=== Test 2: HTTP polling (Lua mod protocol) ===');
  const { body: { code } } = await postJson(`${BASE}/api/lobby`, {});
  log('http', 'created lobby', code);

  const j1 = await postJson(`${BASE}/api/lobby/${code}/join`, { name: 'IngamePlayer1' });
  const j2 = await postJson(`${BASE}/api/lobby/${code}/join`, { name: 'IngamePlayer2' });
  log('http', 'joined', j1.body.playerId, '(host:', j1.body.isHost, ')');
  log('http', 'joined', j2.body.playerId, '(host:', j2.body.isHost, ')');

  const p1 = j1.body.playerId, p2 = j2.body.playerId;

  // p1 pushes its position
  await postJson(`${BASE}/api/lobby/${code}/state`, { playerId: p1, state: { x: 100, y: 200, z: 50, yaw: 45 } });

  // p2 polls — should see p1's state
  const snap1 = await getJson(`${BASE}/api/lobby/${code}/snapshot?playerId=${p2}&since=0`);
  log('http', 'p2 snapshot:', JSON.stringify(snap1.body));

  // p1 sends a chat event — p2 should pick it up on next poll
  await postJson(`${BASE}/api/lobby/${code}/event`, { playerId: p1, name: 'chat', data: { text: 'hi from p1' } });
  const snap2 = await getJson(`${BASE}/api/lobby/${code}/snapshot?playerId=${p2}&since=${snap1.body.seq}`);
  log('http', 'p2 snapshot 2:', JSON.stringify(snap2.body));

  // Bad inputs
  const badJoin = await postJson(`${BASE}/api/lobby/NOPE/join`, { name: 'x' });
  const badState = await postJson(`${BASE}/api/lobby/${code}/state`, { playerId: 'fake', state: { x: 0, y: 0, z: 0, yaw: 0 } });

  // p2 leaves explicitly
  await postJson(`${BASE}/api/lobby/${code}/leave`, { playerId: p2 });
  const lobbyAfter = await getJson(`${BASE}/api/lobby/${code}`);

  return [
    ['HTTP join returns playerId', typeof p1 === 'string' && p1.length > 0],
    ['First HTTP joiner is host', j1.body.isHost === true],
    ['Second HTTP joiner is not host', j2.body.isHost === false],
    ['Snapshot shows other players (p2 sees p1)', snap1.body.players.some((p) => p.id === p1 && p.state?.x === 100)],
    ['Snapshot does NOT include requester themselves', !snap1.body.players.some((p) => p.id === p2)],
    ['Snapshot returns event seq', typeof snap1.body.seq === 'number'],
    ['Event picked up via since-cursor', snap2.body.events.some((e) => e.name === 'chat')],
    ['Bad lobby code -> 404', badJoin.status === 404],
    ['Bad playerId -> 404', badState.status === 404],
    ['After leave, player gone from lobby', !lobbyAfter.body.players.some((p) => p.id === p2)],
  ];
}

async function testMixedTransports() {
  console.log('\n=== Test 3: WebSocket + HTTP in same lobby ===');
  const { body: { code } } = await postJson(`${BASE}/api/lobby`, {});

  // Alice joins via WebSocket (browser test client)
  const alice = await connect(code, 'WebAlice');
  await sleep(100);

  // Bob joins via HTTP (Lua mod)
  const join = await postJson(`${BASE}/api/lobby/${code}/join`, { name: 'IngameBob' });
  const bobId = join.body.playerId;
  await sleep(50);

  // Bob (HTTP) pushes state — Alice (WS) should receive it as a "state" event
  await postJson(`${BASE}/api/lobby/${code}/state`, { playerId: bobId, state: { x: 7, y: 8, z: 9, yaw: 270 } });
  await sleep(100);

  // Alice (WS) sends state — Bob (HTTP) should see it on next poll
  alice.send(JSON.stringify({ type: 'state', data: { x: 11, y: 22, z: 33, yaw: 180 } }));
  await sleep(100);
  const bobSnap = await getJson(`${BASE}/api/lobby/${code}/snapshot?playerId=${bobId}&since=0`);

  alice.close();
  await sleep(50);

  return [
    ['WS Alice was notified about HTTP Bob joining', !!alice.received.find((m) => m.type === 'player_joined' && m.player.name === 'IngameBob')],
    ['WS Alice received HTTP Bob state relay', !!alice.received.find((m) => m.type === 'state' && m.data.x === 7)],
    ['HTTP Bob snapshot sees WS Alice state', bobSnap.body.players.some((p) => p.name === 'WebAlice' && p.state?.x === 11)],
  ];
}

(async () => {
  const all = [];
  all.push(...(await testWebSocketRelay()));
  all.push(...(await testHttpPolling()));
  all.push(...(await testMixedTransports()));

  let pass = 0;
  console.log('\n=== Results ===');
  for (const [label, ok] of all) {
    console.log(`${ok ? 'PASS' : 'FAIL'} - ${label}`);
    if (ok) pass++;
  }
  console.log(`\n${pass}/${all.length} checks passed`);
  process.exit(pass === all.length ? 0 : 1);
})();
