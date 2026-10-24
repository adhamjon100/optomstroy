import type pg from 'pg';
import type { Logger } from 'pino';
import type { SyncEntity, SyncTrigger } from '../../common/enums.js';
import type { SyncErrorCode } from '../../jobs/sync-errors.writer.js';
import { isOnecAuthFailure, isOnecError, OnecError } from '../../integrations/onec/onec-error.js';
import type { OnecChangesPage, OnecGateway } from '../../integrations/onec/onec-gateway.js';
import type { OnecAuthPause } from '../alerts/onec-auth-pause.js';
import type { ApplyRunTracker, ApplyScope, ChangeItemHandler, EntityCounts } from './apply.types.js';
import { type CatalogApplier, newApplyState } from './catalog-applier.js';
import {
  type CatalogChangePublisher,
  newCatalogChangeSink,
  publishCatalogChanges,
} from './catalog-change-publisher.js';
import { refreshCatalogDerived } from './catalog-derived.js';
import { CATALOG_LOAD_ENTITIES } from './catalog-full-load.service.js';
import type { CatalogSliceSource } from './catalog-source.js';
import { applyPriceRows, finishPriceSlice, newSliceTracker } from './catalog-slices.js';
import { flushErrors, idsByRef } from './replica-writer.js';

/** Узел плана обмена (07 §5.64, ядро §22.10: одна торговая точка). */
export const ONEC_NODE = 'pos';

export interface OnecChangesOptions {
  /** Элементов на странице `/changes` (`ONEC_SYNC_PAGE_SIZE`, по умолчанию 1000, максимум 5000). */
  readonly pageSize?: number;
  /** Сверять номер с `/health.lastAckMessageNumber` перед запросом (05 SYNC-011) — по умолчанию да. */
  readonly reconcileWithHealth?: boolean;
  /** Обработчики не-каталожных типов (клиенты, документы, файлы картинок, QR). */
  readonly handlers?: readonly ChangeItemHandler[];
  /** Источник среза цен для перечитки по `Document_УстановкаЦенНоменклатуры` (05 SYNC-015). */
  readonly slices?: CatalogSliceSource;
  /**
   * Сущности плана обмена, по которым фиксируется сбой цикла, не дошедшего до применения ни одной строки (1С
   * недоступна на первом `/changes`, отказ авторизации, ответ не по контракту): прогон `failed` + `sync_errors` +
   * рост `consecutive_errors` (05 SYNC-029 (б), SYNC-038; RM-E-002 п. 2). По умолчанию — справочники каталога,
   * которые в режиме расширения приходят только через `onec.changes` (без срезов `stock`/`prices`).
   */
  readonly planEntities?: readonly SyncEntity[];
  readonly now?: () => Date;
  /** Публикатор `catalog.prices-changed|stock-changed` в транзакции применения (05 SYNC-070, ревью F-trace-3). */
  readonly catalogChanges?: CatalogChangePublisher;
  /**
   * Пауза чтения после 401/403 (05 §6.5; ТЗ для 1С А.1; разбор п. 89): пока действует, цикл к 1С не обращается
   * (`paused_auth`); отказ авторизации на `/health`, `/changes` или ack включает паузу и тревогу администратору.
   * Нет — без паузы (тесты конвейера).
   */
  readonly authPause?: Pick<OnecAuthPause, 'active' | 'record'>;
}

/** Справочники каталога, инкремент которых в режиме расширения идёт только через план обмена (05 SYNC-011). */
export const ONEC_PLAN_ENTITIES: readonly SyncEntity[] = CATALOG_LOAD_ENTITIES.filter(
  (e) => e !== 'stock' && e !== 'prices',
);

/** Код адаптера «ответ 2xx не по контракту» (= `ONEC_INVALID_RESPONSE` шлюза расширения). */
const INVALID_RESPONSE = 'INVALID_RESPONSE';

