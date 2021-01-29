#!/bin/bash

# set -x
set -o pipefail

## functions
clear_stdin() {
  while read -r -t 0; do read -r; done
}
msg_start() {
  [[ $MSG_STATUS == 1 ]] \
    && exception "Message already started"
  MSG_STATUS=1
  printf -- "%s ... " "$@" >&2
}
msg_end() {
  [[ $MSG_STATUS == 0 ]] \
    && exception "Message not started"
  MSG_STATUS=0
  printf "[ done ]\n" >&2
}
confirm() {
  printf -- "%s [YES/No] " "${1:-"Are you sure?"}" >&2
  clear_stdin
  read -r
  [[ "$REPLY" =~ ^[Yy]([Ee][Ss])?$ || -z "$REPLY" ]] \
    && return 0
  [[ "$REPLY" =~ ^[Nn][Oo]?$ ]] \
    && return 1
  confirm "Type"
}
prompt() {
  printf -- "%s: " "${1:-Enter value}" >&2
  clear_stdin
  # silent user input (e.g. for password)
  if [[ $2 == silent ]]; then
    read -rs
  else
    read -r
  fi
  [[ -n "$REPLY" ]] \
    && return 0
  prompt "$1"
}
set_dev_mode() {
  case "$1" in
    "$ALWAYS"|"$NEVER"|"$AUTO")
      SET_DEVEL=$1
      return 0
    ;;
  esac
  exception "Invalid parameter -d value" 2
  return 2
}
exception() {
  printf -- "EXCEPTION: %s\n" "${1:-$SCRIPT_NAME Unknown exception}" >&2
  exit "${2:-1}"
}
print_usage() {
  fmt -w "$(tput cols)" <<< "$USAGE"
}
check_command() {
  command -v "$1" >/dev/null 2>&1
}
git_repo_exists() {
  [[ -d "${1:-.}/.git" ]]
}
git_local_branch_exists() {
  git -C "${2:-.}" rev-parse --verify "$1" >/dev/null 2>&1
}
git_current_branch() {
  local out
  out=$(git -C "${1:-.}" rev-parse --abbrev-ref HEAD) \
    || exception "$out"
  printf -- "%s\n" "$out"
}
git_same_commit() {
  [[ "$( git -C "${3:-.}" rev-parse "$1" )" == "$( git -C "${3:-.}" rev-parse "$2" )" ]]
}
git_init() {
  local out
  out=$(git -C "${1:-.}" init 2>&1) \
    || exception "$out"
}
git_add_all() {
  local out
  out=$(git -C "${1:-.}" add -A 2>&1) \
    || exception "$out"
}
git_checkout() {
  local out
  # shellcheck disable=SC2086
  out=$(git -C "${2:-.}" checkout $1 2>&1) \
    || exception "$out"
}
git_status_empty() {
  [[ -z "$(git -C "${1:-.}" status --porcelain)" ]]
}
git_remote_exists() {
  [[ -n "$(git -C "${2:-.}" config remote."${1:-origin}".url 2>/dev/null)" ]]
}
git_pull() {
  local out
  # shellcheck disable=SC2086
  out=$(git -C "${1:-.}" pull $2 2>&1) \
    || exception "$out"
}
git_merge() {
  local out
  # shellcheck disable=SC2086
  out=$(git -C "${2:-.}" merge $1 2>&1) \
    || exception "$out"
}
git_push() {
  local out
  # shellcheck disable=SC2086
  out=$(git -C "${2:-.}" push $1 2>&1) \
    || exception "$out"
}
git_commit() {
  local out
  # shellcheck disable=SC2086
  out=$(git -C "${2:-.}" commit $3 -m "$1" 2>&1) \
    || exception "$out"
}
git_fetch_all() {
  local out
  out=$(git -C "${1:-.}" fetch --all 2>&1) \
    || exception "$out"
}
gitlab_api() {
  local req response status output
  req="GET"
  [[ -n "$2" ]] \
    && req="POST"
  response=$(curl --silent --write-out "\n%{http_code}\n" \
    --header "Authorization: Bearer $TOKEN" \
    --header "Content-Type: application/json" \
    --request $req --data "${2:-{\}}" "https://$GITLAB_URL/$1")
  status=$(sed -n '$p' <<< "$response")
  output=$(sed '$d' <<< "$response")
  [[ "$status" != 20* ]] \
    && printf -- "%s\n" "$output" >&2 \
    && exception "Invalid request $1 [$status]"
  printf -- "%s\n" "$output"
}
authorize() {
  local username password
  [[ -s "$TOKEN_PATH" ]] \
    && return
  prompt "Username"
  username="$REPLY"
  prompt "Password" silent
  password="$REPLY"
  echo
  gitlab_api "oauth/token" \
    "{\"grant_type\":\"password\",\"username\":\"$username\",\"password\":\"$password\"}" \
    | jq -r '.access_token' > "$TOKEN_PATH"
}
get_project_id() {
  gitlab_api "api/v4/projects/${1//\//%2F}" | jq .id
}
project_exists() {
  get_project_id "$1" >/dev/null 2>&1
}
get_group_id() {
  gitlab_api "api/v4/groups/${1//\//%2F}" | jq .id
}
create_request() {
  local project_id
  project_id=$(get_project_id "$1") \
    || exit 1
  gitlab_api "api/v4/projects/$project_id/merge_requests" \
    "{\"id\":\"$project_id\", \"source_branch\":\"$SOURCE_BRANCH\", \"target_branch\":\"master\", \
    \"remove_source_branch\": \"false\", \"title\": \"Update from $SOURCE_BRANCH branch\"}" >/dev/null
}
create_project() {
  local visibility
  visibility="public"
  [[ -n "$3" ]] \
    && visibility="private"
  gitlab_api "api/v4/projects" \
    "{\"namespace_id\":\"$1\", \"name\":\"$2\", \"visibility\":\"$visibility\"}" \
    | jq -r '.id'
}
get_role() {
  gitlab_api "api/v4/projects/$1/members/all/$2" | jq -r '.access_level'
}
add_developer() {
  local role
  [[ -z "$2" ]] \
    && return
  role=$(get_role "$1" "$2" 2>/dev/null)
  (( role >= 30 )) \
    && return
  gitlab_api "api/v4/projects/$1/members" \
    "{\"access_level\":\"30\", \"user_id\":\"$2\"}" >/dev/null
}
create_group() {
  gitlab_api "api/v4/groups" \
    "{\"name\":\"$1\", \"path\":\"$1\", \"parent_id\":\"$2\", \"visibility\":\"public\"}" \
    | jq -r '.id'
}
get_user_id() {
  gitlab_api "api/v4/users?username=$1" \
    | jq -r '.[] | .id' | sed 's/null//'
}
create_ns() {
  local parent_ns parent_id
  parent_ns=$(dirname "$1")
  [[ "$parent_ns" == . ]] \
    && exception "Root group $1 does not exist"
  parent_id=$(get_group_id "$parent_ns" 2>/dev/null) \
    || parent_id=$(create_ns "$parent_ns") \
    || exit 1
  create_group "$(basename "$1")" "$parent_id"
}
init_user_repo() {
  local user group_id project_ns project_folder user_id actual_remote_ns remote_url
  user="$1"
  group_id="$2"
  project_ns="$REMOTE_NS/$user"
  project_folder="$CACHE_FOLDER/$project_ns"
  if ! project_exists "$project_ns"; then
    user_id=""
    [[ $SET_DEVEL == "$NEVER" ]] \
      || user_id=$(get_user_id "$user") \
      || exit 1
    [[ $SET_DEVEL == "$ALWAYS" && -z "$user_id" ]] \
      && exception "User $user does not exist"
    project_id=$(create_project "$group_id" "$user" "$user_id") \
      && add_developer "$project_id" "$user_id" \
      && copy_issues "$project_id" "$user_id" \
      || exit 1
    rm -rf "$project_folder"
  fi
  if [[ -d "$project_folder" ]]; then
    # verify local remote
    actual_remote_ns=$(get_remote_namespace "$project_folder") \
      || exit 1
    [[ "$actual_remote_ns" != "$project_ns" ]] \
      && exception "Invalid user project remote origin url"
    git_pull "$project_folder" "origin $SOURCE_BRANCH:$SOURCE_BRANCH" \
      || exit 1
  else
    # clone existing remote
    remote_url="https://oauth2:$TOKEN@gitlab.com/$project_ns.git"
    git clone -q "$remote_url" "$project_folder" 2>/dev/null \
      || exception "Unable to clone user project $project_ns"
  fi
  # create first commit in case of empty repo (stay on main branch for update)
  if ! git -C "$project_folder" log >/dev/null 2>&1; then
    git_commit "initial commit" "$project_folder" "--allow-empty"
    git_push "--all" "$project_folder"
    return
  fi
  # checkout SOURCE_BRANCH
  git_checkout "$SOURCE_BRANCH" "$project_folder" \
    || exception "Missing $SOURCE_BRANCH"
}
replace_readme() {
  local project_ns project_folder main_branch
  project_ns="$1"
  project_folder="$2"
  main_branch="$3"
  sed -i "s~/$PROJECT_NS/~/$project_ns/~g" "$project_folder/$README_FILE"
  [[ -z "$PROJECT_BRANCH" ]] \
    && return
  sed -i "s~/$PROJECT_BRANCH/\(pipeline\|raw\|file\)~/$main_branch/\1~g" "$project_folder/$README_FILE"
  sed -i "s~ref=$PROJECT_BRANCH~ref=$main_branch~g" "$project_folder/$README_FILE"
}
update_user_repo() {
  local project_ns project_folder main_branch
  project_ns="$REMOTE_NS/$1"
  project_folder="$CACHE_FOLDER/$project_ns"
  # update from assignment
  rsync -a --delete --exclude .git/ "$PROJECT_FOLDER/" "$project_folder"
  # replace remote in readme file
  main_branch=$(git -C "$project_folder" remote show origin | grep "HEAD branch:" | tr -d " " | cut -d: -f2)
  [[ $README_REPLACE == 1 ]] \
    && replace_readme "$project_ns" "$project_folder" "$main_branch"
  git_status_empty "$project_folder" \
    && return
  # commit
  git_add_all "$project_folder"
  git_commit "Update assignment" "$project_folder"
  # if first commit create SOURCE_BRANCH on main branch and push both
  git_checkout "-B $SOURCE_BRANCH" "$project_folder"
  git_push "--all" "$project_folder"
  # create PR iff new commit
  git_same_commit "$main_branch" "$SOURCE_BRANCH" "$project_folder" \
    && return
  create_request "$project_ns" "$main_branch" "$SOURCE_BRANCH"
}
get_remote_namespace() {
  # shellcheck disable=SC1087
  git -C "$1" config --get remote.origin.url | sed "s/^.*$GITLAB_URL[:/]//;s/.git$//"
}
read_issues() {
  [[ -z "$PROJECT_ID" ]] \
    && ISSUES_COUNT=0 \
    && return
  ISSUES=$(gitlab_api "api/v4/projects/$PROJECT_ID/issues?labels=assignment") \
    && ISSUES_COUNT=$(jq length <<< "$ISSUES") \
    || exit 1
}
copy_issues() {
  local issue
  (( "$ISSUES_COUNT" < 0 )) \
    && read_issues
  for (( i=0; i < ISSUES_COUNT; i++ )); do
    issue=$(jq ".[$i] | { title,description,due_date }" <<< "$ISSUES")
    [[ -n "$2" ]] \
      && issue=$(jq --arg a "$2" '. + {assignee_ids:[$a]}' <<< "$issue")
    gitlab_api "api/v4/projects/$1/issues" "$issue" >/dev/null \
      || exit 1
  done
}

