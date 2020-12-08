
[![Build Status](https://travis-ci.org/InternetGuru/cad.svg?branch=master)](https://travis-ci.org/InternetGuru/cad)

# Coding Assignment Distribution | CAD

> The `update.sh` script distributes a GitLab assignment repository _detaching its history_ into individual repositories for each solver usernames. For future updates it creates a separate `source` branch and creates pull requests into main branch whenever updated. For each solver, the script sets developer rights in newly created repository if username exists. This project also provides GitLab CI template (see below).

## Requirements

* Installed `jq`, see https://stedolan.github.io/jq/
* Installed `git` with defined user and email
* Existing (working) project with assignment branch or assignment project
* GitLab account
* List of students (GitLab account names)

## Installation

Simply clone this project into your computer and set alias.

  ```
  { ~ }  » git clone https://github.com/InternetGuru/cad.git
  { ~ }  » echo alias cad=\"\$HOME/cad/update.sh\" >> .bashrc
  { ~ }  » source .bashrc
  ```

For global installation create link in `/usr/local/share`.

```
{ ~ }  » ln -s "$HOME/cad/update.sh" /usrl/local/share/cad
```

## Example CLI Usage

Distribute a GitLab assignment project into two individual solver repositories.

    ```
    cad -n "/umiami/vjm/csc220/fall20/assn1" -u "user1 user2"
    ```

## GitLab CI Usage

1. Make sure you have your [personal access token](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html#creating-a-personal-access-token). On GitLab [set ACCESS_TOKEN variable](https://docs.gitlab.com/ee/ci/variables/#create-a-custom-variable-in-the-ui) into your root namespace.

   - E.g. into `umiami/george`

1. Navigate into the project and switch to the branch you want to distribute.

   - E.g. [umiami/george/csc220/matrix@fall20](https://gitlab.com/umiami/george/csc220/matrix/-/tree/fall20)

1. Add the following lines into your `.gitlab-ci.yml` file and insert users into `USERS` variable separated by space, e.g. `"student-1 student-2 student-3"`. You may want to select a different [CAD](https://github.com/InternetGuru/cad) revision. Do not modify `CAD_REVISION` variable unless you know what you're doing.

   ```
   include: 'https://raw.githubusercontent.com/InternetGuru/cad/master/gitlab-distribute.yml'

   variables:
     USERS: ""
     CAD_REVISION: "1"

   stages:
     - distribute
   ```

1. [Execute CI pipeline](https://docs.gitlab.com/ee/ci/pipelines/#run-a-pipeline-manually) on desired branch. Assignment projects will be created / updated in `project_namespace/project_branch/project_name`.

   - E.g. solver repositories in [umiami/george/csc220/fall20/matrix](https://gitlab.com/umiami/george/csc220/fall20/matrix)


## Known Bugs and Suggestions

- [x] BASH Linting (Shellcheck)
- [ ] Automatic Testing, including macOS (BUTT)
- [x] Add changelog and semantic versioning (git flow)
- [ ] Configurable destination projects visibility (private / public)
- [x] Standalone assignment support (with no base project or with no git at all)
- [ ] Support --quiet / default / --verbose
- [x] Set users as developers by parameter `-d,--developer=ALWAYS|AUTO|NEVER` (default `AUTO`)
- [ ] Dry run to verify parameters and print out destinations
- [ ] In distributed projects make the `source` branch protected
- [ ] Specify editable files
- [ ] Add GitHub support

[1]: https://docs.gitlab.com/ee/user/group/
[2]: https://about.gitlab.com/product/continuous-integration/
