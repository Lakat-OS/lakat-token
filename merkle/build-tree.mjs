#!/usr/bin/env node
// Builds the Merkle tree for LakatTokenDistributor and prints its root.
//
//   node merkle/build-tree.mjs                       # merkle/allocations.json
//   node merkle/build-tree.mjs allocations.csv --out merkle/out
//
// Input is a JSON array of { address, tokens } / { address, amount } objects,
// or a CSV of address,amount pairs (header optional). The format is chosen by
// file extension: .json is JSON, anything else is parsed as CSV.
//
// Output (in --out):
//   tree.json    the full dumped tree; keep it, `proof.mjs` reads it
//   claims.json  address -> { index, amount, proof }, ready to serve to a frontend
//
// The leaf encoding is ["uint256", "address", "uint256"] = (index, account,
// amount), matching LakatTokenDistributor.leafHash.
//
// Flags:
//   --out <dir>          where to write tree.json / claims.json (default merkle/out)
//   --decimals <n>       token decimals for human-readable amounts (default 18)
//   --units tokens|base  how to read the amount column (CSV only; default: from
//                        the header, else tokens)
//   --delimiter <c>      CSV delimiter (default: sniffed, `,` or `;`)
//   --on-duplicate <m>   error (default) | sum | keep — what to do when an
//                        address appears more than once
//   --root-only          print just the root, e.g. ROOT=$(… --root-only)

import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import fs from "node:fs";
import path from "node:path";
import { parseCsv, sniffDelimiter } from "./csv.mjs";

export const LEAF_TYPES = ["uint256", "address", "uint256"];

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ADDRESS_HEADERS = ["address", "account", "user", "wallet", "recipient", "to"];
const BASE_UNIT_HEADERS = ["amount", "wei", "raw", "base", "baseunits"];
const TOKEN_HEADERS = ["tokens", "token", "value", "balance", "qty", "quantity", "allocation"];

/** Parse a human-readable decimal string into base units, without floats. */
export function parseUnits(value, decimals) {
  // Spreadsheets like to add thousands separators and scientific notation.
  const str = String(value).trim().replace(/[_\s]/g, "").replace(/,(?=\d{3}\b)/g, "");
  if (/e/i.test(str)) {
    throw new Error(`"${value}" is in scientific notation; format the column as text and re-export`);
  }
  if (!/^\d+(\.\d+)?$/.test(str)) {
    throw new Error(`not a positive decimal number: "${value}"`);
  }
  const [whole, frac = ""] = str.split(".");
  if (frac.length > decimals) {
    throw new Error(`"${value}" has more than ${decimals} decimals`);
  }
  return BigInt(whole + frac.padEnd(decimals, "0"));
}

const normalise = (s) => s.toLowerCase().replace(/[^a-z]/g, "");

/** CSV -> [{ address, amount }] with amounts already in base units. */
export function readCsv(text, { decimals = 18, units, delimiter } = {}) {
  const rows = parseCsv(text, delimiter ?? sniffDelimiter(text));
  if (rows.length === 0) throw new Error("CSV is empty");

  let addressCol = 0;
  let amountCol = 1;
  let headerUnits;

  const hasHeader = !ADDRESS_RE.test(rows[0][0] ?? "");
  if (hasHeader) {
    const header = rows.shift().map(normalise);
    const findCol = (names) => header.findIndex((h) => names.includes(h));

    addressCol = findCol(ADDRESS_HEADERS);
    if (addressCol === -1) {
      throw new Error(`no address column in header [${header}]; expected one of ${ADDRESS_HEADERS}`);
    }
    const baseCol = findCol(BASE_UNIT_HEADERS);
    const tokenCol = findCol(TOKEN_HEADERS);
    if (baseCol === -1 && tokenCol === -1) {
      throw new Error(
        `no amount column in header [${header}]; expected one of ${[...BASE_UNIT_HEADERS, ...TOKEN_HEADERS]}`,
      );
    }
    // A `tokens` column wins if both are present, but the explicit --units flag
    // always overrides whatever the header implies.
    amountCol = tokenCol !== -1 ? tokenCol : baseCol;
    headerUnits = tokenCol !== -1 ? "tokens" : "base";
    if (rows.length === 0) throw new Error("CSV has a header but no rows");
  }

  const effectiveUnits = units ?? headerUnits ?? "tokens";

  return rows.map((row, i) => {
    const line = i + 1 + (hasHeader ? 1 : 0);
    const address = (row[addressCol] ?? "").trim();
    const raw = (row[amountCol] ?? "").trim();
    if (!raw) throw new Error(`line ${line}: missing amount`);
    try {
      return {
        address,
        amount: effectiveUnits === "base" ? BigInt(raw.replace(/[_\s]/g, "")) : parseUnits(raw, decimals),
        line,
      };
    } catch (e) {
      throw new Error(`line ${line}: ${e.message}`);
    }
  });
}

/** JSON array -> [{ address, amount }] with amounts already in base units. */
export function readJson(text, { decimals = 18 } = {}) {
  const entries = JSON.parse(text);
  if (!Array.isArray(entries)) throw new Error("JSON input must be an array");

  return entries.map((entry, i) => {
    const hasAmount = entry.amount !== undefined;
    const hasTokens = entry.tokens !== undefined;
    if (hasAmount === hasTokens) {
      throw new Error(`entry ${i}: set exactly one of "amount" (base units) or "tokens" (decimal)`);
    }
    return {
      address: entry.address,
      amount: hasAmount ? BigInt(entry.amount) : parseUnits(entry.tokens, decimals),
      line: i,
    };
  });
}