export type ChangesPullStatus =
  /** Сообщение применено и подтверждено, `sync_node_state` сдвинут. */
  | 'applied'
  /** Регистраций нет — сообщение пустое, ack не отправлялся. */
  | 'empty'
  /** Применено (COMMIT), но ack не прошёл — следующий цикл повторит сообщение (идемпотентно, SYNC-031). */
  | 'applied_not_acked'
  /** Номер сообщения не больше применённого — данные не применялись (SYNC-032), отправлен только ack. */
  | 'stale'
  /** Идёт другой цикл `onec.changes` (advisory lock) — singleton на узел (SYNC-011). */
  | 'skipped_locked'
  /** Пауза чтения после 401/403 (05 §6.5): к 1С не обращались, `until` — конец паузы. */
  | 'paused_auth';

export interface ChangesPullResult {
  readonly status: ChangesPullStatus;
  readonly messageNumber?: number;
  readonly pages: number;
  readonly items: number;
  readonly runIds: Readonly<Partial<Record<SyncEntity, string>>>;
  readonly counts: Readonly<Partial<Record<SyncEntity, EntityCounts>>>;
  readonly errors: number;
  /** Элементы без обработчика (состав плана обмена шире подключённых обработчиков). */
  readonly unhandled: number;
  /**
   * Элементы типов, применение которых отложено до решения заказчика (ПКО и поступления — Q-012): пропущены
   * осознанно, после подключения обработки — разовая перерегистрация `npm run onec:reregister` (05 §6.2 п. 3).
   */
  readonly deferred: number;
  /** Конец паузы чтения (`paused_auth`). */
  readonly pausedUntil?: string;
}

/** Ключ advisory-lock цикла `onec.changes` (singleton на узел). */
const LOCK_KEY = 'onec.changes:pos';

/**
 * Инкремент фазы 1 по плану обмена «POS» (05 §6.2, SYNC-011; ядро §22.8):
 * `GET /changes?since=N` (+ страницы того же сообщения N+1 по `cursor`) → применение **всех** страниц в **одной**
 * транзакции → COMMIT → `POST /changes/ack {N+1}` → `sync_node_state.last_message_number = N+1`.
 * Любая ошибка страницы/применения → ROLLBACK, ack не отправляется; следующий цикл получит то же сообщение заново.
 * Прогоны `sync_runs` — по каждой затронутой сущности (`mode=incremental`, `cursor_to` = номер сообщения).
 */
export class OnecChangesService {
  private readonly handlersByType = new Map<string, ChangeItemHandler>();

  constructor(
    private readonly pool: pg.Pool,
    private readonly gateway: OnecGateway,
    private readonly applier: CatalogApplier,
    private readonly runs: ApplyRunTracker,
    private readonly log: Logger,
    private readonly options: OnecChangesOptions = {},
  ) {
    for (const h of options.handlers ?? []) for (const t of h.types) this.handlersByType.set(t, h);
  }

  /**
   * Один цикл узла. Singleton (05 SYNC-011, AC-SYNC-011) — **сессионный** advisory-lock на выделенном соединении:
   * он держится на весь цикл «чтение `since` → все страницы → COMMIT → ack → `sync_node_state`» и снимается в
   * `finally`. Блокировка уровня транзакции не годится: она снимается на COMMIT, и второй цикл, начавшийся между
   * COMMIT и ack первого, получил бы от 1С новое сообщение N+1, регистрации которого снял бы ack первого (потеря
   * изменений, ревью E-onec-sync-1). Второй цикл при занятом lock к 1С не обращается (`skipped_locked`).
   */
  async pullOnce(
    opts: { trigger?: SyncTrigger; requestId?: string; signal?: AbortSignal } = {},
  ): Promise<ChangesPullResult> {
    const pause = await this.options.authPause?.active();
    if (pause) {
      this.log.warn(
        { until: pause.until.toISOString() },
        'onec.changes.paused_auth: чтение из 1С приостановлено (401/403)',
      );
      return { ...EMPTY_RESULT, status: 'paused_auth', pausedUntil: pause.until.toISOString() };
    }
    const client = await this.pool.connect();
    let locked = false;
    try {
      const lock = await client.query<{ ok: boolean }>(`SELECT pg_try_advisory_lock(hashtext($1)) AS ok`, [LOCK_KEY]);
      locked = lock.rows[0]?.ok === true;
      if (!locked) {
        return { ...EMPTY_RESULT, status: 'skipped_locked' };
      }
      return await this.pullLocked(client, opts);
    } finally {
      await this.releaseLock(client, locked);
    }
  }

