#!/usr/bin/env bash

set -e  # abort on any unhandled error
set -u  # abort on use of uninitialized variable

# constants
declare -r DEBUG=

# global variables used internally to this script
declare PROFILE_DIR=
declare RESTIC_TAG=
declare RESTIC_ARGS=
declare -i RENICE=0
declare PRE_HOOKS=
declare POST_HOOKS=
declare -i KEEP_LAST=
declare -i KEEP_HOURLY=
declare -i KEEP_DAILY=
declare -i KEEP_WEEKLY=
declare -i KEEP_MONTHLY=
declare -i KEEP_YEARLY=

function main() {
  PROFILE_DIR="$(guess_profile_dir)"

  cmd="${1:-}"
  [[ -z "$cmd" ]] && { usage; return 1; }
  shift
  dbg "Command is $cmd"

  # argumentless commands process early and exit
  case "$cmd" in
    list-profiles)
      list_profiles
      return 0
      ;;
    list-repos)
      list_repos
      return 0
      ;;
  esac

  # make sure we still have arguments remaining
  if [[ "$#" -lt 1 ]] ; then
    usage
    return 1
  fi

  # loop over remaining cmdline args, treating them as profiles
  for arg in "$@" ; do
    case "$cmd" in
      edit)
        profile_edit "$arg"
        ;;
      redit)
        repo_edit "$arg"
        ;;
      init)
        restic_init "$arg"
        ;;
      status)
        restic_status "$arg"
        ;;
      start)
        restic_start "$arg"
        ;;
      check)
        restic_check "$arg"
        ;;
      forget)
        restic_forget "$arg"
        ;;
      prune)
        restic_prune "$arg"
        ;;
      cleanup)
        restic_forget "$arg"
        restic_prune "$arg"
        ;;
      shell)
        restic_shell "$arg"
        ;;
      *)
        usage
        return 1
    esac
  done

  return 0
}

### SUBCOMMAND: INIT ###########################################################
function restic_init {
  local -r profile="$1"
  load_profile "$profile"
  nice -n $RENICE restic init
}

### SUBCOMMAND: STATUS ###########################################################
function restic_status {
  local -r profile="$1"
  local restic_args=''

  load_profile "$profile"

  [[ -n "$RESTIC_TAG" ]] && restic_args="$restic_args --tag $RESTIC_TAG"

  nice -n $RENICE restic snapshots --host "$(uname -n)" --last $restic_args
  nice -n $RENICE restic stats
}

### SUBCOMMAND: START ##########################################################
function restic_start {
  local -r profile="$1"
  load_profile "$profile"
  local restic_args="$RESTIC_ARGS"

  [[ -n "$RESTIC_TAG" ]] && restic_args="$restic_args --tag $RESTIC_TAG"

  for epattern in "${BACKUP_EXCLUDE[@]}" ; do
    restic_args="$restic_args --exclude $epattern"
  done

  for ipattern in "${BACKUP_INCLUDE[@]}" ; do
    [[ ! -e "$ipattern" ]] && abort "Include path not found: $ipattern"
  done

  if [[ -n "${PRE_HOOKS}" ]] ; then
    for cmd in "${PRE_HOOKS[@]}" ; do
      echo "Executing pre-hook: $cmd"
      $cmd
    done
  fi

  echo "Starting backup profile '$profile'"
  nice -n $RENICE restic backup $restic_args "${BACKUP_INCLUDE[@]}"

  if [[ -n "${POST_HOOKS}" ]] ; then
    for cmd in "${POST_HOOKS[@]}" ; do
      echo "Executing post-hook: $cmd"
      $cmd
    done
  fi
}

