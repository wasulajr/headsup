import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

export function readJson(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}
export function writeJson(file, data) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data));
  fs.renameSync(tmp, file);
}
export function acquireLock(file) {
  // flock belongs to the open file description shared with fd 3. The kernel
  // releases it when Node exits, even if the hook deadline kills the process.
  // Keep this inode in place: unlinking it would let two writers lock different files.
  const fd = fs.openSync(file + '.flock', 'a+', 0o600);
  try {
    const result = spawnSync('/usr/bin/perl', ['-MFcntl=:flock', '-e', String.raw`
      open(my $fh, '+<&=', 3) or die "open flock descriptor: $!";
      local $SIG{ALRM} = sub { exit 75 };
      alarm 2;
      flock($fh, LOCK_EX) or die "flock: $!";
    `], { stdio: ['ignore', 'ignore', 'pipe', fd], encoding: 'utf8' });
    if (result.error) throw result.error;
    if (result.status === 75) throw new Error('UTILIZATION_LOCK_BUSY');
    if (result.status !== 0) throw new Error('UTILIZATION_FLOCK_FAILED: ' + result.stderr);
    return () => fs.closeSync(fd);
  } catch (error) {
    fs.closeSync(fd);
    throw error;
  }
}

function listJsonl(root) {
  const files = [], stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
    catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    for (const entry of entries) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) stack.push(file);
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) files.push(file);
    }
  }
  return files;
}

export function resolveTranscript(root, payload, env) {
  const id = payload.session_id || env.CODEX_THREAD_ID;
  if (!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(id || '')) {
    throw new Error('UTILIZATION_SESSION_ID_MISSING');
  }
  if (payload.transcript_path) return { id, file: path.resolve(payload.transcript_path) };
  // Filename lookup only. Never parse another session or guess from cwd/mtime.
  const matches = listJsonl(root).filter(file => path.basename(file).endsWith(`-${id}.jsonl`));
  if (matches.length !== 1) throw new Error(matches.length ? 'UTILIZATION_TRANSCRIPT_AMBIGUOUS' : 'UTILIZATION_TRANSCRIPT_MISSING');
  return { id, file: matches[0] };
}

const emptyCounts = () => ({ userMessages: 0, agentMessages: 0, toolCalls: 0,
  toolOutputs: 0, turnsStarted: 0, turnsCompleted: 0 });
function consume(row, state) {
  const p = row.payload || {};
  if (row.type === 'session_meta') {
    if (p.id === state.id) {
      if (!state.meta) state.ancestorId = p.forked_from_id || null;
      state.meta = { id: p.id, cwd: p.cwd, model: p.model, cli_version: p.cli_version };
    } else if (state.meta && p.id === state.ancestorId) {
      // Measured native forks prepend a child header before copied parent history.
      // Follow only that declared ancestry; never relabel the child as its parent.
      state.ancestorId = p.forked_from_id || null;
    } else {
      throw new Error('UTILIZATION_TRANSCRIPT_ID_MISMATCH');
    }
    return;
  }
  if (row.type === 'event_msg') {
    if (p.type === 'token_count') {
      state.usage = p.info || state.usage; state.rateLimits = p.rate_limits || state.rateLimits;
    }
    const counter = { user_message: 'userMessages', agent_message: 'agentMessages',
      task_started: 'turnsStarted', task_complete: 'turnsCompleted' }[p.type];
    if (counter) state.counts[counter]++;
  } else if (row.type === 'response_item') {
    if (['function_call', 'custom_tool_call'].includes(p.type)) state.counts.toolCalls++;
    if (['function_call_output', 'custom_tool_call_output'].includes(p.type)) state.counts.toolOutputs++;
  }
}
// Native rollouts put timestamp, optional ordinal, type, then payload.type first.
// Counters need only that header. Never deserialize a multi-MB tool output just
// to count it. Reordered/noncanonical records retain the full JSON parser.
function consumeLine(buffer, state) {
  const prefix = buffer.subarray(0, 512).toString('utf8');
  const outer = /^\{\s*"timestamp"\s*:\s*"[^"\\]*"\s*,\s*(?:"ordinal"\s*:\s*\d+\s*,\s*)?"type"\s*:\s*"([a-z_]+)"/.exec(prefix);
  if (outer && !['session_meta', 'event_msg', 'response_item'].includes(outer[1])) return;
  const header = /^\{\s*"timestamp"\s*:\s*"[^"\\]*"\s*,\s*(?:"ordinal"\s*:\s*\d+\s*,\s*)?"type"\s*:\s*"(event_msg|response_item)"\s*,\s*"payload"\s*:\s*\{\s*"type"\s*:\s*"([a-z_]+)"/.exec(prefix);
  if (header && !(header[1] === 'event_msg' && header[2] === 'token_count')) {
    consume({ type: header[1], payload: { type: header[2] } }, state);
    return;
  }
  const line = buffer.toString('utf8');
  if (line.trim()) {
    let row;
    try { row = JSON.parse(line); }
    catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      throw new SyntaxError('UTILIZATION_MALFORMED_TRANSCRIPT_RECORD');
    }
    consume(row, state);
  }
}

