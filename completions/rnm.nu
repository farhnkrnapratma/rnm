def "nu-complete rnm completion-modes" [] {
  [bash fish zsh nu all detect]
}

export extern "rnm" [
  --dry-run(-d)
  --disable-log
  --rollback
  --camel-case
  --pascal-case
  --snake-case
  --screaming-snake-case
  --kebab-case
  --install-completions: string@"nu-complete rnm completion-modes"
  --gen-config(-c)
  --install(-i)
  --reinstall(-r)
  --update(-u)
  --uninstall(-x)
  --purge(-p)
  --help(-h)
  target_dir?: path
]
