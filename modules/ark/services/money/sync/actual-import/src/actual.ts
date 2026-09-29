// Opening the budget, and looking things up by the names people use.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import * as api from '@actual-app/api';

export { api };

export interface ActualConfig {
  serverURL: string;
  tokenFile: string;
  syncId?: string | null;
  encryptionPasswordFile?: string | null;
}

export const readSecret = (file: string) => fs.readFileSync(file, 'utf8').trim();

// Runs fn with the budget open. The budget is downloaded fresh into a temp
// dir every time: it is small, and a stale local copy is the classic way the
// API gets itself stuck. shutdown() pushes whatever fn changed to the server.
export async function withActual<T>(actual: ActualConfig, fn: () => Promise<T>): Promise<T> {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'actual-import-'));
  let open = false;
  try {
    await api.init({ dataDir, serverURL: actual.serverURL, sessionToken: readSecret(actual.tokenFile), verbose: false });
    open = true;
    // Actual's "Sync ID" is the file's group id.
    let syncId = actual.syncId;
    if (!syncId) {
      const budgets = await api.getBudgets();
      const only = budgets.length === 1 ? budgets[0] : undefined;
      if (!only?.groupId) {
        const list = budgets.map((b) => `  ${b.name}: ${b.groupId}`).join('\n') || '  (none)';
        throw new Error(`expected exactly one budget on the server, found ${budgets.length}; set ark.money.syncId to one of:\n${list}`);
      }
      syncId = only.groupId;
    }
    await api.downloadBudget(syncId, actual.encryptionPasswordFile ? { password: readSecret(actual.encryptionPasswordFile) } : {});
    return await fn();
  } finally {
    if (open) await api.shutdown().catch((e: Error) => console.error('shutdown:', e.message));
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
}

export interface Category {
  id: string;
  name: string;
  group: string;
  group_id: string;
  is_income: boolean;
  hidden: boolean;
}

export interface Group {
  id: string;
  name: string;
  is_income: boolean;
  hidden: boolean;
  categories: Category[];
}

export async function groups(): Promise<Group[]> {
  return (await api.getCategoryGroups()).map((g) => ({
    id: g.id,
    name: g.name,
    is_income: g.is_income ?? false,
    hidden: g.hidden ?? false,
    categories: (g.categories ?? []).map((c) => ({
      id: c.id,
      name: c.name,
      group: g.name,
      group_id: g.id,
      is_income: c.is_income ?? false,
      hidden: c.hidden ?? false,
    })),
  }));
}

const fold = (s: string) => s.trim().toLowerCase();

// "Groceries", or "Everyday/Groceries" when two groups have a category of the same name.
export async function findCategory(ref: string): Promise<Category> {
  const all = (await groups()).flatMap((g) => g.categories);
  const [groupPart, namePart] = ref.includes('/') ? ref.split('/', 2) : [undefined, ref];
  const hits = all.filter((c) => fold(c.name) === fold(namePart ?? '') && (groupPart === undefined || fold(c.group) === fold(groupPart)));
  if (hits.length === 1) return hits[0]!;
  if (hits.length === 0) throw new Error(`no category '${ref}'; \`categories\` lists them`);
  throw new Error(`'${ref}' is a category in several groups: ${hits.map((c) => `${c.group}/${c.name}`).join(', ')}; say which`);
}

export async function findGroup(name: string): Promise<Group> {
  const hits = (await groups()).filter((g) => fold(g.name) === fold(name));
  if (hits.length === 1) return hits[0]!;
  if (hits.length === 0) throw new Error(`no category group '${name}'; \`categories\` lists them`);
  throw new Error(`${hits.length} groups are named '${name}'`);
}

export async function findPayee(name: string) {
  const hits = (await api.getPayees()).filter((p) => fold(p.name) === fold(name));
  if (hits.length === 1) return hits[0]!;
  if (hits.length === 0) throw new Error(`no payee '${name}'; \`payees\` lists them`);
  throw new Error(`${hits.length} payees are named '${name}'`);
}

export async function findAccount(name: string) {
  const hits = (await api.getAccounts()).filter((a) => fold(a.name) === fold(name));
  if (hits.length === 1) return hits[0]!;
  if (hits.length === 0) throw new Error(`no account '${name}'; \`balances\` lists them`);
  throw new Error(`${hits.length} accounts are named '${name}'`);
}

/** Case-insensitive name -> id maps for resolving what transactions reference. */
export async function names() {
  const cats = new Map((await groups()).flatMap((g) => g.categories).map((c) => [c.id, c]));
  const payees = new Map((await api.getPayees()).map((p) => [p.id, p]));
  const accounts = new Map((await api.getAccounts()).map((a) => [a.id, a]));
  return { cats, payees, accounts };
}
