// Everything else one might do to the budget: what `ark service money ...`
// runs on the host as `money-sync actual <op> <json>`. Each op takes a JSON
// object and returns JSON; names (categories, payees, accounts) come in as
// people write them and go out resolved. Amounts are cents, Actual's sign
// (spending negative).
import { api, findAccount, findCategory, findGroup, findPayee, groups, names } from './actual.js';

type Args = Record<string, unknown>;
const str = (a: Args, k: string): string => {
  const v = a[k];
  if (typeof v !== 'string' || v === '') throw new Error(`${k} is required`);
  return v;
};
const optStr = (a: Args, k: string): string | undefined => (typeof a[k] === 'string' && a[k] !== '' ? (a[k] as string) : undefined);
const num = (a: Args, k: string): number => {
  const v = a[k];
  if (typeof v !== 'number') throw new Error(`${k} must be a number (cents)`);
  return v;
};

// The whole ledger, every account, as rows with names instead of ids.
async function allTransactions(since = '2000-01-01', until = '2100-01-01') {
  const { cats, payees, accounts } = await names();
  const rows = [];
  for (const account of accounts.values()) {
    for (const t of await api.getTransactions(account.id, since, until)) {
      const payee = t.payee ? payees.get(t.payee) : undefined;
      rows.push({
        id: t.id,
        date: t.date,
        account: account.name,
        offbudget: account.offbudget ?? false,
        payee: payee?.name ?? null,
        imported_payee: t.imported_payee ?? null,
        category: (t.category && cats.get(t.category)?.name) ?? null,
        group: (t.category && cats.get(t.category)?.group) ?? null,
        amount: t.amount,
        notes: t.notes ?? null,
        cleared: t.cleared ?? false,
        reconciled: t.reconciled ?? false,
        transfer: Boolean(t.transfer_id || payee?.transfer_acct),
        split: t.is_parent ? 'parent' : t.is_child ? 'child' : null,
        starting_balance: t.starting_balance_flag ?? false,
      });
    }
  }
  return rows.sort((a, b) => a.date.localeCompare(b.date) || a.id.localeCompare(b.id));
}

type Row = Awaited<ReturnType<typeof allTransactions>>[number];

// Ids may be given as unique prefixes (what the tables show).
function resolveIds(rows: Row[], refs: string[]) {
  return refs.map((ref) => {
    const hits = rows.filter((r) => r.id.startsWith(ref));
    if (hits.length === 1) return hits[0]!;
    if (hits.length === 0) throw new Error(`no transaction with id ${ref}`);
    throw new Error(`${hits.length} transactions start with ${ref}; give more of the id`);
  });
}

