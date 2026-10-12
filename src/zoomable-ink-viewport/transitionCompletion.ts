/** Native may retain this function after timing animations finish. Keep consumers
 * in replaceable state and release them when finished, superseded, or unmounted. */
export function createTransitionCompletion() {
  let pending: {token: number; remaining: number; finish: () => void} | null = null;
  return {
    begin(token: number, axes: number, finish: () => void) {
      pending = {token, remaining: axes, finish};
    },
    clear() { pending = null; },
    completeAxis(token: number, finished = true) {
      if (!pending || pending.token !== token) return;
      if (!finished) { pending = null; return; }
      if (--pending.remaining > 0) return;
      const finish = pending.finish;
      pending = null;
      finish();
    },
  };
}
