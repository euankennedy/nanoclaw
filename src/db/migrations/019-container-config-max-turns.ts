import type { Migration } from './index.js';

/**
 * `max_turns` on `container_configs`: caps the number of agentic turns the
 * provider runs per query. NULL falls back to the code default (20). Local
 * customization preserved across the file→DB container-config refactor —
 * before that refactor maxTurns lived in `groups/<folder>/container.json`,
 * which is now regenerated from the DB on every spawn.
 */
export const migration019: Migration = {
  version: 19,
  name: 'container-config-max-turns',
  up(db) {
    db.exec(`ALTER TABLE container_configs ADD COLUMN max_turns INTEGER;`);
  },
};
