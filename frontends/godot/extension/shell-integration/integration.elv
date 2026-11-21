use str
use path
# Elvish cannot emit OSC133 B reliably from script; A/C/D still provide jumps.
set edit:before-readline = (conj $edit:before-readline {
  printf "\e]133;A\a"
  var cwd = (str:replace '%' '%25' (pwd))
  set cwd = (str:replace ' ' '%20' $cwd)
  set cwd = (str:replace '#' '%23' $cwd)
  set cwd = (str:replace '?' '%3F' $cwd)
  set cwd = (str:replace "\e" '%1B' $cwd)
  set cwd = (str:replace "\a" '%07' $cwd)
  set cwd = (str:replace "\n" '%0A' $cwd)
  set cwd = (str:replace "\r" '%0D' $cwd)
  set cwd = (str:replace "\t" '%09' $cwd)
  printf "\e]7;file://localhost%s\a" $cwd
})
set edit:after-readline = (conj $edit:after-readline {|_| printf "\e]133;C\a" })
set edit:after-command = (conj $edit:after-command {|info|
  var code = 0
  if (not-eq $info[error] $nil) { set code = 1 }
  printf "\e]133;D;"$code"\a"
})
