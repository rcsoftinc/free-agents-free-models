# install.sh - put a missing agent CLI on this machine the way its vendor says
# to. Sourced by setup.sh only; not a standalone entry point (uses `say` and
# `prompt_yn` from there).
#
# Each adapter names its vendor's install script (FA_<agent>_INSTALL_URL), the
# shell that script is written for (FA_<agent>_INSTALL_SHELL, bash unless said
# otherwise) and the directory the script puts the binary in (FA_<agent>_BIN_DIR,
# under $HOME). What runs is the one line the vendor's own page gives,
# `curl -fsSL <url> | bash`, so what lands is what a person following that page
# gets. The earlier version of this guessed a package name per agent for npm,
# pip3 or cargo: none of the seven on the machine this was written on came from
# any of those - every one came from its vendor's script - and the guessed names
# had never been run. All seven URLs were fetched and read on 2026-11-17: each
# serves a script, and each script's install directory is where that binary
# actually is on a real machine.
#
# After an install the binary's directory goes on PATH for the rest of this
# process - the installers add it to shell profiles for later shells; this one
# is already running - so the credential checks and the bootstrap that follow
# find what was just installed. Before anything is installed, every adapter's
# directory that already exists is put on PATH the same way: a CLI installed by
# an earlier run of setup, in a shell that never re-read its profile, is
# otherwise reported missing and offered again.
#
#   FA_AUTO_INSTALL=1   install every missing agent without asking (setup.sh
#                       reads it for the system tools too)

INSTALLED_NOW=()      # agents this run installed
INSTALL_SKIPPED=()    # declined, or no installer known for the adapter
INSTALL_FAILED=()     # the vendor's script failed, or left no binary where it said

agent_bin_dir() { # $1=agent -> the absolute directory its installer uses, or ""
  local d; d="$(adapter_field "$1" BIN_DIR)"
  [[ -n "$d" ]] && printf '%s/%s' "$HOME" "$d"
  return 0
}

path_add_front() { # $1=dir -> on PATH, once, in front
  case ":${PATH}:" in *":$1:"*) ;; *) export PATH="$1:${PATH}" ;; esac
}

agents_path_extend() { # every adapter's install directory that exists -> PATH
  local a d
  for a in "${FA_AGENTS[@]}"; do
    d="$(agent_bin_dir "$a")"
    [[ -n "$d" && -d "$d" ]] && path_add_front "$d"
  done
  return 0
}

install_agent() { # $1=agent -> 0 installed, 1 skipped, 2 failed
  local a="$1" url sh d
  url="$(adapter_field "$a" INSTALL_URL)"
  if [[ -z "$url" ]]; then
    say "  no installer is known for $a - see docs/SETUP.md"
    INSTALL_SKIPPED+=("$a"); return 1
  fi
  sh="$(adapter_field "$a" INSTALL_SHELL)"; sh="${sh:-bash}"
  # Said before the question: bash shows a `read -p` prompt only on a terminal,
  # and the line a person is asked about belongs in the output either way.
  say "  installs with: curl -fsSL $url | $sh"
  if [[ "${FA_AUTO_INSTALL:-0}" != "1" ]] && ! prompt_yn "  install it now?"; then
    say "  skipped $a"
    INSTALL_SKIPPED+=("$a"); return 1
  fi
  say "$a: installing - curl -fsSL $url | $sh"
  if ! curl -fsSL "$url" | "$sh"; then
    say "$a: the installer failed (its output is above) - install it by hand, then run setup again"
    INSTALL_FAILED+=("$a"); return 2
  fi
  d="$(agent_bin_dir "$a")"
  [[ -n "$d" && -d "$d" ]] && path_add_front "$d"
  if adapter_installed "$a"; then
    say "$a: installed${d:+ in $d}"
    INSTALLED_NOW+=("$a"); return 0
  fi
  say "$a: the installer finished but left no '$(adapter_field "$a" VERSION_BIN)'${d:+ in $d} - its output above says where it went, if anywhere"
  INSTALL_FAILED+=("$a"); return 2
}

install_missing_agents() { # every agent not on PATH is offered its installer
  local a
  agents_path_extend
  for a in "${FA_AGENTS[@]}"; do
    adapter_installed "$a" && continue
    say "$a: not installed"
    install_agent "$a" || true
  done
  return 0
}

# The export line the shell setup ran from needs before it finds what this run
# installed: the installers add their directories to shell profiles, and that
# shell has already read its profile.
installed_now_path_line() { # -> 'export PATH=...' for the agents installed now, or ""
  local a d dirs=""
  for a in "${INSTALLED_NOW[@]}"; do
    d="$(agent_bin_dir "$a")"
    [[ -n "$d" ]] || continue
    case ":${dirs}:" in *":$d:"*) ;; *) dirs="${dirs:+${dirs}:}${d}" ;; esac
  done
  [[ -n "$dirs" ]] && printf 'export PATH="%s:$PATH"' "$dirs"
  return 0
}
