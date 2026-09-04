# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-03

Initial release.

### Added
- `status` command. Read-only, needs no administrator rights. Reports the installed driver,
  any pending Windows Update driver offer, and flags an offer that is older than what is
  installed.
- `block` command. Adds the GPU hardware IDs to the Device Installation Restrictions deny
  list, enables it non-retroactively, keeps the admin override on, and hides a matching
  pending update.
- `unblock` command. Suspends the block without discarding the deny list, so a vendor
  installer can run.
- `restore` command. Removes all driver-blocking policy and unhides driver updates.
- GPU detection for AMD, NVIDIA and Intel. On a multi-GPU machine the adapter can be named
  positionally, quoted or as bare words, or with `-Device`. Matching is a case-insensitive
  substring of the adapter name.
- Ambiguous or unmatched device names list the available adapters as ready-to-copy commands
  rather than describing the flag to use.
- Automatic elevation for the commands that change policy.
