# Contributing to Yardlet

Thanks for taking the time. Yardlet is a personal open-source project, and reports from people who use it are the
most useful contribution right now.

## Issues

- **Bugs:** open a [bug report](../../issues/new?template=bug_report.yml). Include the Yardlet version
  (Yardlet > About Yardlet), your macOS version, the agent and its CLI version, and the steps that lead to the problem.
- **Ideas:** open a [feature request](../../issues/new?template=feature_request.yml) and describe the problem first,
  then what you would like Yardlet to do.
- **Security problems:** do not open an issue. Follow [SECURITY.md](SECURITY.md).

Before you attach a log or a screenshot, remove tokens, email addresses, private repository names and anything else
you would not post in public.

## Pull requests

Pull requests are not accepted yet. Development still happens outside this repository, and this repository is updated
from it at each release, so a pull request merged here would be overwritten by the next update. Once development
moves into this repository, pull requests will open and this file will say how.

Until then, if you have a fix, describe it in an issue, with a patch or a link to a branch if you like. If the change is
used, the commit credits you.

## What fits Yardlet

Yardlet runs each agent's own CLI with its own sign-in and session history, and tries to stay as close as possible to
the agent's own app. A proposal fits best when it works for every agent, can be turned on and off, and leaves nothing
behind once it is turned off or removed. A feature that only one provider's API offers is not, on its own, a reason
to add a control.

## Building from source

See [Development](README.md#development) in the README.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE), like the rest of the
project.
