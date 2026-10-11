# LinkDesk deployment and screen capture permissions

Mac TCC authorization has repeatedly failed after ad-hoc signed binaries were copied over the installed app. Preserve the working installed identity.

- Use `scripts/install-mac.sh` for Mac installation. Do not manually copy or re-sign `/Applications/LinkDesk.app` to bypass its identity check.
- `scripts/build-mac.sh` accepts `LINKDESK_SIGN_IDENTITY`. Without it, outputs are local test builds, not updates to the installed app.
- A signing identity migration must be deliberate and documented. The script permits an explicit migration to a certificate-signed build; it never permits a changed ad-hoc identity over an existing app.
- Verify recording permission using a normal LaunchServices/Finder launch of `/Applications/LinkDesk.app`, then quit and reopen it. A directly executed binary may inherit its terminal/agent host's permissions and is not an adequate permission test.
- Do not edit TCC databases, weaken designated requirements, or change bundle identifiers as a permission workaround.
- Keep signing keys, passwords, and provisioning material out of logs, source archives, and shared outputs.
