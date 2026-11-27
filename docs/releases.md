# Cue releases

GitHub Actions runs the Cue tests on pull requests and pushes to `main`. A stable version tag also builds a universal ZIP, signs it with Developer ID, submits it to Apple for notarization, and publishes the stapled build to GitHub Releases. The workflow then pushes a signed Sparkle appcast to the public `appcast` branch. That keeps app updates independent of the Cloudflare Pages website deployment.

## Configure GitHub Actions once

Add these repository secrets under **Settings → Secrets and variables → Actions**.

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application PKCS#12 export with its private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the PKCS#12 export |
| `APPLE_ID` | Apple Account used for notarization |
| `APPLE_APP_PASSWORD` | App-specific password for notarization |
| `SPARKLE_PRIVATE_KEY` | Exported Sparkle EdDSA private key |

Add `APPLE_TEAM_ID` and `SPARKLE_PUBLIC_KEY` as repository **variables**.

After building once, Sparkle's `generate_keys` tool is in the SwiftPM artifact's `bin` directory. Run `generate_keys --account org.cueplayer.Minimal` and use the printed public key for the variable. Export the private key with `generate_keys --account org.cueplayer.Minimal -x <private-key-file>` and load the file into the GitHub secret. Keep a secure backup of the key pair and remove the plaintext export after storing it. Future releases must continue to use the production key pair.

## Publish a release

1. Set `MARKETING_VERSION` and increase the integer `CURRENT_PROJECT_VERSION` in `project.yml`. Run `xcodegen generate` and commit the version and project changes.
2. Tag the release commit with the marketing version and push the tag, for example `git push origin v0.1.16` after creating `v0.1.16` locally.
3. Confirm the Actions run published both the ZIP and [the feed](https://raw.githubusercontent.com/jamesacklin/cue/appcast/appcast.xml). The feed points to the GitHub asset for that tag.

To retry an existing tag with the current release tooling, run the **Cue** workflow manually from `main` and enter the tag in `release_tag`. It builds and tests the tagged source.

Existing users install the first Sparkle-enabled release from GitHub manually. To verify the rollout end to end, install it in Applications, publish a newer build, and choose **Cue → Check for Updates…**. Confirm the new build relaunches and retains the existing Plex library selection. Builds made locally without `SPARKLE_PUBLIC_KEY` omit the update menu.
