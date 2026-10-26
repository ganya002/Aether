#!/bin/zsh
# Runs zsh, bash, and fish (when installed) with Aether's shell integration under script(1),
# with a throwaway HOME and ZDOTDIR, and checks the escape sequences they print.
#
#   scripts/test-shell-integration.sh [integration-dir]
#
# The default directory is the copy Aether writes when it starts a shell:
#   ~/Library/Application Support/Aether/shell-integration
# `AETHER_SHELL_TESTS=1 swift test --filter shellIntegrationEndToEnd` writes a fresh copy and runs this script on it.
set -u

root=${1:-"$HOME/Library/Application Support/Aether/shell-integration"}
if [[ ! -r "$root/zsh/.zshenv" ]]; then
  print -u2 "No integration files in $root"
  exit 2
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/aether-shell-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
failures=0

check() {
  # check <name> <file> <literal text that must appear>
  if grep -qF -- "$3" "$2"; then
    print "ok   $1"
  else
    print "FAIL $1: missing $(print -r -- "$3" | cat -v) in $2"
    failures=$((failures + 1))
  fi
}

refute() {
  if grep -qF -- "$3" "$2"; then
    print "FAIL $1: unexpected $(print -r -- "$3" | cat -v)"
    failures=$((failures + 1))
  else
    print "ok   $1"
  fi
}

# Types each line after a pause, the way a person would, then exits.
feed() {
  sleep 1.5
  for line in "$@"; do
    print -r -- "$line"
    sleep 0.6
  done
  print exit
  sleep 0.5
}

ESC=$'\e'
BEL=$'\a'
mkdir -p "$work/dir with space"

# zsh ----------------------------------------------------------------------
run_zsh() {
  # run_zsh <transcript> <extra env...>
  local out=$1; shift
  local zhome="$work/zhome" zdot="$work/zdot"
  rm -rf "$zhome" "$zdot"; mkdir -p "$zhome" "$zdot"
  cat > "$zdot/.zshenv" <<EOF
print -r -- "\$ZDOTDIR" > "$work/zshenv-ran"
# Like powerlevel10k's instant prompt: anything printed from here to the end of .zshrc is a bug.
exec 3>&1 4>&2 >"$work/zsh-init-output" 2>&1
EOF
  print 'print zprofile >> "$HOME/../zsh-files"' > "$zdot/.zprofile"
  cat > "$zdot/.zshrc" <<'EOF'
print zshrc >> "$HOME/../zsh-files"
print -r -- "${ZDOTDIR-unset} ${AETHER_ORIG_ZDOTDIR-unset}" > "$HOME/../zsh-zdotdir"
PS1='custom %~> '
precmd() { user_precmd_ran=1 }
autoload -Uz add-zsh-hook
mine() { true }
add-zsh-hook precmd mine
exec 1>&3 2>&4 3>&- 4>&-
EOF
  print 'print zlogin >> "$HOME/../zsh-files"' > "$zdot/.zlogin"
  rm -f "$work/zsh-files"
  feed 'cd "$HOME/../dir with space"' 'false' 'echo hello; echo "precmd=$user_precmd_ran"' 'print -r -- "$PS1" > "$HOME/../zsh-ps1"' \
    | env -i HOME="$zhome" TERM=xterm-256color PATH=/usr/bin:/bin USER="$USER" \
        ZDOTDIR="$root/zsh" AETHER_ORIG_ZDOTDIR="$zdot" "$@" \
        script -q "$out" /bin/zsh -l >/dev/null 2>&1
}

z="$work/zsh.out"
run_zsh "$z"
check "zsh: prompt report" "$z" "${ESC}]7502;prompt;shell=zsh${BEL}"
check "zsh: prompt start mark" "$z" "${ESC}]133;A${BEL}"
check "zsh: input start mark" "$z" "${ESC}]133;B${BEL}"
check "zsh: command line" "$z" "${ESC}]7502;cmd=false${BEL}"
check "zsh: output start mark" "$z" "${ESC}]133;C${BEL}"
check "zsh: finished with status" "$z" "${ESC}]133;D;1${BEL}"
check "zsh: exit status report" "$z" "${ESC}]7502;prompt;shell=zsh;exit=1${BEL}"
check "zsh: encoded command" "$z" "${ESC}]7502;cmd=echo%20hello%3B%20echo%20%22precmd%3D%24user_precmd_ran%22${BEL}"
check "zsh: directory" "$z" "dir%20with%20space${BEL}"
check "zsh: title at prompt" "$z" "${ESC}]2;zsh "
check "zsh: title for command" "$z" "${ESC}]2;false${BEL}"
check "zsh: user's precmd still runs" "$z" "precmd=1"
check "zsh: user's prompt" "$z" "custom "
check "zsh: .zshenv ran with the user's ZDOTDIR" "$work/zshenv-ran" "$work/zdot"
check "zsh: .zprofile" "$work/zsh-files" "zprofile"
check "zsh: .zshrc" "$work/zsh-files" "zshrc"
check "zsh: .zlogin" "$work/zsh-files" "zlogin"
check "zsh: ZDOTDIR restored, AETHER_ORIG_ZDOTDIR gone" "$work/zsh-zdotdir" "$work/zdot unset"
refute "zsh: PS1 has no marks while a command runs" "$work/zsh-ps1" "133;"
if [[ -s "$work/zsh-init-output" ]]; then
  print "FAIL zsh: printed during startup: $(cat -v "$work/zsh-init-output")"
  failures=$((failures + 1))
