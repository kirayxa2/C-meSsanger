import express from 'express';
import { createServer } from 'http';
import path from 'path';
import { LobbyManager } from './lobby';
import { attachWebSocket } from './server';

const PORT = parseInt(process.env.PORT ?? '8080', 10);

const app = express();
app.use(express.json());

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
  const code = req.params.code.toUpperCase();
  const info = lobbyManager.getLobbyInfo(code);
  if (!info) {
    res.status(404).json({ error: 'Lobby not found' });
    return;
  }
  res.json(info);
});

app.use(express.static(path.join(__dirname, '..', 'public')));

const server = createServer(app);
attachWebSocket(server, lobbyManager);

server.listen(PORT, () => {
  console.log(`[c-messanger] listening on :${PORT}`);
});
