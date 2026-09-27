/**
 * --script-timeout-ms validation: create-time range/coupling checks in
 * prepareScheduledTask, and the content JSON shape createScheduledTask
 * persists (the container's resolveScriptTimeoutMs reads that exact key).
 */
import { describe, expect, it } from 'vitest';

import { prepareScheduledTask, SCRIPT_TIMEOUT_MAX_MS, validateScriptTimeoutMs } from './create.js';

describe('validateScriptTimeoutMs', () => {
  it('passes through a valid override and null/undefined', () => {
    expect(validateScriptTimeoutMs(90_000, true)).toBe(90_000);
    expect(validateScriptTimeoutMs(null, true)).toBeNull();
    expect(validateScriptTimeoutMs(undefined, false)).toBeNull();
  });

  it('rejects out-of-range and non-integer values', () => {
    expect(() => validateScriptTimeoutMs(999, true)).toThrow(/between 1000/);
    expect(() => validateScriptTimeoutMs(SCRIPT_TIMEOUT_MAX_MS + 1, true)).toThrow(/between 1000/);
    expect(() => validateScriptTimeoutMs(1500.5, true)).toThrow(/integer/);
  });

  it('rejects an override without a script', () => {
    expect(() => validateScriptTimeoutMs(60_000, false)).toThrow(/requires --script/);
  });
});

describe('prepareScheduledTask scriptTimeoutMs', () => {
  it('carries the override through when a script is present', () => {
    const prepared = prepareScheduledTask({
      prompt: 'p',
      recurrence: '0 9 * * *',
      script: 'echo hi',
      scriptTimeoutMs: 120_000,
    });
    expect(prepared.scriptTimeoutMs).toBe(120_000);
  });

  it('defaults to null when omitted', () => {
    const prepared = prepareScheduledTask({ prompt: 'p', recurrence: '0 9 * * *', script: 'echo hi' });
    expect(prepared.scriptTimeoutMs).toBeNull();
  });

  it('refuses an override on a script-less task', () => {
    expect(() =>
      prepareScheduledTask({ prompt: 'p', processAfter: '2999-01-01T00:00:00.000Z', scriptTimeoutMs: 60_000 }),
    ).toThrow(/requires --script/);
  });
});
