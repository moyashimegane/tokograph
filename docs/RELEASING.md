# Releasing

One-time GitHub settings (required by .github/workflows/release.yml):
1. Settings → Environments → environment `release` with required reviewers
   (repo owner): every release run waits for manual approval.
2. Settings → Rules → Rulesets → tag ruleset for `v*` restricting tag
   creation to repo admins.
3. Releases are cut by pushing a `v*` tag pointing at a commit on `main`.
   The workflow refuses tags whose commit is not reachable from `main`.

Release checklist:
- [ ] CI green on the commit to be tagged (workflow `ci` on main)
- [ ] `swift run -c release tokograph --measure` → wall < 2 s, peakRSS < 200 MB on full local dataset
- [ ] Manual: popover reopen re-triggers refresh
- [ ] Tag + push, approve the `release` environment run
- [ ] `gh attestation verify Tokograph.zip --repo moyashimegane/tokograph` on the published asset
