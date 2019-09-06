# resticctl

A profile based control script for restic backup

## SYNOPSIS

  resticctl (init|start|edit|forget|prune|cleanup|check|shell) profile [profile2 profileX]

## DESCRIPTION

`restic` is a command line backup tool written to do backups right. It's design
goals are to be Easy, Fast, Verifiable, Secure, Efficient, Free.

`resticctl` is a wrapper that allow backup profiles for restic to be defined.
Those profiles can then be operated on without having to repeat configuration
directives over and over, or manually defining environment variables.

resticctl can be setup and then scheduled using cron or systemd timers.

## COMMANDS

`resticctl` recognizes the following commands:

### init
Initialize a new restic repository.

### start
Start a backup.

### edit
Edit profile configuration.

### forget
Forrget old snapshots based on retention policies.

### prune
Prune old data from repository.

### cleanup
'forget' and 'prune' together.

### check
Check the repository for errors.

### shell
Start a shell with the relevant environment variables set.

If more than 1 profile is given, loop through each one in sequence.

## INSTALLATION

`resticctl` consists of a single script - save it to wherever is appropriate
for your system. You probably want to make sure that is somewhere in your $PATH
Running `make install` will by default install it as `/usr/local/bin/resticctl`

## GETTING STARTED

Once you have the script installed, run `resticctl edit myprofile`. Replace
"myprofile" with whatever you want to call your profile. A default configuration
file will be opened in your preferred editor. This file is commented with what
each directive does. Many of the directives are verbatim restic environment
variables.

## CONFIGURATION FILE

The configuration is treated as a bash shell script, so it allows for shell
syntax to be used:
  1. Don't forget proper quoting where appropriate
  2. Shell commands can be used (eg, subshells, variable expansion etc)
