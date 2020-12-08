#!/bin/bash

# set -x

## functions
clear_stdin() {
  while read -r -t 0; do read -r; done
}
msg_start() {
  echo -n "$1 ... "
}
msg_end() {
  echo "[ $1 ]"
}
confirm() {
  #while read -r -t 0; do read -r; done
  echo -n "${1:-"Are you sure?"} [YES/No] "
  #save_cursor_position
  clear_stdin
  read -r
  #[[ -z "$REPLY" ]] && set_cursor_position && echo "yes"
  [[ "$REPLY" =~ ^y(es)?$ || -z "$REPLY" ]] && return 0
  [[ "$REPLY" =~ ^no?$ ]] && return 1
  confirm "Type"
}
prompt() {
  echo -n "${1:-Enter value}: "
  clear_stdin
  # do not echo output (e.g. for password)
  if [[ ${2:-} == silent ]]; then
    read -rs
  else
    read -r
  fi
  [[ -n "$REPLY" ]] && return 0
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
# colorize() {
#   local BWhite NC
#   BWhite='\e[1;37m'
#   NC="\e[m"
#   sed "s/--\?[a-zA-Z]\+\|$SCRIPT_NAME\|^[A-Z].\+/\\$BWhite\0\\$NC/g"
# }
error() {
  GLOBAL_MESSAGE="${1:-"$SCRIPT_NAME Error"}"
  echo "$GLOBAL_MESSAGE" >&2
}
exception() {
  error "EXCEPTION: ${1:-$SCRIPT_NAME Unknown exception}"
  exit "${2:-1}"
}
format_usage() {
  # echo -e "$1" | fmt -w "$(tput cols)" | colorize
  echo -e "$1" | fmt -w "$(tput cols)"
}
check_command() {
  command -v "${1:-}" >/dev/null 2>&1
}
git_repo_exists() {
  [[ -d "${1:-.}/.git" ]]
}
git_local_branch_exists() {
  git -C "${2:-.}" rev-parse --verify "$1" >/dev/null 2>&1
}
git_current_branch() {
  git -C "${1:-.}" rev-parse --abbrev-ref HEAD
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
  out="$(git -C "${1:-.}" pull ${2:-} 2>&1)" \
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
  out="$(git -C "${2:-.}" commit ${3:-} -m "$1" 2>&1)" \
    || exception "$out"
}
git_fetch_all() {
  local out
  out="$(git -C "${1:-.}" fetch --all 2>&1)" \
    || exception "$out"
}
authorize() {
  [[ -f "$ACCESS_TOKEN_FILE" ]] \
    && return
  prompt "Username"
  username="$REPLY"
  prompt "Password" silent
  password="$REPLY"
  echo
  response="$(curl \
    --silent \
    --data "grant_type=password&username=$username&password=$password" \
    --request POST "$GITLAB_URL/oauth/token")"
  error="$(echo "$response" | jq -r '.error')"
  [[ "$error" != "null" ]] \
    && exception "$error: $(echo "$response" | jq -r '.error_description')"
  echo "$response" | jq -r '.access_token' > "$ACCESS_TOKEN_FILE"
}
get_project_id() {
  response="$(curl -s --header "Authorization: Bearer $TOKEN" "$GITLAB_URL/api/v4/projects?search=$(basename "${1:-}")")"
  project_id="$(echo "$response" | jq -r --arg ns "${1:-}" '.[] | select(.path_with_namespace==$ns) | .id')"
  [[ -n "$project_id" ]] \
    || exception "Project '${1:-}' not found"
  echo "$project_id"
}
get_group_id() {
  response="$(curl -s --header "Authorization: Bearer $TOKEN" "$GITLAB_URL/api/v4/groups?search=$1")"
  group_id="$(echo "$response" | jq -r --arg group_name "${1:-}" '.[] | select(.full_path==$group_name) | .id')"
  [[ -z "$group_id" ]] \
    && exception "${1:-} group does not exist" 2
  echo "$group_id"
}
get_origin_url() {
  response="$(curl -s --header "Authorization: Bearer $TOKEN" "$GITLAB_URL/api/v4/projects?search=${2:-}")"
  repo_url="$(echo "$response" | jq -r --argjson group_name "${1:-}" --arg project_name "${2:-}" '.[] | select(.namespace.id==$group_name and .name==$project_name) | .ssh_url_to_repo')"
  if [[ -z "$repo_url" ]]; then
    repo_url="$(create_project "$1" "$2" "$3")" \
      || exit $?
  fi
  echo "https://oauth2:$TOKEN@gitlab.com/${repo_url#*:}"
}
create_pr() {
  project_id="$(get_project_id "${1:-}")"
  response="$(curl -s --header "Authorization: Bearer $TOKEN" \
    -X POST "$GITLAB_URL/api/v4/projects/$project_id/merge_requests" -H "Content-Type: application/json" \
    -d "{\"id\":\"$project_id\", \"source_branch\":\"$PROJECT_BRANCH\", \"target_branch\":\"master\", \
    \"remove_source_branch\": \"false\", \"title\": \"Update from $PROJECT_BRANCH branch\"}")"
  error="$(echo "$response" | jq -r '.error')"
  [[ "$error" == "null" ]] \
    || exception "$error: $(echo "$response" | jq -r '.error_description')"
}
create_project() {
  local repo_url
  response="$(curl -s --header "Authorization: Bearer $TOKEN" \
    -X POST "$GITLAB_URL/api/v4/projects" -H "Content-Type: application/json" -d "{\"namespace_id\":\"${1:-}\", \"name\":\"${2:-}\", \"visibility\":\"private\"}")"
  repo_url="$(echo "$response" | jq -r '.ssh_url_to_repo')"
  project_id="$(echo "$response" | jq -r '.id')"
  [[ "$repo_url" == "null" ]] \
    && exception "$(echo "$response" | jq -r '.message.name')"
  [[ -z "${3:-}" ]] \
    || add_developer "$project_id" "$3" \
    || exit $?
  echo "$repo_url"
}
add_developer() {
  response="$(curl -s --header "Authorization: Bearer $TOKEN" \
    -X POST "$GITLAB_URL/api/v4/projects/${1:-}/members" -H "Content-Type: application/json" -d "{\"access_level\":\"30\", \"user_id\":\"${2:-}\"}")"
  error="$(echo "$response" | jq -r '.error')"
  [[ "$error" == "null" ]] \
    || exception "$error: $(echo "$response" | jq -r '.error_description')"
}
create_group() {
  response="$(curl -s --header "Authorization: Bearer $TOKEN" \
    -X POST "$GITLAB_URL/api/v4/groups?name=${1:-}&path=${1:-}&parent_id=${2:-}")"
  group_id="$(echo "$response" | jq -r '.id')"
  [[ -n "$group_id" && "$group_id" != "null" ]] \
    || exception "Unable to create group ${1:-}"
  echo "$group_id"
}
get_user_id() {
  response="$(curl -s --header "Authorization: Bearer $TOKEN" \
    -X GET "$GITLAB_URL/api/v4/users?username=${1:-}")"
  id="$(echo "$response" | jq -r '.[] | .id')"
  [[ -n "$id" && "$id" != "null" ]] \
    || exception "User ${1:-} is not a registered gitlab user"
  echo "$id"
}
create_groups() {
  # check or create subgroups
  group_id=
  full_path=
  for group in $(echo "${1:-}" | tr '/' ' '); do
    # root group must exist
    if [[ -z "$group_id" ]]; then
      full_path="$group"
      group_id="$(get_group_id "$full_path")" \
        || exit $?
      continue
    fi
    full_path="$full_path/$group"
    tmp_group_id="$(get_group_id "$full_path" 2>/dev/null)" \
      || tmp_group_id="$(create_group "$group" "$group_id")" \
      || exit $?
    group_id="$tmp_group_id"
  done
  echo "$group_id"
}
init_user_repo() {
  user="${1:-}"
  user_id="${2:-}"
  user_project_ns="${3:-}"
  group_id="${4:-}"
  user_project_folder="$USER_CACHE_FOLDER/$user_project_ns"
  # get (or create) remote
  remote_url="$(get_origin_url "$group_id" "$user" "$user_id")"
  if [[ -d "$user_project_folder" ]]; then
    # verify local remote
    actual_remote_url="$(git -C "$user_project_folder" config remote.origin.url)"
    [[ "$actual_remote_url" =~ $user_project_ns ]] \
      || exception "Invalid user project remote origin url"
    git_pull "$user_project_folder" "origin $PROJECT_BRANCH:$PROJECT_BRANCH" \
      || exit $?
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
  # checkout PROJECT_BRANCH
  git_checkout "$PROJECT_BRANCH" "$user_project_folder" \
    || exception "Missing $PROJECT_BRANCH"
}
update_user_repo() {
  project_folder="${1:-}"
  user_project_ns="${2:-}"
  assignment_branch="${3:-}"
  user_project_folder="$USER_CACHE_FOLDER/$user_project_ns"
  # update from assignment
  rsync -a --delete --exclude .git/ "$project_folder/" "$user_project_folder"
  # replace remote in README.md
  main_branch="$(git -C "$user_project_folder" remote show origin | grep "HEAD branch:" | tr -d " " | cut -d: -f2)"
  if [[ $REPLACE_README_REMOTE == 1 ]]; then
    project_remote="$(git -C "$project_folder" config remote.origin.url)"
    project_ns="${project_remote#*:}"
    project_ns="${project_ns%.git}"
    sed -i "s~$project_ns~$user_project_ns~g" "$user_project_folder/README.md"
    sed -i "s~/$assignment_branch/\(pipeline\|raw\|file\)~/$main_branch/\1~g" "$user_project_folder/README.md"
  fi
  git_status_empty "$user_project_folder" \
    && return
  # commit
  git_add_all "$user_project_folder"
  git_commit "Update assignment" "$user_project_folder"
  # if first commit create PROJECT_BRANCH on main branch and push both
  git_checkout "-B $PROJECT_BRANCH" "$user_project_folder"
  git_push "--all" "$user_project_folder"
  # create PR iff new commit
  git_same_commit "$main_branch" "$PROJECT_BRANCH" "$user_project_folder" \
    && return
  create_pr "${user_project_ns#/}" "$main_branch" "$PROJECT_BRANCH"
}

## default options
SCRIPT_NAME="$(basename "$0")"
REMOTE_NAMESPACE=""
PROJECT_FOLDER="." # current folder
ASSIGNMENT_BRANCH="" # current branch
GITLAB_USERNAMES=""
REPLACE_README_REMOTE=0
DEV_MODE="auto"

## usage
USAGE="$(format_usage "DESCRIPTION
      $SCRIPT_NAME creates or updates one or more repositories from PROJECT_FOLDER and ASSIGNMENT_BRANCH. For each USER from GITLAB_USERNAMES remote repository path is REMOTE_NAMESPACE/USER.

      It uses temp folder in ~/.ga-cache for repositories. Supports GitLab API and uses access token at ~/.gitlab_access_token to authorize. Prompts credentials if access token not found.

      All created repositories are owned by the authenticated user and their visibility is private. Each repository has appropriate user assigned with developer rights.

USAGE
      $SCRIPT_NAME -n REMOTE_NAMESPACE -u GITLAB_USERNAMES [-rh] [-f PROJECT_FOLDER] [-b ASSIGNMENT_BRANCH]

OPTIONS
      -b, --branch=ASSIGNMENT_BRANCH
              Branch name with the assignment. Default current branch.

      -d[MODE], --developer[=MODE]
              Set developer rights to newly created projects 'always', 'never', or 'auto' (default).

      -f, --folder=PROJECT_FOLDER
              Path to project with the assignment, default current directory.

      -h, --help
              Display usage.

      -n, --namespace=REMOTE_NAMESPACE
              GitLab root namespace, where root must exist, e.g. /umiami/victor/csc220/asn1

      -r, --replace
              Replace any occurrence of assignment project remote URL with user project remote URL in README.md file.

      -u, --usernames=GITLAB_USERNAMES
              List of one or more GitLab usernames separated by space or newline, where each user must exist.
")"

## option preprocessing
if ! LINE=$(
  getopt -n "$0" \
        -o b:d::f:hn:ru: \
        -l branch:,developer::,folder:,help,namespace:,replace,usernames: \
        -- "$@"
)
then
  exit 1
fi
eval set -- "$LINE"

## load user options
while [ $# -gt 0 ]; do
  case $1 in
    -b|--branch) shift; ASSIGNMENT_BRANCH="$1"; shift ;;
    -d|--developer) shift; set_dev_mode "$1" || exit $?; shift ;;
    -f|--folder) shift; PROJECT_FOLDER="$1"; shift ;;
    -h|--help) echo -e "$USAGE" && exit 0 ;;
    -n|--namespace) shift; REMOTE_NAMESPACE="$1"; shift ;;
    -r|--replace) REPLACE_README_REMOTE=1; shift ;;
    -u|--usernames) shift; GITLAB_USERNAMES="$1"; shift ;;
    --) shift; break ;;
    *-) echo "$0: Unrecognized option '$1'" >&2; exit 2 ;;
     *) break ;;
  esac
