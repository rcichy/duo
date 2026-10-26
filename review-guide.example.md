# Team review guide (example)

Copy this file to `$DUO_HOME/review-guide.md` and replace it with how your team actually reviews merge requests.
Both duo reviewers receive it verbatim, and it takes precedence over their generic rubric. Grow it from real
review threads; keep each point short and checkable.

## Every repo

- **Requirements first.** Does the change do what the ticket asks, all of it, and nothing it did not ask for?
- **Sibling code paths.** When a bug is fixed in one place, search for the same pattern elsewhere and fix or list it.
- **Failure modes.** What happens when the database, cache, queue or an external API fails halfway through?
- **Transactions.** Writes that must succeed together are in one transaction; no network calls inside a transaction.
- **Migrations.** Safe to run on a live table: no long locks, backfills in batches, reversible where possible.
- **Tests.** Each requirement and each failure path has a test that would fail without the change.
- **Simplicity.** No speculative abstractions, no unused parameters, no defensive code for states that cannot happen.
- **Logging.** Errors are logged once, with enough context to debug, and without personal data or secrets.

## Repo-specific

<!-- Label each item with the repo it applies to, e.g. -->
- **[api]** Public endpoints keep backwards compatibility; breaking changes need a new version.
- **[worker]** Tasks are idempotent: running one twice must not double-charge, double-send or duplicate rows.
