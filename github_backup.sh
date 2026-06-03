#!/usr/bin/env zsh
# =============================================================================
# github_backup.sh
# Full backup of GitHub repositories with per-organization filtering.
#
# Dependencies: git, curl, jq
#
# Configuration via environment variables:
#
#   GITHUB_TOKEN        (required) Personal Access Token
#   GITHUB_USER         (required) GitHub Username
#   BACKUP_DIR          Destination directory               [default: ./github-backup]
#   INCLUDE_USER_REPOS  Include personal repos              [default: true]
#   INCLUDE_FORKS       Include forks                       [default: false]
#   ORG_CONFIG          Path to org config file             [default: ./orgs.conf]
#
# orgs.conf format:
#   # Comments with #
#   org1                        <- all repos from the org
#   org2: repo-a, repo-b        <- only repo-a and repo-b
#   org3: *                     <- all repos (explicit)
#
# If ORG_CONFIG does not exist, ALL orgs with ALL repos will be included.
# =============================================================================

emulate -LR zsh
setopt ERR_EXIT PIPE_FAIL NO_UNSET

# --------------- Configuration ------------------------------------------------
GITHUB_TOKEN="${GITHUB_TOKEN}"
GITHUB_USER="${GITHUB_USER}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
INCLUDE_USER_REPOS="${INCLUDE_USER_REPOS:-true}"
INCLUDE_FORKS="${INCLUDE_FORKS:-false}"
ORG_CONFIG="${ORG_CONFIG:-./orgs.conf}"
API_BASE="${API_BASE:-https://api.github.com}"
PER_PAGE="${PER_PAGE:-100}"

# --------------- Colors -------------------------------------------------------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

log()   { echo "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()    { echo "${GREEN}[OK]${NC} $*"; }
warn()  { echo "${YELLOW}[WARN]${NC} $*"; }
error() { echo "${RED}[ERROR]${NC} $*" >&2; }
hdr()   { printf "\n${BOLD}%s${NC}\n" "$*"; }

# --------------- Dependency check ---------------------------------------------
for cmd in git curl jq zip; do
  command -v "$cmd" &>/dev/null || { error "'$cmd' not found."; exit 1; }
done

# --------------- API helpers --------------------------------------------------
gh_api() {
  curl -sf \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$1"
}

gh_api_paged() {
  local endpoint="$1" page=1 result count
  while true; do
    result=$(gh_api "${API_BASE}${endpoint}?per_page=${PER_PAGE}&page=${page}")
    count=$(echo "$result" | jq 'length')
    echo "$result" | jq -c '.[]'
    [[ "$count" -lt "$PER_PAGE" ]] && break
    (( page++ )) || true
  done
}

# --------------- orgs.conf parser ---------------------------------------------
# Emits pairs "org<TAB>repo"  or  "org<TAB>*"
parse_org_config() {
  [[ ! -f "$ORG_CONFIG" ]] && return

  local org repos_part r
  local -a repo_list

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"          # strip inline comments
    line="${line#"${line%%[![:space:]]*}"}"   # trim left
    line="${line%"${line##*[![:space:]]}"}"   # trim right
    [[ -z "$line" ]] && continue

    if [[ "$line" == *:* ]]; then
      org="${line%%:*}";  org="${org// /}"
      repos_part="${line#*:}"
      repo_list=(${(s:,:)repos_part})
      for r in "${repo_list[@]}"; do
        r="${r// /}"
        [[ -n "$r" ]] && printf '%s\t%s\n' "$org" "$r"
      done
    else
      org="${line// /}"
      [[ -n "$org" ]] && printf '%s\t%s\n' "$org" "*"
    fi
  done < "$ORG_CONFIG"
}

# --------------- Clone / update -----------------------------------------------
backup_repo() {
  local clone_url="$1" dest="$2" repo_name="$3"
  local zip_file="${dest}.zip"

  if [[ -f "$zip_file" ]]; then
    log "  ✓ Already present, skipping: ${repo_name}"
    return 2
  fi

  # Update local branches without touching the working tree.
  # git branch --force cannot update the current branch, so
  # git reset --hard is used for that.
  _sync_branches() {
    local default
    default=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    git branch -r | grep -v '\->' | grep -v 'HEAD' | sed 's|.*origin/||' | \
      while read -r branch; do
        if [[ "$branch" == "$default" ]]; then
          git reset --hard "origin/$branch" --quiet 2>/dev/null || true
        else
          git branch --force "$branch" "origin/$branch" 2>/dev/null || true
        fi
      done
  }

  if [[ -d "$dest/.git" ]]; then
    log "  ↻ Updating: ${repo_name}"
    (
      cd "$dest"
      git remote set-url origin "$clone_url"
      git fetch --all --prune --tags --quiet
      _sync_branches
    )
    ok "  Updated: ${repo_name}"
  else
    log "  ↓ Cloning: ${repo_name}"
    git clone "$clone_url" "$dest" --quiet 2>/dev/null || {
      error "  Cannot clone ${repo_name}"
      rm -rf "$dest"
      return 1
    }
    (
      cd "$dest"
      git fetch --all --tags --quiet
      _sync_branches
    )
    local nbranch
    nbranch=$(cd "$dest" && git branch | wc -l | tr -d ' ')
    ok "  Cloned: ${repo_name} (${nbranch} branches)"
  fi

  # Compress the folder and remove the original
  log "  ⎙ Compressing: ${repo_name}"
  rm -f "$zip_file"
  (cd "$(dirname "$dest")" && zip -r "$(basename "$zip_file")" "$(basename "$dest")" --quiet) || {
    error "  Cannot compress ${repo_name}"
    return 1
  }
  rm -rf "$dest"
  ok "  Compressed: $(basename "$zip_file")"
}

# --------------- Personal repo backup -----------------------------------------
backup_user_repos() {
  hdr "── Personal repositories of ${GITHUB_USER} ──"
  local count=0

  while IFS=$'\t' read -r full_name fork owner; do
    [[ "$owner" != "$GITHUB_USER" ]] && continue
    [[ "$INCLUDE_FORKS" != "true" && "$fork" == "true" ]] && continue

    local repo_name="${full_name#*/}"
    local dest="${BACKUP_DIR}/${GITHUB_USER}/${repo_name}"
    mkdir -p "${BACKUP_DIR}/${GITHUB_USER}"
    local url="https://${GITHUB_TOKEN}@github.com/${full_name}.git"

    local rc=0; backup_repo "$url" "$dest" "$full_name" || rc=$?
    case $rc in
      0) (( SUCCESS++ )) || true; (( count++ )) || true ;;
      2) (( SKIPPED++ )) || true ;;
      *) (( FAILED++ )) || true; FAILED_REPOS+=("$full_name") ;;
    esac
    (( TOTAL++ )) || true
  done < <(gh_api_paged "/user/repos" | jq -r '[.full_name, (.fork|tostring), .owner.login] | @tsv')

  log "  → ${count} personal repositories processed"
}

