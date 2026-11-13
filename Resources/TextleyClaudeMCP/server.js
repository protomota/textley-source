'use strict';

// Claude Desktop supplies Node. No package installation, shell command or
// direct file access is needed. Textley enforces every request.
const http = require('node:http');
const readline = require('node:readline');
const maxRequestBytes = 1024 * 1024;
const maxResponseBytes = 4 * 1024 * 1024;
const pending = new Map();
let protocolVersion = '2025-11-25';
let endpoint;
let token = process.env.TEXTLEY_MCP_TOKEN || '';

function respond(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

function failure(id, message, code = -32000) {
  respond({ jsonrpc: '2.0', id, error: { code, message } });
}

try {
  endpoint = new URL(process.env.TEXTLEY_MCP_URL || 'http://127.0.0.1:17327/mcp');
  if (endpoint.protocol !== 'http:' || endpoint.hostname !== '127.0.0.1' || !endpoint.port ||
      endpoint.pathname !== '/mcp' || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    throw new Error('Invalid Textley address');
  }
  if (!/^[a-f0-9]{64}$/i.test(token)) throw new Error('Missing Textley token');
} catch {
  process.stderr.write('Open the Textley extension settings and paste the access token from Textley Settings → Integrations → MCP.\n');
  process.exit(1);
}

const input = readline.createInterface({ input: process.stdin, terminal: false });
input.on('line', line => {
  if (!line.trim()) return;
  if (Buffer.byteLength(line, 'utf8') > maxRequestBytes) {
    failure(null, 'This request is too large for Textley.', -32600);
    return;
  }
  let message;
  try { message = JSON.parse(line); }
  catch { failure(null, 'Invalid JSON request.', -32700); return; }
  if (!message || Array.isArray(message) || message.jsonrpc !== '2.0' || typeof message.method !== 'string') {
    failure(null, 'Invalid MCP request.', -32600);
    return;
  }
  const hasID = Object.hasOwn(message, 'id');
  if (hasID && typeof message.id !== 'string' && typeof message.id !== 'number') {
    failure(null, 'Invalid request identifier.', -32600);
    return;
  }
  if (message.method === 'notifications/cancelled') {
    const active = pending.get(message.params?.requestId);
    if (active) active.destroy(new Error('Cancelled'));
    return;
  }
  if (pending.size >= 32) {
    if (hasID) failure(message.id, 'Textley is handling other requests. Try again shortly.');
    return;
  }
  const body = Buffer.from(JSON.stringify(message), 'utf8');
  const request = http.request(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream',
      Authorization: 'Bearer ' + token,
      'MCP-Protocol-Version': protocolVersion,
      'Content-Length': body.length
    }
  }, response => {
    const chunks = [];
    let bytes = 0;
    response.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > maxResponseBytes) { request.destroy(new Error('Response too large')); return; }
      chunks.push(chunk);
    });
    response.on('end', () => {
      if (!hasID) return;
      if (response.statusCode === 401 || response.statusCode === 403) {
        failure(message.id, 'Textley access needs reconnecting. Copy the current token from Textley Settings → Integrations → MCP into this extension’s settings.');
        return;
      }
      try {
        const result = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (!result || result.jsonrpc !== '2.0' || result.id !== message.id) throw new Error('Invalid response');
        if (message.method === 'initialize' && result.result?.protocolVersion) protocolVersion = result.result.protocolVersion;
        respond(result);
      } catch { failure(message.id, 'Textley returned an unavailable response. Keep Textley open with MCP access enabled and try again.'); }
    });
    response.on('error', () => request.destroy(new Error('Response interrupted')));
  });
  if (hasID) pending.set(message.id, request);
  request.setTimeout(600000, () => request.destroy(new Error('Timed out')));
  request.on('error', () => {
    if (hasID) failure(message.id, 'Open Textley and enable MCP access in Settings → Integrations → MCP, then retry.');
  });
  request.on('close', () => { if (hasID && pending.get(message.id) === request) pending.delete(message.id); });
  request.end(body);
});
input.on('close', () => {
  for (const request of pending.values()) request.destroy();
  token = '';
});
