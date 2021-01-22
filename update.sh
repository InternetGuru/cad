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
  echo -n "$1 ... " >&2
}
msg_end() {
  [[ $MSG_STATUS == 0 ]] \
    && exception "Message not started"
  MSG_STATUS=0
  echo "[ $1 ]" >&2
}
confirm() {
  echo -n "${1:-"Are you sure?"} [YES/No] " >&2
  clear_stdin
  read -r
  [[ "$REPLY" =~ ^[Yy]([Ee][Ss])?$ || -z "$REPLY" ]] \
    && return 0
  [[ "$REPLY" =~ ^[Nn][Oo]?$ ]] \
    && return 1
  confirm "Type"
}
prompt() {
  echo -n "${1:-Enter value}: "
  clear_stdin
  # do not echo output (e.g. for password)
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
    always|never|auto)
      DEV_MODE=$1
      return 0
    ;;
  esac
  exception "Invalid parameter -d value" 2
  return 2
}
exception() {
  echo "EXCEPTION: ${1:-$SCRIPT_NAME Unknown exception}" >&2
  exit "${2:-1}"
}
format_usage() {
  echo -e "$1" | fmt -w "$(tput cols)"
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
  # shellcheck disable=SC2086
  out="$(git -C "${1:-.}" rev-parse --abbrev-ref HEAD)" \
    || exception "$out"
  echo "$out"
}
git_same_commit() {
  [[ "$( git -C "${3:-.}" rev-parse "$1" )" == "$( git -C "${3:-.}" rev-parse "$2" )" ]]
}
git_init() {
  local out
  # shellcheck disable=SC2086
  out="$(git -C "${1:-.}" init 2>&1)" \
    || exception "$out"
}
git_add_all() {
  local out
  # shellcheck disable=SC2086
  out="$(git -C "${1:-.}" add -A 2>&1)" \
    || exception "$out"
}
git_checkout() {
  local out
  # shellcheck disable=SC2086
  out="$(git -C "${2:-.}" checkout $1 2>&1)" \
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
  out="$(git -C "${1:-.}" pull $2 2>&1)" \
    || exception "$out"
}
git_merge() {
  local out
  # shellcheck disable=SC2086
  out="$(git -C "${2:-.}" merge $1 2>&1)" \
    || exception "$out"
}
git_push() {
  local out
  # shellcheck disable=SC2086
  out="$(git -C "${2:-.}" push $1 2>&1)" \
    || exception "$out"
}
git_commit() {
  local out
  # shellcheck disable=SC2086
  out="$(git -C "${2:-.}" commit $3 -m "$1" 2>&1)" \
    || exception "$out"
}
git_fetch_all() {
  local out
  out="$(git -C "${1:-.}" fetch --all 2>&1)" \
    || exception "$out"
}
gitlab_api() {
  req=GET
  [[ -n "$2" ]] \
    && req=POST
  response=$(curl --silent --write-out "\n%{http_code}\n" \
    --header "Authorization: Bearer $TOKEN" \
    --header "Content-Type: application/json" \
    --request $req --data "${2:-{\}}" "$1")
  status="$(echo "$response" | sed -n '$p')"
  output="$(echo "$response" | sed '$d')"
  [[ "$status" != 20* ]] \
    && echo "$output" >&2 \
    && exception "Invalid request $1 [$status]"
  echo "$output"
}
authorize() {
  [[ -s "$ACCESS_TOKEN_PATH" ]] \
    && return
  prompt "Username"
  username="$REPLY"
  prompt "Password" silent
  password="$REPLY"
  echo
  gitlab_api "$GITLAB_URL/oauth/token" \
    "{\"grant_type\":\"password\",\"username\":\"$username\",\"password\":\"$password\"}" \
    | jq -r '.access_token' > "$ACCESS_TOKEN_PATH"
}
get_project_id() {
  gitlab_api "$GITLAB_URL/api/v4/projects?search=$(basename "$1")" \
    | jq -r --arg ns "$1" '.[] | select(.path_with_namespace==$ns) | .id'
}
get_group_id() {
  gitlab_api "$GITLAB_URL/api/v4/groups?search=$1" \
    | jq -r --arg full_path "$1" '.[] | select(.full_path==$full_path) | .id'
}
create_request() {
  project_id="$(get_project_id "$1")" \
    || [[ -n "$project_id" ]] \
    || exit 1
  gitlab_api "$GITLAB_URL/api/v4/projects/$project_id/merge_requests" \
    "{\"id\":\"$project_id\", \"source_branch\":\"$SOURCE_BRANCH\", \"target_branch\":\"master\", \
    \"remove_source_branch\": \"false\", \"title\": \"Update from $SOURCE_BRANCH branch\"}" >/dev/null
}
create_project() {
  gitlab_api "$GITLAB_URL/api/v4/projects" \
    "{\"namespace_id\":\"$1\", \"name\":\"$2\", \"visibility\":\"private\"}" \
    | jq -r '.id'
}
add_developer() {
  gitlab_api "$GITLAB_URL/api/v4/projects/$1/members" \
    "{\"access_level\":\"30\", \"user_id\":\"$2\"}" >/dev/null
}
create_group() {
  gitlab_api "$GITLAB_URL/api/v4/groups?name=$1&path=$1&parent_id=$2" "{}" \
    | jq -r '.id'
}
get_user_id() {
  gitlab_api "$GITLAB_URL/api/v4/users?username=$1" \
    | jq -r '.[] | .id' | sed 's/null//'
}
create_namespace() {
  # check or create subgroups
  group_id=
  full_path=
  for group in $(echo "$1" | tr '/' ' '); do
    # root group must exist
    if [[ -z "$group_id" ]]; then
      full_path="$group"
      group_id="$(get_group_id "$full_path")" \
        || exit 1
      [[ -z "$group_id" ]] \
        && exception "Root group $group does not exist"
      continue
    fi
    full_path="$full_path/$group"
    tmp_group_id="$(get_group_id "$full_path")" \
      || exit 1
    [[ -n "$tmp_group_id" ]] \
      || tmp_group_id="$(create_group "$group" "$group_id")" \
      || exit 1
    [[ -n "$tmp_group_id" ]] \
      || exception "Unable to get/create group $group"
    group_id="$tmp_group_id"
  done
  echo "$group_id"
}
init_user_repo() {
  user="$1"
  user_id="$2"
  group_id="$3"
  user_project_ns="$REMOTE_NAMESPACE/$user"
  user_project_folder="$USER_CACHE_FOLDER/$user_project_ns"
  remote_url="https://oauth2:$TOKEN@gitlab.com/$user_project_ns.git"
  err="$(git ls-remote "$remote_url" 2>&1 >/dev/null)"

  if [[ -n "$err" ]]; then
    project_id="$(create_project "$group_id" "$user")" \
      && dup_issues "$user_id" \
      || exit 1
    [[ -z "$user_id" ]] \
      || add_developer "$project_id" "$user_id" \
      || exit 1
    rm -rf "$user_project_folder"
  fi
  if [[ -d "$user_project_folder" ]]; then
    # verify local remote
    actual_remote_url="$(git -C "$user_project_folder" config remote.origin.url)"
    [[ "$actual_remote_url" =~ /$user_project_ns.git$ ]] \
      || exception "Invalid user project remote origin url"
    git_pull "$user_project_folder" "origin $SOURCE_BRANCH:$SOURCE_BRANCH" \
      || exit 1
  else
    # clone existing remote
    git clone -q "$remote_url" "$user_project_folder" 2>/dev/null \
      || exception "Unable to clone user project $user_project_ns"
  fi
  # create first commit in case of empty repo (stay on main branch for update)
  if ! git -C "$user_project_folder" log >/dev/null 2>&1; then
    git_commit "initial commit" "$user_project_folder" "--allow-empty"
    git_push "--all" "$user_project_folder"
    return
  fi
  # checkout SOURCE_BRANCH
  git_checkout "$SOURCE_BRANCH" "$user_project_folder" \
    || exception "Missing $SOURCE_BRANCH"
}
replace_readme() {
  user_project_ns="$1"
  user_project_folder="$2"
  main_branch="$3"
  project_remote="$(git -C "$PROJECT_FOLDER" config remote.origin.url)"
  project_ns="${project_remote#*:}"
  project_ns="${project_ns%.git}"
  sed -i "s~/$project_ns/~/$user_project_ns/~g" "$user_project_folder/README.md"
  [[ -z "$PROJECT_BRANCH" ]] \
    && return
  sed -i "s~/$PROJECT_BRANCH/\(pipeline\|raw\|file\)~/$main_branch/\1~g" "$user_project_folder/README.md"
  sed -i "s~ref=$PROJECT_BRANCH~ref=$main_branch~g" "$user_project_folder/README.md"
}
update_user_repo() {
  user_project_ns="$REMOTE_NAMESPACE/$1"
  user_project_folder="$USER_CACHE_FOLDER/$user_project_ns"
  # update from assignment
  rsync -a --delete --exclude .git/ "$PROJECT_FOLDER/" "$user_project_folder"
  # replace remote in README.md
  main_branch="$(git -C "$user_project_folder" remote show origin | grep "HEAD branch:" | tr -d " " | cut -d: -f2)"
  [[ $REPLACE_README_REMOTE == 1 ]] \
    && replace_readme "$user_project_ns" "$user_project_folder" "$main_branch"
  git_status_empty "$user_project_folder" \
    && return
  # commit
  git_add_all "$user_project_folder"
  git_commit "Update assignment" "$user_project_folder"
  # if first commit create SOURCE_BRANCH on main branch and push both
  git_checkout "-B $SOURCE_BRANCH" "$user_project_folder"
  git_push "--all" "$user_project_folder"
  # create PR iff new commit
  git_same_commit "$main_branch" "$SOURCE_BRANCH" "$user_project_folder" \
    && return
  create_request "$user_project_ns" "$main_branch" "$SOURCE_BRANCH"
}
get_remote_namespace() {
  # remove hostname prefix and .git suffix from URL (expecting gitlab.com)
  # expecting $PROJECT_FOLDER to be set
  git -C "$PROJECT_FOLDER" config --get remote.origin.url \
  | sed 's/^[^:]*://;s/\.git$//'
}
get_issues() {
  [[ "$ISSUES" != "null" ]] \
    && return
  src_remote_namespace=$(get_remote_namespace)
  [[ -z "$src_remote_namespace" ]] \
    && ISSUES= \
    && return
  msg_start "Get list of assignment issues"
  src_project_id=$(get_project_id "$src_remote_namespace") \
    && ISSUES=$(gitlab_api "$GITLAB_URL/api/v4/projects/$src_project_id/issues?labels=assignment") \
    || exit 1
  msg_end "$DONE"
}
dup_issues() {
  # duplicate issues from source project to user project
  local assignee=$1
  get_issues
  issues_count=$(jq length <<< "$ISSUES")
  for (( i=0; i < issues_count; i++ )); do
    issue=$(jq ".[$i] | { title,description,due_date }" <<< "$ISSUES")
    [[ -n "$assignee" ]] \
      && issue=$(jq --arg a "$assignee" '. + {assignee_ids:[$a]}' <<< "$issue")
    gitlab_api "$GITLAB_URL/api/v4/projects/$project_id/issues" "$issue" \
      || exit 1
  done
}

