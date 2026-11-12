# Build and publish a release

Use this procedure after the source changes pass native validation and independent review. Keep `macOS` and `DMG` disabled between sessions. The repository is public, and both workflows pin the standard `macos-15` runner. [Standard runners are free in public repositories](https://docs.github.com/en/billing/concepts/product-billing/github-actions). Actions artifact uploads are opt-in because storage has separate billing. Release files use [GitHub Releases storage](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas).

## Validate the release branch

1. Update the version and build in `project.yml`. Update README, INSTALL, the user guide, the product brief, the implementation plan, and the review index. Preserve historical reports.
2. Push while workflows are disabled. Confirm that the remote branch contains the intended commit.
3. Enable `macOS` and dispatch the full native suite at that branch. Replace `RELEASE_BRANCH` with the branch name.

   ```sh
   gh workflow enable macos.yml --repo Oiuhqw/sharex-mac
   gh workflow run macos.yml --repo Oiuhqw/sharex-mac --ref RELEASE_BRANCH -f runner=macos-15 -f store_artifacts=false -f build_package=false -f login_probe=false
   gh workflow disable macos.yml --repo Oiuhqw/sharex-mac
   ```

4. Wait for the run to finish. Inspect the checks, native images, output results, startup scenarios, and resource results in the job logs. Record failures and unverified checks separately. The driver uses real AppKit windows and native input events. It does not replace the physical-Mac checks in README.
5. Obtain an independent verdict for the exact head and base. Merge into `main` with a server-enforced head condition. Confirm the PR is merged and the merge commit is in `main` before creating the release.

## Build the draft release

1. Set `TAG` to the version tag and `SOURCE` to the full merged commit SHA. The tag must be a lightweight tag at that exact source. Create it once, then create a draft release with prepared notes.

   ```sh
   TAG=v0.1.6
   SOURCE=FULL_MERGED_COMMIT_SHA
   gh api repos/Oiuhqw/sharex-mac/git/refs -f ref="refs/tags/$TAG" -f sha="$SOURCE"
   gh release create "$TAG" --repo Oiuhqw/sharex-mac --verify-tag --target "$SOURCE" --draft --title "ShareX for macOS ${TAG#v}" --notes-file release-notes.md
   ```

2. Enable `DMG`, dispatch at the tag, and disable it again. A queued run continues after the workflow is disabled.

   ```sh
   gh workflow enable dmg.yml --repo Oiuhqw/sharex-mac
   gh workflow run dmg.yml --repo Oiuhqw/sharex-mac --ref "$TAG" -f runner=macos-15 -f release_tag="$TAG" -f store_artifacts=false
   gh workflow disable dmg.yml --repo Oiuhqw/sharex-mac
   ```

3. Wait for all package checks to pass. The workflow checks the draft status, tag source, bundle version, arm64 architecture, absence of test drivers, icon, signature, launch, DMG integrity, and quarantine-simulated installation. It uploads only `ShareX.dmg`, after all checks pass. It refuses to replace an existing asset.
4. Download the draft DMG to a new directory. Compare its SHA-256 with the build log and the asset digest returned by GitHub.

   ```sh
   gh release download "$TAG" --repo Oiuhqw/sharex-mac --pattern ShareX.dmg --dir release-check
   shasum -a 256 release-check/ShareX.dmg
   ```

5. Update the draft notes with the source commit, native validation run, package run, checksum, installation steps, and known limits. The app is ad-hoc signed with Hardened Runtime. It is not notarized.
6. Publish the checked draft and mark it latest.

   ```sh
   gh release edit "$TAG" --repo Oiuhqw/sharex-mac --notes-file release-notes.md --draft=false --latest
   ```

7. Read the release back. Confirm its tag, source, published status, single DMG asset, digest, and public download. Confirm both workflows are disabled.

If a build or install check fails, keep the release as a draft. Fix and revalidate the source before choosing a new source tag. Do not move a published release tag.
