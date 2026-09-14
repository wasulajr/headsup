Repo: wasulajr/headsup
Issue: #47
Type: repo-suite
Test-Type: repo-suite
Suite-Repo: wasulajr/headsup
Suite-Ref: fix/47-preserve-hook-registrations
Suite-Manifest: qa-tests/47-suite.json

# Independent source QA for #47

Timestamp: 2026-09-14 12:18:50 EDT (2026-09-14T16:18:50Z).

Use the existing trusted repo-suite runner to check out the named candidate branch in a fresh isolated directory. Record the full tested SHA from Candidate identity. No fallback to main, no private GitHub clone/auth inside the AI driver.

Tests execute only setup.sh's actual Step 9 hook-wiring section with disposable settings files. Do not run full setup.sh. Review additive per-event behavior, complete-registration equality, preservation of existing duplicates/metadata/order, partial repair, idempotence, refusal, malformed JSON, and backups. No live hooks or LaunchAgents may be installed.

Every manifest step must exit zero. Checkout/toolchain setup failures are BLOCKED, assertion failures are FAIL. Author-run tests are not independent QA. PASS applies only to the recorded source commit, not the installed runtime. Do not install, activate, deploy, merge, or remove a production hold as part of this test.