## default global variables
SCRIPT_NAME="$(basename "$0")"
REMOTE_NAMESPACE=""
PROJECT_FOLDER="." # current folder
USER_LIST=""
REPLACE_README_REMOTE=0
DEV_MODE="auto"
CACHE_FOLDER=".cad_cache"
USER_CACHE_FOLDER="$HOME/$CACHE_FOLDER"
GITLAB_URL="https://gitlab.com"
ACCESS_TOKEN_FILE=".gitlab_access_token"
ACCESS_TOKEN_PATH="$HOME/$ACCESS_TOKEN_FILE"
DONE=" done "
SOURCE_BRANCH="source"
PROJECT_BRANCH=""
ISSUES=null
MSG_STATUS=0

## usage
USAGE="$(format_usage "DESCRIPTION
      $SCRIPT_NAME distributes PROJECT_FOLDER into one or more repositories. The remote repository path for each USER from USER_LIST is REMOTE_NAMESPACE/USER.

      The script uses ~/$CACHE_FOLDER folder to cache repositories and access token at ~/$ACCESS_TOKEN_FILE to authorize. Prompts credentials if access token is not found.

      All created repositories are owned by the authenticated user and their visibility is set to private. Each repository has appropriate user assigned with developer rights if USER is an existing GitLab username.

