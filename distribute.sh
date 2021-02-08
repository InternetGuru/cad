#!/bin/bash

# set -x
set -o pipefail

## functions
clear_stdin() {
  while read -r -t 0; do read -r; done
}
msg_start() {
  [[ "${MSG_OPENED}" == 'true' ]] \
    && exception 'Message already started'
  MSG_OPENED='true'
  printf -- '%s ... ' "$@" >&2
}
msg_end() {
  [[ "${MSG_OPENED}" == 'false' ]] \
    && exception 'Message not started'
  MSG_OPENED='false'
  printf -- '[ %s ]\n' "${1:-DONE}" >&2
}
confirm() {
  printf -- '%s [YES/No] ' "${1:-'Are you sure?'}" >&2
  clear_stdin
  read -r
  [[ "${REPLY}" =~ ^[Yy]([Ee][Ss])?$ || -z "${REPLY}" ]] \
    && return 0
  [[ "${REPLY}" =~ ^[Nn][Oo]?$ ]] \
    && return 1
  confirm 'Type'
}
prompt() {
  printf -- '%s: ' "${1:-Enter value}" >&2
  clear_stdin
  # silent user input (e.g. for password)
  if [[ "${2}" == 'silent' ]]; then
    read -rs
  else
    read -r
  fi
  [[ -n "${REPLY}" ]] \
    && return 0
  prompt "${1}"
}
exception() {
  printf -- '%s in %s() [ #%d ]\n' "${1:-${SCRIPT_NAME} unknown exception}" "${FUNCNAME[1]}" "${2:-1}" >&2
  exit "${2:-1}"
}
print_usage() {
  fmt -w "$(tput cols)" <<< "${USAGE}"
}
check_command() {
  for cmd in "${@}"; do
    command -v "${cmd}" >/dev/null 2>&1 \
      || exception "Command ${cmd} not found"
  done
}
git_repo_exists() {
  [[ -d "${1:-.}/.git" ]]
}
git_local_branch_exists() {
  git -C "${2:-.}" rev-parse --verify "${1}" >/dev/null 2>&1
}
git_current_branch() {
  declare out
  out="$(git -C "${1:-.}" rev-parse --abbrev-ref HEAD)" \
    || exception "${out}"
  printf -- '%s\n' "${out}"
}
git_same_commit() {
  [[ "$( git -C "${3:-.}" rev-parse "${1}" )" == "$( git -C "${3:-.}" rev-parse "${2}" )" ]]
}
git_init() {
  declare out
  out="$(git -C "${1:-.}" init 2>&1)" \
    || exception "${out}"
}
git_add_all() {
  declare out
  out="$(git -C "${1:-.}" add -A 2>&1)" \
    || exception "${out}"
}
git_checkout() {
  declare -r dir="${1}"
  shift
  declare out
  out="$(git -C "$dir" checkout "${@}" 2>&1)" \
    || exception "${out}"
}
git_status_empty() {
  [[ -z "$(git -C "${1:-.}" status --porcelain)" ]]
}
git_remote_exists() {
  [[ -n "$(git -C "${2:-.}" config remote."${1:-origin}".url 2>/dev/null)" ]]
}
git_pull() {
  declare -r dir="${1}"
  shift
  declare out
  out="$(git -C "${dir}" pull "${@}" 2>&1)" \
    || exception "${out}"
}
git_clone() {
  declare out
  out="$(git clone -q "${@}" 2>&1)" \
    || exception "${out}"
}
git_merge() {
  declare -r dir="${1}"
  shift
  declare out
  out="$(git -C "${dir}" merge "${@}" 2>&1)" \
    || exception "${out}"
}
git_push() {
  declare -r dir="${1}"
  shift
  declare out
  out="$(git -C "${dir}" push "${@}" 2>&1)" \
    || exception "${out}"
}
git_commit() {
  declare -r dir="${1}"
  shift
  declare out
  out="$(git -C "${dir}" commit "${@}" 2>&1)" \
    || exception "${out}"
}
git_fetch_all() {
  declare out
  out="$(git -C "${1:-.}" fetch --all 2>&1)" \
    || exception "${out}"
}
gitlab_api() {
  declare req='GET'
  [[ -n "${2}" ]] \
    && req='POST'
  # shellcheck disable=SC2155
  declare response="$(curl --silent --write-out '\n%{http_code}\n' \
    --header "Authorization: Bearer ${TOKEN}" \
    --header 'Content-Type: application/json' \
    --request ${req} --data "${2:-{\}}" "https://${GITLAB_URL}/${1}")"
  # shellcheck disable=SC2155
  declare status="$(sed -n '$p' <<< "${response}")"
  # shellcheck disable=SC2155
  declare output="$(sed '$d' <<< "${response}")"
  [[ "${status}" != 20* ]] \
    && printf -- '%s\n' "${output}" >&2 \
    && exception "Request status ${status}: ${1}"
  printf -- '%s\n' "${output}"
}
authorize() {
  [[ "$(tty)" =~ "not a tty" ]] \
    && exception "Unable to authorize without TOKEN_FILE"
  exec 0</dev/tty
  prompt 'Username'
  declare username="${REPLY}"
  prompt 'Password' silent
  declare password="${REPLY}"
  echo
  gitlab_api 'oauth/token' \
    "{\"grant_type\":\"password\", \"username\":\"${username}\", \"password\":\"${password}\"}" \
    | jq -r '.access_token' > "${TOKEN_FILE}"
}
get_project_id() {
  gitlab_api "api/v4/projects/${1//\//%2F}" | jq -r '.id'
}
get_default_branch() {
  gitlab_api "api/v4/projects/${1//\//%2F}" | jq -r '.default_branch'
}
project_exists() {
  get_project_id "${1}" >/dev/null 2>&1
}
get_group_id() {
  gitlab_api "api/v4/groups/${1//\//%2F}" | jq -r '.id'
}
request_exists() {
  gitlab_api "api/v4/projects/${1}/merge_requests?state=opened&source_branch=${SOURCE_BRANCH}" \
    | grep -qv "^\[\]$"
}
create_request() {
  gitlab_api "api/v4/projects/${1}/merge_requests" \
    "{\"id\":\"${1}\", \"source_branch\":\"${SOURCE_BRANCH}\", \"target_branch\":\"master\", \
    \"remove_source_branch\":\"false\", \"title\":\"Update from ${SOURCE_BRANCH} branch\"}" >/dev/null
}
create_project() {
  declare visibility='public'
  [[ -n "${3}" ]] \
    && visibility='private'
  gitlab_api 'api/v4/projects' \
    "{\"namespace_id\":\"${1}\", \"name\":\"${2}\", \"visibility\":\"${visibility}\"}" \
    | jq -r '.id'
}
get_role() {
  gitlab_api "api/v4/projects/${1}/members/all/${2}" | jq -r '.access_level'
}
add_developer() {
  [[ -z "${2}" ]] \
    && return
  # shellcheck disable=SC2155
  declare -ir role="$(get_role "${1}" "${2}" 2>/dev/null)"
  (( role >= 30 )) \
    && return
  gitlab_api "api/v4/projects/${1}/members" \
    "{\"access_level\":\"30\", \"user_id\":\"${2}\"}" >/dev/null
}
create_group() {
  gitlab_api 'api/v4/groups' \
    "{\"name\":\"${1}\", \"path\":\"${1}\", \"parent_id\":\"${2}\", \"visibility\":\"public\"}" \
    | jq -r '.id'
}
get_user_id() {
  gitlab_api "api/v4/users?username=${1}" \
    | jq -r '.[] | .id' | sed 's/null//'
}
create_ns() {
  # shellcheck disable=SC2155
  declare -r parent_ns="$(dirname "${1}")"
  [[ "${parent_ns}" == '.' ]] \
    && exception "Root group ${1} does not exist"
  declare parent_id
  parent_id="$(get_group_id "${parent_ns}" 2>/dev/null)" \
    || parent_id="$(create_ns "${parent_ns}")" \
    || exit 1
  create_group "$(basename "${1}")" "${parent_id}"
}
init_user_repo() {
  declare -r project_ns="${REMOTE_NS}/${1}"
  declare -r project_folder="${CACHE_FOLDER}/${project_ns}"
  if ! project_exists "${project_ns}"; then
    declare user_id=''
    [[ "${ASSIGN}" == "${NEVER}" ]] \
      || user_id="$(get_user_id "${1}")" \
      || exit 1
    [[ "${ASSIGN}" == "${ALWAYS}" && -z "${user_id}" ]] \
      && exception "User ${1} does not exist"
    [[ -n "${GROUP_ID}" ]] \
      || GROUP_ID="$(get_group_id "${REMOTE_NS}" 2>/dev/null)" \
      || GROUP_ID="$(create_ns "${REMOTE_NS}")" \
      || exit 1
    project_id="$(create_project "${GROUP_ID}" "${1}" "${user_id}")" \
      && add_developer "${project_id}" "${user_id}"
    [[ "${COPY_ISSUES}" == 'true' ]] \
      && copy_issues "${project_id}" "${user_id}"
    rm -rf "${project_folder}"
  fi
  if [[ -d "${project_folder}" ]]; then
    # verify local remote
    declare actual_remote_ns
    actual_remote_ns="$(get_remote_namespace "${project_folder}")" \
      || exit 1
    [[ "${actual_remote_ns}" != "${project_ns}" ]] \
      && exception 'Invalid user project remote origin url'
    git_pull "${project_folder}" 'origin' "${SOURCE_BRANCH}:${SOURCE_BRANCH}"
  else
    # clone existing remote
    declare -r remote_url="https://oauth2:${TOKEN}@${GITLAB_URL}/${project_ns}.git"
    git_clone "${remote_url}" "${project_folder}"
  fi
  # create first commit in case of empty repo (stay on main branch for update)
  if ! git -C "${project_folder}" log >/dev/null 2>&1; then
    git_commit "${project_folder}" '--allow-empty' '-m "initial commit"'
    git_push "${project_folder}" '--all'
    return
  fi
  # checkout SOURCE_BRANCH
  git_checkout "${project_folder}" "${SOURCE_BRANCH}"
}
update_links() {
  sed -i "s~/${PROJECT_NS}/~/${1}/~g" "${2}"
  sed -i "s~/${PROJECT_BRANCH}/\(pipeline\|raw\|file\)~/${3}/\1~g" "${2}"
  sed -i "s~ref=${PROJECT_BRANCH}~ref=${3}~g" "${2}"
}
update_user_repo() {
  declare -r user_ns="${REMOTE_NS}/${1}"
  declare -r user_dir="${CACHE_FOLDER}/${user_ns}"
  declare user_branch
  user_branch="$(get_default_branch "${user_ns}")" \
    || exit 1
  # update from assignment
  rsync -a --delete --exclude .git/ "${PROJECT_FOLDER}/" "${user_dir}"
  # replace remote in readme file
  [[ "${UPDATE_LINKS}" == 'true' ]] \
    && update_links "${user_ns}" "${user_dir}/${README_FILE}" "${user_branch}"
  git_status_empty "${user_dir}" \
    && return
  # commit
  git_add_all "${user_dir}"
  git_commit "${user_dir}" '-m "Update assignment"'
  # if first commit create SOURCE_BRANCH on main branch and push both
  git_checkout "${user_dir}" "-B${SOURCE_BRANCH}"
  git_push "${user_dir}" '--all'
  # create PR iff new commit
  git_same_commit "${user_branch}" "${SOURCE_BRANCH}" "${user_dir}" \
    && return
  declare project_id
  project_id="$(get_project_id "${user_ns}")" \
    || exit 1
  request_exists "${project_id}" \
    || create_request "${project_id}"
}
get_remote_namespace() {
  git -C "${1}" config --get remote.origin.url | sed "s/^.*${GITLAB_URL}[:/]//;s/.git$//"
}
read_issues() {
  ISSUES="$(gitlab_api "api/v4/projects/${PROJECT_ID}/issues?labels=assignment")" \
    && ISSUES_COUNT="$(jq length <<< "${ISSUES}")" \
    || exit 1
}
copy_issues() {
  (( ISSUES_COUNT < 0 )) \
    && read_issues
  declare i issue
  for (( i=0; i < ISSUES_COUNT; i++ )); do
    issue="$(jq ".[${i}] | {title, description, due_date}" <<< "${ISSUES}")"
    [[ -n "${2}" ]] \
      && issue="$(jq --arg a "${2}" '. + {assignee_ids:[$a]}' <<< "${issue}")"
    gitlab_api "api/v4/projects/${1}/issues" "${issue}" >/dev/null
  done
}
validate_arguments() {
  msg_start 'Validating arguments'
  [[ -n "${REMOTE_NS}" ]] \
    || exception 'Missing argument REMOTE_NAMESPACE' 2
  [[ "${REMOTE_NS}" =~ ^[a-z0-9]{2,}(/[a-z0-9]{2,})*$ ]] \
    || exception 'Invalid argument REMOTE_NAMESPACE' 2
  [[ -d "${PROJECT_FOLDER}" ]] \
    || exception 'Project folder not found'
  [[ "${ASSIGN}" =~ ^(${ALWAYS}|${NEVER}|${AUTO})$ ]] \
    || exception 'Invalid option ASSIGN'
  [[ "${COPY_ISSUES}" == 'false' || -d "${PROJECT_FOLDER}/.git" ]] \
    || exception 'To copy issues, project must be a git repository'
  [[ "${UPDATE_LINKS}" == 'false' || -d "${PROJECT_FOLDER}/.git" ]] \
    || exception 'To update links, project must be a git repository'
  [[ "${UPDATE_LINKS}" == 'false' || -f "${PROJECT_FOLDER}/${README_FILE}" ]] \
    || exception 'Readme file not found'
  [[ ! -t 0 ]] \
    || exception 'Missing stdin' 2
  msg_end
}
read_project_info() {
  msg_start 'Getting project information'
  [[ "${COPY_ISSUES}" == 'false' && "${UPDATE_LINKS}" == 'false' ]] \
    && msg_end SKIPPED \
    && return
  PROJECT_NS="$(get_remote_namespace "${PROJECT_FOLDER}")" \
    && PROJECT_ID="$(get_project_id "${PROJECT_NS}")" \
    && PROJECT_BRANCH="$(git_current_branch "${PROJECT_FOLDER}")" \
    || exit 1
  msg_end
}
acquire_token() {
  [[ -s "${TOKEN_FILE}" ]] \
    || authorize
  TOKEN="$(cat "${TOKEN_FILE}")" \
    || exit 1
}
process_users() {
  declare username
  declare -i valid=0
  declare -i invalid=0
  # shellcheck disable=SC2013
  for username in $(cat <&3); do
    msg_start "Processing repository for ${username}"
    [[ ! "${username}" =~ ^[a-zA-Z0-9][a-z0-9_.-]*$ ]] \
      && msg_end INVALID \
      && invalid+=1 \
      && continue
    valid+=1
    [[ "${DRY_RUN}" == 'true' ]] \
      && msg_end SKIPPED \
      && continue
    init_user_repo "${username}" \
      && update_user_repo "${username}"
    msg_end
  done
  (( valid != 0 || invalid != 0 )) \
    || exception 'Empty or invalid stdin' 2
  (( invalid == 0 )) \
    || exception "Invalid username occurred ${invalid} time(s)" 3
}