  /** Снятие сессионного lock; если не удалось — соединение уничтожается (lock снимет сервер), а не уходит в пул. */
  private async releaseLock(client: pg.PoolClient, locked: boolean): Promise<void> {
    if (!locked) {
      client.release();
      return;
    }
    try {
      await client.query(`SELECT pg_advisory_unlock(hashtext($1))`, [LOCK_KEY]);
      client.release();
    } catch (e) {
      this.log.error({ err: e }, 'onec.changes.unlock_failed: соединение закрыто, lock снят сервером');
      client.release(e instanceof Error ? e : new Error(String(e)));
    }
  }

  private async pullLocked(
    client: pg.PoolClient,
    opts: { trigger?: SyncTrigger; requestId?: string; signal?: AbortSignal },
  ): Promise<ChangesPullResult> {
    const trigger = opts.trigger ?? 'schedule';
    const now = this.options.now ?? (() => new Date());
    // `since` читается под lock: параллельный цикл не может сдвинуть номер между чтением и запросом к 1С.
    let since = await this.lastMessageNumber();
    if (this.options.reconcileWithHealth !== false) since = await this.reconcileWithHealth(since);

    const runIds = new Map<SyncEntity, string>();
    const counts = new Map<SyncEntity, EntityCounts>();
    const scope: ApplyScope = {
      client,
      syncedAt: now(),
      counts,
      errors: [],
      catalogChanges: newCatalogChangeSink(),
      runIdFor: async (entity) => {
        let id = runIds.get(entity);
        if (!id) {
          id = await this.runs.start({
            entity,
            mode: 'incremental',
            trigger,
            cursorFrom: String(since),
            endpoint: 'GET /pos/v1/changes',
          });
          runIds.set(entity, id);
        }
        return id;
      },
    };
    const state = newApplyState();
    let messageNumber: number | undefined;
    let pages = 0;
    let items = 0;
    let errorCount: number;
    let foreign: { unhandled: number; deferred: number };
    let committed = false;
    try {
      await client.query('BEGIN');
      let cursor: string | undefined;
      for (;;) {
        const page: OnecChangesPage = (
          await this.gateway.getChanges(
            { since, limit: this.options.pageSize ?? 1000, ...(cursor !== undefined ? { cursor } : {}) },
            {
              ...(opts.requestId ? { requestId: opts.requestId } : {}),
              ...(opts.signal ? { signal: opts.signal } : {}),
            },
          )
        ).body;
        if (pages === 0) await this.markNodeReachable();
        pages += 1;
        if (messageNumber === undefined) messageNumber = page.messageNumber;
        else if (page.messageNumber !== messageNumber) {
          throw new Error(
            `/changes: номер сообщения изменился между страницами (${messageNumber} → ${page.messageNumber})`,
          );
        }
        if (page.messageNumber <= since) {
          // SYNC-032: пакет с номером не больше применённого не применяется (только ack для расширения).
          await client.query('ROLLBACK');
          await this.ack(page.messageNumber, since, opts.requestId);
          return { ...EMPTY_RESULT, status: 'stale', messageNumber: page.messageNumber, pages };
        }
        if (page.hasMore && (typeof page.cursor !== 'string' || page.cursor === '')) {
          // 05 §6.2 п. 1–2: `hasMore=true` без курсора — ответ не по контракту. Выход из цикла с ack подтвердил бы
          // непрочитанные страницы сообщения (ревью E-onec-sync-6) → ROLLBACK, ack не отправляется.
          throw new OnecError(
            'getChanges',
            200,
            INVALID_RESPONSE,
            `/changes: hasMore=true без cursor (страница ${pages} сообщения ${page.messageNumber})`,
          );
        }
        items += page.items.length;
        await this.applier.applyItems(scope, state, page.items, false);
        if (!page.hasMore) break;
        cursor = page.cursor ?? undefined;
      }
      if (items === 0) {
        await client.query('ROLLBACK');
        return { ...EMPTY_RESULT, status: 'empty', ...(messageNumber !== undefined ? { messageNumber } : {}), pages };
      }
      await this.applier.flushDeferred(scope, state);
      // Цены: перечитка среза по затронутым видам цен в той же транзакции (05 §6.2, SYNC-015).
      if (state.priceListsToRefresh.size > 0) await this.refreshPrices(scope, [...state.priceListsToRefresh]);
      foreign = await this.applyForeign(scope, state.foreign);
      await refreshCatalogDerived(client, state);
      // Прогон на каждую затронутую сущность (SYNC-011), даже если её строки не вели учёт версий (срезы цен).
      for (const e of [...counts.keys()]) await scope.runIdFor(e);
      errorCount = countErrors(counts);
      await flushErrors(scope);
      // Корзины: изменения цен/остатков — задачами в той же транзакции (05 SYNC-070, 06 §7.5; ревью F-trace-3).
      await publishCatalogChanges(this.options.catalogChanges, client, scope.catalogChanges);
      await client.query('COMMIT');
      committed = true;
    } catch (e) {
      if (!committed) await client.query('ROLLBACK').catch(() => undefined);
      await this.recordFailure(runIds, counts, messageNumber, since, trigger, e);
      await this.markNodeError(e);
      if (isOnecAuthFailure(e)) await this.options.authPause?.record(e);
      this.log.warn(
        { err: e, since, messageNumber, pages },
        'onec.changes.failed: сообщение не применено, ack не отправлен',
      );
      throw e;
    }

    const status = errorCount > 0 ? 'partial' : 'success';
    await this.finishRuns(
      runIds,
      counts,
      status,
      messageNumber,
      errorCount > 0 ? `${errorCount} ошибок позиций (sync_errors)` : undefined,
    );
    // Ack — ещё под сессионным lock: следующий цикл начнётся только после того, как узел сдвинут.
    const acked = await this.ack(messageNumber, since, opts.requestId);
    const result: ChangesPullResult = {
      status: acked ? 'applied' : 'applied_not_acked',
      messageNumber: messageNumber,
      pages,
      items,
      runIds: Object.fromEntries(runIds),
      counts: Object.fromEntries(counts),
      errors: errorCount,
      unhandled: foreign.unhandled,
      deferred: foreign.deferred,
    };
    this.log.info(
      {
        messageNumber,
        pages,
        items,
        errors: errorCount,
        unhandled: foreign.unhandled,
        deferred: foreign.deferred,
        acked,
        entities: [...runIds.keys()],
      },
      'onec.changes.applied',
    );
    return result;
  }

