# iso/payload/

This directory is **generated**, not committed. `iso/build-iso.sh` writes
`secrets.env` here from your `.env`, and bakes the contents into the ISO.

Nothing in this directory should ever be checked in. The `.gitignore` at
the repo root ignores `iso/payload/secrets.env` explicitly.
