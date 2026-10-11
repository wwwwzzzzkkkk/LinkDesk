# LinkDesk audio plugins

Derived from BlackHole (Existential Audio Inc.), GPL-3.0. See vendor/LICENSE and vendor/UPSTREAM.json for pinned source provenance. The only vendor code change adds `kEnableMuteControl` to independently disable applying mute to PCM. LinkDeskAudio.c configures separate names, UIDs, stereo 48kHz, and the control-only dual endpoint. Upstream source hashes in the manifest refer to the original unmodified files.

The dual endpoint's controls are proxy state: the Mac app applies them to built-in speaker volume/mute, while the tablet PCM stays unaffected. The tablet endpoint retains ordinary volume/mute processing. Factory UUIDs differ between bundles. Builds use the existing fixed LinkDesk code-signing identity. Installation is a separate administrator action described in VOLUME_CONTROL.md.