  /**
   * Итог неудачного цикла — **вне** откатанной транзакции (05 SYNC-029 (б), SYNC-038; RM-E-002 п. 2): прогоны
   * затронутых сущностей → `failed` (+ `consecutive_errors`), по каждому — строка `sync_errors` с кодом
   * `ONEC_UNAVAILABLE`/`ONEC_REJECTED`/`OTHER` (пишет трекер прогонов). Если сбой случился до применения первой
   * строки (1С недоступна на первом `/changes`), затронутых сущностей нет — сбой фиксируется по сущностям плана
   * обмена (`planEntities`), иначе недоступность 1С в режиме расширения не оставляла бы следов (ревью E-onec-sync-2).
   */
  private async recordFailure(
    runIds: Map<SyncEntity, string>,
    counts: Map<SyncEntity, EntityCounts>,
    messageNumber: number | undefined,
    since: number,
    trigger: SyncTrigger,
    e: unknown,
  ): Promise<void> {
    if (runIds.size === 0) {
      for (const entity of this.options.planEntities ?? ONEC_PLAN_ENTITIES) {
        try {
          const id = await this.runs.start({
            entity,
            mode: 'incremental',
            trigger,
            cursorFrom: String(since),
            endpoint: 'GET /pos/v1/changes',
          });
          runIds.set(entity, id);
        } catch (err) {
          // Занятый singleton сущности (идёт full/reconcile) — сбой этим циклом по ней не учитывается.
          this.log.debug({ err, entity }, 'onec.changes.failure_run_skipped');
        }
      }
    }
    const message = e instanceof Error ? e.message : String(e);
    await this.finishRuns(runIds, counts, 'failed', messageNumber, message, nodeErrorCode(e));
  }

