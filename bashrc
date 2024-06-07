#!/bin/bash

# default settings if not set yet
[ -z "${HISTIGNORE+x}" ]        && export HISTIGNORE="&: *:history*:bg:fg:exit"
(( ${HISTSIZE:-0} < 1000 ))     && export HISTSIZE=500000
(( ${HISTFILESIZE:-0} < 1000 )) && export HISTFILESIZE=500000
[ -z "${HISTTIMEFORMAT+x}" ]    && export HISTTIMEFORMAT="[%F %T]  "

# default dir where pane history gets saved
HISTDIR="$HOME/.bash_history.d"

# some internal flags
__TRM_LP_ACTIVE=
__TRM_RELOAD_HIST=0

# look where this shell is running and setup HISTFILE accordingly
__trm_init_histfile() {
	local hist

	# if running in tmux, setup dedicated history file
	if [ -n "$TMUX_PANE" ]; then
		__TRM_RELOAD_HIST=1
		# either basing on env variable from tmux-resurrect restore.sh
		if [[ -n "$TMUX_RESURRECT_BASH_HISTFILE" && -f "$HISTDIR/$TMUX_RESURRECT_BASH_HISTFILE" ]]; then
			hist="$HISTDIR/$TMUX_RESURRECT_BASH_HISTFILE"
			tmux set-option -p -t "$TMUX_PANE" @_resurrect_pane_bash_histfile "$TMUX_RESURRECT_BASH_HISTFILE"
		else
			# or basing on pane option earlier shell set (eg. we're midnight commander subshell -> share history file with parent shell)
			hist=$(tmux show-options -p -v -q -t "$TMUX_PANE" @_resurrect_pane_bash_histfile)
			if [[ -n "$hist" && -f "$HISTDIR/$hist" ]]; then
				hist="$HISTDIR/$hist"
			# if no envvar, nor pane option, start a new history file with random name and save its name as pane option
			else
				mkdir -p "$HISTDIR"
				hist="$(mktemp -q "$HISTDIR/bash_history_tmux_XXXXXXXX")"
				tmux set-option -p -t "$TMUX_PANE" @_resurrect_pane_bash_histfile "$(basename "$hist")"
			fi
		fi
		# in any case under tmux, load global history first, and then let bash load pane history on top of that
		[ -s ~/.bash_history ] && history -r ~/.bash_history
		[ -s "$HISTDIR/bash_history" ] && history -r "$HISTDIR/bash_history"
		# also register hook to merge history back to global shared file when pane is closed
		# / Note: unfortunately pane-exited hook does not work for this, as it executes with pane_id of another alive pane,
		#   not the one that has been closed; so we need to use pane-died + remain-on-exit, and kill pane manually after merging history /
		tmux set-hook -t "$TMUX_PANE" -p pane-died "run-shell \"cat \\\"$hist\\\" >>\\\"$HISTDIR/bash_history\\\" 2>/dev/null && rm -f \\\"$hist\\\"\" ; kill-pane" \; \
			set-option -t "$TMUX_PANE" -p remain-on-exit on

	# not running under tmux - use shared history file directly, save entries asap, but don't reload new commands so we kinda
	# have best of both worlds - not loosing history, and having per shell unique in-RAM history
	else
		__TRM_RELOAD_HIST=0
		hist="$HISTDIR/bash_history"
		[ -s ~/.bash_history ] && history -r ~/.bash_history
	fi

	export HISTFILE="$hist"
}


# Now setup hooks for:
# a) saving history on the fly (using DEBUG trap, so long-running stuff like "ssh somewhere" or
#    "docker run something" will be saved to $HISTFILE before running them commands)
# b) reloading history, in case some nested another shell adds something to $HISTFILE
#
# Unfortunately, this is not as simple as it sounds, cause I'm also user of liquidprompt and
# midnight commander, which both use bash hooks I'd like to use.
# I'd love to use bash-preexec, but it fiddles with HISTCONTROL, so it's no-go for now.
#
# Trying to get this always working quickly feels like herding cats. And makes mess like this:

__trm_precmd() {
	# It turns out that liquidprompt unconditionally resets DEBUG trap on startup and on "prompt_on" command,
	# without consideration it may be used by something else. So we need this contraption...
	# Note: if LP is not used, this should boil down to calling "trap '__trm_preexec..." once, which is all what's needed.
	local v
	if (( ${__TRM_LP_ACTIVE:-0} == 0 )); then
		[[ "${PROMPT_COMMAND[*]}" == *"__lp_set_prompt"* ]] && v=1 || v=0
	else
		[[ -n "${LP_OLD_PS1-}" && "$PS1" != "${LP_OLD_PS1-}" && "$PS1" != "${_LP_MARK_SYMBOL-} " ]] && v=1 || v=0
	fi
	if [[ $__TRM_LP_ACTIVE != "$v" ]]; then
		# first time use, or after liquidprompt's prompt_off / prompt_on commands
		trap '__trm_preexec "$_"' DEBUG
		__TRM_LP_ACTIVE="$v"
	fi

	# finally, all we want to do in precmd hook (PROMPT_COMMAND)
	history -a
	(( __TRM_RELOAD_HIST )) && history -n
}

__trm_preexec() {
	# fortunately, no hack here
	history -a
	(( ${__TRM_LP_ACTIVE:-0} )) && __lp_before_command "$@"
}


###############################################################################
# main: init HISTFILE variable
__trm_init_histfile

# and hook up our functions (__trm_precmd executed on first prompt registers __trm_preexec)
# adding like that (with NL character) should make this work in all cases (borrowed from mc subshell.c)
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}__trm_precmd"$'\n'
