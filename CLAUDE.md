# Notes for Claude

- **Privacy:** never put the repository owner's personal email address in commits
  (author/committer), files, docs, logs, release notes or anything else public.
  Commit as the GitHub noreply identity. The only public contact address is the
  one already in the game's Copyright & DMCA page.
- **Admin builds** (`--dart-define=TUNETRAIL_ADMIN=true`) are never built on GitHub
  or published anywhere; they're built locally (docs/admin-build.md).
- Commit messages: write them to a file and use `git commit -F`.
