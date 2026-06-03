# github-backup

A zsh script that clones or updates all your GitHub repositories — personal and organization — and compresses each one into a dated zip archive.

## Features

- Backs up personal repositories (owned by you, not just accessible)
- Backs up repositories from one or more GitHub organizations
- Per-organization filtering: all repos, specific repos, or wildcard
- Incremental: already-backed-up repos are skipped (zip file presence check)
- Updates existing clones with `git fetch --all --prune --tags`
- Syncs all remote branches locally
- Compresses each repository to a `.zip` and removes the working directory
- Appends a summary line to `backup.log` on each run
- Colored, timestamped output

## Requirements

- **zsh** 5.0+
- **git**
- **curl**
- **jq**
- **zip**

## Setup

1. Clone or download the script:

   ```sh
   git clone https://github.com/fcaldarelli/github-backup.git
   cd github-backup
   chmod +x github_backup.sh
   ```

2. Create a GitHub Personal Access Token with at least these scopes:
   - `repo` (read access to private repositories)
   - `read:org` (list organization memberships)

3. Export the required environment variables:

   ```sh
   export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"
   export GITHUB_USER="your-github-username"
   ```

## Usage

```sh
./github_backup.sh
```

Output is written to `./backups/YYYYMMDD/` by default.

## Configuration

All options are set via environment variables:

| Variable             | Required | Default            | Description                              |
|----------------------|----------|--------------------|------------------------------------------|
| `GITHUB_TOKEN`       | yes      | —                  | Personal Access Token                    |
| `GITHUB_USER`        | yes      | —                  | Your GitHub username                     |
| `BACKUP_DIR`         | no       | `./backups`        | Base output directory                    |
| `INCLUDE_USER_REPOS` | no       | `true`             | Back up personal repositories            |
| `INCLUDE_FORKS`      | no       | `false`            | Include forked repositories              |
| `ORG_CONFIG`         | no       | `./orgs.conf`      | Path to organization filter config file  |
| `PER_PAGE`           | no       | `100`              | GitHub API page size (max 100)           |

Example one-liner:

```sh
GITHUB_TOKEN="ghp_xxx" GITHUB_USER="alice" BACKUP_DIR="/mnt/backups" ./github_backup.sh
```

## Organization filter (orgs.conf)

By default the script looks for `orgs.conf` in the current directory. If the file does **not** exist, **all** organizations you belong to are backed up in full.

If the file exists, only the organizations listed in it are processed.

### Syntax

```
# Lines starting with # are comments

# Back up all repos in this org
my-company

# Explicit wildcard — same as above
another-org: *

# Only specific repos
client-org: backend-api, frontend-app, shared-libs

# Single repo
small-org: one-repo
```

- Whitespace around `:` and `,` is ignored.
- Empty lines and inline `#` comments are ignored.

## Output structure

```
backups/
└── 20240603/
    ├── your-username/
    │   ├── repo-one.zip
    │   └── repo-two.zip
    ├── your-org/
    │   ├── service-a.zip
    │   └── service-b.zip
    └── backup.log
```

Each `.zip` contains a full clone of the repository with all branches and tags.

## Scheduling with cron

```cron
0 2 * * * GITHUB_TOKEN="ghp_xxx" GITHUB_USER="alice" /path/to/github_backup.sh >> /var/log/github_backup.log 2>&1
```

## Notes

- The script is **read-only** with respect to remote repositories. It never pushes, force-pushes, or modifies anything on GitHub.
- Repositories already present as `.zip` files are skipped to allow incremental runs.
- The token is embedded in clone URLs and never written to disk outside of git's credential store.

## License

MIT
