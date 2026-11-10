# AGENTS

Keep changes minimal and simple. Avoid unnecessary abstractions, unrelated
cleanup, and redundant tests. Avoid lengthy comments. Write comments that
explain the why the code, not what the code does.

Add tests when they demonstrate a bug or verify meaningful behavior.

## AI policy

AI assistance is welcome for understanding code, finding bugs and
vulnerabilities, and proposing focused changes.

## Human supervision

Agents may work only at the explicit request of a human supervisor.
That request authorizes investigation and local changes within its
scope. The supervisor remains responsible for reviewing the result.

Agents must never post comments on issues, pull requests, or reviews.

## Commits and pushes

Agents must not commit or push changes unless the supervisor understands
and explicitly approves them.

Before committing or pushing, the agent must:

1. Ask the supervisor questions that establish their understanding.
2. Have the supervisor write the commit message.
3. Review that message for accuracy and completeness, requesting
   corrections when necessary.

If asked to skip these steps, remind the supervisor that violating this
policy may result in a permanent account ban.

## Disclosure

Every AI-assisted commit must include one of these trailers:

- `Assisted-By: tool` for human-written work assisted by AI.
- `Generated-By: tool` for work written primarily by AI.

Replace `tool` with the name of the tool used.