  /** `sync_node_state.last_message_number` узла `pos` (строка создаётся seed-ом 0001; при отсутствии — 0). */
  async lastMessageNumber(): Promise<number> {
    const r = await this.pool.query<{ n: string }>(
      `SELECT last_message_number::text AS n FROM sync_node_state WHERE node = $1`,
      [ONEC_NODE],
    );
    return r.rows[0] ? Number(r.rows[0].n) : 0;
  }

  /** Ack только после COMMIT; успех → номер узла; 409 ACK_OUT_OF_ORDER → номер из `/health` (05 §6.3 `x-retry`). */
  private async ack(messageNumber: number, since: number, requestId?: string): Promise<boolean> {
    try {
      await this.gateway.ackChanges(messageNumber, requestId ? { requestId } : undefined);
      await this.pool.query(
        `INSERT INTO sync_node_state (node, last_message_number, last_ack_at, last_error_code, onec_reachable, unreachable_since)
         VALUES ($1, $2, now(), NULL, true, NULL)
         ON CONFLICT (node) DO UPDATE SET
           last_message_number = GREATEST(sync_node_state.last_message_number, EXCLUDED.last_message_number),
           last_ack_at = now(), last_error_code = NULL, onec_reachable = true, unreachable_since = NULL, updated_at = now()`,
        [ONEC_NODE, Math.max(messageNumber, since)],
      );
      return true;
    } catch (e) {
      if (isOnecError(e) && e.code === 'POS_E_ACK_OUT_OF_ORDER') {
        const health = await this.gateway.getHealth().catch(() => undefined);
        const last = health?.body.lastAckMessageNumber;
        if (typeof last === 'number') await this.setNodeNumber(last);
        this.log.warn(
          { messageNumber, lastAck: last },
          'onec.changes.ack_out_of_order: номер узла выровнен по /health',
        );
        return false;
      }
      await this.markNodeError(e);
      if (isOnecAuthFailure(e)) await this.options.authPause?.record(e);
      this.log.warn(
        { err: e, messageNumber },
        'onec.changes.ack_failed: данные применены, сообщение будет выдано повторно',
      );
      return false;
    }
  }

  /** При старте цикла — продолжать с большего из `last_message_number` и `/health.lastAckMessageNumber`. */
  private async reconcileWithHealth(since: number): Promise<number> {
    try {
      const h = await this.gateway.getHealth();
      await this.markNodeReachable();
      const last = h.body.lastAckMessageNumber;
      if (typeof last === 'number' && last > since) {
        await this.setNodeNumber(last);
        return last;
      }
    } catch (e) {
      this.log.debug({ err: e }, 'onec.changes.health_unavailable');
    }
    return since;
  }

  private async setNodeNumber(n: number): Promise<void> {
    await this.pool.query(
      `INSERT INTO sync_node_state (node, last_message_number) VALUES ($1, $2)
       ON CONFLICT (node) DO UPDATE SET last_message_number = GREATEST(sync_node_state.last_message_number, EXCLUDED.last_message_number),
              updated_at = now()`,
      [ONEC_NODE, n],
    );
  }

  /**
   * 1С ответила (страница `/changes` или `/health`) — связь есть (05 SYNC-038 п. 1: `onec_reachable` отражает
   * последний запрос). Без этого после сбоя при пустом плане обмена (ack не нужен) узел оставался бы «недоступен».
   */
  private async markNodeReachable(): Promise<void> {
    await this.pool
      .query(
        `UPDATE sync_node_state SET onec_reachable = true, unreachable_since = NULL, updated_at = now()
          WHERE node = $1 AND (NOT onec_reachable OR unreachable_since IS NOT NULL)`,
        [ONEC_NODE],
      )
      .catch(() => undefined);
  }

  private async markNodeError(e: unknown): Promise<void> {
    const code = nodeErrorCode(e);
    const unreachable = code === 'ONEC_UNAVAILABLE';
    await this.pool
      .query(
        `UPDATE sync_node_state SET last_error_code = $2,
                onec_reachable = CASE WHEN $3 THEN false ELSE onec_reachable END,
                unreachable_since = CASE WHEN $3 THEN coalesce(unreachable_since, now()) ELSE unreachable_since END,
                updated_at = now()
          WHERE node = $1`,
        [ONEC_NODE, code, unreachable],
      )
      .catch(() => undefined);
  }

