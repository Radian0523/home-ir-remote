// Durable Object "home"（design.md §5.1、§5.2、ADR-018）。
// ESP32 の device WebSocket を最大1本、Hibernation API で保持する。
// device WebSocket の受け入れと置換、即時操作（エアコン・照明）、一発予約（最大2件、ADR-024）と Alarm を持つ。

import { DurableObject } from "cloudflare:workers";
import { encode, type Setting } from "./encoder";
import { encodeLight, type LightButton } from "./light";
import { log } from "./log";

export interface Env {
  HOME: DurableObjectNamespace<Home>;
  DEVICE_TOKEN: string;
  APP_TOKEN: string;
}

const DEVICE_TAG = "device";
/** 予約の一覧（ADR-024） */
const SCHEDULES_KEY = "schedules";
/** 1件だけ持っていた頃（ADR-011）のキー。残っていれば一覧の1件として読む */
const LEGACY_SCHEDULE_KEY = "schedule";
/** 同時に持てる予約の数 */
export const MAX_SCHEDULES = 2;

/** device socket に付ける情報。複数残っているとき最新の接続を選ぶために使う */
interface DeviceAttachment {
  connectedAt: number; // ms
}

/** 永続化する業務データ。予約1件分（§5.2）。最大 MAX_SCHEDULES 件を executeAt の早い順で持つ */
interface ScheduleRecord {
  id: string;
  executeAt: string; // UTC 正規形
  setting: Setting;
  payload: string; // 受付時に生成した36文字。後日のコード変更で予約内容が変わらないため
}

/** API が返す形。payload は返さない（§5.5） */
export interface ScheduleView {
  id: string;
  executeAt: string;
  setting: Setting;
}

