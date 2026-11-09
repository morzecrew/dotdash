# dotdash-relay

Not released yet. The first release comes with the next dotdash release, from
the same tag.

### Added

- A relay for networks that let only domestic addresses through: devices reach a dotdash server through a machine inside the country, on port 443, under the name of a site next to that machine. dotdash's `relay-config` task prints the machine's init command and secrets; its `relay-entry` task prints the line that adds the relay to the server's links.