function fingerprint(fd, offset, length) {
  const data = Buffer.alloc(length);
  const size = fs.readSync(fd, data, 0, length, offset);
  return crypto.createHash('sha256').update(data.subarray(0, size)).digest('hex');
}

export function readTranscript(file, id, cacheFile) {
  const fd = fs.openSync(file, 'r');
  try {
    const stat = fs.fstatSync(fd);
    let cached = readJson(cacheFile);
    const same = cached?.version === 1 && cached.path === file && cached.id === id &&
      cached.dev === stat.dev && cached.ino === stat.ino && cached.offset <= stat.size &&
      cached.prefix === fingerprint(fd, 0, Math.min(cached.offset, 256)) &&
      cached.boundary === fingerprint(fd, Math.max(0, cached.offset - 256), Math.min(cached.offset, 256));
    if (!same) cached = { version: 1, path: file, id, dev: stat.dev, ino: stat.ino,
      offset: 0, meta: null, usage: null, rateLimits: null, counts: emptyCounts() };
    const initialOffset = cached.offset;
    let offset = cached.offset, fragments = [], pendingBytes = 0;
    while (offset < stat.size) {
      const chunk = Buffer.allocUnsafe(Math.min(1024 * 1024, stat.size - offset));
      const n = fs.readSync(fd, chunk, 0, chunk.length, offset);
      if (!n) throw new Error('UTILIZATION_TRANSCRIPT_CHANGED_DURING_READ');
      offset += n;
      const data = chunk.subarray(0, n);
      let start = 0, end;
      while ((end = data.indexOf(10, start)) !== -1) {
        const part = data.subarray(start, end);
        const line = fragments.length ? Buffer.concat([...fragments, part], pendingBytes + part.length) : part;
        consumeLine(line, cached);
        cached.offset += pendingBytes + part.length + 1;
        fragments = []; pendingBytes = 0; start = end + 1;
      }
      if (start < n) { fragments.push(data.subarray(start)); pendingBytes += n - start; }
    }
    // An incomplete final line is not committed and is re-read next invocation.
    if (!cached.meta || cached.meta.id !== id) throw new Error('UTILIZATION_TRANSCRIPT_ID_MISMATCH');
    cached.prefix = fingerprint(fd, 0, Math.min(cached.offset, 256));
    cached.boundary = fingerprint(fd, Math.max(0, cached.offset - 256), Math.min(cached.offset, 256));
    writeJson(cacheFile, cached);
    return { ...cached, bytesRead: offset - initialOffset, snapshotBytes: stat.size };
  } finally { fs.closeSync(fd); }
}
