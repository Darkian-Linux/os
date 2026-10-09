# ~/.zshrc — Darkian Linux per-user zsh configuration.
#
# System-wide settings (including the prompt) live in /etc/zsh/zshrc.  This
# file only needs to exist so zsh does not run its interactive "new user"
# setup wizard on first login.  Add your own customisations below.

HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS APPEND_HISTORY
