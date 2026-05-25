import { WebSocket } from 'ws';
import { ClientToServer, LobbyInfo, PlayerInfo, ServerToClient } from './types';

const LOBBY_TTL_MS = 4 * 60 * 60 * 1000; // 4 hours
const MAX_PLAYERS = 8;
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no I, O, 0, 1 to avoid confusion
const CODE_LENGTH = 6;

interface Player {
  id: string;
  ws: WebSocket;
  name: string;
  isHost: boolean;
}

interface Lobby {
  code: string;
  players: Map<string, Player>;
  hostId: string | null;
  started: boolean;
  createdAt: number;
}

function toPlayerInfo(p: Player): PlayerInfo {
  return { id: p.id, name: p.name, isHost: p.isHost };
}

export class LobbyManager {
  private lobbies = new Map<string, Lobby>();

  constructor() {
    setInterval(() => this.cleanup(), 5 * 60 * 1000);
  }

  createLobby(): string {
    let code: string;
    do {
      code = this.generateCode();
    } while (this.lobbies.has(code));

    this.lobbies.set(code, {
      code,
      players: new Map(),
      hostId: null,
      started: false,
      createdAt: Date.now(),
    });
    return code;
  }

  hasLobby(code: string): boolean {
    return this.lobbies.has(code);
  }

  getLobbyInfo(code: string): LobbyInfo | null {
    const lobby = this.lobbies.get(code);
    if (!lobby) return null;
    return {
      code: lobby.code,
      players: [...lobby.players.values()].map(toPlayerInfo),
      started: lobby.started,
    };
  }

  joinLobby(
    code: string,
    ws: WebSocket,
    name: string,
  ): { player: Player; lobby: Lobby } | { error: string } {
    const lobby = this.lobbies.get(code);
    if (!lobby) return { error: 'Lobby not found' };
    if (lobby.started) return { error: 'Lobby already started' };
    if (lobby.players.size >= MAX_PLAYERS) return { error: 'Lobby full' };

    const id = this.generatePlayerId();
    const isHost = lobby.hostId === null;
    const player: Player = { id, ws, name, isHost };
    lobby.players.set(id, player);
    if (isHost) lobby.hostId = id;

    // Notify the joining player about themselves and current lobby state
    this.sendTo(player, {
      type: 'joined',
      you: toPlayerInfo(player),
      lobby: {
        code: lobby.code,
        players: [...lobby.players.values()].map(toPlayerInfo),
        started: lobby.started,
      },
    });

    // Notify everyone else in the lobby
    this.broadcast(lobby, { type: 'player_joined', player: toPlayerInfo(player) }, player.id);

    return { player, lobby };
  }

  leaveLobby(lobby: Lobby, player: Player) {
    if (!lobby.players.has(player.id)) return;
    lobby.players.delete(player.id);
    this.broadcast(lobby, { type: 'player_left', playerId: player.id });

    if (lobby.players.size === 0) {
      this.lobbies.delete(lobby.code);
      return;
    }

    // Promote a new host if the previous one left
    if (lobby.hostId === player.id) {
      const next = lobby.players.values().next().value;
      if (next) {
        next.isHost = true;
        lobby.hostId = next.id;
        this.broadcast(lobby, { type: 'player_joined', player: toPlayerInfo(next) });
      }
    }
  }

  handleMessage(lobby: Lobby, player: Player, msg: ClientToServer) {
    switch (msg.type) {
      case 'state':
        this.broadcast(
          lobby,
          { type: 'state', playerId: player.id, data: msg.data },
          player.id,
        );
        break;
      case 'event':
        this.broadcast(
          lobby,
          { type: 'event', playerId: player.id, name: msg.name, data: msg.data },
          player.id,
        );
        break;
      case 'ai_state':
        // Only the host is the source of truth for AI
        if (player.isHost) {
          this.broadcast(lobby, { type: 'ai_state', data: msg.data }, player.id);
        }
        break;
      case 'start':
        if (player.isHost && !lobby.started) {
          lobby.started = true;
          this.broadcast(lobby, { type: 'started' });
        }
        break;
      case 'chat':
        this.broadcast(lobby, { type: 'chat', playerId: player.id, text: msg.text });
        break;
    }
  }

  private cleanup() {
    const now = Date.now();
    for (const [code, lobby] of this.lobbies) {
      if (now - lobby.createdAt > LOBBY_TTL_MS) {
        for (const player of lobby.players.values()) {
          player.ws.close(1000, 'Lobby expired');
        }
        this.lobbies.delete(code);
      }
    }
  }

  private broadcast(lobby: Lobby, msg: ServerToClient, exceptPlayerId?: string) {
    const data = JSON.stringify(msg);
    for (const player of lobby.players.values()) {
      if (player.id === exceptPlayerId) continue;
      if (player.ws.readyState === WebSocket.OPEN) {
        player.ws.send(data);
      }
    }
  }

  private sendTo(player: Player, msg: ServerToClient) {
    if (player.ws.readyState === WebSocket.OPEN) {
      player.ws.send(JSON.stringify(msg));
    }
  }

  private generateCode(): string {
    let code = '';
    for (let i = 0; i < CODE_LENGTH; i++) {
      code += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
    }
    return code;
  }

  private generatePlayerId(): string {
    return Math.random().toString(36).slice(2, 10);
  }
}
