// 猪猪包 friend relay: pairs two cats with a one-time code and passes small events between paired,
// online cats (presence, status, visits). One Durable Object holds everything; sockets hibernate.
//
// Client connects to wss://zhuzhubao.lynie.cc/ws with headers X-Pet-Id and X-Pet-Key. The first
// connection registers the id with the key's hash; later ones must present the same key.
// Nothing else about the user is stored: an id, a key hash, the name they chose, their pairings,
// invite tokens and daily counters. Visits and greetings are passed on live and never stored.

import { DurableObject } from "cloudflare:workers";

const CODE_TTL = 24 * 3600 * 1000;
const MAX_FRIENDS = 20;
const MAX_USERS = 5000;
const LIMIT = { shrimp: 3, pet: 30, hi: 40, reply: 40, enter: 30 };   // per sender, per friend, per day
const VISIT_ACTS = new Set(["enter", "pet", "shrimp", "hi", "leave"]);
// "peek": the cat is hiding at the screen edge, i.e. resting; nobody can drop by then.
const STATUSES = new Set(["awake", "sleep", "lie", "drink", "eat", "peek"]);
const REDEEM_PER_HOUR = 10;

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === "/health") return new Response("ok");
    const add = url.pathname.match(/^\/add\/([a-z0-9]{10})\/?$/);
    if (add) {
      const info = await env.HUB.get(env.HUB.idFromName("hub")).fetch(new Request("https://hub/info?code=" + add[1]));
      return invitePage(add[1], await info.json(), req.headers.get("User-Agent") ?? "");
    }
    if (url.pathname === "/" ) return Response.redirect("https://github.com/Flitternie/zhuzhubao", 302);
    if (url.pathname !== "/ws") return new Response("猪猪包", { status: 404 });
    if (req.headers.get("Upgrade") !== "websocket") return new Response("websocket only", { status: 426 });
    return env.HUB.get(env.HUB.idFromName("hub")).fetch(req);
  },
};

async function sha256(s) {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
}
// Days are counted in China time, where the users are.
const dayOf = (t) => Math.floor((t + 8 * 3600 * 1000) / 86400000);
const cleanText = (s) => String(s ?? "").replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, "").trim().slice(0, 30);
const cleanName = (s) => String(s ?? "").replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 12);

