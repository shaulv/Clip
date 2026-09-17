# Contributing to Clip

## Setup

```bash
git clone <your fork> && cd clip
./build.sh
```

That is all of it. macOS 14+ and Xcode. No package manager, because there are no
packages.

## The project file is generated

`Clip.xcodeproj/project.pbxproj` is written by `regen-project.py` from the files
on disk. Add a Swift file under `Clip/`, run `python3 regen-project.py`, done.
`build.sh` and `package.sh` run it for you.

Do not hand-edit the pbxproj. The reason it is generated at all is that the
original was unparseable - an unquoted `+` in a path and some 23-character
object ids, which Xcode reports only as "the project is damaged".

## Before you optimise anything, measure it

This is the rule that has paid off most, and it is not a formality.

The last performance pass began by reading the code and concluding the search
pipeline was the problem. Measuring said otherwise: the dominant cost was
**derived theme colors**, at 0.62 ms per row, because they were computed
properties running a contrast search on every read. Thirty rows meant 18 ms per
frame against a 16 ms budget. The search code was a distant third.

An earlier pass measured search at 664.8 ms, "fixed" it to 37 ms, and only a
re-measurement caught that the fix had introduced a 245 ms regression of its
own - the cache key was an interpolated string being built 74 times per
keystroke.

So:

```bash
python3 perf-probe.py --save before
# ... make one change ...
python3 perf-probe.py --compare before
```

One change, one measurement. If the number does not move, revert it - a change
that does not help is not neutral, it is a change.

## Running the tests

There are two test layers, and they run in different places for a reason.

**`ClipTests` (XCTest, runs in CI):**

```bash
python3 regen-project.py   # regenerates the ClipTests target too, see above
xcodebuild -project Clip.xcodeproj -scheme Clip \
  -destination 'platform=macOS' -derivedDataPath build-test \
  CODE_SIGNING_ALLOWED=NO test
```

`ClipTests` is a hosted bundle: `xcodebuild` builds `Clip.app`, launches it as
the test host, and runs the suite inside that process - unattended, the same
way it runs on the `macos-14` GitHub Actions runner in `.github/workflows/ci.yml`.
The scheme's Test action sets `CLIP_QA_SANDBOX=1` on the host, so every test
here runs against a throwaway database, media folder, Keychain service and
preferences domain (see "Tests never touch real data" below) - never a real
user's history.

**`qa-probe.py` and `security-probe.py` (do not run in CI):**

```bash
python3 qa-probe.py --prove         # or without --prove, for a normal run
python3 security-probe.py --prove
python3 perf-probe.py --save before
```

These drive a REAL, LAUNCHED, interactive GUI app: they open the menu-bar
panel, click into it, fire global hotkeys, and read what actually rendered.
That needs a logged-in macOS desktop session with the app frontmost - exactly
what a GitHub-hosted macOS runner does not have. A job that tried would either
hang waiting for a GUI that never appears or silently no-op. `ci.yml` documents
this in a disabled placeholder job (`qa-probe-placeholder`, `if: false`) rather
than pretending the gap doesn't exist. Run these two locally, on your own Mac,
with Clip able to take focus, before you push anything that touches the
pasteboard, hotkeys, sync, or the theme system.

## Every assertion must be proved able to fail

```bash
python3 qa-probe.py --prove        # runs checks that MUST fail
python3 security-probe.py --prove
```

When you add an assertion, break the code on purpose once and watch it go red,
then put the code back. This suite has shipped assertions that could not fail:

- A flag set `false` in one place and never set anywhere else. It "passed"
  forever.
- A cache check that varied two inputs at once, so the stale-cache case it
  existed to catch could never arise. Deliberately removing a field from the
  cache key did not fail it.
- Three security checks that were matching against the doc comments which
  *document* the good behaviour, rather than against the code.

## Tests never touch real data

`CLIP_QA_SANDBOX=1` redirects the database, the media folder, the Keychain
service and the preferences. Use it. Both halves were learned by damage: one
probe seeded and cleared against the live database, and a later one left the
user's real history limit set to 20 because preferences were not sandboxed yet.

`security-probe.py` reads the real store's permissions but never writes to it.

`CLIP_QA_UPSTREAM_HOST` is the production sync host `qa-probe.py` checks is
never compiled into the app. It defaults to a neutral placeholder
(`example.invalid`) so the published copy never contains a real host. Set it
locally if you need this check to match your own production host.

## A silent guard is a defect

