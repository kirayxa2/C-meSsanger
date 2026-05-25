import { WebSocket } from 'ws';
import {
  ClientToServer,
  HttpSnapshotResponse,
  LobbyInfo,
  PlayerInfo,
  PlayerState,
  ServerToClient,
} from './types';

const LOBBY_TTL_MS = 4 * 60 * 60 * 1000; // 4 hours
const MAX_PLAYERS = 8;
const HTTP_PLAYER_TIMEOUT_MS = 10_000; // kick HTTP-only players after 10s of silence
const EVENT_BUFFER_LIMIT = 200; // keep last N events per lobby for HTTP poll catch-up
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no I, O, 0, 1 to avoid confusion
const CODE_LENGTH = 6;

interface Player {
  id: string;
  name: string;
  isHost: boolean;
  // One of these is set depending on transport:
  ws?: WebSocket;        // WebSocket client (browser test page)
  httpLastSeen?: number; // HTTP polling client (UE4SS Lua mod)
  // Latest known state, populated whenever any transport sends one
  state?: PlayerState;
  stateUpdatedAt?: number;
}

interface BufferedEvent {
  seq: number;
  fromPlayerId: string;
  name: string;
  data?: unknown;
}

interface Lobby {
  code: string;
  players: Map<string, Player>;
  hostId: string | null;
  started: boolean;
  createdAt: number;
  // Monotonic event sequence for HTTP poll catch-up
  eventSeq: number;
  events: BufferedEvent[];
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
      eventSeq: 0,
      events: [],
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
        this.applyState(lobby, player, msg.data);
        break;
      case 'event':
        this.recordEvent(lobby, player.id, msg.name, msg.data);
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
        this.recordEvent(lobby, player.id, 'chat', { text: msg.text });
        this.broadcast(lobby, { type: 'chat', playerId: player.id, text: msg.text });
        break;
    }
  }

  // === HTTP polling API (used by the UE4SS Lua mod) ===

  joinLobbyHttp(
    code: string,
    name: string,
  ): { ok: true; playerId: string; isHost: boolean; lobby: LobbyInfo } | { ok: false; error: string } {
    const lobby = this.lobbies.get(code);
    if (!lobby) return { ok: false, error: 'Lobby not found' };
    if (lobby.players.size >= MAX_PLAYERS) return { ok: false, error: 'Lobby full' };

    const id = this.generatePlayerId();
    const isHost = lobby.hostId === null;
    const player: Player = {
      id,
      name,
      isHost,
      httpLastSeen: Date.now(),
    };
    lobby.players.set(id, player);
    if (isHost) lobby.hostId = id;

    // Tell WebSocket clients about the new player
    this.broadcast(lobby, { type: 'player_joined', player: toPlayerInfo(player) });

    return {
      ok: true,
      playerId: id,
      isHost,
      lobby: {
        code: lobby.code,
        players: [...lobby.players.values()].map(toPlayerInfo),
        started: lobby.started,
      },
    };
  }

  pushStateHttp(code: string, playerId: string, state: PlayerState): { ok: boolean; error?: string } {
    const lobby = this.lobbies.get(code);
    if (!lobby) return { ok: false, error: 'Lobby not found' };
    const player = lobby.players.get(playerId);
    if (!player) return { ok: false, error: 'Player not in lobby' };
    player.httpLastSeen = Date.now();
    this.applyState(lobby, player, state);
    return { ok: true };
  }

  pushEventHttp(
    code: string,
    playerId: string,
    name: string,
    data?: unknown,
  ): { ok: boolean; error?: string } {
    const lobby = this.lobbies.get(code);
    if (!lobby) return { ok: false, error: 'Lobby not found' };
    const player = lobby.players.get(playerId);
    if (!player) return { ok: false, error: 'Player not in lobby' };
    player.httpLastSeen = Date.now();

    if (name === 'start' && player.isHost && !lobby.started) {
      lobby.started = true;
      this.broadcast(lobby, { type: 'started' });
      this.recordEvent(lobby, playerId, 'started', undefined);
      return { ok: true };
    }
    if (name === 'chat') {
      const text = (data as { text?: string } | undefined)?.text ?? '';
      this.broadcast(lobby, { type: 'chat', playerId, text });
    } else {
      this.broadcast(lobby, { type: 'event', playerId, name, data }, playerId);
    }
    this.recordEvent(lobby, playerId, name, data);
    return { ok: true };
  }

  getSnapshotHttp(
    code: string,
    requesterId: string,
    since: number,
  ): { ok: true; data: HttpSnapshotResponse } | { ok: false; error: string } {
    const lobby = this.lobbies.get(code);
    if (!lobby) return { ok: false, error: 'Lobby not found' };
    const requester = lobby.players.get(requesterId);
    if (!requester) return { ok: false, error: 'Player not in lobby' };
    requester.httpLastSeen = Date.now();

    const players = [...lobby.players.values()]
      .filter((p) => p.id !== requesterId)
      .map((p) => ({
        id: p.id,
        name: p.name,
        isHost: p.isHost,
        state: p.state ?? null,
        stateUpdatedAt: p.stateUpdatedAt ?? 0,
      }));

    const events = lobby.events.filter((e) => e.seq > since && e.fromPlayerId !== requesterId);

    return {
      ok: true,
      data: {
        players,
        events,
        seq: lobby.eventSeq,
        started: lobby.started,
      },
    };
  }

  leaveLobbyHttp(code: string, playerId: string) {
    const lobby = this.lobbies.get(code);
    if (!lobby) return;
    const player = lobby.players.get(playerId);
    if (!player) return;
    this.leaveLobby(lobby, player);
  }

  // === Helpers ===

  private applyState(lobby: Lobby, player: Player, state: PlayerState) {
    player.state = state;
    player.stateUpdatedAt = Date.now();
    this.broadcast(lobby, { type: 'state', playerId: player.id, data: state }, player.id);
  }

  private recordEvent(lobby: Lobby, fromPlayerId: string, name: string, data?: unknown) {
    lobby.eventSeq += 1;
    lobby.events.push({ seq: lobby.eventSeq, fromPlayerId, name, data });
    if (lobby.events.length > EVENT_BUFFER_LIMIT) {
      lobby.events.splice(0, lobby.events.length - EVENT_BUFFER_LIMIT);
    }
  }

  private cleanup() {
    const now = Date.now();
    for (const [code, lobby] of this.lobbies) {
      // Drop HTTP-only players who haven't polled in a while
      for (const player of [...lobby.players.values()]) {
        if (player.ws) continue;
        if (player.httpLastSeen === undefined) continue;
        if (now - player.httpLastSeen > HTTP_PLAYER_TIMEOUT_MS) {
          this.leaveLobby(lobby, player);
        }
      }
      if (now - lobby.createdAt > LOBBY_TTL_MS) {
        for (const player of lobby.players.values()) {
          player.ws?.close(1000, 'Lobby expired');
        }
        this.lobbies.delete(code);
      }
    }
  }

  private broadcast(lobby: Lobby, msg: ServerToClient, exceptPlayerId?: string) {
    const data = JSON.stringify(msg);
    for (const player of lobby.players.values()) {
      if (player.id === exceptPlayerId) continue;
      if (player.ws && player.ws.readyState === WebSocket.OPEN) {
        player.ws.send(data);
      }
      // HTTP-only players will pick this up via their next snapshot poll
    }
  }

  private sendTo(player: Player, msg: ServerToClient) {
    if (player.ws && player.ws.readyState === WebSocket.OPEN) {
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
