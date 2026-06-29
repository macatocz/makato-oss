// Synthetic "Wrapper for Wrapper's Sake" anti-pattern.
//
// Source: plugins/makato-build/skills/build-simplify/references/simplification-patterns.md
// § *Wrapper for Wrapper's Sake*.
//
// This file is the "before" state of a SIMPLIFY finding the smoke test
// reasons about. `build-simplify` Step 4 would classify the wrapper as
// SIMPLIFY because it adds no cross-cutting behavior; Step 6 would inline the
// wrapped `UserService`. The smoke test does NOT apply the simplification —
// it asserts the 7-step JSONL arc and the R1 envelope shape against an
// unmodified diff. The file's only job is to exist as a `.ts` (non-doc,
// non-config) touch target so Step 7a's "code files touched" gate fires.

export interface User {
  id: string;
  name: string;
}

export class UserService {
  findById(id: string): User | null {
    return { id, name: 'placeholder' };
  }

  save(user: User): void {
    /* persists user */
  }
}

// Anti-pattern: pure delegation, no added behavior.
export class UserServiceWrapper {
  constructor(private inner: UserService) {}

  findById(id: string): User | null {
    return this.inner.findById(id);
  }

  save(user: User): void {
    return this.inner.save(user);
  }
}
