// Quick end-to-end smoke test:
// 1) create a lobby, 2) open two ws clients, 3) verify host can start + state relays.
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

(async () => {
  const r = await fetch(`${BASE}/api/lobby`, { method: 'POST' });
  const { code } = await r.json();
  log('main', 'created lobby', code);

  const a = await connect(code, 'Alice');
  await sleep(50);
  const b = await connect(code, 'Bob');
  await sleep(150);

  // Alice (host) starts the game
  a.send(JSON.stringify({ type: 'start' }));
  await sleep(100);

  // Alice broadcasts position; Bob should receive it
  a.send(JSON.stringify({ type: 'state', data: { x: 1, y: 2, z: 3, yaw: 90 } }));
  await sleep(100);

  // Bob opens a door; Alice should receive event
  b.send(JSON.stringify({ type: 'event', name: 'door_open', data: { id: 'door_42' } }));
  await sleep(100);

  // Bob (non-host) tries to start — should be ignored
  b.send(JSON.stringify({ type: 'start' }));
  await sleep(100);

  a.close();
  await sleep(150);
  b.close();
  await sleep(100);

  // Assertions
  const aliceJoined = a.received.find((m) => m.type === 'joined');
  const bobJoined = b.received.find((m) => m.type === 'joined');
  const aliceSawBob = a.received.find((m) => m.type === 'player_joined' && m.player.name === 'Bob');
  const bobSawStart = b.received.find((m) => m.type === 'started');
  const bobSawState = b.received.find((m) => m.type === 'state' && m.data.x === 1);
  const aliceSawEvent = a.received.find((m) => m.type === 'event' && m.name === 'door_open');
  const bobLeftSeenByNoOne = a.received.filter((m) => m.type === 'player_left').length;

  const checks = [
    ['Alice gets "joined" with isHost=true', aliceJoined?.you?.isHost === true],
    ['Bob gets "joined" with isHost=false', bobJoined?.you?.isHost === false],
    ['Alice sees Bob join', !!aliceSawBob],
    ['Bob receives "started" from host', !!bobSawStart],
    ['Bob receives Alice state relay', !!bobSawState],
    ['Alice receives Bob event relay', !!aliceSawEvent],
    ['Non-host start was ignored (no extra "started" for Bob)', b.received.filter((m) => m.type === 'started').length === 1],
  ];

  let pass = 0;
  for (const [label, ok] of checks) {
    console.log(`${ok ? 'PASS' : 'FAIL'} - ${label}`);
    if (ok) pass++;
  }
  console.log(`\n${pass}/${checks.length} checks passed`);
  process.exit(pass === checks.length ? 0 : 1);
})();
