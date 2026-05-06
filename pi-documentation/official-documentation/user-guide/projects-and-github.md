# Projects and GitHub

Pi Manager combines local project discovery with GitHub issue and repository workflows.

## Projects

Projects are discovered under the configured projects root and from manually configured paths. A discovered project records:

- local folder URL
- whether it is a Git repository
- GitHub remote information when available
- display name, icon, and search index metadata

The selected project affects project-scoped resource scanning, Git status, GitHub repository filtering, and Pi Agent working directory.

## GitHub integration

The GitHub screen includes:

- **Project Board** — issues fetched through GitHub search
- **Repo Changes** — local git status and diffs
- **Connection** — authentication state and connection details

Pi Manager uses the GitHub CLI (`gh`) to discover authentication and token state, then calls the GitHub REST API directly.

## Issue-to-agent workflow

A common workflow is:

1. select a local project
2. open its GitHub issue board
3. choose an issue
4. start a Pi Agent session from that issue context
5. review the generated changes in the Repo Changes panel
6. stage, commit, push, comment, or close the issue when ready

Issue prompts include issue title, number, URL, body, relationship metadata, and recent comments.

## Git operations

Pi Manager shells out to `git` for status, diffs, staging, unstaging, commits, and pushes. It does not replace Git; it provides UI around normal Git commands.
