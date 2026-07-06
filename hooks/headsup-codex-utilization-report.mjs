#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const stateRoot = process.env.HEADSUP_CODEX_STATE_ROOT
  || path.join(os.tmpdir(), `headsup-codex-${typeof process.getuid === 'function' ? process.getuid() : 'nouid'}`);
const utilDir = path.join(stateRoot, '.state', 'util');

let sessions = [];
try {
  sessions = fs.readdirSync(utilDir)
    .filter((name) => name.endsWith('.json'))
    .map((name) => {
      const file = path.join(utilDir, name);
      return { file, data: JSON.parse(fs.readFileSync(file, 'utf8')) };
    })
    .sort((a, b) => Number(b.data.lastAt || 0) - Number(a.data.lastAt || 0));
} catch {
  sessions = [];
}

if (!sessions.length) {
  console.log('  ! no utilization snapshots yet');
  console.log('    start or continue a Codex turn after installation');
  process.exit(0);
}

for (const { data } of sessions.slice(0, 8)) {
  const ageSec = Math.max(0, Math.floor((Date.now() - Number(data.lastAt || 0)) / 1000));
  console.log(`  - ${labelFor(data)} (${short(data.uuid)})`);
  console.log(`    ${data.summary || '(no summary yet)'}`);
  console.log(`    age=${formatAge(ageSec)} cwd=${data.cwd || '-'}`);
}

function labelFor(data) {
  if (data.sessionCwd) return path.basename(data.sessionCwd);
  if (data.cwd) return path.basename(data.cwd);
  return 'Codex';
}

function short(value) {
  return String(value || '').slice(0, 8) || 'unknown';
}

function formatAge(sec) {
  if (sec < 60) return `${sec}s`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m`;
  const hr = Math.floor(min / 60);
  return `${hr}h${String(min % 60).padStart(2, '0')}m`;
}
