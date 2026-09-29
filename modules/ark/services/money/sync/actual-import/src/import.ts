// The import: applying one run's change set from money-sync.
//
// Plaid's transaction id is Actual's imported_id, which is what makes this
// idempotent. A pending transaction that posts arrives as a new transaction
// pointing at the pending one (plus a removal of the pending one); it is moved
// to the posted id in place, so a category set while it was pending survives.
import { api } from './actual.js';

export type Entity = Omit<Parameters<typeof api.importTransactions>[1][number], 'account'>;

export interface AccountChanges {
  name: string;
  /** Plaid's account type: decides on/off budget when the account has to be created. */
  type: string;
  /** The bank's current balance in cents (Actual's sign), for the opening balance of a new account. */
  balance: number | null;
  upserts: { transaction_id: string; pending_transaction_id: string | null; entity: Entity }[];
  removed: string[];
}

export interface AccountReport {
  name: string;
  created: boolean;
  opening: number | null;
  added: number;
  updated: number;
  deleted: number;
  locked: number;
  balance: number | null;
}

async function apply(actualId: string, changes: AccountChanges): Promise<Omit<AccountReport, 'name' | 'created' | 'opening' | 'balance'>> {
  const existing = await api.getTransactions(actualId, '2000-01-01', '2100-01-01');
  const byImportedId = new Map(existing.filter((t) => t.imported_id).map((t) => [t.imported_id as string, t]));
  const superseded = new Set<string>(); // pending ids whose posted transaction is in this batch

  const fresh: (Entity & { account: string })[] = [];
  let updated = 0;
  let locked = 0;
  for (const { transaction_id, pending_transaction_id, entity } of changes.upserts) {
    if (pending_transaction_id) superseded.add(pending_transaction_id);
    const prior = byImportedId.get(transaction_id) ?? (pending_transaction_id ? byImportedId.get(pending_transaction_id) : undefined);
    if (!prior) {
      fresh.push({ ...entity, account: actualId });
      continue;
    }
    if (prior.reconciled) {
      locked++;
      continue;
    }
    // Known transaction: bring the bank's facts up to date, leave the
    // payee/category/notes the user may have chosen alone.
    await api.updateTransaction(prior.id, {
      imported_id: entity.imported_id,
      imported_payee: entity.imported_payee,
      amount: entity.amount,
      date: entity.date,
      cleared: entity.cleared,
    });
    byImportedId.set(transaction_id, prior);
    updated++;
  }

  // Never import a pending transaction whose posted form is already here.
  // importTransactions runs Actual's reconciler, which also matches
  // transactions the user typed in by hand instead of duplicating them.
  const toImport = fresh.filter((e) => !superseded.has(e.imported_id ?? ''));
  let added = 0;
  if (toImport.length) {
    const res = await api.importTransactions(actualId, toImport);
    added = res.added.length;
    updated += res.updated.length;
    for (const err of res.errors ?? []) console.error(`${changes.name}: import error: ${err.message}`);
  }

  let deleted = 0;
  for (const id of changes.removed) {
    if (superseded.has(id)) continue;
    const prior = byImportedId.get(id);
    if (!prior) continue;
    if (prior.reconciled) {
      locked++;
      continue;
    }
    await api.deleteTransaction(prior.id);
    deleted++;
  }
  return { added, updated, deleted, locked };
}

export async function runImport(accounts: AccountChanges[]): Promise<AccountReport[]> {
  const byName = new Map((await api.getAccounts()).map((a) => [a.name, a.id]));
  const out: AccountReport[] = [];
  for (const changes of accounts) {
    let id = byName.get(changes.name);
    let created = false;
    let opening: number | null = null;
    if (!id) {
      // Bank and credit card accounts belong in the budget; loans, investments
      // and the like are tracked off budget.
      const offbudget = !['depository', 'credit'].includes(changes.type);
      id = await api.createAccount({ name: changes.name, offbudget }, 0);
      byName.set(changes.name, id);
      created = true;
      // Only so much history is imported; an opening balance the day before
      // the oldest imported transaction makes the account agree with the bank
      // (posted transactions only: the bank's current balance leaves pending ones out).
      if (changes.balance !== null) {
        const posted = changes.upserts.filter((u) => u.entity.cleared !== false);
        opening = changes.balance - posted.reduce((sum, u) => sum + (u.entity.amount ?? 0), 0);
        const oldest = changes.upserts.map((u) => u.entity.date).sort()[0];
        const date = oldest ? new Date(Date.parse(oldest) - 86_400_000).toISOString().slice(0, 10) : new Date().toISOString().slice(0, 10);
        if (opening !== 0) {
          await api.addTransactions(id, [{ date, amount: opening, payee_name: 'Starting Balance', cleared: true, notes: 'Balance before the first import' }]);
        }
      }
    }
    const counts = await apply(id, changes);
    out.push({ name: changes.name, created, opening, ...counts, balance: await api.getAccountBalance(id) });
  }
  return out;
}
