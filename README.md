# Beekeeper
The purpose of Beekeeper is to relieve anxiety by remembering things using a
simple command-line interface. Currently, the things it can remember for you are
bookmarks to locations of files + directories and aliases of commands. Then you
can easily recall your bookmarks or run your aliases by using the label you
create for them. The following video illustrates Beekeeper's features:

![Beekeeper Demo](doc/README/assets/bk-demo.gif)

# Installation

Installing Beekeeper takes two steps: build and install the `bk` executable,
then run `bk init` once to set it up.

## Building and installing

You will need [Stack](https://docs.haskellstack.org/en/stable/) a project
management tool for the [Haskell](https://www.haskell.org/) programming
language. Then clone this repository and run the following to install Beekeeper:

```.bash
stack build
stack install
```

Make sure the directory `stack install` copies `bk` into (usually
`~/.local/bin`) is on your `PATH`.

## Initializing Beekeeper

Before using Beekeeper for the first time run:

```.bash
bk init
```

This does the following:

1. It creates `~/.bk` and an empty bookmarks file, `~/.bk/bookmarks.csv`. If the
   bookmarks file already exists it is left untouched, so your bookmarks and
   aliases are never lost.

2. Beekeeper detects your shell from the `SHELL` environment variable and
   installs a completion script for it. Completions cover Beekeeper's commands
   and the labels of your bookmarks and aliases. Bash, zsh, and fish are
   supported; any other shell are currently unsupported.

   | Shell | Completion script                                   | Startup file updated                                |
   |-------|-----------------------------------------------------|-----------------------------------------------------|
   | bash  | `~/.bk/completions/bk.bash`                         | `~/.bash_profile` on macOS, `~/.bashrc` elsewhere  |
   | zsh   | `~/.bk/completions/_bk`                             | `$ZDOTDIR/.zshrc` (`~/.zshrc` if `ZDOTDIR` is unset) |
   | fish  | `$XDG_CONFIG_HOME/fish/completions/bk.fish` (`~/.config/fish/...` if unset) | none, fish loads it automatically |

Restart your shell afterwards to turn on completions.

It is safe to run `bk init` again, for example after upgrading Beekeeper or
switching shells. It regenerates the completion script, never overwrites your
bookmarks file, and only asks about the startup file if the Beekeeper block is
not already there.

## Where Beekeeper keeps its data

Beekeeper saves all of its data to `~/.bk`. We strive to keep all of
Beekeeper's data human readable and not dependent on any heavy external
libraries or tools. This is the reason we chose
[CSV](https://en.wikipedia.org/wiki/Comma-separated_values) as Beekeeper's
underlying data format.

# Usage

The following sections give examples of every feature Beekeeper supports.

## Adding a bookmark or alias
To add a bookmark use the following command:

```.bash
bk bookmark LABEL=TARGET
```

the string `LABEL` is the name of the bookmark and its value is `TARGET`. For
example, `bk bookmark math-proj="path/to/math/project"` will add a bookmark
with label `math-proj` whose target is `path/to/math/project`.

Adding an alias is very similar to adding a bookmark:

```.bash
bk alias code-proj="code path/to/project"
```

The labels of bookmarks must begin with an alphabet symbol and then only consist
of alphanumeric symbols or underscore or hyphen. Targets are not allowed to be
empty.

The main difference between `bk bookmark` and `bk alias` is that when we
ask Beekeeper to run a bookmark its target is output to the terminal, but when
we ask Beekeeper to run an alias it will execute its target as a command.

## Running a bookmark or alias
To run a bookmark or alias we simply give `bk` the label of the bookmark:

```.bash
bk LABEL
```

Then if `LABEL` is a bookmark its target is output to the terminal, but if its
an alias its target is executed as a command.

The above is the same as `bk run LABEL`. 

Aliases run in your own shell (the one named by `SHELL`), started as an
interactive shell with your full environment. So an alias can use anything
you'd use at your prompt: environment variables, pipes, and the functions and
aliases defined in your shell's startup file. `bk` exits with the same status
as the command it ran.

Any extra arguments after the label are passed on to the alias's command, with
their quoting kept:

```.bash
bk alias greet="echo hello"
bk greet "big world"     # runs: echo hello "big world"
```

Having the bookmark target simply output to the terminal means that we can use
it with other commands. For example,

```.bash
cd `bk LABEL`
```

will change directory into the target of `LABEL`. This makes it easy to inject
Beekeeper into your workflow on the command line.

## Searching for a bookmark or alias
Use:

```.bash
bk find LABEL
```

to search for the target whose label is `LABEL`. A more sophisticated search is
underdevelopment.

## Renaming a bookmark or alias
Use:

```.bash
bk rename OLD_LABEL NEW_LABEL
```

## Removing a bookmark or alias
Use:

```.bash
bk remove LABEL
```

to remove a bookmark or alias.

## Listing bookmarks
If you run Beekeeper with no arguments at all:

```.bash
bk
```

then it will list recent bookmarks. This is the list of all bookmarks and
aliases that were created within the last 10 days.

You can list just bookmarks using:

```.bash
bk bookmarks
```

and just aliases using:

```.bash
bk aliases
```

Use:

```.bash
bk list
```

to see a list of all bookmarks and aliases.

## Help and version
Use:

```.bash
bk --help
```

for the help menu and use:

```.bash
bk --version
```

to show the currently installed version.

# Contributing
## Testing

Shell integration tests live in `test/shell`. They run `bk init`, bookmarks, and
aliases against real bash, zsh, and fish shells, each starting from a fresh,
empty `HOME`. The easiest way to run them is in Docker, which builds `bk` and
installs all three shells for you:

```.bash
cd test
docker compose run --rm bk            # all shells
docker compose run --rm bk fish       # just fish
docker compose run --rm bk zsh bash   # a subset, in that order
```

To run them without Docker, put `bk` on your `PATH` and run
`test/shell/run.sh [SHELL...]`. Set `KEEP_HOMES=1` to keep each shell's
temporary `HOME` afterwards for inspection.