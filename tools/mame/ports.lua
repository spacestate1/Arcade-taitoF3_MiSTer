for tag, port in pairs(manager.machine.ioport.ports) do
    for name, f in pairs(port.fields) do print(string.format("PORT %-14s FIELD %-24s mask=%08X", tag, name, f.mask)) end
end
