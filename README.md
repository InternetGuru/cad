
[![Build Status](https://travis-ci.org/InternetGuru/cad.svg?branch=master)](https://travis-ci.org/InternetGuru/cad)

# Coding Assignment Distribution | CAD

> The `update.sh` script distributes a GitLab assignment repository _detaching its history_ into individual repositories for each solver usernames. For future updates it creates a separate `source` branch and creates pull requests into main branch whenever updated. For each solver, the script sets developer rights in newly created repository if username exists.

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