# global constants
# shellcheck disable=SC2155
declare -r SCRIPT_NAME="$(basename "${0}")"
declare -r TOKEN_FILE="${HOME}/.gitlab_access_token"
declare -r CACHE_FOLDER="${HOME}/.cad_cache"
declare -r README_FILE='README.md'
declare -r GITLAB_URL='gitlab.com'
declare -r SOURCE_BRANCH='source'
declare -r ALWAYS='always'
declare -r NEVER='never'
declare -r AUTO='auto'

# default variables
declare DIRECTORY='.'
declare DRY_RUN='false'
declare COPY_ISSUES='false'
declare UPDATE_LINKS='false'
declare MSG_OPENED='false'
declare ASSIGN="${AUTO}"
declare GROUP_ID=''
declare PROJECT_NS=''
declare PROJECT_ID=''
declare PROJECT_BRANCH=''
declare ISSUES=''
declare -i ISSUES_COUNT=-1

# USAGE
declare -r USAGE="DESCRIPTION
      This script reads USERNAMES from stdin using IFS. For each USERNAME it distributes files from PROJECT_FOLDER into REMOTE_NAMESPACE/USERNAME. Root namespace in REMOTE_NAMESPACE must exist, meaning e.g. 'umiami' in 'umiami/csc220/fall20'.

