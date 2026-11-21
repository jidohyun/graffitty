# Loaded after normal fish configuration through --init-command.
status is-interactive; or return
set -q __graffitty_integrated; and return
set -g __graffitty_integrated 1
functions -q fish_prompt; or source $__fish_data_dir/functions/fish_prompt.fish
functions -c fish_prompt __graffitty_original_prompt
function __graffitty_restore_status
    return $argv[1]
end
function fish_prompt
    set -l previous_status $status
    printf '\e]133;D;%d\a\e]133;A\a' $previous_status
    printf '\e]7;file://localhost%s\a' (string escape --style=url -- $PWD | string replace -a '%2F' '/')
    __graffitty_restore_status $previous_status
    __graffitty_original_prompt
    printf '\e]133;B\a'
end
function __graffitty_preexec --on-event fish_preexec
    printf '\e]133;C\a'
end
