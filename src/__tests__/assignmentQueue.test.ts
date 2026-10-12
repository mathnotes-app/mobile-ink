import { createAssignmentQueue } from '../continuous-engine-pool/assignmentQueue';

const assignment = (id: string) => [{ page: { id, title: id, rotation: 0, data: 'old' }, pageIndex: 0 }];

it('serializes native loads and skips superseded queued windows', async () => {
  const queue = createAssignmentQueue();
  let release!: () => void;
  const started: string[] = [];
  const first = queue.enqueue(assignment('a'), async (_, isCurrent) => {
    started.push('a');
    await new Promise<void>(resolve => { release = resolve; });
    expect(isCurrent()).toBe(false);
  });
  await Promise.resolve();
  const skipped = queue.enqueue(assignment('b'), async () => { started.push('b'); });
  const last = queue.enqueue(assignment('c'), async () => { started.push('c'); });
  expect(started).toEqual(['a']);
  release();
  await Promise.all([first, skipped, last]);
  expect(started).toEqual(['a', 'c']);
});

it('uses newly captured ink when a return to its page was already queued', async () => {
  const queue = createAssignmentQueue();
  let release!: () => void;
  const first = queue.enqueue(assignment('b'), async () => {
    await new Promise<void>(resolve => { release = resolve; });
    queue.captured('a', 'new ink', 'preview');
  });
  await Promise.resolve();
  const original = assignment('a');
  const last = queue.enqueue(original, async pages => {
    expect(pages[0].page.data).toBe('new ink');
    expect(pages[0].page.previewUri).toBe('preview');
  });
  release();
  await Promise.all([first, last]);
  expect(original[0].page.data).toBe('old');
});

it('drains active work, cancels queued work, and recovers after errors', async () => {
  const queue = createAssignmentQueue();
  await expect(queue.enqueue(assignment('a'), async () => { throw new Error('failed'); })).rejects.toThrow('failed');
  const run = jest.fn(async () => undefined);
  await queue.enqueue(assignment('b'), run);
  expect(run).toHaveBeenCalledTimes(1);
  const canceled = queue.enqueue(assignment('c'), run);
  await queue.drain();
  await canceled;
  expect(run).toHaveBeenCalledTimes(1);
});