## default global variables
SCRIPT_NAME=$(basename "$0")
REMOTE_NS=""
PROJECT_FOLDER="." # current folder
USER_LIST=""
README_FILE="README.md"
README_REPLACE=0
CACHE_FOLDER="$HOME/.cad_cache"
GITLAB_URL="gitlab.com"
TOKEN_FILE=".gitlab_access_token"
TOKEN_PATH="$HOME/$TOKEN_FILE"
SOURCE_BRANCH="source"
PROJECT_NS=""
PROJECT_ID=""
PROJECT_BRANCH=""
ISSUES=""
ISSUES_COUNT=-1
MSG_STATUS=0
ALWAYS="always"
NEVER="never"
AUTO="auto"
SET_DEVEL="$AUTO"

## usage
USAGE="USAGE
      $SCRIPT_NAME -n REMOTE_NAMESPACE -u USER_LIST [-rh] [-f PROJECT_FOLDER]

OPTIONS
      -d[MODE], --developer[=MODE]
              Set developer rights to newly created projects '$ALWAYS', '$NEVER', or '$AUTO' (default).

      -f, --folder=PROJECT_FOLDER
              Path to project with the assignment, default current directory.

      -h, --help
              Display usage.

      -n, --namespace=REMOTE_NAMESPACE
              GitLab root namespace, where root must exist, e.g. umiami/george/csc220/fall20

      -r, --replace
              Replace any occurrence of assignment project remote URL with user project remote URL in $README_FILE file.

      -u, --usernames=USER_LIST
              List of one or more solvers separated by space or newline, e.g. 'user1 user2'.