The rule (see `ARCHITECTURE.md`): a `guard ... else { return }` with no
feedback, on a path a user triggered or that runs at startup, is a defect even
when the code inside it is correct. Silence reads as "nothing happened," and
the user has no way to tell that from "it worked." Report through
`NoticeCenter` instead - `.transient` for news, `.persistent` for a standing
condition, `.integrity` for data at risk.

Today this is enforced by `qa-probe.py`'s `run_m4_silent_paths` (probe section
134) against a named list of 15 functions, not the whole codebase - roughly
155 `try?` sites and several hundred bare silent guards outside that list are
not yet gated. If you touch one of the 15, the probe fails on a new
unallowlisted silent path inside it. If you add a new user-triggered or
startup guard anywhere, give it a notice rather than assuming the gate will
catch its absence - it will not, yet.

## A theme must pass the AAA contrast gate

`ThemeRules` (`Clip/Theme/ThemeRules.swift`) is the one place the contrast
targets are written down, and three things read it so they cannot drift apart:
the audit that grades a theme, the warnings shown live in the theme builder,
and the brief handed to the AI that generates or refines a theme. Body text is
held to AAA (7:1), not merely AA (4.5:1) - stricter than the WCAG minimum,
deliberately, and every derived color (tints, accent-as-text, text on
selection) is tuned to that same 7:1 target since they all route through
`ThemeRules.Level.body.ratio`. The audit composites colors before it measures
them, not the authored values alone - a fixed pass grading authored colors
missed eight of nine type tints failing on every light theme, because what
actually renders on screen is a composite, not the swatch. If you touch a
color, a tint, or a theme preset, run the theme builder's own contrast matrix
before you call it done, not just the swatch.

## When a test fails after you changed a design

Update the assertion to the new intent - do not relax it, and do not work around
it. A quarter of this suite's long-standing failures were tests pinned to a
design that had deliberately moved on: a control that had been renamed, an
action row that had gained a button at position 0 so every hard-coded index
pointed one to the left, a feature that had been replaced by a better one.

Each of those had been "a known failure" for a while, and each was hiding
whether anything real was broken. Say in the comment what changed and why the
old assertion no longer describes the intent.

## Style

Match what is there. In particular:

- **Comments explain why, not what.** Nearly every non-obvious decision in this
  codebase carries the reason it is that way, usually including what went wrong
  first. That is the most valuable thing in the repository - keep it up.
- Prefer a measurement in a comment over an adjective. "0.62 ms per row" beats
  "slow".
- British or American spelling: the code says **color**. The one exception is
  `DesignDocTheme.colorBlock`, which reads other people's design documents and
  accepts both, because their spelling is not ours to standardise.

## Security

Anything touching the pasteboard, the database, the Keychain, the network or an
imported file: read [SECURITY.md](SECURITY.md) first, and add a check to
`security-probe.py` for whatever control you relied on.

Clip stores every password its user has ever copied. That is the standard the
code is held to.

## Commits

Say what changed and why it needed to. If you fixed a bug, say what the bug
actually was - the commit log here is the most reliable documentation of how
this thing behaves under pressure.

## Filing an issue

Use the templates: [bug report](../.github/ISSUE_TEMPLATE/bug_report.yml) for
something that did not work, [feature request](../.github/ISSUE_TEMPLATE/feature_request.yml)
for something Clip does not do yet. Both ask for your macOS version and Clip's
version (Settings > General > About), and for `qa-probe.py`'s output only if
you ran it - leave that field blank otherwise.

## Proposing a change

1. Fork, branch, and make the change. Keep it to one concern - a change that
   fixes a bug and reformats an unrelated file is two changes wearing one
   commit.
2. Run `regen-project.py`, then build both configurations and run `xcodebuild
   test` locally. If your change touches the pasteboard, hotkeys, sync, or the
   theme system, run `qa-probe.py --prove` and `security-probe.py --prove` on
   your own Mac too - CI cannot, for the reason above.
3. Open a pull request against `main` describing what changed and why. `ci.yml`
   builds Debug and Release and runs `ClipTests` automatically; the warning
   count is gated against a recorded baseline, so a change that adds a new
   compiler warning fails the build rather than silently raising the count.
4. If the change adds a new user-visible behavior, run it past `SECURITY.md`
   and add a check to `security-probe.py` for whatever control you relied on.
5. Expect review to ask "how do you know this works," and have an answer that
   is a measurement or a probe run, not an adjective.