export class Hub extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, keyhash TEXT NOT NULL, name TEXT NOT NULL DEFAULT '', created INTEGER, seen INTEGER);
      CREATE TABLE IF NOT EXISTS pairs (a TEXT NOT NULL, b TEXT NOT NULL, created INTEGER, PRIMARY KEY (a, b));
      CREATE TABLE IF NOT EXISTS codes (code TEXT PRIMARY KEY, owner TEXT NOT NULL, exp INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS quota (from_id TEXT, to_id TEXT, kind TEXT, day INTEGER, n INTEGER, PRIMARY KEY (from_id, to_id, kind, day));
      CREATE TABLE IF NOT EXISTS attempts (id TEXT, hour INTEGER, n INTEGER, PRIMARY KEY (id, hour));
    `);
    // Keep-alive pings are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/info") {       // for the invite page: who made this code, still good?
      const c = this.one("SELECT owner, exp FROM codes WHERE code = ?", url.searchParams.get("code") ?? "");
      const ok = !!c && c.exp > Date.now();
      return Response.json({ ok, name: ok ? this.nameOf(c.owner) : "" });
    }
    const id = req.headers.get("X-Pet-Id") ?? "";
    const key = req.headers.get("X-Pet-Key") ?? "";
    if (!/^[A-Za-z0-9-]{16,64}$/.test(id) || key.length < 32 || key.length > 128) return new Response("bad id", { status: 400 });
    const hash = await sha256(key);
    const now = Date.now();
    const row = this.one("SELECT keyhash FROM users WHERE id = ?", id);
    if (!row) {
      if (this.one("SELECT COUNT(*) AS c FROM users").c >= MAX_USERS) return new Response("full", { status: 503 });
      this.sql.exec("INSERT INTO users (id, keyhash, created, seen) VALUES (?, ?, ?, ?)", id, hash, now, now);
    } else if (row.keyhash !== hash) {
      return new Response("wrong key", { status: 401 });
    }
    this.sql.exec("UPDATE users SET seen = ? WHERE id = ?", now, id);

    const wasOnline = this.online(id);
    if ((await this.ctx.storage.getAlarm()) == null) await this.ctx.storage.setAlarm(now + 60000);
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, [id]);
    server.serializeAttachment({ id, status: "awake", at: now });
    this.send(server, { t: "hello", you: id, name: this.nameOf(id), friends: this.friendList(id) });
    if (!wasOnline) this.tellFriends(id, { t: "presence", id, online: true, status: "awake" });
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, raw) {
    if (typeof raw !== "string" || raw.length > 2000) return;
    let m;
    try { m = JSON.parse(raw); } catch { return; }
    const me = ws.deserializeAttachment()?.id;
    if (!me) return;
    const now = Date.now();
    switch (m.t) {
      case "status": {
        if (!STATUSES.has(m.s)) return;
        const a = ws.deserializeAttachment();
        if (a.status === m.s) return;
        ws.serializeAttachment({ ...a, status: m.s });
        this.tellFriends(me, { t: "presence", id: me, online: true, status: m.s });
        return;
      }
      case "name": {
        const name = cleanName(m.name);
        if (!name) return;
        this.sql.exec("UPDATE users SET name = ? WHERE id = ?", name, me);
        this.toUser(me, { t: "name", id: me, name, self: true });
        this.tellFriends(me, { t: "name", id: me, name });
        return;
      }
      case "code": {
        this.sql.exec("DELETE FROM codes WHERE owner = ? OR exp < ?", me, now);
        // An invite link token: 10 characters, nothing to type, too many to guess.
        const ABC = "abcdefghjkmnpqrstuvwxyz23456789";
        let code;
        for (let i = 0; i < 20; i++) {
          code = [...crypto.getRandomValues(new Uint8Array(10))].map((b) => ABC[b % ABC.length]).join("");
          if (!this.one("SELECT 1 AS x FROM codes WHERE code = ?", code)) break;
        }
        this.sql.exec("INSERT OR REPLACE INTO codes (code, owner, exp) VALUES (?, ?, ?)", code, me, now + CODE_TTL);
        this.send(ws, { t: "code", code, exp: now + CODE_TTL });
        return;
      }
      case "redeem": {
        const hour = Math.floor(now / 3600000);
        const used = this.one("SELECT n FROM attempts WHERE id = ? AND hour = ?", me, hour)?.n ?? 0;
        if (used >= REDEEM_PER_HOUR) return this.send(ws, { t: "redeem", ok: false, why: "slow" });
        this.sql.exec("INSERT INTO attempts (id, hour, n) VALUES (?, ?, 1) ON CONFLICT (id, hour) DO UPDATE SET n = n + 1", me, hour);
        this.sql.exec("DELETE FROM attempts WHERE hour < ?", hour - 1);
        const code = String(m.code ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
        const c = this.one("SELECT owner, exp FROM codes WHERE code = ?", code);
        if (!c || c.exp < now) return this.send(ws, { t: "redeem", ok: false, why: "bad" });
        if (c.owner === me) return this.send(ws, { t: "redeem", ok: false, why: "self" });
        if (this.isPaired(me, c.owner)) {
          this.sql.exec("DELETE FROM codes WHERE code = ?", code);
          return this.send(ws, { t: "redeem", ok: false, why: "already", friend: this.friendInfo(c.owner) });
        }
        for (const u of [me, c.owner]) {
          if (this.one("SELECT COUNT(*) AS c FROM pairs WHERE a = ?", u).c >= MAX_FRIENDS) return this.send(ws, { t: "redeem", ok: false, why: "full" });
        }
        this.sql.exec("DELETE FROM codes WHERE code = ?", code);
        this.sql.exec("INSERT OR IGNORE INTO pairs (a, b, created) VALUES (?, ?, ?), (?, ?, ?)", me, c.owner, now, c.owner, me, now);
        this.send(ws, { t: "redeem", ok: true });
        this.toUser(me, { t: "paired", friend: this.friendInfo(c.owner) });
        this.toUser(c.owner, { t: "paired", friend: this.friendInfo(me) });
        return;
      }
      case "visit": {
        // A friend "drops by": their pixel hand appears by your cat and pets it, drops a shrimp, says hi.
        const to = String(m.to ?? "");
        const act = m.act;
        if (!VISIT_ACTS.has(act) || !this.isPaired(me, to)) return this.send(ws, { t: "visited", to, act, ok: false, why: "nofriend" });
        if (!this.online(to)) return this.send(ws, { t: "visited", to, act, ok: false, why: "offline" });
        if (act !== "leave" && this.statusOf(to) === "peek") return this.send(ws, { t: "visited", to, act, ok: false, why: "rest" });
        if (act in LIMIT && !this.count(me, to, act, now)) return this.send(ws, { t: "visited", to, act, ok: false, why: "quota" });
        const out = { t: "visit", from: me, act };
        if (act === "hi") out.text = cleanText(m.text);
        this.toUser(to, out);
        return this.send(ws, { t: "visited", to, act, ok: true });
      }
      case "reply": {
        const to = String(m.to ?? "");
        const text = cleanText(m.text);
        if (!text || !this.isPaired(me, to) || !this.online(to)) return this.send(ws, { t: "replied", to, ok: false });
        if (!this.count(me, to, "reply", now)) return this.send(ws, { t: "replied", to, ok: false, why: "quota" });
        this.toUser(to, { t: "reply", from: me, text });
        return this.send(ws, { t: "replied", to, ok: true });
      }
      case "unpair": {
        const other = String(m.id ?? "");
        this.sql.exec("DELETE FROM pairs WHERE (a = ? AND b = ?) OR (a = ? AND b = ?)", me, other, other, me);
        this.toUser(me, { t: "unpaired", id: other });
        this.toUser(other, { t: "unpaired", id: me });
        return;
      }
    }
  }

  async webSocketClose(ws, code) { this.left(ws); try { ws.close(code === 1005 ? 1000 : code, "bye"); } catch {} }
  async webSocketError(ws) { this.left(ws); }

  left(ws) {
    const me = ws.deserializeAttachment()?.id;
    if (!me) return;
    const still = this.sockets(me).some((s) => s !== ws);
    if (!still) {
      this.sql.exec("UPDATE users SET seen = ? WHERE id = ?", Date.now(), me);
      this.tellFriends(me, { t: "presence", id: me, online: false });
    }
  }

  // helpers
  /** Counts one action toward today's limit; false when the limit is reached. */
  count(from, to, kind, now) {
    const day = dayOf(now);
    const n = this.one("SELECT n FROM quota WHERE from_id = ? AND to_id = ? AND kind = ? AND day = ?", from, to, kind, day)?.n ?? 0;
    if (n >= LIMIT[kind]) return false;
    this.sql.exec("INSERT INTO quota (from_id, to_id, kind, day, n) VALUES (?, ?, ?, ?, 1) ON CONFLICT DO UPDATE SET n = n + 1", from, to, kind, day);
    this.sql.exec("DELETE FROM quota WHERE day < ?", day - 1);
    return true;
  }
  one(q, ...a) { return this.sql.exec(q, ...a).toArray()[0]; }
  all(q, ...a) { return this.sql.exec(q, ...a).toArray(); }
  nameOf(id) { return this.one("SELECT name FROM users WHERE id = ?", id)?.name ?? ""; }
  isPaired(a, b) { return !!this.one("SELECT 1 AS x FROM pairs WHERE a = ? AND b = ?", a, b); }
  /** Open sockets that are still alive: the app pings every few seconds, so one that has been quiet
   *  for 90 s belongs to a Mac that went to sleep or lost its network without closing. */
  sockets(id) {
    const now = Date.now();
    return this.ctx.getWebSockets(id).filter((s) => {
      if (s.readyState !== WebSocket.OPEN) return false;
      const last = Math.max(this.ctx.getWebSocketAutoResponseTimestamp(s)?.getTime() ?? 0, s.deserializeAttachment()?.at ?? 0);
      return now - last < 90000;
    });
  }

  /** Once a minute while anyone is connected: close sockets that went quiet and tell friends. */
  async alarm() {
    const now = Date.now();
    const all = this.ctx.getWebSockets();
    for (const s of all) {
      const last = Math.max(this.ctx.getWebSocketAutoResponseTimestamp(s)?.getTime() ?? 0, s.deserializeAttachment()?.at ?? 0);
      if (s.readyState === WebSocket.OPEN && now - last >= 90000) {
        try { s.close(1001, "stale"); } catch {}
        this.left(s);
      }
    }
    if (this.ctx.getWebSockets().some((s) => s.readyState === WebSocket.OPEN)) await this.ctx.storage.setAlarm(now + 60000);
  }
  online(id) { return this.sockets(id).length > 0; }
  statusOf(id) { return this.sockets(id)[0]?.deserializeAttachment()?.status ?? "awake"; }
  friendInfo(id) { const on = this.online(id); return { id, name: this.nameOf(id), online: on, status: on ? this.statusOf(id) : null }; }
  friendList(id) { return this.all("SELECT b FROM pairs WHERE a = ? ORDER BY created", id).map((r) => this.friendInfo(r.b)); }
  send(ws, m) { try { ws.send(JSON.stringify(m)); return true; } catch { return false; } }
  toUser(id, m) { let ok = false; for (const s of this.sockets(id)) ok = this.send(s, m) || ok; return ok; }
  tellFriends(id, m) { for (const r of this.all("SELECT b FROM pairs WHERE a = ?", id)) this.toUser(r.b, m); }
}

// MARK: the invite page (https://zhuzhubao.lynie.cc/add/<token>): opens the app with zhuzhubao://add/<token>

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const DOWNLOAD = "https://github.com/Flitternie/zhuzhubao/releases/latest";

function invitePage(code, info, ua) {
  const name = info.name || "朋友";
  const open = `zhuzhubao://add/${code}?from=${encodeURIComponent(info.name || "")}`;
  const wechat = /MicroMessenger/i.test(ua);
  const phone = /iPhone|iPad|Android|Mobile/i.test(ua) && !/Macintosh/i.test(ua);
  let note = "";
  if (wechat) note = `<p class="note">微信里打不开猪猪包：点右上角「···」，选「在默认浏览器中打开」。</p>`;
  else if (phone) note = `<p class="note">猪猪包是 Mac 上的桌宠，请在 Mac 电脑上打开这个链接。</p>`;
  const body = info.ok ? `
    <div class="bubble">${esc(name)} 邀请你做小咪好友！</div>
    <img class="cat" src="/cat.png" alt="猪猪包" width="128" height="128">
    ${note}
    <a class="btn" id="open" href="${esc(open)}">打开猪猪包，加好友</a>
    <p class="small">点了以后猪猪包会问你要不要加，<br>点「好呀」就加上啦。</p>
    <p class="small">还没有猪猪包？<a href="${DOWNLOAD}">下载 Mac 版</a><br>装好打开后，再点一次上面的按钮。</p>` : `
    <div class="bubble">这个邀请链接用过或过期啦</div>
    <img class="cat" src="/cat.png" alt="猪猪包" width="128" height="128">
    <p class="small">请好友在猪猪包菜单 →「小咪好友」<br>→「添加小咪好友」，再发一个新的链接给你。</p>
    <p class="small">还没有猪猪包？<a href="${DOWNLOAD}">下载 Mac 版</a></p>`;
  const auto = info.ok && !wechat && !phone ? `<script>setTimeout(function(){location.href=${JSON.stringify(open)}},400)</script>` : "";
  const html = `<!doctype html><html lang="zh-Hans"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>小咪好友邀请 · 猪猪包</title>
<style>
@font-face{font-family:"Fusion Pixel";src:url(/pixel.woff2) format("woff2");font-display:swap}
:root{--ink:#403c42;--paper:#fff;--bg:#f6f1e7;--shade:#dcd9e0;--accent:#e8a0a8}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:var(--bg);color:var(--ink);
  font-family:"Fusion Pixel",-apple-system,"PingFang SC",sans-serif;padding:24px 16px}
main{max-width:420px;width:100%;display:flex;flex-direction:column;align-items:center;text-align:center}
.bubble{position:relative;background:var(--paper);font-size:24px;line-height:1.3;padding:12px 18px;margin-bottom:14px;
  box-shadow:0 -3px 0 0 var(--ink),0 3px 0 0 var(--ink),-3px 0 0 0 var(--ink),3px 0 0 0 var(--ink),inset -3px -3px 0 0 var(--shade)}
.bubble:after{content:"";position:absolute;left:50%;bottom:-12px;margin-left:-6px;width:12px;height:9px;background:var(--paper);
  clip-path:polygon(0 0,100% 0,50% 100%);filter:drop-shadow(0 3px 0 var(--ink))}
.cat{width:256px;height:256px;max-width:70vw;max-height:70vw;image-rendering:pixelated;margin:4px 0 10px}
.btn{display:inline-block;font:inherit;font-size:22px;color:var(--ink);text-decoration:none;background:#eeeef2;padding:12px 22px;margin:6px 0 14px;
  box-shadow:0 -3px 0 0 var(--ink),0 3px 0 0 var(--ink),-3px 0 0 0 var(--ink),3px 0 0 0 var(--ink),inset -3px -3px 0 0 var(--shade)}
.btn:hover{background:#dcdce4}.btn:active{transform:translateY(2px)}
.code{font-size:20px;margin:4px 0 12px}.code b{letter-spacing:2px;font-weight:normal;background:var(--paper);padding:2px 8px}
.small{font-size:15px;line-height:1.6;opacity:.85;margin:6px 0;text-wrap:balance;word-break:keep-all}
.small a{color:var(--ink)}
.note{font-size:16px;background:#fff4d6;padding:8px 12px;margin:0 0 10px;text-wrap:balance}
.bubble,.btn{text-wrap:balance}
</style></head><body><main>${body}</main>${auto}</body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}
