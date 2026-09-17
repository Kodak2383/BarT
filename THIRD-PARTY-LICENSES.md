# Third-party code

## Ice

<https://github.com/jordanbaird/Ice> — Copyright © Jordan Baird — **GPL-3.0**

BarT contains code taken from Ice. In particular:

| Where in BarT | What |
| --- | --- |
| `BarT/Engine/DragHideEngine.swift` | The `scromble` technique (`scromble(_:pid:)`), taken one to one from `MenuBarItemManager.scrombleEvent`; the undocumented `CGEvent` window-ID fields and their raw values |
| `BarT/Engine/EventTap.swift` | The tap construction, from `Ice/Events/EventTap.swift` |
| `BarT/Engine/Bridging.swift` | The private CGS signatures, verified one to one against `Ice/Bridging/Shims/Private.swift` @ `11edd39115f3f43a83ae114b5348df6a0e1741cf`, and the shim approach from `Ice/Bridging/Shims/Deprecated.swift` |
| `BarT/Engine/MenuBarItemSource.swift` | The approach to identifying item owners |

Because of this, **BarT as a whole is licensed under the GPL-3.0** — see [LICENSE](LICENSE). The
full text of the GPL-3.0 in that file is the licence of both projects.

Every location above is also marked in the source with the file and commit it came from.
