#!/usr/bin/env bats
# Tests for command extraction (parse mode).
# Verifies shfmt AST -> individual command strings.

load test_helper

# -- simple commands (no metacharacters => fast path, output as-is) --

@test "parse: simple command" {
  run_parse "ls -la"
  assert_commands "ls -la"
}

@test "parse: command with path argument" {
  run_parse "cat /etc/hosts"
  assert_commands "cat /etc/hosts"
}

@test "parse: simple command with redirect (preserved in output)" {
  run_parse "echo hello > /tmp/out"
  assert_commands "echo hello > /tmp/out"
}

@test "parse: simple command with input redirect" {
  run_parse "sort < /tmp/in"
  assert_commands "sort < /tmp/in"
}

# -- pipes --

@test "parse: two-command pipe" {
  run_parse "ls | grep foo"
  assert_commands "ls" "grep foo"
}

@test "parse: three-command pipe" {
  run_parse "ls | grep foo | head -5"
  assert_commands "ls" "grep foo" "head -5"
}

@test "parse: pipe with arguments on both sides" {
  run_parse "git log --oneline | head -20"
  assert_commands "git log --oneline" "head -20"
}

# -- AND/OR chains --

@test "parse: AND chain" {
  run_parse "mkdir -p dir && cd dir"
  assert_commands "mkdir -p dir" "cd dir"
}

@test "parse: OR chain" {
  run_parse "test -f file || echo missing"
  assert_commands "test -f file" "echo missing"
}

@test "parse: mixed AND/OR" {
  run_parse "cmd1 && cmd2 || cmd3"
  assert_commands "cmd1" "cmd2" "cmd3"
}

# -- semicolons --

@test "parse: semicolon-separated" {
  run_parse "echo hello; echo world"
  assert_commands "echo hello" "echo world"
}

@test "parse: mixed pipe and semicolon" {
  run_parse "ls | head; echo done"
  assert_commands "ls" "head" "echo done"
}

# -- subshells and blocks --

@test "parse: subshell" {
  run_parse "(cd /tmp && ls)"
  assert_commands "cd /tmp" "ls"
}

@test "parse: block" {
  run_parse "{ echo a; echo b; }"
  assert_commands "echo a" "echo b"
}

# -- command substitution --

@test "parse: command substitution extracted" {
  run_parse 'echo $(date)'
  assert_commands 'echo $(..)' "date"
}

@test "parse: nested command substitution" {
  run_parse 'echo $(cat $(ls))'
  assert_commands 'echo $(..)' 'cat $(..)' "ls"
}

# -- process substitution --

@test "parse: process substitution extracted" {
  run_parse "diff <(ls dir1) <(ls dir2)"
  assert_commands "diff" "ls dir1" "ls dir2"
}

# -- control flow --

@test "parse: if statement" {
  run_parse 'if test -f x; then echo yes; else echo no; fi'
  assert_commands "test -f x" "echo yes" "echo no"
}

@test "parse: for loop" {
  run_parse 'for f in *.txt; do cat "$f"; done'
  assert_commands 'cat "$f"'
}

@test "parse: while loop" {
  run_parse 'while read -r line; do echo "$line"; done'
  assert_commands 'read -r line' 'echo "$line"'
}

# -- DeclClause (export/local/declare with command substitution) --

@test "parse: export with command substitution" {
  run_parse 'export FOO=$(date); echo done'
  assert_commands "date" "echo done"
}

@test "parse: local with command substitution" {
  run_parse 'local x=$(whoami); echo "$x"'
  assert_commands "whoami" 'echo "$x"'
}

@test "parse: declare indexed array with command substitution" {
  run_parse 'declare -a arr=($(evil_cmd)); echo done'
  assert_commands "evil_cmd" "echo done"
}

@test "parse: declare associative array with command substitution" {
  run_parse 'declare -A map=([key]=$(evil_cmd)); echo done'
  assert_commands "evil_cmd" "echo done"
}

# -- quoted special characters (correctly treated as simple) --

@test "parse: pipe character inside double quotes" {
  run_parse 'echo "hello | world"'
  # contains | but shfmt correctly identifies it as quoted
  assert_commands 'echo "hello | world"'
}

@test "parse: pipe character inside single quotes" {
  run_parse "echo 'hello | world'"
  assert_commands "echo 'hello | world'"
}

@test "parse: semicolon inside quotes" {
  run_parse 'echo "a; b"'
  assert_commands 'echo "a; b"'
}

# -- bash -c recursive expansion --

# -- case statement --

@test "parse: case statement" {
  run_parse 'case $x in a) echo yes;; b) echo no;; esac'
  assert_commands "echo yes" "echo no"
}

# -- background commands --

@test "parse: background command" {
  run_parse 'evil_cmd & echo done'
  assert_commands "evil_cmd" "echo done"
}

# -- function declarations --

@test "parse: function declaration body extracted" {
  run_parse 'f() { evil_cmd; }; f'
  assert_commands "evil_cmd" "f"
}

# -- redirections with command substitution --

@test "parse: redirect target with command substitution" {
  run_parse 'echo hello > $(evil_cmd)'
  assert_commands "echo hello" "evil_cmd"
}

# -- coproc --

@test "parse: coproc command extracted" {
  run_parse 'coproc evil_cmd; echo done'
  assert_commands "evil_cmd" "echo done"
}

# -- bash -c recursive expansion --

@test "parse: bash -c with compound inner command" {
  run_parse "bash -c 'ls | grep foo'"
  assert_commands "ls" "grep foo"
}

@test "parse: bash -c with simple inner command" {
  # bash -c 'echo hello' contains no metacharacters BUT $() detection
  # triggers compound path... wait, it doesn't have $( either.
  # It DOES have a backtick? No. Let me check: bash -c 'echo hello'
  # has no |&;`$(<> so it takes simple path.
  run_parse "bash -c 'echo hello'"
  assert_commands "bash -c 'echo hello'"
}

# -- backtick command substitution (triggers compound path) --

@test "parse: backtick command substitution" {
  run_parse 'echo `date`'
  assert_commands 'echo $(..)' "date"
}

# -- variable assignments --

@test "parse: env var prefix preserved in output" {
  run_parse "FOO=bar cmd arg"
  assert_commands "FOO=bar cmd arg"
}

# -- edge cases --

@test "parse: empty input" {
  run_parse ""
  assert_no_commands
}

@test "parse: comment passes through simple path" {
  run_parse "# this is a comment"
  assert_commands "# this is a comment"
}

@test "parse: hash inside double quotes is not a comment" {
  run_parse 'echo "foo # bar"'
  assert_commands 'echo "foo # bar"'
}

@test "parse: complex real-world git command" {
  run_parse "git log --oneline -20 | head -10"
  assert_commands "git log --oneline -20" "head -10"
}

@test "parse: nvm use && yarn test" {
  run_parse "nvm use && yarn test"
  assert_commands "nvm use" "yarn test"
}

# -- newline-separated commands --

@test "parse: newline-separated commands extracted separately" {
  run_parse $'echo hello\nrm -rf /'
  assert_commands "echo hello" "rm -rf /"
}
