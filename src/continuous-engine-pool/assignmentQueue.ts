import type { ContinuousEnginePoolAssignment } from './types';

/** Native loads cannot overlap: an older load could overwrite a newer page. */
export function createAssignmentQueue() {
  let tail = Promise.resolve();
  let generation = 0;
  const pending = new Set<ContinuousEnginePoolAssignment[]>();
  return {
    enqueue(
      assignments: ContinuousEnginePoolAssignment[],
      run: (pages: ContinuousEnginePoolAssignment[], isCurrent: () => boolean) => Promise<void>,
    ): Promise<void> {
      const request = ++generation;
      const pages = assignments.map(assignment => ({ ...assignment }));
      pending.add(pages);
      const task = tail.then(async () => {
        if (request === generation) await run(pages, () => request === generation);
      }).finally(() => pending.delete(pages));
      // A rejected caller must not poison the queue for the next scroll/retry.
      tail = task.catch(() => undefined);
      return task;
    },
    captured(pageId: string, data: string, previewUri?: string) {
      // A queued return to a page must use ink captured while leaving it,
      // rather than the stale page object supplied before that capture finished.
      for (const pages of pending) {
        for (const assignment of pages) {
          if (assignment.page.id === pageId) {
            assignment.page = { ...assignment.page, data, previewUri };
          }
        }
      }
    },
    async drain() {
      ++generation;
      await tail;
    },
  };
}
