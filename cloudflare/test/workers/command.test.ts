// POST /command の統合テスト（design.md §5.5）
import { SELF, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const CMD_URL = "https://example.com/command";
const WS_URL = "https://example.com/device/ws";
const good = { power: true, mode: "cool", temp: 26, fan: "auto", vane: "middle" };

// token: 省略で APP_TOKEN、null で Authorization ヘッダなし
function post(body: unknown, token: string | null = env.APP_TOKEN, raw = false): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (token !== null) headers.Authorization = `Bearer ${token}`;
  return SELF.fetch(CMD_URL, { method: "POST", headers, body: raw ? (body as string) : JSON.stringify(body) });
}

async function connectDevice(): Promise<WebSocket> {
  const res = await SELF.fetch(WS_URL, { headers: { Upgrade: "websocket", Authorization: `Bearer ${env.DEVICE_TOKEN}` } });
  expect(res.status).toBe(101);
  const ws = res.webSocket!;
  ws.accept();
  return ws;
}

describe("POST /command", () => {
  it("APP_TOKEN が無い・違う・DEVICE_TOKEN では 401", async () => {
    expect((await post(good, null)).status).toBe(401);
    expect((await post(good, "wrong")).status).toBe(401);
    expect((await post(good, env.DEVICE_TOKEN)).status).toBe(401);
  });

  it("不正な設定と壊れた JSON は 400", async () => {
    expect((await post({ ...good, temp: 40 })).status).toBe(400);
    expect((await post({ ...good, fan: "4" })).status).toBe(400);
    expect((await post({})).status).toBe(400);
    expect((await post("{not json", env.APP_TOKEN, true)).status).toBe(400);
  });

  it("GET は 405", async () => {
    expect((await SELF.fetch(CMD_URL, { headers: { Authorization: `Bearer ${env.APP_TOKEN}` } })).status).toBe(405);
  });

  it("device が接続していれば 202 と 36文字が届く。切断後は 503", async () => {
    const ws = await connectDevice();
    const received = new Promise<string>((resolve) => ws.addEventListener("message", (ev) => resolve(String(ev.data))));

    const res = await post(good);
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ ok: true });
    expect(await received).toBe("23CB26010020180A365800000000001000F5");

    ws.close(1000, "test done");
    // close が DO 側へ伝わるのを待つ
    await new Promise((r) => setTimeout(r, 100));
    const offline = await post(good);
    expect(offline.status).toBe(503);
    expect(await offline.json()).toEqual({ error: "device_offline" });
  });

  // 2026-11-12 の障害の再現: ESP32 が古い接続を捨てて再接続すると、古い接続は close の応答が来ないまま
  // getWebSockets() に残る。その間も新しい接続へ送れること
  it("閉じきらない古い接続が残っていても、新しい接続へ送る", async () => {
    // 古い接続: accept しない（相手が読まない）ので、DO からの close に応答が返らず閉じきらない
    const stale = await SELF.fetch(WS_URL, { headers: { Upgrade: "websocket", Authorization: `Bearer ${env.DEVICE_TOKEN}` } });
    expect(stale.status).toBe(101);

    const ws = await connectDevice();
    const received = new Promise<string>((resolve) => ws.addEventListener("message", (ev) => resolve(String(ev.data))));

    for (let i = 0; i < 3; i++) {
      const res = await post(good);
      expect(res.status).toBe(202);
    }
    expect(await received).toBe("23CB26010020180A365800000000001000F5");
    ws.close(1000, "test done");
    // 後片付け: 古い接続も読み始めて閉じる（残すとテストの実行が終わらない）
    stale.webSocket!.accept();
    stale.webSocket!.close(1000, "test done");
  });
});
