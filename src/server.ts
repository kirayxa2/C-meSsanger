import { Server } from 'http';
import { URL } from 'url';
import { WebSocket, WebSocketServer } from 'ws';
import { LobbyManager } from './lobby';
import { ClientToServer } from './types';

export function attachWebSocket(server: Server, lobbyManager: LobbyManager) {
  const wss = new WebSocketServer({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '', 'http://localhost');
    if (url.pathname !== '/ws') {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      handleConnection(ws, url, lobbyManager);
    });
  });
}

function handleConnection(ws: WebSocket, url: URL, lobbyManager: LobbyManager) {
  const code = url.searchParams.get('code')?.toUpperCase();
  const name = url.searchParams.get('name')?.slice(0, 32) || 'Player';

  if (!code) {
    ws.send(JSON.stringify({ type: 'error', message: 'Missing code' }));
    ws.close(1008, 'Missing code');
    return;
  }

  const result = lobbyManager.joinLobby(code, ws, name);
  if ('error' in result) {
    ws.send(JSON.stringify({ type: 'error', message: result.error }));
    ws.close(1008, result.error);
    return;
  }

  const { player, lobby } = result;

  ws.on('message', (raw) => {
    let msg: ClientToServer;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      ws.send(JSON.stringify({ type: 'error', message: 'Invalid JSON' }));
      return;
    }
    if (!msg || typeof msg !== 'object' || typeof (msg as { type?: unknown }).type !== 'string') {
      ws.send(JSON.stringify({ type: 'error', message: 'Invalid message' }));
      return;
    }
    lobbyManager.handleMessage(lobby, player, msg);
  });

  ws.on('close', () => lobbyManager.leaveLobby(lobby, player));
  ws.on('error', () => lobbyManager.leaveLobby(lobby, player));
}
