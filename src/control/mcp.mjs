// autoDev — the Control API over MCP (stdio), for the bootstrap Marj: a Claude Code
// session with this server registered IS Marj (PRD §32–34), and Claude Remote
// Control steers that same session (§33). Zero dependencies: JSON-RPC 2.0, one
// message per line, the subset of MCP every client uses (initialize, tools/list,
// tools/call, ping). The controller contract is delivered as the server's
// `instructions`, so no Marj file is ever written into a repository.
//
//   autodev mcp            serve on stdio for the current repo
//   autodev marj enable    (= claude mcp add --scope local autodev -- autodev mcp: this repo only)

import { createInterface } from 'node:readline';
import { ControlSession, OPERATIONS, attentionAcrossProjects } from './api.mjs';
import { controllerContract } from '../controller/controller.mjs';

const PROTOCOL = '2024-11-05';

function schemaFor(op) {
  const d = OPERATIONS[op];
  const props = Object.fromEntries(Object.entries(d.params).map(([k, v]) => [k, { type: k === 'bug' ? 'boolean' : 'string', description: v }]));
  return { type: 'object', properties: props, required: Object.entries(d.params).filter(([, v]) => /^required/.test(v)).map(([k]) => k), additionalProperties: false };
}

export function toolList() {
  const tools = Object.entries(OPERATIONS).map(([op, d]) => ({ name: op, description: d.description + (d.reads ? ' (read-only)' : ' (ACTION — autoDev validates it)'), inputSchema: schemaFor(op) }));
  tools.push({ name: 'attention_across_projects', description: 'Every registered project on this machine: what awaits a human, what is in flight, the next action. Read-only; never changes state.', inputSchema: { type: 'object', properties: {}, additionalProperties: false } });
  tools.push({ name: 'capabilities', description: 'The operations this session may perform.', inputSchema: { type: 'object', properties: {}, additionalProperties: false } });
  return tools;
}

export async function handle(msg, session, { name = 'Marj', user = 'the developer', version = '0' } = {}) {
  const reply = (result) => ({ jsonrpc: '2.0', id: msg.id, result });
  const error = (code, message) => ({ jsonrpc: '2.0', id: msg.id, error: { code, message } });
  switch (msg.method) {
    case 'initialize':
      return reply({ protocolVersion: PROTOCOL, capabilities: { tools: { listChanged: false } }, serverInfo: { name: 'autodev-control', version }, instructions: `autoDev controller (${name}). When ${user} talks about autoDev work — status, requirements, stories, gates, approvals, reviews, verification, executors, pausing, what needs attention — you act as ${name} under the contract below and use ONLY these tools for it. Ordinary coding, questions, and edits in this session stay normal Claude Code; the contract does not stop you from writing code the user asks you to write directly.\n\n${controllerContract({ name, user })}\n\nThis MCP server IS the autoDev Control API. Every tool call is validated and recorded by autoDev; read tools never change state.` });
    case 'notifications/initialized': return null;
    case 'ping': return reply({});
    case 'tools/list': return reply({ tools: toolList() });
    case 'tools/call': {
      const { name: tool, arguments: args = {} } = msg.params || {};
      if (tool === 'capabilities') return reply({ content: [{ type: 'text', text: JSON.stringify({ operations: session.capabilities() }) }] });
      if (tool === 'attention_across_projects') { const r = await attentionAcrossProjects(); return reply({ content: [{ type: 'text', text: JSON.stringify(r) }] }); }
      if (!OPERATIONS[tool]) return reply({ content: [{ type: 'text', text: JSON.stringify({ ok: false, error: { code: 'unknown_op', message: `unknown tool ${tool}` } }) }], isError: true });
      const r = await session.call(tool, args);
      return reply({ content: [{ type: 'text', text: JSON.stringify(r) }], ...(r.ok ? {} : { isError: true }) });
    }
    default:
      if (msg.id === undefined) return null;   // unknown notification
      return error(-32601, `method not found: ${msg.method}`);
  }
}

export async function serveStdio({ cwd = process.cwd(), actor, name, user, version, input = process.stdin, output = process.stdout } = {}) {
  const session = new ControlSession({ cwd, actor: actor || { kind: 'controller', name: name || 'Marj', provider: 'mcp' } });
  const rl = createInterface({ input, crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.trim()) continue;
    let msg; try { msg = JSON.parse(line); } catch { output.write(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }) + '\n'); continue; }
    let res;
    try { res = await handle(msg, session, { name, user, version }); }
    catch (e) { res = msg.id === undefined ? null : { jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: e.message } }; }
    if (res) output.write(JSON.stringify(res) + '\n');
  }
}
