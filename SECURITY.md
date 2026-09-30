# Security policy

## Reporting a vulnerability

**Please do not open a public issue.** Email
[support@ferriteengineering.com](mailto:support@ferriteengineering.com) with
`Security` in the subject line.

Useful things to include, as far as you have them: the version and platform,
what an attacker can do, and the smallest input or steps that show it. A
proof-of-concept file is worth more than a description of one.

## What to expect

Ferrite Engineering is a small team, so here is the honest version rather than
a service-level agreement: you will get a human acknowledgement within five
business days, and from there an explanation of what we think the impact is
and what we intend to do about it. If we disagree that it is a vulnerability
we will say so and why, rather than going quiet.

We will credit you by name in the release notes if you would like to be
credited, and we will not involve lawyers over a good-faith report.

## Where we would look first

- **Project configuration executes commands.** A regression config names the
  simulator and the command that runs a test, so opening someone else's
  project is closer to running their script than to opening their document.
  A path from a config file to a command the user did not intend -- or to one
  that escapes where we say it runs -- is the highest-value report here.
- **The distributed-execution backend**, whose submit, poll and cancel
  commands come from a signed policy file: anything that lets an unsigned or
  altered policy be honoured.
- **CXP**, the local peer protocol other Crux apps use to cross-probe: it
  accepts connections from processes on the same machine.

## Not vulnerabilities

Two things get reported often enough to be worth stating up front.

**The Keygen account id and the licence verify key are public on purpose.**
They are compiled into every build and published in the source with comments
saying so. The only credential any app ever transmits is the customer's own
licence key, as `Authorization: License <key>`; there is no product token and
no admin token in any build. Finding these is finding a design decision.

**Licence-tier enforcement is not a security boundary.** The open core is
Apache-2.0 and the paid overlay's gating is a commercial mechanism running on
hardware its user controls. "I can turn on Pro features by modifying my own
machine" is not a report we will treat as a vulnerability. Anything that lets
one person affect *another* person's licence, data or machine is.

## Third-party engines

These tools invoke external EDA engines -- Yosys, GHDL, Icarus Verilog,
Verilator, Verible and others -- as separate processes. A flaw inside one of
those belongs upstream with that project. How we invoke them, what we pass
them, and what we do with what they return is ours: report that here.