else
  print "ok   zsh: nothing printed during startup"
fi

z0="$work/zsh-off.out"
run_zsh "$z0" AETHER_SHELL_INTEGRATION=0
refute "zsh off: no reports" "$z0" "7502;"
check "zsh off: .zshrc still loads" "$work/zsh-files" "zshrc"

# zsh without a ZDOTDIR of its own reads ~/.zshrc.
zh="$work/zhome2"; mkdir -p "$zh"
print 'print home-zshrc > "$HOME/marker"; PS1="h> "' > "$zh/.zshrc"
feed 'true' | env -i HOME="$zh" TERM=xterm-256color PATH=/usr/bin:/bin ZDOTDIR="$root/zsh" \
  script -q "$work/zsh-home.out" /bin/zsh -l >/dev/null 2>&1
check "zsh: ~/.zshrc when ZDOTDIR was unset" "$zh/marker" "home-zshrc"
check "zsh: hooks with ~/.zshrc" "$work/zsh-home.out" "${ESC}]7502;cmd=true${BEL}"

# bash ---------------------------------------------------------------------
bhome="$work/bhome"; mkdir -p "$bhome"
cat > "$bhome/.bash_profile" <<'EOF'
echo profile >> "$HOME/../bash-files"
[ -r ~/.bashrc ] && . ~/.bashrc
EOF
cat > "$bhome/.bashrc" <<'EOF'
echo bashrc >> "$HOME/../bash-files"
PS1='bash> '
PROMPT_COMMAND='user_pc=$?;'
trap 'user_trap=1' DEBUG
HISTCONTROL=ignorespace
EOF
b="$work/bash.out"
feed 'cd "$HOME/../dir with space"' 'false' 'echo "pc=$user_pc trap=$user_trap"' ' echo a; echo b' \
  | env -i HOME="$bhome" TERM=xterm-256color PATH=/usr/bin:/bin AETHER_BASH_LOGIN=1 \
      script -q "$b" /bin/bash --rcfile "$root/bash/aether.bash" -i >/dev/null 2>&1
check "bash: prompt report" "$b" "${ESC}]7502;prompt;shell=bash${BEL}"
check "bash: prompt start mark" "$b" "${ESC}]133;A${BEL}"
check "bash: input start mark" "$b" "${ESC}]133;B${BEL}"
check "bash: command line" "$b" "${ESC}]7502;cmd=false${BEL}"
check "bash: output start mark" "$b" "${ESC}]133;C${BEL}"
check "bash: finished with status" "$b" "${ESC}]133;D;1${BEL}"
check "bash: exit status report" "$b" "${ESC}]7502;prompt;shell=bash;exit=1${BEL}"
check "bash: directory" "$b" "dir%20with%20space${BEL}"
check "bash: user's PROMPT_COMMAND sees the status" "$b" "pc=1 trap=1"
check "bash: command left out of history" "$b" "${ESC}]7502;cmd=echo%20a${BEL}"
check "bash: .bash_profile" "$work/bash-files" "profile"
check "bash: .bashrc" "$work/bash-files" "bashrc"

# fish ---------------------------------------------------------------------
if fish=$(command -v fish); then
  fhome="$work/fhome"; mkdir -p "$fhome"
  f="$work/fish.out"
  feed 'false' 'echo hello' \
    | env -i HOME="$fhome" TERM=xterm-256color PATH=/usr/bin:/bin:${fish:h} \
        XDG_DATA_DIRS="$root/xdg:/usr/local/share:/usr/share" AETHER_FISH_DATA_DIR="$root/xdg" \
        script -q "$f" "$fish" -l >/dev/null 2>&1
  check "fish: prompt report" "$f" "${ESC}]7502;prompt;shell=fish"
  check "fish: command line" "$f" "${ESC}]7502;cmd=false${BEL}"
  check "fish: exit status report" "$f" "${ESC}]7502;prompt;shell=fish;exit=1${BEL}"
else
  print "skip fish: not installed"
fi

if (( failures )); then
  print "$failures failed"
  exit 1
fi
print "all passed"
