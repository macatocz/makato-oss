# Simplification Patterns

AI-generated code has characteristic over-engineering patterns. Each entry below names
the pattern, shows what it looks like, and describes what to do instead.

## Unnecessary Factory or Builder

**What it looks like:** A factory class or builder that has exactly one caller, creates
exactly one type, and adds no configuration logic beyond passing arguments to a constructor.

```java
// Over-engineered
class OrderFactory {
    Order create(String id, BigDecimal amount) {
        return new Order(id, amount);
    }
}
// Simple
new Order(id, amount)
```

**Do instead:** Call the constructor directly. Factories earn their place when creation
logic is complex, conditional, or shared across many callers.

## Premature Interface Extraction

**What it looks like:** An interface with exactly one implementation, introduced at
the same time as the implementation, with no test doubles and no existing second
implementor in the codebase.

**Do instead:** Use the concrete class directly. Extract an interface when a second
implementation actually exists or when a mock is genuinely needed in a test (and even
then, prefer the existing test utilities in the codebase).

## Wrapper for Wrapper's Sake

**What it looks like:** A class or function that delegates every method to a wrapped
object without adding any behavior, translation, or error handling.

```typescript
class UserServiceWrapper {
    constructor(private inner: UserService) {}
    findById(id: string) { return this.inner.findById(id); }
    save(user: User) { return this.inner.save(user); }
}
```

**Do instead:** Use the wrapped object directly. Wrappers earn their place when they
add cross-cutting concerns (logging, retries, auth) or adapt an interface.

## Single-Use Private Helper

**What it looks like:** A private method extracted from a single call site, with a name
that just describes what the one call site does, making the code *longer* to read because
the reader must jump between two methods to follow one logical flow.

**Do instead:** Inline the helper back into its single call site. Extract only when the
extracted logic is reused, independently testable, or significantly reduces cognitive load
at the call site.

## Over-Generic Naming

**What it looks like:** Variables, methods, or classes named with placeholders
(`data`, `info`, `item`, `result`, `obj`, `Manager`, `Handler`, `Processor`) that
force the reader to infer meaning from context rather than naming.

**Do instead:** Rename to the domain concept. `data` → `invoicePayload`. `result` →
`createdOrder`. `Manager` → `InvoiceApprovalService`. Over-generic names are often a
symptom of premature generalization.

## Dead Branch

**What it looks like:** A conditional branch that can never be reached given the calling
contract — e.g., a null-check on a value that is always initialized before the call,
or an `else` branch that handles a case the type system prevents.

**Do instead:** Remove the dead branch. If there is genuine uncertainty about whether
the value can be null, address the uncertainty at the source (type annotation, assertion,
or contract) rather than silently swallowing the case.

## Unused Parameter

**What it looks like:** A method or function parameter that is never read inside the
method body. Often introduced as "might be useful later."

**Do instead:** Remove the parameter. If it was added for future extensibility, the
future use is speculative — YAGNI applies. Add it back when it is needed.

## Trivial Delegation Chain

**What it looks like:** A call chain where A calls B which calls C which calls D, and
B and C add no behavior — they simply pass the call along. Each layer was given a
descriptive name but does nothing beyond forwarding.

**Do instead:** Collapse the chain so A calls D directly (or the nearest layer that
adds value). Delegation chains that exist only to satisfy a rigid layering ideology
without behavior at each layer add indirection without value.

## Redundant DTO / Data Class

**What it looks like:** A data class created to hold exactly the fields of an existing
class, used only to pass that class's data from one place to another within the same
bounded context, with a near-identical structure.

**Do instead:** Pass the original class or a subset of its fields directly. DTOs earn
their place at system boundaries (API response plans, persistence mappings) where
decoupling is real.

## Over-Specified Configuration

**What it looks like:** Configuration objects or constants that enumerate every possible
option with its default value, rather than relying on the framework's actual defaults.

**Do instead:** Specify only the values that differ from the framework default. Explicit
defaults are a maintenance liability — they must be updated when the framework changes
its defaults.
