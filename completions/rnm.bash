# bash completion for rnm
_rnm()
{
  local cur prev opts completion_modes
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"
  opts="--dry-run -d --disable-log --rollback --camel-case --pascal-case --snake-case --screaming-snake-case --kebab-case --install-completions --gen-config -c --install -i --reinstall -r --update -u --uninstall -x --purge -p --help -h --"
  completion_modes="bash fish zsh nu all detect"

  if [[ $prev == --install-completions ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$completion_modes" -- "$cur")
    return 0
  fi

  if [[ $cur == --install-completions=* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$completion_modes" -- "${cur#*=}")
    COMPREPLY=("${COMPREPLY[@]/#/--install-completions=}")
    return 0
  fi

  if [[ $cur == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
    return 0
  fi

  mapfile -t COMPREPLY < <(compgen -d -- "$cur")
}

complete -F _rnm rnm
