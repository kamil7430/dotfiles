# dotfiles

My dotfiles. You guys all know what that means ;D

## Install

```bash
git clone --bare git@github.com:kamil7430/dotfiles.git "$HOME/.dotfiles"

# needed before checkout; afterwards it comes from the tracked .bashrc
alias dot='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'

dot config --local status.showUntrackedFiles no
dot checkout
```

If `checkout` refuses because a file already exists, move it aside and rerun.

## Don't

Never run `dot clean -xdf`. Everything in `$HOME` is gitignored by design
(`*` plus `git add -f` for tracked files), and `-x` targets exactly the
ignored files. It will wipe your home directory.
