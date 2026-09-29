#!/usr/bin/env node
// actual-import: the Actual half of money-sync (see ../../src/main.rs).
//
// Why this is Node: Actual has no HTTP API for transactions. Writing one
// means speaking the client's CRDT sync protocol and running its reconciler
// and rules engine, which exist only in the official @actual-app/api. So
// money-sync (Rust) does everything else and pipes requests through here.
//
// stdin, one of:
//   the import:  { actual, accounts: [ AccountChanges ] }          -> { accounts: [ AccountReport ] }
//   any other op: { actual, op: "budget.month", args: { ... } }   -> { result: ... }
// with actual = { serverURL, tokenFile, syncId?, encryptionPasswordFile? }.
// import.ts and ops.ts have the details; stdout is the answer alone.
import fs from 'node:fs';
import { withActual, type ActualConfig } from './actual.js';
import { runImport, type AccountChanges } from './import.js';
import { runOp } from './ops.js';

// Everything the API might print goes to stderr; stdout is the report alone.
console.log = console.error;

interface Request {
  actual: ActualConfig;
  accounts?: AccountChanges[];
  op?: string;
  args?: Record<string, unknown>;
}

const request = JSON.parse(fs.readFileSync(0, 'utf8')) as Request;
const answer = await withActual(request.actual, async () => {
  if (request.op) return { result: await runOp(request.op, request.args ?? {}) };
  return { accounts: await runImport(request.accounts ?? []) };
});
process.stdout.write(JSON.stringify(answer) + '\n');
