# Publishing an update

The development workspace retains its original private experiment history. The
public repository contains audited text source/recipes and a separate clean git
history. Do not push the old workspace history or import phone backups into it.

In the maintainer workspace, after verification and local commits:

```sh
python3 tools/publication/publish.py --message 'Explain the completed update' --push
```

The dedicated checkout is `build/public-repo`; its origin is the new GitHub
repository. Input allowlists, binary/secret refusal and PUBLICATION.json record
the export. Review the staged diff before a release. The push reads a token from
a private ignored file (`CERRO_GITHUB_TOKEN_FILE` override); no credential is
embedded in URLs, git config or command arguments. The checked-in helper contains
no token. Public-clone contributors can use their normal GitHub authentication
and normal git workflows instead of this maintainer export helper.

The owner has explicitly requested a push after each completed update. A failed
push must be reported and retried when connectivity returns. Retain upstream
copyright and actual external contributor attribution. AI assistance is disclosed
in README/repository description, without adding fictional AI authors to commits.

Actual --push exports committed HEAD source bytes only. Untracked or uncommitted
camera experiments are not silently included with another completed update.
--export-only can still audit a working candidate before committing.
