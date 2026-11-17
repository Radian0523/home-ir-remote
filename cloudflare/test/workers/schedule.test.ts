// /schedule と Alarm の統合テスト（design.md §5.2、§5.5、§10）
import { SELF, env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

const URL_ = "https://example.com/schedule";
const WS_URL = "https://example.com/device/ws";
const good = { power: true, mode: "cool", temp: 26, fan: "auto", vane: "middle" };
const EXPECTED_PAYLOAD = "23CB26010020180A365800000000001000F5";

function futureIso(seconds: number): string {
  return new Date(Date.now() + seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function auth(token: string = env.APP_TOKEN): Record<string, string> {
  return { Authorization: `Bearer ${token}`, "content-type": "application/json" };
}

async function post(body: unknown): Promise<Response> {
  return SELF.fetch(URL_, { method: "POST", headers: auth(), body: JSON.stringify(body) });
}

async function delOne(id: string): Promise<Response> {
  return SELF.fetch(`${URL_}/${id}`, { method: "DELETE", headers: auth() });
}

/** GET の結果から id を除いた形（id は毎回変わるため） */
async function listWithoutIds(): Promise<unknown[]> {
  const list = (await (await get()).json()) as { id: string }[];
  return list.map(({ id: _id, ...rest }) => rest);
}

async function get(): Promise<Response> {
  return SELF.fetch(URL_, { headers: auth() });
}

async function del(): Promise<Response> {
  return SELF.fetch(URL_, { method: "DELETE", headers: auth() });
}

function stub() {
  return env.HOME.get(env.HOME.idFromName("home"));
}

/** 一番早い予約の時刻を過去へずらし、発火時刻が来た状態にする（実時間で待つと Alarm が勝手に走るため） */
async function makeFirstDue(): Promise<void> {
  await runInDurableObject(stub(), async (_i, state) => {
    const list = (await state.storage.get<{ executeAt: string }[]>("schedules"))!;
    list[0]!.executeAt = new Date(Date.now() - 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
    await state.storage.put("schedules", list);
  });
}

async function connectDevice(): Promise<WebSocket> {
  const res = await SELF.fetch(WS_URL, { headers: { Upgrade: "websocket", Authorization: `Bearer ${env.DEVICE_TOKEN}` } });
  const ws = res.webSocket!;
  ws.accept();
  return ws;
}

describe("/schedule", () => {
  beforeEach(async () => {
    await del();
  });

  it("APP_TOKEN が無ければ全メソッド 401", async () => {
    for (const method of ["GET", "POST", "DELETE"]) {
      const res = await SELF.fetch(URL_, { method, headers: { "content-type": "application/json" }, body: method === "POST" ? "{}" : undefined });
      expect(res.status, method).toBe(401);
    }
    expect((await SELF.fetch(`${URL_}/x`, { method: "DELETE" })).status).toBe(401);
  });

  it("予約がなければ GET は 200 の空配列", async () => {
    const res = await get();
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual([]);
  });

  it("POST は予約を作り id を付けて返す。GET は payload を含まない", async () => {
    const executeAt = futureIso(3600);
    const res = await post({ executeAt, setting: good });
    expect(res.status).toBe(200);
    const created = (await res.json()) as { id: string };
    expect(created).toEqual({ id: expect.any(String), executeAt, setting: good });

    const shown = await (await get()).json();
    expect(shown).toEqual([created]);
    expect(JSON.stringify(shown)).not.toContain(EXPECTED_PAYLOAD);
  });

  it("不正な body は 400 で、予約は増えない", async () => {
    const executeAt = futureIso(3600);
    await post({ executeAt, setting: good });

    for (const bad of ["2020-01-01T00:00:00Z", futureIso(3600).replace("Z", ".000Z"), "2027-02-30T10:00:00Z", futureIso(3600).replace("Z", "+09:00"), 123, undefined]) {
      const res = await post({ executeAt: bad, setting: good });
      expect(res.status, String(bad)).toBe(400);
    }
    expect((await post({ executeAt: futureIso(60), setting: { ...good, temp: 99 } })).status).toBe(400);
    expect((await SELF.fetch(URL_, { method: "POST", headers: auth(), body: "{oops" })).status).toBe(400);

    expect(await listWithoutIds()).toEqual([{ executeAt, setting: good }]);
  });

  it("2件まで持てて早い順に返す。3件目は 409 で、既存の予約は変わらない", async () => {
    const later = futureIso(7200);
    const sooner = futureIso(600);
    expect((await post({ executeAt: later, setting: good })).status).toBe(200);
    expect((await post({ executeAt: sooner, setting: { ...good, power: false } })).status).toBe(200);

    const third = await post({ executeAt: futureIso(900), setting: good });
    expect(third.status).toBe(409);
    expect(await third.json()).toEqual({ error: "schedule_full" });

    expect(await listWithoutIds()).toEqual([
      { executeAt: sooner, setting: { ...good, power: false } },
      { executeAt: later, setting: good },
    ]);
  });

  it("DELETE /schedule/{id} は1件だけ消し、Alarm は残りに合わせる", async () => {
    const a = (await (await post({ executeAt: futureIso(600), setting: good })).json()) as { id: string };
    const bExecuteAt = futureIso(7200);
    await post({ executeAt: bExecuteAt, setting: good });

    expect((await delOne(a.id)).status).toBe(200);
    expect(await listWithoutIds()).toEqual([{ executeAt: bExecuteAt, setting: good }]);
    const alarm = await runInDurableObject(stub(), (_i, state) => state.storage.getAlarm());
    expect(alarm).toBe(Date.parse(bExecuteAt));

    // 無い id はエラーにしない
    expect((await delOne("nope")).status).toBe(200);
    expect((await SELF.fetch(`${URL_}/${a.id}`, { method: "GET", headers: auth() })).status).toBe(405);
  });

  it("DELETE は全予約と Alarm を消し、Alarm は発火しない", async () => {
    await post({ executeAt: futureIso(3600), setting: good });
    await post({ executeAt: futureIso(7200), setting: good });
    expect((await del()).status).toBe(200);
    expect(await (await get()).json()).toEqual([]);
    expect(await runDurableObjectAlarm(stub())).toBe(false);
  });

  it("1件目が発火すると payload を1回送り、Alarm は2件目に張り直す。再発火しても二重送信しない", async () => {
    const ws = await connectDevice();
    const received: string[] = [];
    ws.addEventListener("message", (ev) => received.push(String(ev.data)));

    const second = futureIso(7200);
    await post({ executeAt: futureIso(600), setting: good });
    await post({ executeAt: second, setting: { ...good, power: false } });
    await makeFirstDue();

    expect(await runDurableObjectAlarm(stub())).toBe(true);
    await new Promise((r) => setTimeout(r, 50));
    expect(received).toEqual([EXPECTED_PAYLOAD]);
    expect(await listWithoutIds()).toEqual([{ executeAt: second, setting: { ...good, power: false } }]);
    expect(await runInDurableObject(stub(), (_i, state) => state.storage.getAlarm())).toBe(Date.parse(second));

    // 時刻前に Alarm が呼ばれても何も送らず、2件目は残る
    await runInDurableObject(stub(), (instance) => instance.alarm());
    await new Promise((r) => setTimeout(r, 50));
    expect(received).toEqual([EXPECTED_PAYLOAD]);
    expect((await listWithoutIds()).length).toBe(1);
    ws.close(1000, "done");
  });

  it("device 未接続で発火すると予約は消え、例外にならない", async () => {
    await post({ executeAt: futureIso(600), setting: good });
    await makeFirstDue();
    await expect(runDurableObjectAlarm(stub())).resolves.toBe(true);
    expect(await (await get()).json()).toEqual([]);
  });

  it("1件だけ持っていた頃の予約も一覧に出て、取り消せる", async () => {
    const executeAt = futureIso(3600);
    await runInDurableObject(stub(), async (_i, state) => {
      await state.storage.put("schedule", { executeAt, setting: good, payload: EXPECTED_PAYLOAD });
    });
    expect(await (await get()).json()).toEqual([{ id: "legacy", executeAt, setting: good }]);
    expect((await delOne("legacy")).status).toBe(200);
    expect(await (await get()).json()).toEqual([]);
  });

  it("PUT と PATCH は 405", async () => {
    expect((await SELF.fetch(URL_, { method: "PUT", headers: auth(), body: "{}" })).status).toBe(405);
    expect((await SELF.fetch(URL_, { method: "PATCH", headers: auth() })).status).toBe(405);
  });
});
