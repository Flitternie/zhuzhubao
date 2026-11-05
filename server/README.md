# 猪猪包朋友中转服务器

Cloudflare Worker + 一个 Durable Object（SQLite），部署在 `zhuzhubao.lynie.cc`。只负责配对和实时转发串门的事件，没有账号。

- 邀请页：`/add/<10 位码>` 显示谁邀请你，并用 `zhuzhubao://add/<码>?from=<名字>` 拉起应用；`public/` 里是页面用的像素字体子集（Fusion Pixel，OFL）和猫图。改了页面文字要重新生成字体子集（pyftsubset）。

- 连接：WebSocket，请求头 `X-Pet-Id`（随机 id）和 `X-Pet-Key`（随机密钥，服务器只存它的 SHA-256）。第一次连接即注册。
- 客户端消息：`name`、`status`（awake / sleep / lie / drink / eat / peek）、`code`（要一个 24 小时有效、一次性的 10 位邀请码）、`redeem`、`visit`（enter / pet / shrimp / hi / leave）、`reply`、`unpair`；文本 `ping` 由运行时自动回 `pong`，不会唤醒对象。
- 规则：对方不在线或在休息（peek）时串门会被拒绝；每天按北京时间计数的上限见 `src/index.js` 的 `LIMIT`；兑换邀请码每小时最多 10 次。
- 存储：users（id、密钥哈希、名字）、pairs、codes、quota、attempts。串门和招呼不存。

```sh
npx wrangler dev --port 8799   # 本地
npx wrangler deploy            # 上线
```
