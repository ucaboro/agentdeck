// AgentDeck Bridge
//
// Lets AgentDeck (a local macOS app) drive Cursor's agent chats through three links:
//
//   cursor://agentdeck.agentdeck-bridge/open?chat=<id>
//       Show that chat (Cursor's own `composer.openComposer`).
//   cursor://agentdeck.agentdeck-bridge/decide?chat=<id>&decision=accept|reject&token=<t>
//       Accept or reject what that chat is waiting on (the same commands as the buttons on
//       Cursor's own "needs approval" notifications).
//   cursor://agentdeck.agentdeck-bridge/new?prompt=<text>&mode=agent|plan|chat&token=<t>
//       Start a new chat in this window and submit the prompt.
//
// `decide` and `new` act on your behalf, so they require a token that only AgentDeck knows: a random
// value AgentDeck writes to ~/Library/Application Support/AgentDeck/bridge-token (mode 0600). A web page
// or another app that guesses the link format cannot use them. `open` only changes what is shown.
// No network access; the only file read is that token.
const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const CHAT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN_FILE = path.join(os.homedir(), 'Library', 'Application Support', 'AgentDeck', 'bridge-token');
const MODES = new Set(['agent', 'plan', 'chat']);
const MAX_PROMPT = 20000;

// Visible in Cursor: Output panel → "AgentDeck Bridge". Never logs the token or the prompt text.
let log = { info() {}, warn() {} };

function tokenOK(given) {
  let expected;
  try { expected = fs.readFileSync(TOKEN_FILE, 'utf8').trim(); } catch { return false; }
  if (!expected || typeof given !== 'string' || given.length !== expected.length) return false;
  return crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected));
}

async function has(cmd) {
  return (await vscode.commands.getCommands(true)).includes(cmd);
}

async function run(cmd, ...args) {
  if (!(await has(cmd))) { log.warn(`command not available in this Cursor version: ${cmd}`); return false; }
  log.info(`running ${cmd}`);
  try { await vscode.commands.executeCommand(cmd, ...args); return true; }
  catch (err) { log.warn(`${cmd} failed: ${err && err.message ? err.message : err}`); return false; }
}

async function openChat(id) {
  return (await run('composer.openComposer', id)) || (await run('glass.openAgentById', id));
}

async function decide(id, decision) {
  // Cursor's accept/reject commands act on a chat that is loaded in this window, so show it first.
  await openChat(id);
  const cmd = decision === 'accept' ? 'composer.acceptPendingFromNotification' : 'composer.rejectPendingFromNotification';
  return run(cmd, id);
}

async function newChat(prompt, mode) {
  return run('composer.createNew', { partialState: { text: prompt }, autoSubmit: true, unifiedMode: mode });
}

// Cursor delivers extension links to the most recently active window, which may be a different project.
// Links carry the target `folder`; if it isn't open here, focus that folder's window and pass the link on once.
function servesFolder(folder) {
  const want = path.resolve(folder);
  return (vscode.workspace.workspaceFolders || []).some((f) => {
    const have = path.resolve(f.uri.fsPath);
    return want === have || want.startsWith(have + path.sep);
  });
}

async function forwardIfElsewhere(uri, q) {
  const folder = q.get('folder');
  if (!folder || servesFolder(folder)) return false;
  if (q.get('hop')) {
    log.warn(`link for ${folder} arrived here again after forwarding; handling it in this window`);
    return false;
  }
  log.info(`link is for ${folder}, not this window; focusing that window and forwarding`);
  await vscode.commands.executeCommand('vscode.openFolder', vscode.Uri.file(folder), { forceNewWindow: false, forceReuseWindow: false });
  await new Promise((r) => setTimeout(r, 1200));
  await vscode.env.openExternal(uri.with({ query: uri.query + '&hop=1' }));
  return true;
}

function activate(context) {
  log = vscode.window.createOutputChannel('AgentDeck Bridge', { log: true });
  context.subscriptions.push(log);
  const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath).join(', ') || '(no folder)';
  log.info(`AgentDeck Bridge ${context.extension.packageJSON.version} active in window for ${folders}`);
  context.subscriptions.push(
    vscode.window.registerUriHandler({
      async handleUri(uri) {
        const q = new URLSearchParams(uri.query);
        log.info(`received ${uri.path} folder=${q.get('folder') || '-'} chat=${q.get('chat') || '-'} mode=${q.get('mode') || '-'} prompt=${(q.get('prompt') || '').length} chars token=${q.get('token') ? (tokenOK(q.get('token')) ? 'valid' : 'INVALID') : 'none'}${q.get('hop') ? ' (forwarded)' : ''}`);
        if (await forwardIfElsewhere(uri, q)) return;
        switch (uri.path) {
          case '/open': {
            const id = q.get('chat') || '';
            if (!CHAT_ID.test(id)) return vscode.window.showWarningMessage('AgentDeck: that chat link is not valid.');
            if (!(await openChat(id))) vscode.window.showWarningMessage('AgentDeck could not open that chat. It may belong to a different Cursor window.');
            return;
          }
          case '/decide': {
            const id = q.get('chat') || '';
            const decision = q.get('decision');
            if (!tokenOK(q.get('token'))) return vscode.window.showWarningMessage('AgentDeck: ignored an approval link that was not sent by AgentDeck.');
            if (!CHAT_ID.test(id) || (decision !== 'accept' && decision !== 'reject')) return vscode.window.showWarningMessage('AgentDeck: that approval link is not valid.');
            if (!(await decide(id, decision))) vscode.window.showWarningMessage('AgentDeck could not apply that decision. Open the chat in Cursor to respond.');
            return;
          }
          case '/new': {
            if (!tokenOK(q.get('token'))) return vscode.window.showWarningMessage('AgentDeck: ignored a new-chat link that was not sent by AgentDeck.');
            const prompt = (q.get('prompt') || '').slice(0, MAX_PROMPT);
            const mode = MODES.has(q.get('mode')) ? q.get('mode') : 'agent';
            if (!prompt.trim()) return vscode.window.showWarningMessage('AgentDeck: the new chat had no prompt.');
            if (!(await newChat(prompt, mode))) vscode.window.showWarningMessage('AgentDeck could not start a chat in this window.');
            return;
          }
          default:
            log.warn(`unknown link ${uri.path}`);
        }
      },
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
