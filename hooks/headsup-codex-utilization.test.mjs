import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { readTranscript, resolveTranscript, acquireLock } from './headsup-codex-transcript.mjs';
const id='11111111-1111-1111-1111-111111111111', other='22222222-2222-2222-2222-222222222222';
const row=(type,payload)=>JSON.stringify({timestamp:'2026-11-17T16:00:00Z',ordinal:1,type,payload})+'\n';
const meta=(sid=id)=>row('session_meta',{id:sid,cwd:'/same',cli_version:'test'});
const event=(type,extra={})=>row('event_msg',{type,...extra});
const usage=n=>event('token_count',{info:{total_token_usage:{total_tokens:n}},rate_limits:{primary:{used_percent:n}}});
function fixture(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'util-test-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));return {dir,file:path.join(dir,`rollout-${id}.jsonl`),cache:path.join(dir,'cache.json')};}
test('canonical records match full parser counts and latest usage',t=>{
 const {file,cache}=fixture(t);fs.writeFileSync(file,meta()+usage(1)+event('user_message')+event('agent_message')+event('task_started')+event('task_complete')+row('response_item',{type:'function_call',arguments:'x'.repeat(2_000_000)})+row('response_item',{type:'custom_tool_call'})+row('response_item',{type:'function_call_output',output:'x'.repeat(2_000_000)})+row('response_item',{type:'custom_tool_call_output'})+row('response_item',{type:'message',content:'ignored'})+row('compacted',{message:'x'.repeat(2_000_000)})+usage(9));
 const x=readTranscript(file,id,cache);assert.equal(x.usage.total_token_usage.total_tokens,9);assert.equal(x.rateLimits.primary.used_percent,9);assert.deepEqual(x.counts,{userMessages:1,agentMessages:1,toolCalls:2,toolOutputs:2,turnsStarted:1,turnsCompleted:1});assert.equal(x.offset,fs.statSync(file).size);
});
test('unchanged reads zero transcript bytes and appends count once',t=>{const {file,cache}=fixture(t);fs.writeFileSync(file,meta()+usage(1));readTranscript(file,id,cache);assert.equal(readTranscript(file,id,cache).bytesRead,0);const append=event('task_started')+usage(2);fs.appendFileSync(file,append);let x=readTranscript(file,id,cache);assert.equal(x.bytesRead,Buffer.byteLength(append));assert.equal(x.counts.turnsStarted,1);assert.equal(readTranscript(file,id,cache).counts.turnsStarted,1);});
test('partial UTF8 final record waits for newline and never loses or doubles count',t=>{const {file,cache}=fixture(t);fs.writeFileSync(file,meta());const bytes=Buffer.from(event('agent_message',{text:'hello 🐈'}));fs.appendFileSync(file,bytes.subarray(0,bytes.length-4));assert.equal(readTranscript(file,id,cache).counts.agentMessages,0);fs.appendFileSync(file,bytes.subarray(bytes.length-4));assert.equal(readTranscript(file,id,cache).counts.agentMessages,1);});
test('reordered JSON uses full parser',t=>{const {file,cache}=fixture(t);fs.writeFileSync(file,meta()+JSON.stringify({payload:{type:'task_started'},type:'event_msg'})+'\n');assert.equal(readTranscript(file,id,cache).counts.turnsStarted,1);});
test('truncation rebuilds counters',t=>{const {file,cache}=fixture(t);fs.writeFileSync(file,meta()+event('task_started')+usage(33));readTranscript(file,id,cache);fs.writeFileSync(file,meta()+usage(1));const x=readTranscript(file,id,cache);assert.equal(x.usage.total_token_usage.total_tokens,1);assert.equal(x.counts.turnsStarted,0);});
test('replacement with equal-sized file resets cache',t=>{const {file,cache}=fixture(t);fs.writeFileSync(file,meta()+usage(1));readTranscript(file,id,cache);fs.writeFileSync(file+'.new',meta()+usage(2));fs.renameSync(file+'.new',file);assert.equal(readTranscript(file,id,cache).usage.total_token_usage.total_tokens,2);});
test('rewrite at same size resets using fingerprints',t=>{const {file,cache}=fixture(t);fs.writeFileSync(file,meta()+usage(1));readTranscript(file,id,cache);fs.writeFileSync(file,meta()+usage(2));assert.equal(readTranscript(file,id,cache).usage.total_token_usage.total_tokens,2);});
test('wrong transcript identity refuses without caching',t=>{const {file,cache}=fixture(t);fs.writeFileSync(file,meta(other));assert.throws(()=>readTranscript(file,id,cache),/ID_MISMATCH/);assert.equal(fs.existsSync(cache),false);});
test('filename identity ignores newer sibling in same directory',t=>{const {dir,file}=fixture(t);fs.writeFileSync(file,meta());fs.writeFileSync(path.join(dir,`rollout-${other}.jsonl`),meta(other));assert.equal(resolveTranscript(dir,{session_id:id},{}).file,file);assert.throws(()=>resolveTranscript(dir,{},{}),/SESSION_ID_MISSING/);});
test('payload session overrides daemon environment session',t=>{const {dir,file}=fixture(t);fs.writeFileSync(file,meta());assert.equal(resolveTranscript(dir,{session_id:id},{CODEX_THREAD_ID:other}).file,file);});
test('malformed complete JSON fails loudly without cursor advance',t=>{const {file,cache}=fixture(t);fs.writeFileSync(file,meta());const x=readTranscript(file,id,cache);fs.appendFileSync(file,'not-json\n');assert.throws(()=>readTranscript(file,id,cache),SyntaxError);assert.equal(JSON.parse(fs.readFileSync(cache)).offset,x.offset);});
test('lock rejects live owner and releases cleanly',t=>{const {dir}=fixture(t);const file=path.join(dir,'test.lock');const release=acquireLock(file);assert.throws(()=>acquireLock(file),/LOCK_BUSY/);release();acquireLock(file)();});
test('empty legacy lock and termination of a kernel lock owner permit recovery', t => {
 const {dir}=fixture(t), file=path.join(dir,'test.lock');
 fs.writeFileSync(file,'');
 const moduleUrl=new URL('./headsup-codex-transcript.mjs',import.meta.url).href;
 const killed=spawnSync(process.execPath,['--input-type=module','-e',
   `import {acquireLock} from ${JSON.stringify(moduleUrl)}; acquireLock(${JSON.stringify(file)}); process.kill(process.pid,"SIGKILL");`]);
 assert.equal(killed.signal,'SIGKILL');
 acquireLock(file)();
});
test('full hook uses stdin identity, retains events, clears usage on session switch',t=>{
 const {dir,file}=fixture(t);fs.writeFileSync(file,meta()+usage(7));const otherFile=path.join(dir,`rollout-${other}.jsonl`);fs.writeFileSync(otherFile,meta(other));
 const env={...process.env,CODEX_HOME:dir,HEADSUP_CODEX_STATE_ROOT:path.join(dir,'state'),AI_POWER_TERM_SESSION_ID:'fixture',AI_POWER_TERM_HOOK_URL:'',STEVE_TABS_HOOK_URL:''};
 function run(sid,p){const r=spawnSync(process.execPath,[new URL('./headsup-codex-utilization.mjs',import.meta.url).pathname,'PreToolUse'],{env,input:JSON.stringify({session_id:sid,transcript_path:p}),encoding:'utf8',timeout:4000});assert.equal(r.status,0,r.stderr);return JSON.parse(fs.readFileSync(path.join(dir,'state/.state/util/apt-fixture.json')));}
 assert.equal(run(id,file).usage.total_token_usage.total_tokens,7);assert.equal(run(id,file).transcriptRead.bytes,0);const x=run(other,otherFile);assert.equal(x.sessionId,other);assert.equal(x.usage,undefined);assert.equal(x.events.PreToolUse,3);
});

test('fork retains child identity while accepting declared parent history',t=>{const {file,cache}=fixture(t);fs.writeFileSync(file,row('session_meta',{id,cwd:'/child',forked_from_id:other})+meta(other)+event('task_started')+usage(4));const x=readTranscript(file,id,cache);assert.equal(x.meta.id,id);assert.equal(x.meta.cwd,'/child');assert.equal(x.counts.turnsStarted,1);assert.equal(x.usage.total_token_usage.total_tokens,4);});
test('undeclared foreign header is rejected',t=>{const {file,cache}=fixture(t);fs.writeFileSync(file,meta()+meta(other));assert.throws(()=>readTranscript(file,id,cache),/ID_MISMATCH/);assert.equal(fs.existsSync(cache),false);});
