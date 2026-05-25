// Wire protocol shared between server and clients (UE4SS Lua mod or test web client).
// Keep this file in sync with the Lua mod when we build it.

export type ClientToServer =
  | { type: 'state'; data: PlayerState }
  | { type: 'event'; name: string; data?: unknown }
  | { type: 'ai_state'; data: unknown }
  | { type: 'start' }
  | { type: 'chat'; text: string };

export type ServerToClient =
  | { type: 'joined'; you: PlayerInfo; lobby: LobbyInfo }
  | { type: 'player_joined'; player: PlayerInfo }
  | { type: 'player_left'; playerId: string }
  | { type: 'state'; playerId: string; data: PlayerState }
  | { type: 'event'; playerId: string; name: string; data?: unknown }
  | { type: 'ai_state'; data: unknown }
  | { type: 'started' }
  | { type: 'chat'; playerId: string; text: string }
  | { type: 'error'; message: string };

export interface PlayerState {
  x: number;
  y: number;
  z: number;
  yaw: number;
  pitch?: number;
  anim?: string;
}

export interface PlayerInfo {
  id: string;
  name: string;
  isHost: boolean;
}

export interface LobbyInfo {
  code: string;
  players: PlayerInfo[];
  started: boolean;
}