export const ops: Record<string, (a: Args) => Promise<unknown>> = {
  // ---- accounts
  balances: async () => {
    const out = [];
    for (const a of await api.getAccounts()) {
      out.push({ id: a.id, name: a.name, offbudget: a.offbudget ?? false, closed: a.closed ?? false, balance: await api.getAccountBalance(a.id) });
    }
    return out;
  },

  // ---- categories and groups
  categories: async () => groups(),

  'category.add': async (a) => {
    const groupName = str(a, 'group');
    const name = str(a, 'name');
    let group = (await groups()).find((g) => g.name.toLowerCase() === groupName.toLowerCase());
    let groupCreated = false;
    if (!group) {
      const id = await api.createCategoryGroup({ name: groupName });
      group = { id, name: groupName, is_income: false, hidden: false, categories: [] };
      groupCreated = true;
    }
    if (group.categories.some((c) => c.name.toLowerCase() === name.toLowerCase())) throw new Error(`'${group.name}/${name}' exists already`);
    const id = await api.createCategory({ name, group_id: group.id });
    return { id, group: group.name, groupCreated };
  },
  'category.rename': async (a) => {
    const c = await findCategory(str(a, 'name'));
    await api.updateCategory(c.id, { name: str(a, 'newName') });
    return { id: c.id };
  },
  'category.move': async (a) => {
    const c = await findCategory(str(a, 'name'));
    const g = await findGroup(str(a, 'group'));
    await api.updateCategory(c.id, { name: c.name, group_id: g.id });
    return { id: c.id, group: g.name };
  },
  'category.hide': async (a) => {
    const c = await findCategory(str(a, 'name'));
    await api.updateCategory(c.id, { name: c.name, hidden: a.hidden !== false });
    return { id: c.id };
  },
  'category.delete': async (a) => {
    const c = await findCategory(str(a, 'name'));
    const to = optStr(a, 'moveTo');
    await api.deleteCategory(c.id, to ? (await findCategory(to)).id : undefined);
    return { id: c.id, movedTo: to ?? null };
  },
  'group.add': async (a) => ({ id: await api.createCategoryGroup({ name: str(a, 'name'), is_income: a.income === true }) }),
  'group.rename': async (a) => {
    const g = await findGroup(str(a, 'name'));
    await api.updateCategoryGroup(g.id, { name: str(a, 'newName') });
    return { id: g.id };
  },
  'group.delete': async (a) => {
    const g = await findGroup(str(a, 'name'));
    const to = optStr(a, 'moveTo');
    await api.deleteCategoryGroup(g.id, to ? (await findCategory(to)).id : undefined);
    return { id: g.id, movedTo: to ?? null };
  },

  // ---- the budget itself
  'budget.months': async () => api.getBudgetMonths(),
  'budget.month': async (a) => {
    const m = await api.getBudgetMonth(str(a, 'month'));
    const field = (o: Record<string, unknown>, k: string) => o[k];
    return {
      month: m.month,
      toBudget: m.toBudget,
      incomeAvailable: m.incomeAvailable,
      totalIncome: m.totalIncome,
      totalBudgeted: m.totalBudgeted,
      totalSpent: m.totalSpent,
      totalBalance: m.totalBalance,
      fromLastMonth: m.fromLastMonth,
      forNextMonth: m.forNextMonth,
      lastMonthOverspent: m.lastMonthOverspent,
      groups: m.categoryGroups.map((g) => ({
        name: String(field(g, 'name')),
        is_income: Boolean(field(g, 'is_income')),
        hidden: Boolean(field(g, 'hidden')),
        budgeted: Number(field(g, 'budgeted') ?? 0),
        spent: Number(field(g, 'spent') ?? 0),
        balance: Number(field(g, 'balance') ?? 0),
        categories: (g.categories ?? []).map((c) => ({
          id: String(field(c, 'id')),
          name: String(field(c, 'name')),
          hidden: Boolean(field(c, 'hidden')),
          budgeted: Number(field(c, 'budgeted') ?? 0),
          spent: Number(field(c, 'spent') ?? 0),
          balance: Number(field(c, 'balance') ?? 0),
          carryover: Boolean(field(c, 'carryover')),
        })),
      })),
    };
  },
  'budget.set': async (a) => {
    const c = await findCategory(str(a, 'category'));
    await api.setBudgetAmount(str(a, 'month'), c.id, num(a, 'amount'));
    return { category: `${c.group}/${c.name}` };
  },
  'budget.carryover': async (a) => {
    const c = await findCategory(str(a, 'category'));
    await api.setBudgetCarryover(str(a, 'month'), c.id, a.flag !== false);
    return { category: `${c.group}/${c.name}` };
  },
  // Every category's budgeted amount from one month copied onto another.
  'budget.copy': async (a) => {
    const from = await api.getBudgetMonth(str(a, 'from'));
    const to = str(a, 'to');
    let copied = 0;
    for (const g of from.categoryGroups) {
      if (g.is_income) continue;
      for (const c of g.categories ?? []) {
        const budgeted = Number(c.budgeted ?? 0);
        await api.setBudgetAmount(to, String(c.id), budgeted);
        copied++;
      }
    }
    return { copied };
  },
  'budget.hold': async (a) => ({ held: await api.holdBudgetForNextMonth(str(a, 'month'), num(a, 'amount')) }),

  // ---- transactions
  transactions: async (a) => {
    let rows = await allTransactions(optStr(a, 'since'), optStr(a, 'until'));
    const account = optStr(a, 'account');
    if (account) rows = rows.filter((r) => r.account.toLowerCase() === account.toLowerCase());
    const payee = optStr(a, 'payee');
    if (payee) rows = rows.filter((r) => (r.payee ?? '').toLowerCase().includes(payee.toLowerCase()) || (r.imported_payee ?? '').toLowerCase().includes(payee.toLowerCase()));
    const category = optStr(a, 'category');
    if (category) rows = rows.filter((r) => (r.category ?? '').toLowerCase() === category.toLowerCase());
    if (a.uncategorized === true) rows = rows.filter((r) => !r.category && !r.transfer && !r.offbudget && r.split !== 'parent');
    const limit = typeof a.limit === 'number' ? a.limit : undefined;
    return limit ? rows.slice(-limit) : rows;
  },
  // Set category, payee and/or notes on transactions given by id (prefix), or
  // on every uncategorized transaction of a payee.
  'transaction.update': async (a) => {
    const rows = await allTransactions();
    const refs = Array.isArray(a.ids) ? (a.ids as string[]) : [];
    let targets = resolveIds(rows, refs);
    const payeeFilter = optStr(a, 'ofPayee');
    if (payeeFilter) {
      targets = targets.concat(
        rows.filter((r) => !r.category && !r.transfer && r.split !== 'parent' && (r.payee ?? r.imported_payee ?? '').toLowerCase() === payeeFilter.toLowerCase()),
      );
    }
    if (targets.length === 0) throw new Error('nothing to update: give transaction ids, or ofPayee');
    const fields: Record<string, unknown> = {};
    const category = optStr(a, 'category');
    if (category) fields.category = category.toLowerCase() === 'none' ? null : (await findCategory(category)).id;
    const payee = optStr(a, 'payee');
    if (payee) {
      const existing = (await api.getPayees()).find((p) => p.name.toLowerCase() === payee.toLowerCase());
      fields.payee = existing ? existing.id : await api.createPayee({ name: payee });
    }
    if (typeof a.notes === 'string') fields.notes = a.notes;
    if (typeof a.cleared === 'boolean') fields.cleared = a.cleared;
    if (Object.keys(fields).length === 0) throw new Error('nothing to change: give category, payee, notes or cleared');
    for (const t of targets) await api.updateTransaction(t.id, fields);
    return { updated: targets.length, ids: targets.map((t) => t.id) };
  },
  'transaction.delete': async (a) => {
    const targets = resolveIds(await allTransactions(), Array.isArray(a.ids) ? (a.ids as string[]) : []);
    for (const t of targets) await api.deleteTransaction(t.id);
    return { deleted: targets.length };
  },
  'transaction.add': async (a) => {
    const account = await findAccount(str(a, 'account'));
    const category = optStr(a, 'category');
    const id = await api.addTransactions(account.id, [
      {
        date: str(a, 'date'),
        amount: num(a, 'amount'),
        payee_name: optStr(a, 'payee'),
        category: category ? (await findCategory(category)).id : undefined,
        notes: optStr(a, 'notes'),
        cleared: a.cleared !== false,
      },
    ]);
    return { result: id };
  },

  // Totals by category, payee or account over a period; on-budget, no
  // transfers, no split parents (their children carry the categories).
  spending: async (a) => {
    const by = optStr(a, 'by') ?? 'category';
    const rows = (await allTransactions(optStr(a, 'since'), optStr(a, 'until'))).filter(
      (r) => !r.offbudget && !r.transfer && !r.starting_balance && r.split !== 'parent',
    );
    const key = (r: Row) =>
      by === 'payee' ? (r.payee ?? r.imported_payee ?? '(no payee)') : by === 'account' ? r.account : by === 'group' ? (r.group ?? '(uncategorized)') : (r.category ?? '(uncategorized)');
    const totals = new Map<string, { name: string; spent: number; income: number; count: number }>();
    for (const r of rows) {
      const k = key(r);
      const t = totals.get(k) ?? { name: k, spent: 0, income: 0, count: 0 };
      if (r.amount < 0) t.spent += r.amount;
      else t.income += r.amount;
      t.count++;
      totals.set(k, t);
    }
    return [...totals.values()].sort((x, y) => x.spent - y.spent || y.income - x.income);
  },

  // ---- payees
  payees: async () => {
    const rows = await allTransactions();
    const counts = new Map<string, number>();
    for (const r of rows) if (r.payee) counts.set(r.payee, (counts.get(r.payee) ?? 0) + 1);
    return (await api.getPayees()).map((p) => ({ id: p.id, name: p.name, transfer: Boolean(p.transfer_acct), transactions: counts.get(p.name) ?? 0 }));
  },
  'payee.rename': async (a) => {
    const p = await findPayee(str(a, 'name'));
    await api.updatePayee(p.id, { name: str(a, 'newName') });
    return { id: p.id };
  },
  'payee.merge': async (a) => {
    const into = await findPayee(str(a, 'into'));
    const from = Array.isArray(a.from) ? (a.from as string[]) : [];
    const ids = [];
    for (const name of from) ids.push((await findPayee(name)).id);
    await api.mergePayees(into.id, ids);
    return { into: into.name, merged: ids.length };
  },

  // ---- rules
  rules: async () => {
    const { cats, payees, accounts } = await names();
    const show = (field: string, value: unknown): unknown => {
      if (typeof value !== 'string') return value;
      if (field === 'category') return cats.get(value) ? `${cats.get(value)!.group}/${cats.get(value)!.name}` : value;
      if (field === 'payee') return payees.get(value)?.name ?? value;
      if (field === 'account') return accounts.get(value)?.name ?? value;
      return value;
    };
    return (await api.getRules()).map((r) => ({
      id: r.id,
      stage: r.stage ?? 'default',
      conditionsOp: r.conditionsOp,
      conditions: r.conditions.map((c) => ({ field: c.field, op: c.op, value: show(c.field, c.value) })),
      actions: r.actions.map((x) => ('field' in x ? { op: x.op, field: x.field, value: show(x.field, x.value) } : { op: x.op, value: x.value })),
    }));
  },
  // payee is NAME -> category, or imported payee text contains TEXT -> category.
  'rule.add': async (a) => {
    const c = await findCategory(str(a, 'category'));
    const payee = optStr(a, 'payee');
    const contains = optStr(a, 'contains');
    if (!payee && !contains) throw new Error('give payee or contains');
    const conditions = [];
    if (payee) conditions.push({ field: 'payee' as const, op: 'is' as const, value: (await findPayee(payee)).id, type: 'id' as const });
    if (contains) conditions.push({ field: 'imported_payee' as const, op: 'contains' as const, value: contains, type: 'string' as const });
    const created = await api.createRule({
      stage: 'default',
      conditionsOp: 'and',
      conditions,
      actions: [{ op: 'set', field: 'category', value: c.id, type: 'id' }],
    });
    return { id: (created as { id?: string }).id ?? null, category: `${c.group}/${c.name}` };
  },
  'rule.delete': async (a) => ({ deleted: await api.deleteRule(str(a, 'id')) }),
};

export async function runOp(op: string, args: Args): Promise<unknown> {
  const handler = ops[op];
  if (!handler) throw new Error(`unknown op '${op}'; one of: ${Object.keys(ops).join(', ')}`);
  return handler(args);
}
