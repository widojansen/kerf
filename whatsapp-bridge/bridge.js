/**
 * Kerf WhatsApp Bridge
 *
 * Communicates with Kerf (Elixir) via stdin/stdout JSON lines.
 * Runs Baileys for WhatsApp Web multi-device connectivity.
 *
 * CRITICAL: stdout is the protocol channel. All logging goes to stderr via pino.
 * Never use console.log — it writes to stdout and corrupts the protocol.
 *
 * Protocol:
 *   Node -> Elixir: one JSON object per line on stdout
 *   Elixir -> Node: one JSON object per line on stdin
 *
 * Started by Kerf.Channels.WhatsApp GenServer via Erlang Port.
 */

import { createInterface } from 'readline';
import { mkdirSync } from 'fs';
import { resolve } from 'path';

import makeWASocket, {
  Browsers,
  DisconnectReason,
  makeCacheableSignalKeyStore,
  useMultiFileAuthState,
  isJidGroup,
} from '@whiskeysockets/baileys';

import pino from 'pino';

// --- Configuration ---

const AUTH_DIR = process.env.KERF_WA_AUTH_DIR || resolve('auth_info');
const LOG_LEVEL = process.env.KERF_WA_LOG_LEVEL || 'warn';

// Logger writes to stderr (fd 2), never stdout
const logger = pino({ level: LOG_LEVEL }, pino.destination(2));

// --- Protocol helpers ---

function emit(event) {
  process.stdout.write(JSON.stringify(event) + '\n');
}

// --- State ---

let sock = null;
let connected = false;
let reconnectAttempts = 0;
const MAX_RECONNECT_DELAY = 60000; // 60s

// --- Baileys connection ---

async function connectBaileys() {
  mkdirSync(AUTH_DIR, { recursive: true });

  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);

  sock = makeWASocket({
    auth: {
      creds: state.creds,
      keys: makeCacheableSignalKeyStore(state.keys, logger),
    },
    printQRInTerminal: false,
    logger,
    browser: Browsers.macOS('Chrome'),
  });

  // --- connection.update ---
  sock.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      emit({ type: 'qr', data: qr });
    }

    if (connection === 'open') {
      connected = true;
      reconnectAttempts = 0;

      const user = sock.user
        ? { id: sock.user.id, name: sock.user.name || null }
        : null;

      emit({ type: 'connected', user });

      // Announce availability for typing indicators
      sock.sendPresenceUpdate('available').catch(() => {});
    }

    if (connection === 'close') {
      connected = false;
      const reason = lastDisconnect?.error?.output?.statusCode;
      const shouldReconnect = reason !== DisconnectReason.loggedOut;

      if (shouldReconnect) {
        emit({
          type: 'disconnected',
          reason: lastDisconnect?.error?.message || 'unknown',
          code: reason || 0,
        });

        // Exponential backoff: 2s, 4s, 8s, ... up to 60s
        const delay = Math.min(
          2000 * Math.pow(2, reconnectAttempts),
          MAX_RECONNECT_DELAY
        );
        reconnectAttempts++;
        logger.info({ delay, attempt: reconnectAttempts }, 'Reconnecting...');

        setTimeout(() => {
          connectBaileys().catch((err) => {
            logger.error({ err }, 'Reconnection failed');
          });
        }, delay);
      } else {
        emit({ type: 'logged_out' });
        // Give Elixir time to process the event before exiting
        setTimeout(() => process.exit(0), 500);
      }
    }
  });

  // --- creds.update ---
  sock.ev.on('creds.update', saveCreds);

  // --- messages.upsert ---
  sock.ev.on('messages.upsert', async (upsert) => {
    // Only process real-time messages, not history sync
    if (upsert.type !== 'notify') return;

    for (const msg of upsert.messages) {
      try {
        if (!msg.message) continue;

        const remoteJid = msg.key.remoteJid;
        if (!remoteJid || remoteJid === 'status@broadcast') continue;

        // Skip own messages
        if (msg.key.fromMe) continue;

        // Extract text content
        const text =
          msg.message.conversation ||
          msg.message.extendedTextMessage?.text ||
          msg.message.imageMessage?.caption ||
          msg.message.videoMessage?.caption ||
          '';

        if (!text) continue;

        const timestamp = msg.messageTimestamp
          ? Number(msg.messageTimestamp)
          : Math.floor(Date.now() / 1000);

        emit({
          type: 'message',
          id: msg.key.id || '',
          from: remoteJid,
          participant: msg.key.participant || null,
          pushName: msg.pushName || null,
          text,
          timestamp,
          isGroup: isJidGroup(remoteJid),
        });
      } catch (err) {
        logger.error({ err, msgKey: msg.key }, 'Failed to process message');
      }
    }
  });

  emit({ type: 'ready' });
}

// --- stdin command handling ---

const rl = createInterface({ input: process.stdin });

rl.on('line', async (line) => {
  let cmd;
  try {
    cmd = JSON.parse(line);
  } catch (err) {
    logger.error({ line, err }, 'Failed to parse stdin command');
    return;
  }

  try {
    switch (cmd.type) {
      case 'send': {
        if (!sock || !connected) {
          emit({
            type: 'send_result',
            id: cmd.id || null,
            success: false,
            error: 'not connected',
          });
          return;
        }
        try {
          await sock.sendMessage(cmd.to, { text: cmd.text });
          emit({ type: 'send_result', id: cmd.id || null, success: true });
        } catch (err) {
          emit({
            type: 'send_result',
            id: cmd.id || null,
            success: false,
            error: err.message || 'send failed',
          });
        }
        break;
      }

      case 'typing': {
        if (!sock || !connected) return;
        try {
          const status = cmd.composing ? 'composing' : 'paused';
          await sock.sendPresenceUpdate(status, cmd.jid);
        } catch (err) {
          logger.debug({ err, jid: cmd.jid }, 'Failed to update presence');
        }
        break;
      }

      case 'read': {
        if (!sock || !connected) return;
        try {
          await sock.readMessages([
            {
              remoteJid: cmd.jid,
              id: cmd.id,
              participant: cmd.participant || undefined,
            },
          ]);
        } catch (err) {
          logger.debug({ err, jid: cmd.jid }, 'Failed to mark as read');
        }
        break;
      }

      case 'shutdown': {
        logger.info('Shutdown command received');
        if (sock) {
          try {
            sock.end(undefined);
          } catch {}
        }
        setTimeout(() => process.exit(0), 500);
        break;
      }

      default:
        logger.warn({ type: cmd.type }, 'Unknown command type');
    }
  } catch (err) {
    logger.error({ err, cmd }, 'Error handling command');
  }
});

// Handle stdin close (Elixir Port closed)
rl.on('close', () => {
  logger.info('stdin closed — Elixir Port closed, exiting');
  if (sock) {
    try {
      sock.end(undefined);
    } catch {}
  }
  process.exit(0);
});

// Handle uncaught errors
process.on('uncaughtException', (err) => {
  logger.error({ err }, 'Uncaught exception');
  emit({ type: 'error', message: err.message || 'uncaught exception' });
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  logger.error({ reason }, 'Unhandled rejection');
  emit({
    type: 'error',
    message: reason?.message || String(reason) || 'unhandled rejection',
  });
});

// --- Start ---

connectBaileys().catch((err) => {
  logger.error({ err }, 'Failed to start Baileys');
  emit({ type: 'error', message: err.message || 'startup failed' });
  process.exit(1);
});
