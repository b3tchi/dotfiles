# When Fixes Keep Failing

**Load this reference when:** three hypotheses in a row have failed, or each fix you try exposes a new problem somewhere else.

## The pattern

You're debugging. You formed a hypothesis, tested it, it didn't work. You formed another, tested it, it didn't work. You're on your third try. Every fix either doesn't move the needle or makes a different symptom appear. You're tempted to attempt fix #4.

**Stop.** Three failures in a row isn't bad luck — it's a signal that you're modelling the system wrong. The thing you think is a local bug is probably architectural.

## Why this happens

Each hypothesis assumes the problem is contained — a bad value here, a missing check there. When that keeps being wrong, it usually means the bug is an emergent property of how several components interact, not a defect inside any one of them. Classic tells:

- Fix #1 stops symptom A, but symptom B appears somewhere unrelated
- Each fix requires "just a bit of refactoring" in a different file
- The fixes work in isolation but break together
- You keep finding new places the same invariant could be violated
- You catch yourself saying "we'll need to touch X too" every attempt

You're not fixing a bug. You're discovering that a design assumption no longer holds.

## What to do instead

**Bring a human in.** This is the moment to pause and discuss with your human partner, not to double down. Frame it clearly:

> I've tried three fixes and each has revealed a new problem in a different place. I think the issue may be architectural rather than local. Here's what I've found: *[list each hypothesis, why it failed, what new symptom it revealed]*. Before attempting another fix, I'd like to check whether the pattern itself is the problem.

**Question the pattern, not the instance.** Useful questions at this point:

- What invariant are these components trying to preserve? Is it actually preserved anywhere?
- Is there a pattern in the codebase that's fundamentally unsound, and we've been patching instances of its failure mode?
- Did a recent refactor change the contract between two components without updating both?
- Is shared state being relied on in places that shouldn't know about it?

**Consider whether a refactor is cheaper than more fixes.** If each fix costs an hour and reveals another hour of fixes, replacing the underlying pattern may be faster than the patch sequence you're about to ship.

## What not to do

- **Don't attempt fix #4 without a new frame.** A fourth try using the same mental model is the same bet, rerolled. It won't behave differently.
- **Don't bundle fixes together to "cover your bases."** Multiple simultaneous changes make it impossible to tell what actually worked.
- **Don't rationalize it as "almost there."** "Almost there" three times in a row is a loop, not progress.

## Real-world signal

From prior debugging sessions: when a loop of 3+ failed fixes gets resolved, the resolution is almost never "the fourth hypothesis was right." It's usually one of:

- Replacing a shared mutable with an explicit dependency
- Moving validation to a different layer
- Deleting a class of bug by making the bad state unrepresentable
- Recognizing two "bugs" were the same design problem surfacing twice

If the thing in front of you doesn't feel like one of these, keep looking before patching.