export class Home extends DurableObject<Env> {
  /**
   * Worker から転送された、認証済みの WebSocket upgrade リクエストを受け入れる。
   * 新しい接続が来たら古い接続を閉じ、新しい接続だけを正とする。
   */
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }

    for (const old of this.ctx.getWebSockets(DEVICE_TAG)) {
      try {
        old.close(1000, "replaced");
      } catch {
        // すでに閉じている場合は無視
      }
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
    this.ctx.acceptWebSocket(server, [DEVICE_TAG]);
    // Hibernation から戻っても残るよう、接続順を attachment に持たせる（送信先は最新を選ぶ）
    const attachment: DeviceAttachment = { connectedAt: Date.now() };
    server.serializeAttachment(attachment);
    log("device_connected");

    return new Response(null, { status: 101, webSocket: client });
  }

  /** ESP32 からアプリ用メッセージは来ない（ADR-010）。業務処理を置かない */
  override async webSocketMessage(_ws: WebSocket, _message: string | ArrayBuffer): Promise<void> {}

  override async webSocketClose(ws: WebSocket, code: number, _reason: string, wasClean: boolean): Promise<void> {
    log("device_disconnected", { code, wasClean });
    try {
      ws.close(code, "closed");
    } catch {
      // 相手側が先に閉じた場合は無視
    }
  }

  override async webSocketError(_ws: WebSocket, _error: unknown): Promise<void> {
    log("device_disconnected", { error: true });
  }

  /**
   * 開いている device socket を新しい順に返す。
   * 置き換えで close した古い接続は、相手（ESP32）がすでに捨てていると close の応答が来ず、
   * 1006 で切れるまで（実測で約17分）getWebSockets() に残る。これを選ぶと send() が例外になり 503 を返してしまう
   * （2026-11-12 の障害）。そのため OPEN のものだけを、接続が新しい順に並べる。
   */
  private deviceSockets(): WebSocket[] {
    const connectedAt = (ws: WebSocket): number =>
      (ws.deserializeAttachment() as DeviceAttachment | null)?.connectedAt ?? 0;
    return this.ctx
      .getWebSockets(DEVICE_TAG)
      .filter((ws) => ws.readyState === WebSocket.OPEN)
      .sort((a, b) => connectedAt(b) - connectedAt(a));
  }

  /**
   * 36文字または8文字を device socket へ1回だけ送る（§5.5）。
   * 最新の接続から順に試し、最初に send() できた1本で終える（同じ命令を2本へ送らない）。
   * 送れる接続が無い → false（503 相当）。送信できたら true（202 相当）。
   * 設計どおり、ESP32 の処理完了やエアコンの受理は確認しない。
   */
  private sendToDevice(payload: string): boolean {
    for (const ws of this.deviceSockets()) {
      try {
        ws.send(payload);
        return true;
      } catch {
        // 閉じかけていた。次に新しい接続を試す
      }
    }
    return false;
  }

  // ---- 一発予約（§5.2、ADR-024）-----------------------------------------------

  /** 保存されている予約を早い順で返す。旧形式（1件）が残っていれば id を付けて含める */
  private async loadSchedules(): Promise<ScheduleRecord[]> {
    const map = await this.ctx.storage.get<ScheduleRecord[] | Omit<ScheduleRecord, "id">>([SCHEDULES_KEY, LEGACY_SCHEDULE_KEY]);
    const list = [...((map.get(SCHEDULES_KEY) as ScheduleRecord[] | undefined) ?? [])];
    const legacy = map.get(LEGACY_SCHEDULE_KEY) as Omit<ScheduleRecord, "id"> | undefined;
    if (legacy) list.push({ id: "legacy", ...legacy });
    return list.sort((a, b) => Date.parse(a.executeAt) - Date.parse(b.executeAt));
  }

  /**
   * 一覧を保存し、Alarm を一番早い予約に合わせる。旧形式のキーはここで消す。
   * トランザクションでまとめて書き、一覧と Alarm がずれた状態を残さない。
   */
  private async saveSchedules(list: ScheduleRecord[]): Promise<void> {
    await this.ctx.storage.transaction(async (txn) => {
      await txn.delete(LEGACY_SCHEDULE_KEY);
      if (list.length === 0) {
        await txn.delete(SCHEDULES_KEY);
        await txn.deleteAlarm();
      } else {
        await txn.put(SCHEDULES_KEY, list);
        await txn.setAlarm(Date.parse(list[0]!.executeAt));
      }
    });
  }

  private static view(rec: ScheduleRecord): ScheduleView {
    return { id: rec.id, executeAt: rec.executeAt, setting: rec.setting };
  }

  /** GET /schedule。予約を早い順に並べた配列（なければ空配列） */
  async getSchedules(): Promise<ScheduleView[]> {
    return (await this.loadSchedules()).map(Home.view);
  }

  /** POST /schedule。予約を1件足す。すでに MAX_SCHEDULES 件あれば足さずに full を返す */
  async addSchedule(setting: Setting, executeAt: string): Promise<{ ok: true; value: ScheduleView } | { ok: false; error: "schedule_full" }> {
    const list = await this.loadSchedules();
    if (list.length >= MAX_SCHEDULES) {
      log("schedule_full");
      return { ok: false, error: "schedule_full" };
    }
    const rec: ScheduleRecord = { id: crypto.randomUUID(), executeAt, setting, payload: encode(setting) };
    list.push(rec);
    list.sort((a, b) => Date.parse(a.executeAt) - Date.parse(b.executeAt));
    await this.saveSchedules(list);
    log("schedule_set", { executeAt });
    return { ok: true, value: Home.view(rec) };
  }

  /** DELETE /schedule/{id}。無い id でもエラーにしない（取り消し済みと区別しない） */
  async deleteSchedule(id: string): Promise<void> {
    const list = await this.loadSchedules();
    const rest = list.filter((r) => r.id !== id);
    if (rest.length === list.length) return;
    await this.saveSchedules(rest);
    log("schedule_deleted");
  }

  /** DELETE /schedule。予約をすべて消し、Alarm も消す */
  async deleteAllSchedules(): Promise<void> {
    await this.saveSchedules([]);
    log("schedule_deleted", { all: true });
  }

  /**
   * Alarm handler。順序は §5.2 に固定する。
   *   読む → 時刻が来たものがなければ Alarm を張り直して終了
   *   → 来たものを一覧から削除し、残りに Alarm を合わせて完了を待つ
   *   → 接続中なら来たものを早い順に1回ずつ send → 失敗は記録して正常終了
   * 削除までに失敗した場合はまだ送っていないので、例外をそのまま投げて Alarm の再試行に任せる。
   * 削除が完了した後は何があっても例外を投げない（再試行で二重送信しないため、ADR-005）。
   */
  override async alarm(): Promise<void> {
    const list = await this.loadSchedules();
    const now = Date.now();
    const due = list.filter((r) => Date.parse(r.executeAt) <= now);
    const rest = list.filter((r) => Date.parse(r.executeAt) > now);
    if (due.length === 0) {
      if (rest.length > 0) await this.saveSchedules(rest);
      return;
    }
    await this.saveSchedules(rest);

    for (const rec of due) {
      try {
        if (this.sendToDevice(rec.payload)) {
          log("schedule_fired_sent", { executeAt: rec.executeAt });
        } else {
          log("schedule_fired_offline", { executeAt: rec.executeAt });
        }
      } catch (e) {
        log("server_error", { where: "alarm", message: e instanceof Error ? e.message : String(e) });
      }
    }
  }

  /** POST /command（§5.5）。検証済みの設定を受け取り、encode して送る。RPC で Worker から呼ばれる */
  async command(setting: Setting): Promise<{ ok: true } | { ok: false; error: "device_offline" }> {
    const payload = encode(setting);
    if (this.sendToDevice(payload)) {
      log("command_sent");
      return { ok: true };
    }
    log("command_offline");
    return { ok: false, error: "device_offline" };
  }

  /** POST /light（§5.5、ADR-022）。検証済みのボタンを8文字へ変換して送る */
  async light(button: LightButton): Promise<{ ok: true } | { ok: false; error: "device_offline" }> {
    if (this.sendToDevice(encodeLight(button))) {
      log("light_sent", { button });
      return { ok: true };
    }
    log("light_offline", { button });
    return { ok: false, error: "device_offline" };
  }
}