done

## globals
GITLAB_URL="https://gitlab.com"
ACCESS_TOKEN_FILE="$HOME/.gitlab_access_token"
USER_CACHE_FOLDER="$HOME/.ga-cache"
DONE=" done "
PROJECT_BRANCH="source"

# parameter validation
[[ ! "$REMOTE_NAMESPACE" =~ ^(/[a-z][a-z0-9]{2,}){3,}$ ]] \
  && error "Missing or invalid REMOTE_NAMESPACE option, value '$REMOTE_NAMESPACE'" \
  && exit 2
usernames=0
for user in $GITLAB_USERNAMES; do
  [[ ! "$user" =~ ^[a-z][a-z0-9_-]{4,}$ ]] \
    && error "Invalid user format, value '$user'" \
    && exit 2
  : $((usernames++))
done
[[ $usernames == 0 ]] \
  && error "Missing or empty GITLAB_USERNAMES option" \
  && exit 2

PROJECT_FOLDER="$(readlink -f "$PROJECT_FOLDER")"

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
if [[ -n "$ASSIGNMENT_BRANCH" ]]; then
  git_checkout "$ASSIGNMENT_BRANCH" "$PROJECT_FOLDER" \
    || exception "Branch $ASSIGNMENT_BRANCH does not exist in $PROJECT_FOLDER"
