# Maintainers

This document is for maintainer-only project operations.

## Local Release

Notarized local release:

```sh
make release-notarize NOTARY_PROFILE=<profile>
```

GitHub release:

```sh
make release-github NOTARY_PROFILE=<profile> TAG=vX.Y.Z
```

Verify the Developer ID signing certificate is installed before releasing:

```sh
security find-identity -v -p codesigning
```

The output must include a `Developer ID Application` identity. If multiple identities are available, pass the intended one explicitly:

```sh
make release-github NOTARY_PROFILE=<profile> TAG=vX.Y.Z SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)"
```

Expected release sequence:

```sh
git push
git tag -a vX.Y.Z -m "eucaly X.Y.Z"
git push origin vX.Y.Z
make release-github NOTARY_PROFILE=<profile> TAG=vX.Y.Z
```

Release safeguards:

- working tree must be clean
- current branch must not be ahead of upstream
- GitHub release requires a tag already at `HEAD`
- that tag must already exist on `origin`
