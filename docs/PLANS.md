# Plans

Use checked-in plans sparingly. This is a public personal infrastructure repo, so plans should help future agents with non-sensitive structural work without turning live operations into public notes.

## Use checked-in plans for

- module/profile/package refactors;
- validation harness improvements;
- documentation architecture;
- public-safe service packaging work;
- multi-step changes where future agents need acceptance criteria and file paths.

Recommended path:

```text
docs/exec-plans/active/<slug>.md
```

Create the directory when the first checked-in plan is needed.

## Keep private or scratch notes for

- incident response;
- live host state;
- private topology and operational details;
- copied command transcripts;
- decrypted or sensitive configuration;
- plans that depend on private credentials or unreleased account data.

Private notes can live outside the repo, for example under `~/agents/` or another private planning system.

## Plan shape

A useful checked-in plan should include:

- goal and non-goals;
- acceptance criteria;
- likely files/modules to touch;
- implementation phases small enough for agents to execute;
- validation commands from `docs/VALIDATION.md`;
- public-boundary risks from `docs/PUBLIC_BOUNDARY.md`;
- progress log entries only when they remain useful after the branch lands.

Do not keep stale status logs. Once a plan is complete, either remove it or move durable decisions into the appropriate docs/checks.
