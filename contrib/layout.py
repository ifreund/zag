#!/bin/env python3
#
# Fibonacci sprial layout for river, implemented in simple python. Reading this
# code should help you get a basic understanding of how to use river-layout to
# create a basic layout generator.
#
# This depends on pywayland: https://github.com/flacjacket/pywayland/
#
# Q: Wow, this looks complicated!
# A: For simple layouts, you really only need to care about what's in the
#    layout_handle_layout_demand() function. And the rest isn't as complicated
#    as it looks.

import mmap
import time
from pywayland.client import Display
from pywayland.protocol.wayland import WlOutput
try:
    from pywayland.protocol.river_layout_v3 import RiverLayoutManagerV3
except:
    print("Your pywayland package does not have bindings for river-layout-v3.")
    print("You can add the bindings with the following command:")
    print("     python3 -m pywayland.scanner -i /usr/share/wayland/wayland.xml river-layout-v3.xml")
    print("Note that you may need root privileges if you have pywayland installed system-wide.")
    quit()

layout_manager = None
outputs = []
loop = True

def layout_handle_layout_demand(layout, view_count, usable_w, usable_h, tags, serial):
    x = 0
    y = 0
    w = usable_w
    h = usable_h
    i = 0
    while i < view_count:
        if i == view_count - 1:
            layout.push_view_dimensions(x, y, w, h, serial)
        else:
            if i % 2 == 0:
                w = int(w/2)
                if i % 4 == 2:
                    layout.push_view_dimensions(x + w, y, w, h, serial)
                else:
                    layout.push_view_dimensions(x, y, w, h, serial)
                    x += w
            else:
                h = int(h/2)
                if i % 4 == 3:
                    layout.push_view_dimensions(x, y + h, w, h, serial)
                else:
                    layout.push_view_dimensions(x, y, w, h, serial)
                    y += h

    # Committing the layout means telling the server that your code is done
    # laying out windows. Make sure you have pushed exactly the right amount of
    # view dimensions, a mismatch is a fatal protocol error.
    # 
    # You also have to provide a layout name. This is a user facing string that
    # the server can forward to status bars. You can use it to tell the user
    # which layout is currently in use. You could also add some status
    # information status information about your layout, which is what we do here.
    layout.commit(str(view_count) + " windows layout out by python", serial)

def layout_handle_namespace_in_use(layout):
    # Oh no, the namespace we choose is already used by another client! All we
    # can do now is destroy the layout object. Because we are lazy, we just
    # abort and let our cleanup mechanism destroy it. A more sophisticated
    # client could instead destroy only the one single affected layout object
    # and recover from this mishap. Writing such a client is left as an exercise
    # for the reader.
    print(f"Namespace already in use!")
    global loop
    loop = False

class Output(object):
    def __init__(self):
        self.output = None
        self.layout = None
        self.id = None

    def destroy(self):
        if self.layout != None:
            self.layout.destroy()
        if self.output != None:
            self.output.destroy()

    def configure(self):
        global layout_manager
        if self.layout == None and layout_manager != None:
            # We need to set a namespace, which is used to identify our layout.
            self.layout = layout_manager.get_layout(self.output, "layout.py")
            self.layout.user_data = self
            self.layout.dispatcher["layout_demand"] = layout_handle_layout_demand
            self.layout.dispatcher["namespace_in_use"] = layout_handle_namespace_in_use

def registry_handle_global(registry, id, interface, version):
    global layout_manager
    global output
    if interface == 'river_layout_manager_v3':
        layout_manager = registry.bind(id, RiverLayoutManagerV3, version)
    elif interface == 'wl_output':
        output = Output()
        output.output = registry.bind(id, WlOutput, version)
        output.id = id
        output.configure()
        outputs.append(output)

def registry_handle_global_remove(registry, id):
    for output in outputs:
        if output.id == id:
            output.destroy()
            outputs.remove(output)

display = Display()
display.connect()

registry = display.get_registry()
registry.dispatcher["global"] = registry_handle_global
registry.dispatcher["global_remove"] = registry_handle_global_remove

display.dispatch(block=True)
display.roundtrip()

if layout_manager == None:
    print("No layout_manager, aborting")
    quit()

for output in outputs:
    output.configure()

while loop and display.dispatch(block=True) != -1:
    pass

# Destroy outputs
for output in outputs:
    output.destroy()
    outputs.remove(output)

display.disconnect()

