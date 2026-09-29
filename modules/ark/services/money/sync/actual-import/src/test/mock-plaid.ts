// A scripted stand-in for the Plaid API, for the end-to-end check.
//
//   node mock-plaid.js <port> <phase-file>
//
// The phase file (a number) picks what /transactions/sync answers, so the
// check can walk one bank through: an initial pull split over two pages with
// a pending transaction (1), that transaction posting with a different amount
// while another is modified (2), and nothing new (3). The Hosted Link routes
// are kept for completeness; the linking flow itself lives in the ark CLI.
import fs from 'node:fs';
import http from 'node:http';
// The Plaid shapes money-sync reads (see ../../../cli/plaid.rs).
interface PlaidAccount {
  account_id: string;
  name: string;
  mask: string | null;
  type: string;
  subtype: string | null;
  balances: { current: number | null };
}
interface PlaidTransaction {
  transaction_id: string;
  account_id: string;
  amount: number;
  date: string;
  name: string;
  merchant_name: string | null;
  original_description?: string | null;
  pending: boolean;
  pending_transaction_id: string | null;
}
interface RemovedTransaction {
  transaction_id: string;
  account_id: string;
}

const [port, phaseFile] = process.argv.slice(2);
if (!port || !phaseFile) throw new Error('usage: mock-plaid.js <port> <phase-file>');
const phase = () => Number(fs.readFileSync(phaseFile, 'utf8').trim());

const account = (id: string, name: string, mask: string, subtype: string): PlaidAccount => ({
  account_id: id,
  name,
  mask,
  type: 'depository',
  subtype,
  balances: { current: 923.5 },
});
const checking = account('acc1', 'Plaid Checking', '0000', 'checking');
const savings = account('acc2', 'Plaid Savings', '1111', 'savings'); // never mapped: must be ignored

const txn = (id: string, amount: number, name: string, extra: Partial<PlaidTransaction> = {}): PlaidTransaction => ({
  transaction_id: id,
  account_id: 'acc1',
  amount,
  date: '2026-09-20',
  name,
  merchant_name: null,
  original_description: name,
  pending: false,
  pending_transaction_id: null,
  ...extra,
});
const T1 = txn('T1', 50.25, 'COFFEE SHOP #12', { merchant_name: 'Coffee Shop' });
const P1 = txn('P1', 20, 'GAS STATION PENDING', { pending: true, date: '2026-09-21' });
const T2 = txn('T2', 21.5, 'GAS STATION', { pending_transaction_id: 'P1', date: '2026-09-22' });
const T3 = txn('T3', -1000, 'PAYROLL', { date: '2026-09-23' }); // typed in by hand before the bank saw it
const S1 = txn('S1', -10, 'INTEREST', { account_id: 'acc2' });
const T1modified = { ...T1, amount: 55 };

const page = (
  cursor: string,
  added: PlaidTransaction[] = [],
  modified: PlaidTransaction[] = [],
  removed: RemovedTransaction[] = [],
  has_more = false,
) => ({ added, modified, removed, next_cursor: cursor, has_more });

function transactionsSync(cursor: unknown) {
  const p = phase();
  if (p === 1 && !cursor) return page('p1a', [T1, S1], [], [], true);
  if (p === 1 && cursor === 'p1a') return page('c1', [P1, T3]);
  if (p === 2 && cursor === 'c1') return page('c2', [T2], [T1modified], [{ transaction_id: 'P1', account_id: 'acc1' }]);
  if (p >= 2 && cursor === 'c2') return page('c2');
  return null;
}

type Body = Record<string, unknown>;
const routes: Record<string, (b: Body) => object | null> = {
  '/institutions/get': () => ({ institutions: [], total: 0 }), // the CLI's key check; keys are verified above
  '/accounts/get': (b) => ({
    accounts: b.access_token === 'access-new' ? [account('accN', 'New Bank Checking', '9999', 'checking')] : [checking, savings],
    item: {},
  }),
  '/transactions/sync': (b) => transactionsSync(b.cursor),
  '/link/token/create': (b) =>
    b.hosted_link && Array.isArray(b.products) && b.products.includes('transactions')
      ? { link_token: 'link-token', hosted_link_url: 'https://mock.plaid/link' }
      : null,
  '/link/token/get': (b) =>
    b.link_token === 'link-token'
      ? { link_sessions: [{ finished_at: '2026-09-24T00:00:00Z', results: { item_add_results: [{ public_token: 'public-token' }] } }] }
      : null,
  '/item/public_token/exchange': (b) => (b.public_token === 'public-token' ? { access_token: 'access-new', item_id: 'item-new' } : null),
};

http
  .createServer((req, res) => {
    let raw = '';
    req.on('data', (c: Buffer) => (raw += c));
    req.on('end', () => {
      const send = (code: number, obj: object) => {
        res.writeHead(code, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(obj));
      };
      const error = (error_code: string, error_message: string) =>
        send(400, { error_type: 'INVALID_INPUT', error_code, error_message });

      if (req.headers['plaid-client-id'] !== 'client-id' || req.headers['plaid-secret'] !== 'secret') return error('INVALID_API_KEYS', 'bad keys');
      const body = JSON.parse(raw || '{}') as Body;
      if ('access_token' in body && !['access-test', 'access-new'].includes(body.access_token as string))
        return error('INVALID_ACCESS_TOKEN', 'bad token');
      console.log(req.url, JSON.stringify(body));

      const route = routes[req.url ?? ''];
      if (!route) return error('NOT_FOUND', req.url ?? '');
      const reply = route(body);
      if (!reply) return error('INVALID_FIELD', `unexpected request in phase ${phase()}: ${JSON.stringify(body)}`);
      send(200, reply);
    });
  })
  .listen(Number(port), '127.0.0.1', () => console.log(`mock plaid on ${port}`));
