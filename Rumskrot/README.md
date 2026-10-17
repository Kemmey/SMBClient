# Rumskrot's SMBClient fork

This is [kishikawakatsumi/SMBClient](https://github.com/kishikawakatsumi/SMBClient)
with one small, ordered patch series on top. The series makes the client
survive a broken or hostile server. Upstream's parsers read replies through
an unchecked `ByteReader`, so a truncated or malformed reply traps the
whole process. With the series applied, every such reply throws
`ResponseDecodingError` instead.

[RumskrotNavigator](https://github.com/Kemmey/RumskrotNavigator) pins this fork
([RumskrotNavigator#189](https://github.com/Kemmey/RumskrotNavigator/issues/189),
after the share-list crash in #188). The fork exists only until upstream
carries the same guarantee.

## Rules

The rules match the ones RumskrotArchiveKit uses for vendored code:

1. **Upstream stays untouched and readable.** Nothing outside this
   `Rumskrot/` directory differs from upstream except through the patches
   below. The repository root, including upstream's `README.md`, is upstream's own.
2. **One patch per concern, written in upstream's style.** The patches use
   two-space indentation and the same naming, and their diffs are as small as
   the concern allows, so they rebase cleanly and could be offered upstream
   unchanged. Each non-mechanical edit carries a `RUMSKROT-HARDEN:` comment,
   and the test files carry `RUMSKROT-TESTS:`.
3. **The license travels with the code.** SMBClient is MIT licensed
   (`LICENSE` at the root, Copyright (c) 2024 Kishikawa Katsumi). The
   patches are offered under the same license. Navigator ships that
   license text in Settings → Acknowledgements.
4. **Nothing is force-pushed.** Each upstream base gets its own branch,
   `rumskrot/<upstream-tag>` or `rumskrot/main-<sha7>`. A branch is
   built once and never rewritten, so every revision Navigator has ever
   pinned stays reachable.

## The series

`Rumskrot/UPSTREAM` records the base. The current base is upstream `main` at
`66eafaa` (#232). Upstream's newest tag, 0.3.1, is older than that commit,
which is why the default base is `upstream/main` and not the latest tag.

| # | Patch | What it does |
|---|---|---|
| 1 | Bounds-checked ByteReader; every response parser throws | `ByteReader` checks every read and throws instead of trapping. `Data.to(type:)` uses `loadUnaligned`. The generic read only accepts `FixedWidthInteger`. `Message.Response.init(data:)` and all SMB2, NTLM, DCERPC and information-class parsers throw. Wire counts and directory-entry offsets are checked against the remaining bytes. Also fixes two upstream misreads: `FileFsVolumeInformation.SupportsObjects` was read as 8 bytes instead of 1, and `read(from:)` added `startIndex` twice. |
| 2 | Validate Direct TCP framing and compound reply chains | A frame length must hold at least one header and fit in 24 bits. `NextCommand` must point past its own header. A compound send must get back exactly one reply per request. A frame is appended once, however many replies it chains. |
| 3 | Refuse server values that would underflow or overflow client arithmetic | Refuses a zero negotiated transact, read or write size, and a READ reply longer than requested. Refuses NTLM target info too long for the NT response's 16-bit length. `creditSize(0)` no longer underflows. |
| 4 | FileReader: a READ that makes no progress ends the transfer | A successful zero-byte READ before end of file used to loop forever and now throws. Progress is 1.0 for an empty file instead of NaN, and is capped at 1.0. |
| 5 | listShares refuses an RPC fault or a multi-fragment reply | Upstream's `enumShareAll` decoded whatever came back as a NetShareEnum stub. A fault or a partial reply now throws. |
| 6 | Tests | `ResponseFuzzTests`: every parser gets its well-formed fixture, every truncation of it, and 2,000 seeded corruptions. `MalformedServerTests`: a scripted localhost server sends malformed frames through the real `Connection` and `Session`. Neither suite needs the Samba container. |

## Updating to a new upstream

```sh
git clone ssh://git@ssh.github.com:443/Kemmey/SMBClient.git && cd SMBClient
git checkout rumskrot/main-66eafaa          # the newest rumskrot/* branch
Rumskrot/update-from-upstream.sh            # upstream/main, or name a tag/commit
#   Rumskrot/update-from-upstream.sh 0.4.0
#   Rumskrot/update-from-upstream.sh --latest-tag
```

The script:

1. Fetches upstream.
2. Creates `rumskrot/<label>` at that revision.
3. Commits this directory on it.
4. Applies `patches/*.patch` with `git am --3way`.
5. Runs `swift build` and the offline test suites.
6. Prints the branch, the revision to pin, and the `git push` to publish it.

Pass `--integration` to also run upstream's Samba-backed suites; start the
container first with upstream's `docker-compose up`.

If you run it against a base that already has a branch, it only checks
that branch out and tests it. Running it twice is safe.

**If a patch no longer applies,** the script stops and names the patch.
Resolve the conflict, `git add`, then run `Rumskrot/update-from-upstream.sh --continue`.

**Drop a patch once upstream merges it.** When upstream carries a
change, its patch will conflict or come out empty. Drop it with
`git am --skip`, then `--continue`. Then run
`Rumskrot/update-from-upstream.sh --export` and commit the regenerated
`patches/` as `Rumskrot tooling: regenerate patches`. Once upstream has
merged all five hardening patches, Navigator can go back to pinning
upstream directly, and this fork can be archived.

**To edit a patch**, change the code on the branch. Use a new commit, or
amend before the branch is pushed. Then run `--export` and commit
`patches/`. `--export` writes one file per commit after the recorded base,
skipping `Rumskrot tooling:` commits. It refuses a patch commit that
touches `Rumskrot/`.

## Pinning in Navigator

`Packages/NavigatorSMB/Package.swift`:

```swift
.package(url: "https://github.com/Kemmey/SMBClient.git", revision: "<printed revision>")
```

Then run `xcodebuild -resolvePackageDependencies` for the app, and close
and reopen the workspace in the Xcode MCP. Build every destination: iOS,
iPadOS, Mac and tvOS. Navigator's `SMBErrorMapper` maps
`ResponseDecodingError` to `backendFailure`, which shows the generic
"the server sent something unexpected" error UI.

## Upstream pull request: prepared, not opened

Opening this PR is outward-facing, so it waits for Kim. Proposed title
and description:

> **Make response parsing bounds-checked so a malformed reply throws instead of crashing**
>
> `ByteReader` slices `Data` without checking bounds, so any reply that is
> shorter than its fields, or whose offset/length fields point outside the
> message, traps the client process. That includes a truncated network
> read, a buggy NAS, or a hostile server. We hit it in production in a
> long share list (RumskrotNavigator#188).
>
> This series makes every read checked and throwing, and propagates a new
> public `ResponseDecodingError` through `Message.Response.init(data:)`
> and every parser to the caller:
>
> 1. Bounds-checked, throwing `ByteReader`. `loadUnaligned` for unaligned
>    slices. The generic read is constrained to `FixedWidthInteger`. Fixes
>    `FileFsVolumeInformation.SupportsObjects` being read as 8 bytes, and
>    `read(from:)` double-adding `startIndex`.
> 2. Validation of Direct TCP frame lengths, `NextCommand` chains and
>    compound reply counts.
> 3. Refusal of zero negotiated sizes, over-long READ replies and
>    oversized NTLM target info, all of which reached integer
>    underflow/overflow traps.
> 4. `FileReader` stops on a READ that makes no progress, and its
>    progress stays finite for empty files.
> 5. `enumShareAll` refuses RPC faults and multi-fragment replies.
>
> Plus offline tests: per-parser truncation and seeded-corruption fuzzing,
> and a scripted localhost server for the transport path. Neither needs
> the Samba container. Existing tests are updated only where
> `Header(data:)` now needs `try`.
>
> **API change:** `init(data:)` on public response types and
> `QueryDirectory.Response.files()` now `throw`. Callers that construct
> responses themselves need `try`. Callers that only use `SMBClient` and
> `Session` are unaffected beyond seeing the new error type.

For the PR, the `RUMSKROT-HARDEN:` / `RUMSKROT-TESTS:` comment prefixes
can be removed or kept as plain explanatory comments.
