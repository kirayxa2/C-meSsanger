import express, { Request, Response } from 'express';
import { createServer } from 'http';
import path from 'path';
import { LobbyManager } from './lobby';
import { attachWebSocket } from './server';
import { PlayerState } from './types';

const PORT = parseInt(process.env.PORT ?? '8080', 10);

const app = express();
app.use(express.json({ limit: '32kb' }));

const lobbyManager = new LobbyManager();

// UptimeRobot will hit this every 14 minutes to keep Render free tier awake
app.get('/health', (_req, res) => {
  res.json({ ok: true, ts: Date.now() });
});

app.post('/api/lobby', (_req, res) => {
  const code = lobbyManager.createLobby();
  res.json({ code });
});

app.get('/api/lobby/:code', (req, res) => {
  const code = String(req.params.code).toUpperCase();
  const info = lobbyManager.getLobbyInfo(code);
  if (!info) {
    res.status(404).json({ error: 'Lobby not found' });
    return;
  }
  res.json(info);
});

// === HTTP polling endpoints used by the UE4SS Lua mod ===

function sanitizeName(raw: unknown): string {
  if (typeof raw !== 'string') return 'Player';
  const trimmed = raw.trim().slice(0, 32);
  return trimmed.length > 0 ? trimmed : 'Player';
}

function isValidState(s: unknown): s is PlayerState {
  if (!s || typeof s !== 'object') return false;
  const v = s as Record<string, unknown>;
  return (
    typeof v.x === 'number' &&
    typeof v.y === 'number' &&
    typeof v.z === 'number' &&
    typeof v.yaw === 'number'
  );
}

app.post('/api/lobby/:code/join', (req: Request, res: Response) => {
  const code = String(req.params.code).toUpperCase();
  const name = sanitizeName(req.body?.name);
  const result = lobbyManager.joinLobbyHttp(code, name);
  if (!result.ok) {
    res.status(404).json({ error: result.error });
    return;
  }
  res.json({ playerId: result.playerId, isHost: result.isHost, lobby: result.lobby });
});

app.post('/api/lobby/:code/state', (req: Request, res: Response) => {
  const code = String(req.params.code).toUpperCase();
  const playerId = typeof req.body?.playerId === 'string' ? req.body.playerId : '';
  const state = req.body?.state;
  if (!playerId || !isValidState(state)) {
    res.status(400).json({ error: 'Bad request' });
    return;
  }
  const result = lobbyManager.pushStateHttp(code, playerId, state);
  if (!result.ok) {
    res.status(404).json({ error: result.error });
    return;
  }
  res.json({ ok: true });
});

app.post('/api/lobby/:code/event', (req: Request, res: Response) => {
  const code = String(req.params.code).toUpperCase();
  const playerId = typeof req.body?.playerId === 'string' ? req.body.playerId : '';
  const name = typeof req.body?.name === 'string' ? req.body.name : '';
  if (!playerId || !name) {
    res.status(400).json({ error: 'Bad request' });
    return;
  }
  const result = lobbyManager.pushEventHttp(code, playerId, name, req.body?.data);
  if (!result.ok) {
    res.status(404).json({ error: result.error });
    return;
  }
  res.json({ ok: true });
});

app.get('/api/lobby/:code/snapshot', (req: Request, res: Response) => {
  const code = String(req.params.code).toUpperCase();
  const playerId = typeof req.query.playerId === 'string' ? req.query.playerId : '';
  const since = parseInt((req.query.since as string) ?? '0', 10) || 0;
  if (!playerId) {
    res.status(400).json({ error: 'Missing playerId' });
    return;
  }
  const result = lobbyManager.getSnapshotHttp(code, playerId, since);
  if (!result.ok) {
    res.status(404).json({ error: result.error });
    return;
  }
  res.json(result.data);
});

app.post('/api/lobby/:code/leave', (req: Request, res: Response) => {
  const code = String(req.params.code).toUpperCase();
  const playerId = typeof req.body?.playerId === 'string' ? req.body.playerId : '';
  if (!playerId) {
    res.status(400).json({ error: 'Missing playerId' });
    return;
  }
  lobbyManager.leaveLobbyHttp(code, playerId);
  res.json({ ok: true });
});

app.use(express.static(path.join(__dirname, '..', 'public')));

const server = createServer(app);
attachWebSocket(server, lobbyManager);

server.listen(PORT, () => {
  console.log(`[c-messanger] listening on :${PORT}`);
});
