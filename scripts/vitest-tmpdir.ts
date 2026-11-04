// vitest globalSetup: give each test run its own TMPDIR and remove it afterwards. Many tests make temp dirs
// with mkdtempSync(join(os.tmpdir(), ...)) and leave them; a full run left ~750 in the macOS $TMPDIR.
// Workers start after this runs, so they inherit the env, and os.tmpdir() reads TMPDIR on every call.
// Under /tmp, not the macOS $TMPDIR: its long /var/folders/... path plus one more level pushes test
// sockets (…/data/ncl.sock) past the 104-byte Unix socket path limit (connect EINVAL).
// Fork delta (Euan, 4 Nov 2026).
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';

export default function setup(): () => void {
  const dir = mkdtempSync(join(process.platform === 'win32' ? (process.env.TEMP ?? '.') : '/tmp', 'nc-run-'));
  process.env.TMPDIR = dir;
  return () => rmSync(dir, { recursive: true, force: true });
}