  private async refreshPrices(scope: ApplyScope, priceListRefs: string[]): Promise<void> {
    const slices = this.options.slices;
    if (!slices) {
      scope.errors.push({
        entity: 'prices',
        errorCode: 'OTHER',
        severity: 'warning',
        message: 'перечитка среза цен по документу установки цен недоступна: источник среза не подключён (05 SYNC-015)',
        payload: { priceLists: priceListRefs.length },
      });
      return;
    }
    const known = await idsByRef(scope.client, 'price_lists', priceListRefs);
    const refs = priceListRefs.filter((r) => known.has(r));
    const tracker = newSliceTracker();
    for (const id of known.values()) tracker.scopeIds.add(id);
    for await (const rows of slices.priceSlice(refs)) await applyPriceRows(scope, rows, tracker);
    await finishPriceSlice(scope, tracker);
  }

  /**
   * Элементы не каталога → обработчики модулей-владельцев (05 §6.2, уточнение п. 3; ядро §22.8: регистрация
   * снимается только после применения). Без обработчика — пропуск (счётчик `unhandled`); обработчик с пометкой
   * `deferred` (применение отложено до решения заказчика) — счётчик `deferred`.
   */
  private async applyForeign(
    scope: ApplyScope,
    foreign: readonly Readonly<Record<string, unknown>>[],
  ): Promise<{ unhandled: number; deferred: number }> {
    const groups = new Map<ChangeItemHandler, Readonly<Record<string, unknown>>[]>();
    let unhandled = 0;
    let deferred = 0;
    for (const it of foreign) {
      const type = String(it.type);
      const h =
        this.handlersByType.get(type) ??
        (type === 'ObjectDeletion' ? this.handlersByType.get(String(it.objectType)) : undefined);
      if (!h) {
        unhandled += 1;
        continue;
      }
      const list = groups.get(h) ?? [];
      list.push(it);
      groups.set(h, list);
    }
    for (const [h, list] of groups) {
      if (h.deferred === true) deferred += list.length;
      for (const it of list) {
        const e = h.entityOf(it);
        if (e) await scope.runIdFor(e);
      }
      await h.apply(scope, list);
    }
    if (unhandled > 0)
      this.log.info({ unhandled }, 'onec.changes.unhandled: элементы без обработчика (не каталог) пропущены');
    return { unhandled, deferred };
  }

  private async finishRuns(
    runIds: Map<SyncEntity, string>,
    counts: Map<SyncEntity, EntityCounts>,
    status: 'success' | 'partial' | 'failed',
    messageNumber: number | undefined,
    errorSummary?: string,
    errorCode?: SyncErrorCode,
  ): Promise<void> {
    for (const [entity, runId] of runIds) {
      const c = counts.get(entity);
      const entityStatus = status === 'failed' ? 'failed' : c && c.errors > 0 ? 'partial' : 'success';
      await this.runs
        .finish({
          runId,
          entity,
          status: entityStatus,
          counts: { ...(c ?? {}), messageNumber: messageNumber ?? null },
          ...(errorSummary !== undefined && entityStatus !== 'success' ? { errorSummary } : {}),
          ...(errorCode !== undefined && entityStatus === 'failed' ? { errorCode } : {}),
          ...(messageNumber !== undefined && status !== 'failed' ? { cursorTo: String(messageNumber) } : {}),
        })
        .catch((err: unknown) => this.log.error({ err, runId, entity }, 'onec.changes.run_finish_failed'));
    }
  }
}

const EMPTY_RESULT: ChangesPullResult = {
  status: 'empty',
  pages: 0,
  items: 0,
  runIds: {},
  counts: {},
  errors: 0,
  unhandled: 0,
  deferred: 0,
};

/** Код `sync_errors` / `sync_node_state.last_error_code` по ошибке цикла (07 §6.1.1). */
export function nodeErrorCode(e: unknown): SyncErrorCode {
  if (isOnecError(e)) return e.retryable ? 'ONEC_UNAVAILABLE' : 'ONEC_REJECTED';
  return 'OTHER';
}

function countErrors(counts: Map<SyncEntity, EntityCounts>): number {
  let n = 0;
  for (const c of counts.values()) n += c.errors;
  return n;
}