### SUBCOMMAND: forget #######################################################
function restic_forget {
  local -r profile="$1"
  local restic_args=''
  load_profile "$profile"

  [[ -n "$RESTIC_TAG" ]] && restic_args="$restic_args --tag $RESTIC_TAG"

  local keep_args=''
  [[ "$KEEP_LAST" -gt 0 ]]    && keep_args="$keep_args --keep-last $KEEP_LAST"
  [[ "$KEEP_HOURLY" -gt 0 ]]  && keep_args="$keep_args --keep-hourly $KEEP_HOURLY"
  [[ "$KEEP_DAILY" -gt 0 ]]   && keep_args="$keep_args --keep-daily $KEEP_DAILY"
  [[ "$KEEP_WEEKLY" -gt 0 ]]  && keep_args="$keep_args --keep-weekly $KEEP_WEEKLY"
  [[ "$KEEP_MONTHLY" -gt 0 ]] && keep_args="$keep_args --keep-monthly $KEEP_MONTHLY"
  [[ "$KEEP_YEARLY" -gt 0 ]]  && keep_args="$keep_args --keep-yearly $KEEP_YEARLY"
  restic_args="$restic_args $keep_args"

  nice -n $RENICE restic forget $restic_args
}

### SUBCOMMAND: list_profiles #########################################################
function list_profiles {
  cd "$PROFILE_DIR"
  ls -1 *.profile | sed -e 's/.profile$//g'
}

### SUBCOMMAND: list_profiles #########################################################
function list_repos {
  cd "$PROFILE_DIR"
  ls -1 *.repo | sed -e 's/.repo$//g'
}

### SUBCOMMAND: prune #########################################################
function restic_prune {
  local -r profile="$1"
  load_profile "$profile"

  nice -n $RENICE restic prune
}

### SUBCOMMAND: check #########################################################
function restic_check {
  local -r profile="$1"
  load_profile "$profile"

  nice -n $RENICE restic check
}

### SUBCOMMAND: shell #########################################################
function restic_shell {
  local -r profile="$1"
  load_profile "$profile"

  cat <<EOF
+-----------------------------------------------------------------------------+
 STARTING A NEW SHELL WITH ENVIRONMENT FOR RESTIC PROFILE '$profile'
 Type 'exit' when finished.
+-----------------------------------------------------------------------------+
EOF
  bash --rcfile <(echo "PS1='resticctl '$profile' > '") -i
  echo 'RESTIC SHELL EXITED.'
}

### PROFILE & REPO EDIT ##############################################################
function profile_edit {
  local -r profile_name="$1"
  local -r fname="$(get_profile_filename "$profile_name")"
  local -r tmpname="${fname}.tmp"

  # we want to work on a temporary file until the user is finished and we can
  # validate it as looking like a reasonable configuration
  if [[ -f "$fname" ]] ; then
    # copy the live file to a temp file
    cp -f "$fname" "$tmpname"
  else
    # no existing profile; make a temporary one
    create_profile_template "$profile_name" "$tmpname"
  fi

  edit_file "$fname" "$tmpname"
}

function repo_edit {
  local -r repo_name="$1"
  local -r fname="$(get_repo_filename "$repo_name")"
  local -r tmpname="${fname}.tmp"

  # we want to work on a temporary file until the user is finished and we can
  # validate it as looking like a reasonable configuration
  if [[ -f "$fname" ]] ; then
    # copy the live file to a temp file
    cp -f "$fname" "$tmpname"
  else
    # no existing config file; make a temporary one
    create_repo_template "$repo_name" "$tmpname"
  fi

  edit_file "$fname" "$tmpname"
}

function edit_file {
  local -r fname="$1"
  local -r tmpname="$2"

  # start the editor
  edit_cmd="$(get_editor)"
  while true ; do
    if $edit_cmd "$tmpname" ; then
      # editor exited successfully; test the file before moving back in-place
      # we need to temporarily disable the -e option because any errors inside
      # the config file will cause an abort, instead of being caught in our
      # script as part of the `source` commands
      set +eu
      if ! errs=$(bash -n "$tmpname" 2>&1); then
        echo "Invalid syntax: $errs"
        read -p 'Press enter to edit again' z
        continue
      fi
      set -eu

      if [[ ! -s "$tmpname" ]] ; then
        dbg "Config file returned with zero-bytes"
      elif cmp --silent "$fname" "$tmpname" ; then
        dbg "No changes"
      else
        dbg "Moving $tmpname => $fname"
        mv -f "$tmpname" "$fname"
      fi
    fi
    rm -f "$tmpname"
    break
  done
  return 0
}