USAGE
      $SCRIPT_NAME -n REMOTE_NAMESPACE -u USER_LIST [-rh] [-f PROJECT_FOLDER]

OPTIONS
      -d[MODE], --developer[=MODE]
              Set developer rights to newly created projects 'always', 'never', or 'auto' (default).

      -f, --folder=PROJECT_FOLDER
              Path to project with the assignment, default current directory.

      -h, --help
              Display usage.

      -n, --namespace=REMOTE_NAMESPACE
              GitLab root namespace, where root must exist, e.g. umiami/george/csc220/fall20

      -r, --replace
              Replace any occurrence of assignment project remote URL with user project remote URL in README.md file.

      -u, --usernames=USER_LIST
              List of one or more solvers separated by space or newline, e.g. 'user1 user2'.
")"

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
    -h|--help) echo -e "$USAGE" && exit 0 ;;
    -n|--namespace) shift; REMOTE_NAMESPACE="$1"; shift ;;
    -r|--replace) REPLACE_README_REMOTE=1; shift ;;
    -u|--usernames) shift; USER_LIST="$1"; shift ;;
    --) shift; break ;;
    *-) echo "$0: Unrecognized option '$1'" >&2; exit 2 ;;
     *) break ;;
  esac
done

# parameter validation
[[ ! "$REMOTE_NAMESPACE" =~ ^[a-z0-9]{2,}(/[a-z0-9]{2,}){2,}$ ]] \
  && exception "Missing or invalid REMOTE_NAMESPACE option, value '$REMOTE_NAMESPACE'" 2
