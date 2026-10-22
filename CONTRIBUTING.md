# Contributing

The same rules hold for everyone who opens a pull request here, a person or a Claude session, whoever's account it runs on: GitHub enforces them, so nobody's own instructions are needed to keep them.

## What GitHub holds every pull request to

- The default branch takes changes only by pull request, with no forced push and no deletion (the ruleset "Protect the default branch"). tools/push_org.sh's direct push to main is refused from then on; a change reaches main by a pull request like any other.
- The required check "check" passes (.github/workflows/ci.yml): the framework's suite on a current Ubuntu and on the login node's CentOS 7 stack, the grid tools' tests against their stand-ins, the framework version check, and the review record below. Run `bash scripts/check.sh` before you open or update a pull request; it runs the Ubuntu lane.
- A pull request marked ready carries a section headed `## Adversarial review` in its body: what a reviewer who wanted the change to fail checked, by reading it or by running it, what they found and what was fixed. It is at least a sentence; "LGTM" does not count. The pull request template has the heading. A draft, a bot's pull request and one opened before 2026-10-22 05:00 UTC are not asked for one. Editing the body re-runs the check; "Re-run" on the old run reads the body as it was, so edit the body instead, or push.
- The organization's ruleset "Require owner approval to merge" asks one approval, given after the last push, of a pull request from anyone but an organization owner.

## What everyone is expected to do

- One change, one pull request.
- The review above is adversarial: someone, or a second session, other than the author's first pass, tries to make the change fail before it is marked ready.
- The rules of CLAUDE.md hold for people as for sessions: no API key, no Claude credential and no token anywhere, nothing that reaches another repository's checkout.
