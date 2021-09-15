function __riverctl_list_input_devices
    riverctl list-inputs | sed '/type:/d; /configured:/d'
end

function __fish_riverctl_complete_no_subcommand
    for i in (commandline -opc)
        if contains -- $i close csd-filter-add exit float-filter-add focus-output focus-view input list-inputs list-input-configs move resize snap send-to-output spawn swap toggle-float toggle-fullscreen zoom default-layout output-layout send-layout-cmd set-focused-tags set-view-tags toggle-focused-tags toggle-view-tags spawn-tagmask declare-mode enter-mode map map-pointer unmap unmap-pointer attach-mode background-color border-color-focused border-color-unfocused border-color-urgent border-width focus-follows-cursor set-repeat set-cursor-warp xcursor-theme
            return 1
        end
    end
    return 0
end

function __fish_riverctl_complete_from_input
    set -l cmd (commandline -opc)
    if test (count $cmd) -eq 2
        return 0
    end
    return 1
end

function __fish_riverctl_complete_from_input_devices
    set -l cmd (commandline -opc)
    if test (count $cmd) -eq 3
        return 0
    end
    return 1
end

function __fish_riverctl_complete_from_input_subcommands
    set -l cmd (commandline -opc)
    if test (count $cmd) -eq 4
        return 0
    end
    return 1
end

# Actions
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a close                  -d 'Close the focued view'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a csd-filter-add         -d 'Add app-id to the CSD filter list'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a exit                   -d 'Exit the compositor, terminating the Wayland session'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a float-filter-add       -d 'Add app-id to the float filter list'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a focus-output           -d 'Focus the next or previous output'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a focus-view             -d 'Focus the next or previous view in the stack'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a input                  -d 'Create a configuration rule for an input device'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a list-inputs            -d 'List all input devices'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a list-input-configs     -d 'List all input configurations'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a move                   -d 'Move the focused view in the specified direction'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a resize                 -d 'Resize the focused view along the given axis'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a snap                   -d 'Snap the focused view to the specified screen edge'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a send-to-output         -d 'Send the focused view to the next/previous output'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a spawn                  -d 'Run shell_command using /bin/sh -c'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a swap                   -d 'Swap the focused view with the next/previous visible non-floating view'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a toggle-float           -d 'Toggle the floating state of the focused view'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a toggle-fullscreen      -d 'Toggle the fullscreen state of the focused view'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a zoom                   -d 'Bump the focused view to the top of the layout stack'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a default-layout         -d 'Set the layout namespace to be used by all outputs by default.'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a output-layout          -d 'Set the layout namespace of currently focused output.'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a send-layout-cmd        -d 'Send command to the layout client on the currently focused output with the given namespace'
# Tag managements
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a set-focused-tags       -d 'Show views with tags corresponding to the set bits of tags'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a set-view-tags          -d 'Assign the currently focused view the tags corresponding to the set bits of tags'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a toggle-focused-tags    -d 'Toggle visibility of views with tags corresponding to the set bits of tags'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a toggle-view-tags       -d 'Toggle the tags of the currently focused view'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a spawn-tagmask          -d 'Set a tagmask to filter the tags assigned to newly spawned views on the focused output'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a focus-previous-tags    -d 'Sets tags to their previous value on the focused output'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a send-to-previous-tags  -d 'Assign the currently focused view the previous tags of the focused output'
# Mappings
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a declare-mode           -d 'Create a new mode'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a enter-mode             -d 'Switch to given mode if it exists'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a map                    -d 'Run command when key is pressed while modifiers are held down and in the specified mode'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a map-pointer            -d 'Move or resize views when button and modifers are held down while in the specified mode'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a unmap                  -d 'Remove the mapping defined by the arguments'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a unmap-pointer          -d 'Remove the pointer mapping defined by the arguments'
# Configuration
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a attach-mode            -d 'Configure where new views should attach to the view stack'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a background-color       -d 'Set the background color'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a border-color-focused   -d 'Set the border color of focused views'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a border-color-unfocused -d 'Set the border color of unfocused views'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a border-color-urgent    -d 'Set the border color of urgent views'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a border-width           -d 'Set the border width to pixels'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a focus-follows-cursor   -d 'Configure the focus behavior when moving cursor'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a set-repeat             -d 'Set the keyboard repeat rate and repeat delay'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a set-cursor-warp        -d 'Set the cursor warp mode.'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a set-adaptive-sync      -d 'Set adaptive sync state'
complete -c riverctl -x -n '__fish_riverctl_complete_no_subcommand' -a xcursor-theme          -d 'Set the xcursor theme'