###############################################################################
### HELPER FUNCTIONS BELOW HERE
###############################################################################
function usage {
  cat <<EOF
Usage: $0 command profile [profile2 profileX]

Supported 'command' arguments are:
  list-profiles List configured profiles
  list-repos    List configured repositories
  init          Initialize \$RESTIC_REPOSITORY
  status        List most recent backups
  start         Start a backup
  edit          Edit profile configuration
  redit         Edit repository configuration
  forget        Forget old snapshots based on retention policies
  prune         Prune old data from repository
  cleanup       Run 'forget' then 'prune' in sequence
  check         Check the repository for errors
  shell         Start a shell with the relevant environment variables set

If more than 1 profile is given, loop through each one in sequence.
EOF
  return 0
}

function guess_profile_dir {
  # work out what directory to use for our configs
  for dirpath in /etc/restic $HOME/.config/restic ; do
    if [[ -d "$dirpath" && -w "$dirpath" ]] ; then
      dbg "PROFILE_DIR is $dirpath"
      echo "$dirpath"
      return 0
    fi
  done

  # unable to locate a directory; try to create one
  if [[ $EUID -eq 0 ]] ; then
    if mkdir /etc/restic ; then
      dbg "Created PROFILE_DIR /etc/restic"
      chmod 700 /etc/restic
      echo '/etc/restic'
      return 0
    fi
  fi
  if mkdir $HOME/.config/restic ; then
    dbg "Created PROFILE_DIR: $HOME/.config/restic"
    chmod 700 $HOME/.config/restic
    echo "$HOME/.config/restic"
    return 0
  fi

  # default fail
  abort "Unable to locate suitable configuration directory"
}

function dbg {
  [[ -z $DEBUG ]] && return 0
  echo "DEBUG: $1" >&2
}

function abort {
  echo "ABORT: $1" >&2
  exit 1
}

function get_profile_filename {
  echo "$PROFILE_DIR/${1}.profile"
}
function get_repo_filename {
  echo "$PROFILE_DIR/${1}.repo"
}

function load_profile {
  local -r profile="$1"
  local -r profile_fname="$(get_profile_filename "$profile")"

  clear_existing_profile_vars

  # load profile config
  [[ ! -f "$profile_fname" ]] && abort "Profile not found: $profile_fname"
  [[ ! -r "$profile_fname" ]] && abort "Unable to read profile: $profile_fname"
  source "$profile_fname"
  dbg "Loaded profile: $profile_fname"

  # load repository config
  [[ -z "$REPO" ]] && abort "No REPO configured for profile $profile"
  load_repo "$REPO"

  check_minimum_viable_profile
}

function load_repo {
  local repo="$1"
  local -r repo_fname="$(get_repo_filename "$repo")"

  [[ ! -f "$repo_fname" ]] && abort "Repository configuration file not found: $repo_fname"
  [[ ! -r "$repo_fname" ]] && abort "Unable to read repo configuration file: $repo_fname"
  source "$repo_fname"

  # export restic configuration variables so restic can access directly without
  # us having to do anything special to pass it in later commands.
  # we unset all variables earlier in this function, so testing if they're set
  # here will throw an undefined variable error (due to set -u at top of script)
  # see this page explanation of the syntax to check defined/undefined:
  # https://stackoverflow.com/questions/3601515/how-to-check-if-a-variable-is-set-in-bash
  [[ -n "${RESTIC_REPOSITORY+x}" ]]     && export RESTIC_REPOSITORY
  [[ -n "${RESTIC_PASSWORD+x}" ]]       && export RESTIC_PASSWORD
  [[ -n "${AWS_ACCESS_KEY_ID+x}" ]]     && export AWS_ACCESS_KEY_ID
  [[ -n "${AWS_SECRET_ACCESS_KEY+x}" ]] && export AWS_SECRET_ACCESS_KEY
  [[ -n "${B2_ACCOUNT_ID+x}" ]]         && export B2_ACCOUNT_ID
  [[ -n "${B2_ACCOUNT_KEY+x}" ]]        && export B2_ACCOUNT_KEY

  return 0
}

