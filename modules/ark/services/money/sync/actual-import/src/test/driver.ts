// Drives the Actual side of the end-to-end check, with the same API and the
// same seeded session money-sync uses.
//
//   ACTUAL_URL=... TOKEN_FILE=... node driver.js <step>
//
//   bootstrap      give the fresh server its password (what a real install did long ago)
//   create-budget  a budget with a Checking account and one hand-typed transaction
//   create-stray   a second, empty budget, as a click through the onboarding makes
//   categorize     put the pending gas transaction in a category, as a user would
//   expect <n>     assert what Checking must hold after sync phase n
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import * as api from '@actual-app/api';

const SERVER = process.env.ACTUAL_URL ?? assert.fail('ACTUAL_URL is not set');
const TOKEN = fs.readFileSync(process.env.TOKEN_FILE ?? assert.fail('TOKEN_FILE is not set'), 'utf8').trim();
const [step, arg] = process.argv.slice(2);

async function open() {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'driver-'));
  await api.init({ dataDir, serverURL: SERVER, sessionToken: TOKEN, verbose: false });
}

async function openBudget() {
  await open();
  const budgets = await api.getBudgets();
  const only = budgets[0];
  assert.ok(budgets.length === 1 && only?.groupId, `budgets: ${JSON.stringify(budgets)}`);
  await api.downloadBudget(only.groupId);
}

async function checking() {
  const acc = (await api.getAccounts()).find((a) => a.name === 'Checking');
  assert.ok(acc, 'no Checking account');
  return acc;
}

interface Row {
  imported_id: string | null;
  date: string;
  amount: number;
  cleared: boolean;
  payee: string | null;
  imported_payee: string | null;
  category: string | null;
  notes: string | null;
}

async function rows(accountId: string): Promise<Row[]> {
  const payees = new Map((await api.getPayees()).map((p) => [p.id, p.name]));
  const cats = new Map((await api.getCategories()).map((c) => [c.id, c.name]));
  return (await api.getTransactions(accountId, '2000-01-01', '2100-01-01'))
    .map((t) => ({
      imported_id: t.imported_id ?? null,
      date: t.date,
      amount: t.amount,
      cleared: t.cleared ?? false,
      payee: (t.payee && payees.get(t.payee)) ?? null,
      imported_payee: t.imported_payee ?? null,
      category: (t.category && cats.get(t.category)) ?? null,
      notes: t.notes ?? null,
    }))
    .sort((a, b) => (a.imported_id ?? '').localeCompare(b.imported_id ?? ''));
}

const coffee = (amount: number): Row => ({
  imported_id: 'T1',
  date: '2026-09-20',
  amount,
  cleared: true,
  payee: 'Coffee Shop',
  imported_payee: 'COFFEE SHOP #12',
  category: null,
  notes: null,
});
// The hand-typed payroll transaction, matched by Actual's reconciler instead
// of duplicated: keeps its payee and notes, gains the bank's id.
const payroll: Row = {
  imported_id: 'T3',
  date: '2026-09-23',
  amount: 100000,
  cleared: true,
  payee: 'Employer',
  imported_payee: 'PAYROLL',
  category: null,
  notes: 'manual',
};
const afterPhase1: Row[] = [
  { imported_id: 'P1', date: '2026-09-21', amount: -2000, cleared: false, payee: 'Gas Station Pending', imported_payee: 'GAS STATION PENDING', category: null, notes: null },
  coffee(-5025),
  payroll,
];
// P1 posted as T2 with a new amount and date; it keeps the category from `categorize`.
const afterPhase2: Row[] = [
  coffee(-5500),
  { imported_id: 'T2', date: '2026-09-22', amount: -2150, cleared: true, payee: 'Gas Station Pending', imported_payee: 'GAS STATION', category: 'Gas', notes: null },
  payroll,
];
const expected: Record<string, Row[]> = { 1: afterPhase1, 2: afterPhase2, 3: afterPhase2 };

try {
  if (step === 'bootstrap') {
    const r = await fetch(`${SERVER}/account/bootstrap`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: 'test-password' }),
    });
    assert.equal(r.status, 200, await r.text());
  } else if (step === 'create-budget') {
    await open();
    await api.runImport('Family', async () => {
      const id = await api.createAccount({ name: 'Checking', offbudget: false }, 0);
      await api.addTransactions(id, [{ date: '2026-09-23', amount: 100000, payee_name: 'Employer', notes: 'manual' }]);
    });
  } else if (step === 'create-stray') {
    // What someone clicking through Actual's onboarding leaves behind.
    await open();
    await api.runImport('My Finances', async () => {});
  } else if (step === 'categorize') {
    await openBudget();
    const acc = await checking();
    const group = await api.createCategoryGroup({ name: 'Bills' });
    const gas = await api.createCategory({ name: 'Gas', group_id: group });
    const p1 = (await api.getTransactions(acc.id, '2000-01-01', '2100-01-01')).find((t) => t.imported_id === 'P1');
    assert.ok(p1, 'P1 not imported');
    await api.updateTransaction(p1.id, { category: gas });
  } else if (step === 'expect') {
    const want = expected[arg ?? ''];
    assert.ok(want, `usage: driver.js expect <1|2|3>`);
    await openBudget();
    const acc = await checking();
    const got = await rows(acc.id);
    console.log(JSON.stringify(got, null, 1));
    assert.deepEqual(got, want);
    const balance = got.reduce((sum, t) => sum + t.amount, 0);
    assert.equal(await api.getAccountBalance(acc.id), balance);

    // "Plaid Savings" was not in the budget; the first sync created it (a
    // depository account, so on budget), imported its one transaction, and
    // opened it with the bank's balance (923.50) minus that transaction, dated
    // the day before it, so the account agrees with the bank.
    const all = await api.getAccounts();
    assert.deepEqual(all.map((a) => a.name).sort(), ['Checking', 'Plaid Savings']);
    const savings = all.find((a) => a.name === 'Plaid Savings');
    assert.ok(savings && !savings.offbudget, 'Plaid Savings must be on budget');
    assert.deepEqual(await rows(savings.id), [
      { imported_id: null, date: '2026-09-19', amount: 91350, cleared: true, payee: 'Starting Balance', imported_payee: 'Starting Balance', category: null, notes: 'Balance before the first import' },
      { imported_id: 'S1', date: '2026-09-20', amount: 1000, cleared: true, payee: 'Interest', imported_payee: 'INTEREST', category: null, notes: null },
    ]);
    assert.equal(await api.getAccountBalance(savings.id), 92350);
  } else {
    throw new Error(`unknown step '${step}'`);
  }
} finally {
  await api.shutdown().catch(() => {});
}