"

## option preprocessing
if ! LINE=$(
  getopt -n "$0" \
        -o d::f:hn:ru: \
        -l developer::,folder:,help,namespace:,replace,usernames: \
        -- "$@"
)
then
  exit 1
fi
eval set -- "$LINE"

## load user options
while (( $# > 0 )); do
  case $1 in
    -d|--developer) shift; set_dev_mode "$1" || exit 2; shift ;;
    -f|--folder) shift; PROJECT_FOLDER="$1"; shift ;;
    -h|--help) print_usage && exit 0 ;;
    -n|--namespace) shift; REMOTE_NS="$1"; shift ;;
    -r|--replace) README_REPLACE=1; shift ;;
    -u|--usernames) shift; USER_LIST="$1"; shift ;;
    --) shift; break ;;
    *-) printf -- "%s: Unrecognized option '%s'\n" "$0" "$1" >&2; exit 2 ;;
     *) break ;;
  esac
done

# parameter validation
[[ ! "$REMOTE_NS" =~ ^[a-z0-9]{2,}(/[a-z0-9]{2,}){2,}$ ]] \
  && exception "Missing or invalid REMOTE_NAMESPACE option, value '$REMOTE_NS'" 2
USERNAMES=0
for USER in $USER_LIST; do
  [[ ! "$USER" =~ ^[a-z][a-z0-9_-]{4,}$ ]] \
    && exception "Unsupported user format, value '$USER'" 2
  (( USERNAMES++ ))
