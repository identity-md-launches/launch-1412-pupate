// Shared pieces of the local launch harness: paths, the anvil accounts, the mainnet contracts the fork
// must carry, JSON-RPC and `cast` helpers. Nothing here prints MAINNET_RPC_URL.
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const HERE = dirname(fileURLToPath(import.meta.url));
export const ROOT = resolve(HERE, '..', '..');
export const CHAIN_ID = 31337;
export const PORT = Number(process.env.ANVIL_PORT || 8545);
export const RPC_URL = `http://127.0.0.1:${PORT}`;
/** Runtime files (anvil's pid and log) live outside the repository. */
export const RUN_DIR = join(tmpdir(), 'pupate-local');
export const PID_FILE = join(RUN_DIR, 'anvil.pid');
export const LOG_FILE = join(RUN_DIR, 'anvil.log');
export const ADDRESSES_FILE = join(ROOT, 'site', 'public', 'addresses.local.json');
export const QUESTION_FILE = join(ROOT, 'keeper', 'questions', 'floor.question.txt');

/** anvil's default accounts (mnemonic "test test ... junk"). Public test keys, worthless anywhere else. */
export const ACCOUNTS = {
  deployer: { index: 0, address: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' }, // DEVELOPER, OPERATOR, deployer
  buyer: { index: 1, address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' }, // the smoke test's trader
  swarm: { index: 8, address: '0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f' }, // stands in for IMD's 10% swarm share
  attester: {
    index: 9,
    address: '0xa0Ee7A142d267C1f36714E4a8F75612F20a79720',
    key: '0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6',
  },
};

/** All ten default accounts, in anvil's order. */
export const DEFAULT_ACCOUNTS = [
  '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
  '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
  '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
  '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
  '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65',
  '0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc',
  '0x976EA74026E726554dB657fA54763abd0C3a0aa9',
  '0x14dC79964da2C08b23698B3D3cc7Ca32193d9955',
  '0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f',
  '0xa0Ee7A142d267C1f36714E4a8F75612F20a79720',
];

/** Mainnet contracts the fork must carry. Uniswap ones from developers.uniswap.org/docs/protocols/v4/deployments. */
export const MAINNET = {
  poolManager: '0x000000000004444c5dc75cB358380D2e3dE08A90',
  universalRouter: '0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af',
  quoter: '0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203',
  stateView: '0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227',
  permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
  collection: '0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D',
  imd: '0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7',
  seaport: '0x0000000000000068F116a894984e2DB1123eB395',
  create2Factory: '0x4e59b44847b379578588920cA78FbF26c0B4956C',
};
export const POOL_KEY = { fee: 12500, tickSpacing: 60 };
export const ZERO = '0x0000000000000000000000000000000000000000';
export const BPS = 10_000n;

// ------------------------------------------------------------------ environment

export function readDotEnv() {
  const file = join(ROOT, '.env');
  if (!existsSync(file)) return {};
  const out = {};
  for (const raw of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

/** The upstream RPC. Used only as a value; never printed. */
export function forkUrl() {
  const url = process.env.MAINNET_RPC_URL || readDotEnv().MAINNET_RPC_URL;
  if (!url) throw new Error('MAINNET_RPC_URL is not set (environment or .env)');
  return url;
}

/** Hides the upstream URL (and anything after its host) in text that is about to be printed. */
export function redact(text, url) {
  if (!url) return text;
  let out = text.split(url).join('<MAINNET_RPC_URL>');
  try {
    const host = new URL(url).host;
    out = out.split(host).join('<rpc-host>');
  } catch {
    // not a URL; the full-string replacement above is all there is
  }
  return out;
}

// ------------------------------------------------------------------ JSON-RPC

export async function rpc(method, params = []) {
  const res = await fetch(RPC_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result;
}

export async function anvilUp() {
  try {
    return Number(await rpc('eth_chainId')) === CHAIN_ID;
  } catch {
    return false;
  }
}

export async function latestBlock() {
  const b = await rpc('eth_getBlockByNumber', ['latest', false]);
  return { number: Number(b.number), timestamp: Number(b.timestamp), baseFee: BigInt(b.baseFeePerGas ?? 0) };
}

/**
 * anvil's default keys are public, so on mainnet all ten accounts carry an EIP-7702 delegation to a
 * sweeper contract (code 0xef0100…): any ETH they receive is forwarded away at once. The fork inherits
 * that code, so `up` clears it and the accounts behave as the plain EOAs the tests assume. Returns the
 * accounts that had code.
 */
export async function stripDelegations() {
  const stripped = [];
  for (const account of DEFAULT_ACCOUNTS) {
    const code = await rpc('eth_getCode', [account, 'latest']);
    if (code && code !== '0x') {
      await rpc('anvil_setCode', [account, '0x']);
      stripped.push({ account, code });
    }
  }
  return stripped;
}

export async function hasCode(address) {
  const code = await rpc('eth_getCode', [address, 'latest']);
  return Boolean(code) && code !== '0x';
}

// ------------------------------------------------------------------ processes

const FOUNDRY_TOOLS = new Set(['forge', 'cast', 'anvil', 'chisel']);

/** Where foundryup installs a tool, if it is there. */
function foundryBinary(cmd) {
  const dir = process.env.FOUNDRY_DIR || join(homedir(), '.foundry');
  const file = join(dir, 'bin', process.platform === 'win32' ? `${cmd}.exe` : cmd);
  return existsSync(file) ? file : null;
}

export function run(cmd, args, { env, cwd = ROOT, quiet = false } = {}) {
  const options = {
    cwd,
    env: { ...process.env, NO_COLOR: '1', ...env },
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
  };
  let r = spawnSync(cmd, args, options);
  // foundryup adds its folder to the PATH of the shell it ran in. Another shell (PowerShell, cmd)
  // does not have it, so a Foundry tool that is not found by name is looked for where foundryup puts it.
  if (r.error?.code === 'ENOENT' && FOUNDRY_TOOLS.has(cmd)) {
    const file = foundryBinary(cmd);
    if (file) r = spawnSync(file, args, options);
  }
  if (r.error) throw new Error(`${cmd} could not be started: ${r.error.message}`);
  if (r.status !== 0 && !quiet) {
    throw new Error(`${cmd} ${args.slice(0, 2).join(' ')} failed (exit ${r.status})\n${r.stdout}\n${r.stderr}`);
  }
  return r;
}

/** `cast` against the fork. Returns trimmed stdout. */
export function cast(...args) {
  return run('cast', [...args, '--rpc-url', RPC_URL]).stdout.trim();
}

/** `cast` with no RPC (abi-encode, keccak, calldata...). */
export function castLocal(...args) {
  return run('cast', args).stdout.trim();
}

/**
 * A view call, decoded by cast. Returns an array of strings, one per return value ("true"/"false"
 * for bools, checksummed addresses, decimal numbers). Not `--json`: cast prints uint256 values as bare
 * JSON numbers there, and JSON.parse rounds anything past 2^53.
 */
export function call(to, sig, ...args) {
  const out = cast('call', to, sig, ...args.map(String));
  return out
    .split(/\r?\n/)
    .map((line) => line.replace(/\s+\[[^\]]*\]\s*$/, '').trim()) // "61988988381136436 [6.198e16]" -> the number
    .filter((line) => line.length);
}

export function callUint(to, sig, ...args) {
  return BigInt(call(to, sig, ...args)[0]);
}

/**
 * A transaction from one of anvil's unlocked accounts. `sigOrData` is a function signature with
 * `args`, or raw calldata with none. Returns the receipt; throws if it reverted.
 */
export function send(from, to, sigOrData, args = [], { value } = {}) {
  const cli = ['send', to, sigOrData, ...args.map(String), '--from', from, '--unlocked', '--json'];
  if (value !== undefined) cli.push('--value', String(value));
  const receipt = JSON.parse(cast(...cli));
  if (Number(receipt.status) !== 1) throw new Error(`transaction ${receipt.transactionHash} reverted`);
  return receipt;
}

// ------------------------------------------------------------------ files

export function readAddresses() {
  if (!existsSync(ADDRESSES_FILE)) {
    throw new Error(`${ADDRESSES_FILE} is missing: run \`node script/local/up.mjs\` first`);
  }
  return JSON.parse(readFileSync(ADDRESSES_FILE, 'utf8'));
}

/** keccak256 of the exact bytes of keeper/questions/floor.question.txt (the local stand-in for IMD's questionHash). */
export function localQuestionHash() {
  const hex = '0x' + readFileSync(QUESTION_FILE).toString('hex');
  return castLocal('keccak', hex);
}

// ------------------------------------------------------------------ formatting

const ETH = 10n ** 18n;

export function fmtEth(wei) {
  return `${fixed(BigInt(wei), 18, 6)} ETH`;
}

export function fmtPupate(wei) {
  return `${fixed(BigInt(wei), 18, 3)} PUPATE`;
}

export function fmtGwei(wei) {
  return `${fixed(BigInt(wei), 9, 3)} gwei`;
}

function fixed(value, decimals, places) {
  const neg = value < 0n;
  const v = neg ? -value : value;
  const unit = 10n ** BigInt(decimals);
  const whole = v / unit;
  const frac = ((v % unit) * 10n ** BigInt(places)) / unit;
  const fracStr = frac.toString().padStart(places, '0').replace(/0+$/, '');
  return `${neg ? '-' : ''}${whole.toLocaleString('en-US')}${fracStr ? '.' + fracStr : ''}`;
}

export function pct(part, whole) {
  if (whole === 0n) return 'n/a';
  return `${(Number((part * 10000n) / whole) / 100).toFixed(2)}%`;
}

export { ETH };
