#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const event = process.argv[2] || 'Unknown';
const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
const uid = typeof process.getuid === 'function' ? process.getuid() : 'nouid';
const stateRoot = process.env.HEADSUP_CODEX_STATE_ROOT || path.join(os.tmpdir(), `headsup-codex-${uid}`);
const stateDir = path.join(stateRoot, '.state');
const utilDir = path.join(stateDir, 'util');
const aptSessionId = process.env.AI_POWER_TERM_SESSION_ID || process.env.STEVE_TABS_SESSION_ID || '';
const sessionId = aptSessionId || process.env.ITERM_SESSION_ID || '';
const uuid = sanitizeKey(
  aptSessionId
    ? `apt-${aptSessionId}`
    : sessionId.includes(':') ? sessionId.split(':').slice(1).join(':') : sessionId
)
  || `no-iterm-${hashText(process.cwd())}`;

const now = Date.now();
const stateFile = path.join(utilDir, `${uuid}.json`);
const lineFile = path.join(utilDir, `${uuid}.statusline`);
const historyFile = path.join(utilDir, 'history.jsonl');

fs.mkdirSync(utilDir, { recursive: true });

const state = readJson(stateFile, null) || {
  version: 1,
  uuid,
  cwd: process.cwd(),
  startedAt: now,
  lastAt: now,
  state: 'idle',
  durationsMs: { idle: 0, working: 0, waiting: 0 },
  events: {},
};

const previousState = state.state || 'idle';
const elapsed = Math.max(0, now - Number(state.lastAt || now));
state.durationsMs[previousState] = Number(state.durationsMs[previousState] || 0) + elapsed;
state.state = stateForEvent(event);
state.lastAt = now;
state.cwd = process.cwd();
state.events[event] = Number(state.events[event] || 0) + 1;

const session = findBestSession(path.join(codexHome, 'sessions'), process.cwd());
if (session) {
  state.sessionPath = session.path;
  state.sessionId = session.meta?.id || state.sessionId;
  state.sessionCwd = session.meta?.cwd || state.sessionCwd;
  state.model = session.meta?.model || state.model;
  state.cliVersion = session.meta?.cli_version || state.cliVersion;
  state.usage = session.usage || state.usage;
  state.rateLimits = session.rateLimits || state.rateLimits;
  state.transcriptCounts = session.counts || state.transcriptCounts;
}

state.summary = buildSummary(state);
writeJsonAtomic(stateFile, state);
writeTextAtomic(lineFile, `${state.summary}\n`);

try {
  fs.appendFileSync(historyFile, JSON.stringify({
    ts: new Date(now).toISOString(),
    uuid,
    event,
    state: state.state,
    summary: state.summary,
    usage: state.usage || null,
    rateLimits: state.rateLimits || null,
    cwd: process.cwd(),
  }) + '\n');
} catch {
  // Best effort only.
}

function stateForEvent(name) {
  if (name === 'PermissionRequest' || name === 'Stop') return 'waiting';
  if (name === 'SessionStart') return 'idle';
  return 'working';
}

function sanitizeKey(value) {
  return String(value || '').replace(/[^A-Za-z0-9_.-]/g, '_');
}

function hashText(text) {
  let hash = 2166136261;
  for (const ch of String(text)) {
    hash ^= ch.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16);
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJsonAtomic(file, value) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2));
  fs.renameSync(tmp, file);
}

function writeTextAtomic(file, value) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, value);
  fs.renameSync(tmp, file);
}

function findBestSession(root, cwd) {
  let files = [];
  try {
    files = listJsonl(root)
      .map((file) => ({ file, mtime: fs.statSync(file).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime)
      .slice(0, 30);
  } catch {
    return null;
  }

  let fallback = null;
  for (const entry of files) {
    const parsed = parseSession(entry.file);
    if (!parsed) continue;
    fallback ||= parsed;
    if (parsed.meta?.cwd === cwd) return parsed;
  }
  return fallback;
}

function listJsonl(root) {
  const out = [];
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) stack.push(full);
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) out.push(full);
    }
  }
  return out;
}

function parseSession(file) {
  let meta = null;
  let usage = null;
  let rateLimits = null;
  const counts = {
    userMessages: 0,
    agentMessages: 0,
    toolCalls: 0,
    toolOutputs: 0,
    turnsStarted: 0,
    turnsCompleted: 0,
  };

  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }

  for (const line of text.split('\n')) {
    if (!line) continue;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    if (row.type === 'session_meta') {
      meta = row.payload || meta;
      continue;
    }
    if (row.type === 'event_msg') {
      const payload = row.payload || {};
      if (payload.type === 'token_count') {
        usage = payload.info || usage;
        rateLimits = payload.rate_limits || rateLimits;
      } else if (payload.type === 'user_message') {
        counts.userMessages += 1;
      } else if (payload.type === 'agent_message') {
        counts.agentMessages += 1;
      } else if (payload.type === 'task_started') {
        counts.turnsStarted += 1;
      } else if (payload.type === 'task_complete') {
        counts.turnsCompleted += 1;
      }
      continue;
    }
    if (row.type === 'response_item') {
      const payload = row.payload || {};
      if (payload.type === 'function_call' || payload.type === 'custom_tool_call') {
        counts.toolCalls += 1;
      } else if (payload.type === 'function_call_output' || payload.type === 'custom_tool_call_output') {
        counts.toolOutputs += 1;
      }
    }
  }

  return { path: file, meta, usage, rateLimits, counts };
}

function buildSummary(s) {
  const usage = s.usage || {};
  const total = usage.total_token_usage || {};
  const last = usage.last_token_usage || {};
  const rate = s.rateLimits || {};
  const primary = rate.primary || {};
  const secondary = rate.secondary || {};
  const counts = s.transcriptCounts || {};
  const durations = s.durationsMs || {};

  const pieces = [
    `Codex ${s.state}`,
    `${fmtTokens(last.total_tokens || 0)} last`,
    `${fmtTokens(total.total_tokens || 0)} total`,
  ];

  if (primary.used_percent != null || secondary.used_percent != null) {
    pieces.push(`limit ${fmtPct(primary.used_percent)}/${fmtPct(secondary.used_percent)}`);
  }
  if (counts.toolCalls != null) pieces.push(`${counts.toolCalls} tools`);
  pieces.push(`W ${fmtDuration(durations.working || 0)}`);
  pieces.push(`Q ${fmtDuration(durations.waiting || 0)}`);
  return pieces.join(' | ');
}

function fmtPct(value) {
  if (value == null || Number.isNaN(Number(value))) return '-';
  return `${Number(value).toFixed(0)}%`;
}

function fmtTokens(value) {
  const n = Number(value || 0);
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

function fmtDuration(ms) {
  const sec = Math.floor(Number(ms || 0) / 1000);
  if (sec < 60) return `${sec}s`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m`;
  const hr = Math.floor(min / 60);
  return `${hr}h${String(min % 60).padStart(2, '0')}m`;
}