# Subcommands
complete -c riverctl -x -n '__fish_seen_subcommand_from focus-output'         -a 'next previous'
complete -c riverctl -x -n '__fish_seen_subcommand_from focus-view'           -a 'next previous'
complete -c riverctl -x -n '__fish_seen_subcommand_from move'                 -a 'up down left right'
complete -c riverctl -x -n '__fish_seen_subcommand_from resize'               -a 'horizontal vertical'
complete -c riverctl -x -n '__fish_seen_subcommand_from snap'                 -a 'up down left right'
complete -c riverctl -x -n '__fish_seen_subcommand_from send-to-output'       -a 'next previous'
complete -c riverctl -x -n '__fish_seen_subcommand_from swap'                 -a 'next previous'
complete -c riverctl -x -n '__fish_seen_subcommand_from map'                  -a '-release -repeat'
complete -c riverctl -x -n '__fish_seen_subcommand_from unmap'                -a '-release'
complete -c riverctl -x -n '__fish_seen_subcommand_from attach-mode'          -a 'top bottom'
complete -c riverctl -x -n '__fish_seen_subcommand_from focus-follows-cursor' -a 'disabled normal'
complete -c riverctl -x -n '__fish_seen_subcommand_from set-cursor-warp'      -a 'disabled on-output-change'
complete -c riverctl -x -n '__fish_seen_subcommand_from set-adaptive-sync'    -a 'disabled enabled'

# Subcommands for 'input'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input'         -a "(__riverctl_list_input_devices)"
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'events'               -d 'Configure whether the input device\'s events will be used'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'accel-profile'        -d 'Set the pointer acceleration profile'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'pointer-accel'        -d 'Set the pointer acceleration factor'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'click-method'         -d 'Set the click method'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'drag'                 -d 'Enable or disable the tap-and-drag functionality'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'drag-lock'            -d 'Enable or disable the drag lock functionality'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'disable-while-typing' -d 'Enable or disable the disable-while-typing functionality'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'middle-emulation'     -d 'Enable or disable the middle-emulation functionality'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'natural-scroll'       -d 'Enable or disable the natural-scroll functionality'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'left-handed'          -d 'Enable or disable the left handed mode'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'tap'                  -d 'Enable or disable the tap functionality'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'tap-button-map'       -d 'Configure the button mapping for tapping'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'scroll-method'        -d 'Set the scroll method'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_devices' -a 'scroll-button'        -d 'Set the scroll button'

# Subcommands for the subcommands of 'input'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_subcommands; and __fish_seen_subcommand_from drag drag-lock disable-while-typing middle-emulation natural-scroll left-handed tap' -a 'enabled disabled'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_subcommands; and __fish_seen_subcommand_from events'         -a 'enabled disabled disabled-on-external-mouse'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_subcommands; and __fish_seen_subcommand_from accel-profile'  -a 'none flat adaptive'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_subcommands; and __fish_seen_subcommand_from click-method'   -a 'none button-areas clickfinger'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_subcommands; and __fish_seen_subcommand_from tap-button-map' -a 'left-right-middle left-middle-right'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_subcommands; and __fish_seen_subcommand_from scroll-method'  -a 'none'       -d 'No scrolling'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_subcommands; and __fish_seen_subcommand_from scroll-method'  -a 'two-finger' -d 'Scroll by swiping with two fingers simultaneously'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_subcommands; and __fish_seen_subcommand_from scroll-method'  -a 'edge'       -d 'Scroll by swiping along the edge'
complete -c riverctl -x -n '__fish_seen_subcommand_from input; and __fish_riverctl_complete_from_input_subcommands; and __fish_seen_subcommand_from scroll-method'  -a 'button'     -d 'Scroll with pointer movement while holding down a button'