# --------------- Organization backup ------------------------------------------
backup_orgs() {
  # Associative map: org -> space-separated repo string (or "*")
  declare -A org_filter

  if [[ -f "$ORG_CONFIG" ]]; then
    log "Loading configuration from: ${ORG_CONFIG}"
    while IFS=$'\t' read -r org repo; do
      if (( ${+org_filter[$org]} )); then
        org_filter[$org]+=" $repo"
      else
        org_filter[$org]="$repo"
      fi
    done < <(parse_org_config)

    if [[ ${#org_filter[@]} -eq 0 ]]; then
      warn "Config file found but no valid org. No org will be processed."
      return
    fi
  else
    warn "ORG_CONFIG file '${ORG_CONFIG}' not found → including ALL orgs with all repos."
    while IFS= read -r org_name; do
      [[ -n "$org_name" ]] && org_filter[$org_name]="*"
    done < <(gh_api_paged "/user/orgs" | jq -r '.login')
  fi

  for org in "${(k)org_filter[@]}"; do
    local filter="${org_filter[$org]}"
    hdr "── Organization: ${org} ──"

    # Check whether to fetch all repos (wildcard)
    local all_repos=false
    for token in ${(s: :)filter}; do
      [[ "$token" == "*" ]] && { all_repos=true; break; }
    done

    local count=0
    while IFS=$'\t' read -r full_name fork; do
      local repo_name="${full_name#*/}"

      [[ "$INCLUDE_FORKS" != "true" && "$fork" == "true" ]] && continue

      if [[ "$all_repos" == "false" ]]; then
        local match=false
        for wanted in ${(s: :)filter}; do
          [[ "$wanted" == "$repo_name" ]] && { match=true; break; }
        done
        [[ "$match" == "false" ]] && continue
      fi

      local dest="${BACKUP_DIR}/${org}/${repo_name}"
      mkdir -p "${BACKUP_DIR}/${org}"
      local url="https://${GITHUB_TOKEN}@github.com/${full_name}.git"

      local rc=0; backup_repo "$url" "$dest" "$full_name" || rc=$?
      case $rc in
        0) (( SUCCESS++ )) || true; (( count++ )) || true ;;
        2) (( SKIPPED++ )) || true ;;
        *) (( FAILED++ )) || true; FAILED_REPOS+=("$full_name") ;;
      esac
      (( TOTAL++ )) || true
    done < <(gh_api_paged "/orgs/${org}/repos" | jq -r '[.full_name, (.fork|tostring)] | @tsv')

    log "  → ${count} repositories processed in ${org}"
  done
}

# --------------- Main ---------------------------------------------------------
TOTAL=0; SUCCESS=0; SKIPPED=0; FAILED=0; FAILED_REPOS=()

main() {
  BACKUP_DIR="${BACKUP_DIR}/$(date '+%Y%m%d')"

  hdr "=== GitHub Backup ==="
  log "User           : ${GITHUB_USER}"
  log "Output         : ${BACKUP_DIR}"
  log "Personal repos : ${INCLUDE_USER_REPOS}"
  log "Include forks  : ${INCLUDE_FORKS}"
  log "Org config     : ${ORG_CONFIG}"

  mkdir -p "$BACKUP_DIR"

  [[ "$INCLUDE_USER_REPOS" == "true" ]] && backup_user_repos
  backup_orgs

  hdr "=== Summary ==="
  ok  "Completed  : ${SUCCESS}/${TOTAL}"
  [[ $SKIPPED -gt 0 ]] && log "Skipped    : ${SKIPPED}/${TOTAL}"
  if [[ $FAILED -gt 0 ]]; then
    error "Failed     : ${FAILED}/${TOTAL}"
    for r in "${FAILED_REPOS[@]}"; do error "  - $r"; done
  fi
  echo "Backup: $(date '+%Y-%m-%d %H:%M:%S') | OK=${SUCCESS} SKIP=${SKIPPED} FAIL=${FAILED}" \
    >> "${BACKUP_DIR}/backup.log"
}

main "$@"
