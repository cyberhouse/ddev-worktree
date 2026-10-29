#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# (https://bats-core.readthedocs.io/en/stable/installation.html) and Worktrunk for the wt tests
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=cyberhouse/ddev-worktree

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  export CI=true
  # Never touch the real Worktrunk user config
  export WORKTRUNK_CONFIG_PATH="${TESTDIR}/worktrunk/config.toml"
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  export ORIGINAL_PATH="${PATH}"
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true

  # Main checkout in TESTDIR/main, worktrees next to it
  mkdir "${TESTDIR}/main"
  cd "${TESTDIR}/main"
  git init -q -b main
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
}

teardown() {
  set -eu -o pipefail
  export PATH="${ORIGINAL_PATH}"
  for name in "${PROJNAME}" "${PROJNAME}-e2e-1"; do
    ddev delete -Oy "${name}" >/dev/null 2>&1 || true
  done
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${TESTDIR}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

# Installs the add-on and commits the project, so worktrees get .ddev/config.yaml
install_addon() {
  run ddev add-on get "$1"
  assert_success
  git add -A
  git commit -qm init
}

# ddev that only logs its arguments to DDEV_LOG, for the hooks that call ddev
fake_ddev() {
  mkdir -p "${TESTDIR}/bin"
  printf '#!/bin/sh\necho "$*" >> "$DDEV_LOG"\n' > "${TESTDIR}/bin/ddev"
  chmod +x "${TESTDIR}/bin/ddev"
  export DDEV_LOG="${TESTDIR}/ddev.log"
  touch "${DDEV_LOG}"
  export PATH="${TESTDIR}/bin:${PATH}"
}

health_checks() {
  assert_file_exists .ddev/worktree/pre-start
  assert_file_exists .ddev/worktree/post-start
  assert_file_exists .ddev/worktree/pre-remove
  run grep -c '^# >>> ddev-worktree >>>$' "${WORKTRUNK_CONFIG_PATH}"
  assert_output 1
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  install_addon "${DIR}"
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  install_addon "${GITHUB_REPO}"
  health_checks
}

@test "install-worktrunk keeps the user's config and is idempotent" {
  set -eu -o pipefail
  mkdir -p "$(dirname "${WORKTRUNK_CONFIG_PATH}")"
  printf 'worktree-path = "x"\n\n[commit.generation]\ncommand = "a\\\\b"\n' > "${WORKTRUNK_CONFIG_PATH}"
  cp "${WORKTRUNK_CONFIG_PATH}" "${TESTDIR}/original.toml"
  install_addon "${DIR}"
  cp "${WORKTRUNK_CONFIG_PATH}" "${TESTDIR}/first.toml"

  run sh .ddev/worktree/install-worktrunk
  assert_success
  assert_output ''
  assert_files_equal "${WORKTRUNK_CONFIG_PATH}" "${TESTDIR}/first.toml"
  assert_files_equal "${WORKTRUNK_CONFIG_PATH}.bak" "${TESTDIR}/original.toml"

  # Top-level key stays above the block, the user's table below it, backslashes unchanged
  run grep -n -e '^worktree-path' -e '^# >>> ddev-worktree' -e '^\[commit.generation\]' -e '^command' "${WORKTRUNK_CONFIG_PATH}"
  assert_line --index 0 --partial 'worktree-path'
  assert_line --index 1 --partial '# >>> ddev-worktree'
  assert_line --index 2 --partial '[commit.generation]'
  assert_line --index 3 --partial 'command = "a\\b"'
}

@test "install-worktrunk refuses a [pre-start] table" {
  set -eu -o pipefail
  mkdir -p "$(dirname "${WORKTRUNK_CONFIG_PATH}")"
  printf '[pre-start]\nx = "y"\n' > "${WORKTRUNK_CONFIG_PATH}"
  install_addon "${DIR}"

  run sh .ddev/worktree/install-worktrunk
  assert_success
  assert_output --partial 'Worktrunk hooks not installed'
  run grep -c 'ddev-worktree' "${WORKTRUNK_CONFIG_PATH}"
  assert_output 0
}

@test "install-worktrunk allows pre-start keys in [projects]" {
  set -eu -o pipefail
  mkdir -p "$(dirname "${WORKTRUNK_CONFIG_PATH}")"
  printf '[projects."github.com/org/repo"]\npre-start.env = "cp .env.example .env"\n' > "${WORKTRUNK_CONFIG_PATH}"
  install_addon "${DIR}"
  health_checks
}

@test "install-worktrunk leaves a block without end marker alone" {
  set -eu -o pipefail
  mkdir -p "$(dirname "${WORKTRUNK_CONFIG_PATH}")"
  printf '# >>> ddev-worktree >>>\n[[pre-start]]\nx = "y"\n\n[commit.generation]\ncommand = "z"\n' > "${WORKTRUNK_CONFIG_PATH}"
  cp "${WORKTRUNK_CONFIG_PATH}" "${TESTDIR}/original.toml"
  install_addon "${DIR}"

  run sh .ddev/worktree/install-worktrunk
  assert_success
  assert_output --partial 'Worktrunk hooks not changed'
  assert_files_equal "${WORKTRUNK_CONFIG_PATH}" "${TESTDIR}/original.toml"
}

@test "install-worktrunk writes through a symlinked config" {
  set -eu -o pipefail
  mkdir -p "$(dirname "${WORKTRUNK_CONFIG_PATH}")" "${TESTDIR}/dotfiles"
  printf '[commit.generation]\ncommand = "z"\n' > "${TESTDIR}/dotfiles/config.toml"
  ln -s "${TESTDIR}/dotfiles/config.toml" "${WORKTRUNK_CONFIG_PATH}"
  install_addon "${DIR}"

  assert_link_exists "${WORKTRUNK_CONFIG_PATH}"
  run grep -c '^# >>> ddev-worktree >>>$' "${TESTDIR}/dotfiles/config.toml"
  assert_output 1
}

@test "remove deletes the block from the Worktrunk config" {
  set -eu -o pipefail
  mkdir -p "$(dirname "${WORKTRUNK_CONFIG_PATH}")"
  printf 'worktree-path = "x"\n\n[commit.generation]\ncommand = "z"\n' > "${WORKTRUNK_CONFIG_PATH}"
  install_addon "${DIR}"

  run ddev add-on remove worktree
  assert_success
  assert_file_not_exists .ddev/worktree/pre-start
  assert_files_equal "${WORKTRUNK_CONFIG_PATH}" "${WORKTRUNK_CONFIG_PATH}.bak"
}

@test "pre-start fails without name: in .ddev/config.yaml" {
  set -eu -o pipefail
  install_addon "${DIR}"
  sed -i.orig '/^name:/d' .ddev/config.yaml
  rm .ddev/config.yaml.orig
  git commit -qam 'no name'
  git worktree add -q ../a -b feature/PROJ-5-x

  cd ../a
  run sh "${TESTDIR}/main/.ddev/worktree/pre-start"
  assert_failure
  assert_output --partial 'has no name:'
  assert_file_not_exists .ddev/config.local.yaml
}

@test "pre-start names worktrees after the ticket, else the branch" {
  set -eu -o pipefail
  install_addon "${DIR}"

  # main checkout: nothing to do
  run sh .ddev/worktree/pre-start
  assert_success
  assert_file_not_exists .ddev/config.local.yaml

  git worktree add -q ../a -b feature/PROJ-5-x
  git worktree add -q ../b -b bugfix/PROJ-5-y
  git worktree add -q ../c -b no_ticket
  for wt in a b c; do
    (cd "../${wt}" && sh "${TESTDIR}/main/.ddev/worktree/pre-start")
  done
  run grep '^name:' ../a/.ddev/config.local.yaml
  assert_output "name: ${PROJNAME}-proj-5"
  # same ticket as a: the whole branch
  run grep '^name:' ../b/.ddev/config.local.yaml
  assert_output "name: ${PROJNAME}-bugfix-proj-5-y"
  run grep '^name:' ../c/.ddev/config.local.yaml
  assert_output "name: ${PROJNAME}-no-ticket"

  # untracked, so wt remove doesn't see a dirty worktree
  run git -C ../a status --porcelain
  assert_output ''

  # detached HEAD: the directory name
  git worktree add -q --detach ../d
  (cd ../d && sh "${TESTDIR}/main/.ddev/worktree/pre-start")
  run grep '^name:' ../d/.ddev/config.local.yaml
  assert_output "name: ${PROJNAME}-d"

  # max 63 chars, without a trailing - where the cut lands
  long="$(printf 'a%.0s' $(seq 1 $((62 - ${#PROJNAME} - 1))))"
  git worktree add -q ../e -b "${long}-tail"
  (cd ../e && sh "${TESTDIR}/main/.ddev/worktree/pre-start")
  run grep '^name:' ../e/.ddev/config.local.yaml
  assert_output "name: ${PROJNAME}-${long}"
}

@test "pre-start never renames a worktree and fails when both names are taken" {
  set -eu -o pipefail
  install_addon "${DIR}"
  git worktree add -q ../a -b feature/PROJ-5-x
  (cd ../a && sh "${TESTDIR}/main/.ddev/worktree/pre-start")

  # second run: the name stays, its database belongs to it
  echo '# changed' >> ../a/.ddev/config.local.yaml
  cp ../a/.ddev/config.local.yaml "${TESTDIR}/a.yaml"
  (cd ../a && sh "${TESTDIR}/main/.ddev/worktree/pre-start")
  assert_files_equal ../a/.ddev/config.local.yaml "${TESTDIR}/a.yaml"

  # ticket name and branch name are both proj-5
  git worktree add -q ../b -b PROJ-5
  cd ../b
  run sh "${TESTDIR}/main/.ddev/worktree/pre-start"
  assert_failure
  assert_output --partial "${PROJNAME}-proj-5 is taken"
  assert_file_not_exists .ddev/config.local.yaml
}

@test "post-start and pre-remove only act on a name from pre-start" {
  set -eu -o pipefail
  install_addon "${DIR}"
  fake_ddev
  hooks="${TESTDIR}/main/.ddev/worktree"

  # main checkout: ddev delete would wipe the main project's database
  echo '# personal settings of the main checkout' > .ddev/config.local.yaml
  sh "${hooks}/post-start"
  sh "${hooks}/pre-remove"
  # worktree without pre-start
  git worktree add -q ../a -b feature/PROJ-5-x
  (cd ../a && sh "${hooks}/post-start" && sh "${hooks}/pre-remove")
  run cat "${DDEV_LOG}"
  assert_output ''

  git worktree add -q ../b -b feature/PROJ-6-x
  (cd ../b && sh "${hooks}/pre-start" && sh "${hooks}/post-start" && sh "${hooks}/pre-remove")
  run cat "${DDEV_LOG}"
  assert_line --index 0 start
  assert_line --index 1 'delete -Oy'
}

@test "wt switch -c starts a DDEV project, wt remove deletes it" {
  set -eu -o pipefail
  if ! command -v wt >/dev/null; then
    [ -z "${GITHUB_ACTIONS:-}" ] || fail "wt is not installed"
    skip "wt is not installed"
  fi
  # a copied config.local.yaml of the main checkout must not replace the worktree's name
  echo '/.ddev/config.local.yaml' > .worktreeinclude
  install_addon "${DIR}"
  echo '# personal settings of the main checkout' > .ddev/config.local.yaml
  name="${PROJNAME}-e2e-1"

  run wt switch -c feature/E2E-1-x --yes --no-cd
  assert_success
  run grep '^name:' ../main.feature-E2E-1-x/.ddev/config.local.yaml
  assert_output "name: ${name}"

  # post-start runs ddev start in the background
  for _ in $(seq 1 60); do
    [ "$(ddev describe -j "${name}" 2>/dev/null | jq -r .raw.status)" = running ] && break
    sleep 5
  done
  run bash -c "ddev describe -j '${name}' | jq -r .raw.status"
  assert_output running

  run wt remove feature/E2E-1-x --yes --foreground
  assert_success
  run ddev describe "${name}"
  assert_failure
}

@test "wt hooks do nothing in a repository without the add-on" {
  set -eu -o pipefail
  if ! command -v wt >/dev/null; then
    [ -z "${GITHUB_ACTIONS:-}" ] || fail "wt is not installed"
    skip "wt is not installed"
  fi
  sh "${DIR}/worktree/install-worktrunk"
  fake_ddev
  git add -A
  git commit -qm init

  run wt switch -c feature/OTHER-1-x --yes --no-cd
  assert_success
  assert_dir_exists ../main.feature-OTHER-1-x
  assert_file_not_exists ../main.feature-OTHER-1-x/.ddev/config.local.yaml
  run wt remove feature/OTHER-1-x --yes --foreground
  assert_success
  run cat "${DDEV_LOG}"
  assert_output ''
}

@test "wt hooks run the main checkout's scripts in a branch older than the add-on" {
  set -eu -o pipefail
  if ! command -v wt >/dev/null; then
    [ -z "${GITHUB_ACTIONS:-}" ] || fail "wt is not installed"
    skip "wt is not installed"
  fi
  git add -A
  git commit -qm 'ddev without the add-on'
  git branch feature/OLD-1-x
  install_addon "${DIR}"
  fake_ddev

  run wt switch feature/OLD-1-x --yes --no-cd
  assert_success
  assert_dir_exists ../main.feature-OLD-1-x
  assert_dir_not_exists ../main.feature-OLD-1-x/.ddev/worktree
  run grep '^name:' ../main.feature-OLD-1-x/.ddev/config.local.yaml
  assert_output "name: ${PROJNAME}-old-1"

  # post-start runs in the background
  for _ in $(seq 1 20); do
    grep -qx start "${DDEV_LOG}" && break
    sleep 0.5
  done
  run wt remove feature/OLD-1-x --yes --foreground
  assert_success
  run cat "${DDEV_LOG}"
  assert_line --index 0 start
  assert_line --index 1 'delete -Oy'
}