usernames=0
for user in $USER_LIST; do
  [[ ! "$user" =~ ^[a-z][a-z0-9_-]{4,}$ ]] \
    && exception "Invalid user format, value '$user'" 2
  (( usernames++ ))
done
[[ $usernames == 0 ]] \
  && exception "Missing or empty USER_LIST option" 2

PROJECT_FOLDER="$(readlink -f "$PROJECT_FOLDER")"
[[ ! -d "$PROJECT_FOLDER/.git" ]] \
  || PROJECT_BRANCH="$(git_current_branch "$PROJECT_FOLDER")" \
  || exit 1

# # redir stdin
# exec 3<&0
# exec 0</dev/tty

msg_start "Checking environment"
check_command "git" \
  || exception "Command git is required"
check_command "jq" \
  || exception "Command jq is required"
msg_end "$DONE"

msg_start "Checking paths"
[[ ! -d "$PROJECT_FOLDER" ]] \
  && exception "$PROJECT_FOLDER is not a directory"
[[ $REPLACE_README_REMOTE == 1 && ! -f "$PROJECT_FOLDER/README.md" ]] \
  && exception "Project folder missing README.md"
msg_end "$DONE"

authorize \
  || exception "Unable to authorize"
TOKEN="$(cat "$ACCESS_TOKEN_PATH")"

# process users
msg_start "Creating / checking remote path $REMOTE_NAMESPACE"
group_id="$(get_group_id "$REMOTE_NAMESPACE")" \
  || exit 1
[[ -n "$group_id" ]] \
  || group_id="$(create_namespace "$REMOTE_NAMESPACE")" \
  || exit 1
msg_end "$DONE"
for user in $USER_LIST; do
  # check user
  user_id=""
  [[ $DEV_MODE == "never" ]] \
    || user_id="$(get_user_id "$user")" \
    || exit 1
  [[ $DEV_MODE == "always" && -z "$user_id" ]] \
    && exception "User $user does not exist"
  # update user
  msg_start "Updating user repository for $user"
  init_user_repo "$user" "$user_id" "$group_id" \
    && update_user_repo "$user" \
    || exit 1
  msg_end "$DONE"
done
