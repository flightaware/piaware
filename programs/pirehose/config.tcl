# delay (ms) after a write with compression enabled before flushing the
# compression layer
set ::syncflushInterval 1000

# version range we support
set ::minVersion 9.0
set ::maxVersion 9.0

# how long (ms) without messages before discarding aircraft state
set ::aircraftExpiry 120000

# how long (seconds) to retain individual data fields that have not seen updates
set ::maxDataAge 60