USAGE
      ${SCRIPT_NAME} [-adhiln] REMOTE_NAMESPACE

OPTIONS
      -a[WHEN], --assign[=WHEN]
              Assign ROLE (see below) to users for newly created projects and assign users to issues '${ALWAYS}', '${NEVER}', or '${AUTO}' (default).

      -d, --directory
              Specify the PROJECT_FOLDER (default PWD).

      -h, --help
              Display usage.

      -i, --process-issues
              Look for GitLab issues in the PROJECT_FOLDER. If PROJECT_FOLDER is a GitLab repository, copy issues marked with 'assignment' label into destination repositories.

      -l, --update-links
              Look for a ${README_FILE} if the PROJECT_FOLDER is a GitLab repository. Replace all occurrences of the assignment project's remote URL and its current branch with destination repository remote URL and its main branch.

      -n, --dry-run
              Only process arguments, options and stdin validation. Would not proceed with create or update user repositories.

EXIT CODES
       1      Other error.

       2      Invalid options or arguments including empty or missing stdin.

       3      Some (or all) invalid users.
"

# get options
declare OPT
OPT="$(getopt --name "${0}" --options 'a:d:hiln' \
  --longoptions 'assign:,directory:,help,process-issues,update-links,dry-run' \
  -- "$@")" \
  && eval set -- "${OPT}" \
  || exit 1

# process options
while (( $# > 0 )); do
  case "${1}" in
    -a|--assign) shift; ASSIGN="${1}"; shift ;;
    -d|--directory) shift; DIRECTORY="${1}"; shift ;;
    -h|--help) print_usage && exit 0 ;;
    -i|--process-issues) COPY_ISSUES='true'; shift ;;
    -l|--update-links) UPDATE_LINKS='true'; shift ;;
    -n|--dry-run) DRY_RUN='true'; shift ;;
    --) shift; break ;;
     *) break ;;
  esac
done

# validate and authorize
declare -r REMOTE_NS="${1}"
# shellcheck disable=SC2155
declare -r PROJECT_FOLDER="$(readlink -f "${DIRECTORY}")"

validate_arguments
# redir stdin
exec 3<&0
check_command git jq
acquire_token
read_project_info
process_users