fi
msg_end "$DONE"
if [[ $REPLACE_README_REMOTE == 1 ]]; then
  msg_start "Checking replace readme remote (param -r)"
  git_remote_exists "origin" "$PROJECT_FOLDER" \
    || exception "Project folder missing remote url"
  [[ -f "$PROJECT_FOLDER/README.md" ]] \
    || exception "Project folder missing README.md"
  msg_end "$DONE"
fi

authorize \
  || exception "Unable to authorize"
TOKEN="$(cat "$ACCESS_TOKEN_FILE")"

# process users
msg_start "Creating / checking remote path $REMOTE_NAMESPACE"
group_id="$(create_groups "$REMOTE_NAMESPACE")" \
  || exit $?
msg_end "$DONE"
for user in $GITLAB_USERNAMES; do
  # check user
  user_id=""
  [[ $DEV_MODE == "none" ]] \
    || user_id="$(get_user_id "$user")"
  [[ $DEV_MODE == "always" && -z "$user_id" ]] \
    && continue
  # set user project ns and update user
  user_project_ns="$REMOTE_NAMESPACE/$user"
  msg_start "Updating user repository for $user"
  init_user_repo "$user" "$user_id" "$user_project_ns" "$group_id" \
    && update_user_repo "$PROJECT_FOLDER" "$user_project_ns" "$ASSIGNMENT_BRANCH" \
    || exit $?
  msg_end "$DONE"
done