/**
 * Validate, apply the duplicate policy, and build the tree.
 *
 * Leaf indices are array positions, so the order of `allocations` is part of
 * the published root: never reorder or insert into a list whose root is live.
 */
export function buildTree(allocations, { onDuplicate = "error" } = {}) {
  const byAddress = new Map();
  const ordered = [];

  for (const entry of allocations) {
    if (!ADDRESS_RE.test(entry.address ?? "")) {
      throw new Error(`line ${entry.line}: invalid address ${JSON.stringify(entry.address)}`);
    }
    if (entry.amount <= 0n) throw new Error(`line ${entry.line}: amount must be > 0`);

    const key = entry.address.toLowerCase();
    const seen = byAddress.get(key);
    if (seen) {
      if (onDuplicate === "error") {
        throw new Error(
          `${entry.address} appears on lines ${seen.line} and ${entry.line}. ` +
            "Pass --on-duplicate sum to merge them, or --on-duplicate keep to give it two claimable leaves.",
        );
      }
      if (onDuplicate === "sum") {
        seen.amount += entry.amount;
        continue;
      }
    } else {
      byAddress.set(key, entry);
    }
    ordered.push(entry);
  }

  const values = ordered.map((entry, index) =>
    // Strings, not BigInt: the dumped tree has to be JSON-serialisable.
    [String(index), entry.address, entry.amount.toString()],
  );
  const total = ordered.reduce((sum, e) => sum + e.amount, 0n);

  return { tree: StandardMerkleTree.of(values, LEAF_TYPES), total, count: ordered.length };
}

/** Render base units as a decimal string, for human-readable logging. */
export function formatUnits(amount, decimals) {
  const s = amount.toString().padStart(decimals + 1, "0");
  const frac = s.slice(s.length - decimals).replace(/0+$/, "");
  return s.slice(0, s.length - decimals) + (frac ? `.${frac}` : "");
}

function parseArgs(argv) {
  const opts = { out: "merkle/out", decimals: 18, onDuplicate: "error", rootOnly: false };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--out") opts.out = argv[++i];
    else if (arg === "--decimals") opts.decimals = Number(argv[++i]);
    else if (arg === "--units") opts.units = argv[++i];
    else if (arg === "--delimiter") opts.delimiter = argv[++i];
    else if (arg === "--on-duplicate") opts.onDuplicate = argv[++i];
    else if (arg === "--root-only") opts.rootOnly = true;
    else if (arg.startsWith("--")) throw new Error(`unknown flag ${arg}`);
    else rest.push(arg);
  }
  opts.input = rest[0] ?? "merkle/allocations.json";

  if (opts.units && !["tokens", "base"].includes(opts.units)) {
    throw new Error(`--units must be "tokens" or "base", got "${opts.units}"`);
  }
  if (!["error", "sum", "keep"].includes(opts.onDuplicate)) {
    throw new Error(`--on-duplicate must be "error", "sum" or "keep", got "${opts.onDuplicate}"`);
  }
  return opts;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const { input, out, decimals, rootOnly } = opts;

  if (!fs.existsSync(input)) {
    console.error(`No allocations file at ${input}.`);
    console.error("Copy merkle/allocations.example.json to merkle/allocations.json and edit it,");
    console.error("or pass a path explicitly: node merkle/build-tree.mjs <file.json|file.csv>");
    process.exit(1);
  }

  const text = fs.readFileSync(input, "utf8");
  const allocations = input.toLowerCase().endsWith(".json") ? readJson(text, opts) : readCsv(text, opts);
  const { tree, total, count } = buildTree(allocations, opts);

  // address -> array of claims. Always an array: with --on-duplicate keep an
  // address can hold several independently claimable leaves, and a plain
  // address -> claim map would silently drop all but the last.
  const claims = {};
  for (const [i, [index, account, amount]] of tree.entries()) {
    (claims[account] ??= []).push({
      index: Number(index),
      account,
      amount: String(amount),
      proof: tree.getProof(i),
    });
  }

  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, "tree.json"), JSON.stringify(tree.dump(), null, 2));
  fs.writeFileSync(
    path.join(out, "claims.json"),
    JSON.stringify({ root: tree.root, recipients: count, total: total.toString(), claims }, null, 2),
  );

  if (rootOnly) {
    console.log(tree.root);
    return;
  }

  console.log(`input:       ${input}`);
  console.log(`recipients:  ${count}`);
  console.log(`total:       ${formatUnits(total, decimals)} tokens (${total} base units)`);
  console.log(`tree:        ${path.join(out, "tree.json")}`);
  console.log(`claims:      ${path.join(out, "claims.json")}`);
  console.log("");
  console.log(`MERKLE_ROOT=${tree.root}`);
  console.log("");
  console.log("Fund the distributor with at least the total above, then publish the root:");
  console.log(`  DISTRIBUTOR=<proxy> MERKLE_ROOT=${tree.root} \\`);
  console.log("    forge script script/Deploy.s.sol:SetMerkleRoot \\");
  console.log("      --rpc-url $RPC_URL --broadcast --force");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    main();
  } catch (e) {
    console.error(`error: ${e.message}`);
    process.exit(1);
  }
}