function clear_existing_profile_vars {
  unset RESTIC_REPOSITORY RESTIC_PASSWORD
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  unset B2_ACCOUNT_ID B2_ACCOUNT_KEY
  RESTIC_TAG=
  RESTIC_ARGS=
  RENICE=0
  PRE_HOOKS=
  POST_HOOKS=
  KEEP_LAST=
  KEEP_HOURLY=
  KEEP_DAILY=
  KEEP_WEEKLY=
  KEEP_MONTHLY=
  KEEP_YEARLY=
}

function check_minimum_viable_profile {
  [[ -z "$RESTIC_REPOSITORY" ]] && abort 'Configuration not set: $RESTIC_REPOSITORY'
  [[ ${#BACKUP_INCLUDE[@]} -eq 0 ]] && abort 'BACKUP_INCLUDE cannot be empty'
  while true ; do
    [[ "$KEEP_LAST" -gt 0 ]]    && break
    [[ "$KEEP_HOURLY" -gt 0 ]]  && break
    [[ "$KEEP_DAILY" -gt 0 ]]   && break
    [[ "$KEEP_WEEKLY" -gt 0 ]]  && break
    [[ "$KEEP_MONTHLY" -gt 0 ]] && break
    [[ "$KEEP_YEARLY" -gt 0 ]]  && break
    abort 'At least one of KEEP_LAST, KEEP_HOURLY, KEEP_DAILY, KEEP_WEEKLY, KEEP_MONTHLY or KEEP_YEARLY must be specified'
  done
  return 0
}

function get_editor {
  # check the environment for an editor; fall back to well-known defaults but
  # abort if we can't find anything useful
  if [[ -n "${EDITOR:-}" ]] ; then
    echo "$EDITOR"
  elif [[ -n "${VISUAL:-}" ]] ; then
    echo "$VISUAL"
  elif hash nano 2>/dev/null ; then
    echo nano
  elif hash vim 2>/dev/null ; then
    echo vim
  elif hash vi 2>/dev/null ; then
    echo vi
  else
    abort "Could not find suitable editor. Try setting \$EDITOR"
  fi
}

function create_profile_template {
  local pname="$1"
  local fname="$2"
  cat > "$fname" <<EOF
# Configuration file for restic profile '$pname'
# Created at $(date) by $USER on $(uname -n)
#
# This file follows shell syntax:
#   1. Don't forget proper quoting where appropriate
#   2. Shell commands can be used (eg, subshells, variable expansion etc)

# name of the repository to use. use 'resticctl redit <name>' to create/edit
REPO=

# all snapshots will be tagged with this string
RESTIC_TAG=$pname

# renice the backup process to this value
# learn more about nice by running 'man 1 nice'
RENICE=10

# what to backup and exclude
BACKUP_INCLUDE=(
  '/home'
  '/etc'
)
BACKUP_EXCLUDE=(
  '*.tmp'
)

# if you need to run commands before or after the backup, specify them here
# for example, running a backup of a database to a file
#PRE_HOOKS=(
#  'pg_dump foobar'
#)
#POST_HOOKS=(
#)

# additional arguments to pass to restic when creating backups
#RESTIC_ARGS='--exclude-caches'

# comment whole line to disable the flag.
KEEP_LAST=
KEEP_HOURLY=
KEEP_DAILY=
KEEP_WEEKLY=
KEEP_MONTHLY=
KEEP_YEARLY=
EOF
  return 0
}

function create_repo_template {
  local rname="$1"
  local fname="$2"
  cat > "$fname" <<EOF
# Repository configuration file for restic profile '$rname'
# Created at $(date) by $USER on $(uname -n)
#
# This file follows shell syntax:
#   1. Don't forget proper quoting where appropriate
#   2. Shell commands can be used (eg, subshells, variable expansion etc)

# restic repository and access options
RESTIC_REPOSITORY=
RESTIC_PASSWORD=
#AWS_ACCESS_KEY_ID=
#AWS_SECRET_ACCESS_KEY=
#B2_ACCOUNT_ID=
#B2_ACCOUNT_KEY=
EOF
  return 0
}

main "$@"
