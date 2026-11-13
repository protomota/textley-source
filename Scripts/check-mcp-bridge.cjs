'use strict';

// Adapted from Jotley’s bridge check. Use a disposable Textley vault for verification.
const { spawn } = require('node:child_process');
const readline = require('node:readline');
const assert = require('node:assert/strict');

const native = process.env.TEXTLEY_NATIVE_BRIDGE_BINARY;
const script = process.env.TEXTLEY_BRIDGE_SCRIPT;
assert.ok(native || script, 'Choose the native binary or the Claude extension bridge');
const bridge = spawn(native || process.execPath, native ? ['--mcp-stdio'] : [script], {
  env: process.env,
  stdio: ['pipe', 'pipe', 'pipe']
});
const pending = new Map();
let nextID = 0;
let hadDiagnostics = false;
bridge.stderr.on('data', () => { hadDiagnostics = true; });
readline.createInterface({ input: bridge.stdout }).on('line', line => {
  const message = JSON.parse(line);
  const request = pending.get(message.id);
  assert.ok(request, 'Unexpected or duplicate response');
  pending.delete(message.id);
  clearTimeout(request.timer);
  if (message.error) request.reject(new Error(message.error.message));
  else request.resolve(message.result);
});
bridge.on('exit', () => {
  for (const request of pending.values()) {
    clearTimeout(request.timer);
    request.reject(new Error('Bridge exited before responding'));
  }
});

function call(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++nextID;
    const timer = setTimeout(() => reject(new Error('Bridge request timed out')), 15000);
    pending.set(id, { resolve, reject, timer });
    bridge.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}

function tool(name, args) { return call('tools/call', { name, arguments: args }); }

function json(result) {
  assert.notEqual(result.isError, true, 'Tool failed');
  return JSON.parse(result.content.filter(item => item.type === 'text').map(item => item.text).join('\n'));
}

async function main() {
  const initialized = await call('initialize', {
    protocolVersion: '2025-11-25',
    capabilities: { experimental: { 'codex/auth-change': {} } },
    clientInfo: { name: 'Textley packaged bridge test', version: '1.0.0' }
  });
  assert.equal(initialized.serverInfo.name, 'Textley');
  assert.match(initialized.instructions, /Codex/);
  bridge.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const discovery = await call('tools/list', {});
  assert.equal(discovery.tools.length, 27);
  const vaults = json(await tool('list_vaults', {})).vaults;
  const selected = vaults.find(item => item.name === process.env.TEXTLEY_BRIDGE_VAULT);
  assert.ok(selected, 'Disposable vault is missing');
  const sample = json(await tool('read_file', {
    vault_id: selected.id,
    path: process.env.TEXTLEY_BRIDGE_FILE
  }));
  assert.ok(sample.text.includes(process.env.TEXTLEY_BRIDGE_TEXT));
  const denied = await tool('new_document', {});
  assert.equal(denied.isError, true);
  assert.equal(hadDiagnostics, false, 'Bridge reported diagnostics');
  console.log((native ? 'Native STDIO' : 'Claude chat extension') + ': 27 tools, read and read-only guard verified.');
}

main().catch(error => { console.error(error.message); process.exitCode = 1; }).finally(() => {
  bridge.stdin.end();
  bridge.kill();
});
