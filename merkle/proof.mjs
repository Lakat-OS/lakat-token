#!/usr/bin/env node
// Prints the claim arguments for a recipient, from the tree built by build-tree.mjs.
//
//   node merkle/proof.mjs 0xRecipient [--distributor 0x…]
//   node merkle/proof.mjs --all --json > proofs.json
//
// Flags:
//   --tree <file>        dumped tree to read (default merkle/out/tree.json)
//   --distributor <addr> address to put in the printed `cast send`
//   --json               emit JSON only (no cast invocation)
//   --all                every leaf in the tree, not just one address

import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import fs from "node:fs";

function parseArgs(argv) {
  const opts = { tree: "merkle/out/tree.json", distributor: "$DISTRIBUTOR", json: false, all: false };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--tree") opts.tree = argv[++i];
    else if (arg === "--distributor") opts.distributor = argv[++i];
    else if (arg === "--json") opts.json = true;
    else if (arg === "--all") opts.all = true;
    else if (arg.startsWith("--")) throw new Error(`unknown flag ${arg}`);
    else rest.push(arg);
  }
  opts.address = rest[0];
  return opts;
}

function castSend(claim, distributor) {
  return [
    "cast send \\",
    `  ${distributor} \\`,
    '  "claim(uint256,address,uint256,bytes32[])" \\',
    `  ${claim.index} ${claim.account} ${claim.amount} "[${claim.proof.join(",")}]" \\`,
    "  --rpc-url $RPC_URL --private-key $PRIVATE_KEY",
  ].join("\n");
}

function main() {
  const { address, tree: treePath, distributor, json, all } = parseArgs(process.argv.slice(2));

  if (!address && !all) {
    console.error("usage: node merkle/proof.mjs <address> [--tree merkle/out/tree.json] [--distributor 0x…]");
    console.error("       node merkle/proof.mjs --all --json");
    process.exit(1);
  }
  if (!fs.existsSync(treePath)) {
    console.error(`No tree at ${treePath}. Run \`npm run merkle:build\` first.`);
    process.exit(1);
  }

  const tree = StandardMerkleTree.load(JSON.parse(fs.readFileSync(treePath, "utf8")));

  const claims = [];
  for (const [i, [index, account, amount]] of tree.entries()) {
    if (all || account.toLowerCase() === address.toLowerCase()) {
      claims.push({ index: Number(index), account, amount: String(amount), proof: tree.getProof(i) });
    }
  }

  if (claims.length === 0) {
    console.error(`${address} is not in the tree (root ${tree.root}).`);
    process.exit(1);
  }

  if (json) {
    console.log(JSON.stringify({ root: tree.root, claims }, null, 2));
    return;
  }

  console.log(`root: ${tree.root}`);
  for (const claim of claims) {
    console.log("");
    console.log(JSON.stringify(claim, null, 2));
    console.log("");
    console.log(castSend(claim, distributor));
  }
}

try {
  main();
} catch (e) {
  console.error(`error: ${e.message}`);
  process.exit(1);
}