done
[[ $USERNAMES == 0 ]] \
  && exception "Missing or empty USER_LIST option" 2

# # redir stdin
# exec 3<&0
# exec 0</dev/tty

msg_start "Checking environment"
check_command "git" \
  || exception "Command git is required"
check_command "jq" \
  || exception "Command jq is required"
msg_end

msg_start "Checking paths"
PROJECT_FOLDER=$(readlink -f "$PROJECT_FOLDER")
[[ -d "$PROJECT_FOLDER" ]] \
  || exception "Project folder not found."
[[ $README_REPLACE == 1 && ! -f "$PROJECT_FOLDER/$README_FILE" ]] \
  && exception "Readme file not found."
msg_end

authorize \
  || exception "Unable to authorize"
TOKEN=$(cat "$TOKEN_PATH")

msg_start "Getting project information"
if [[ -d "$PROJECT_FOLDER/.git" ]]; then
  PROJECT_NS=$(get_remote_namespace "$PROJECT_FOLDER") \
    && PROJECT_ID=$(get_project_id "$PROJECT_NS") \
    && PROJECT_BRANCH=$(git_current_branch "$PROJECT_FOLDER") \
    || exit 1
fi
msg_end

msg_start "Processing namespace"
GROUP_ID=$(get_group_id "$REMOTE_NS" 2>/dev/null) \
  || GROUP_ID=$(create_ns "$REMOTE_NS") \
  || exit 1
msg_end

# process users
for USER in $USER_LIST; do
  msg_start "Processing repository for $USER"
  init_user_repo "$USER" "$GROUP_ID" \
    && update_user_repo "$USER" \
    || exit 1
  msg_end
done
