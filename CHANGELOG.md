## master
- `Horde.Supervisor` and `Horde.Registry` now support option `delta_crdt_options`, which you can use to tune your cluster. Also updated to the most recent DeltaCRDT. [#100](https://github.com/derekkraan/horde/pull/100)

## 0.6.0
- `Horde.Supervisor` now behaves more like `DynamicSupervisor`. [#122](https://github.com/derekkraan/horde/pull/122)
- `Horde.Registry` sends an exit signal to the process that "loses" when a conflict is resolved. [#118](https://github.com/derekkraan/horde/pull/118)
- `Horde.Registry.register/3` returns `{:error, {:already_registered, pid}}` when applicable. This improves compatability with `Elixir.Registry`. [#115](https://github.com/derekkraan/horde/pull/115)
- Adds `Horde.Registry.select/2`, which works the same as `Elixir.Registry.select/2`, which will land in Elixir 1.9. [#110](https://github.com/derekkraan/horde/pull/110)
- Fixes a bug causing `Horde.Supervisor` to crash if a child process was restarting when `Horde.Supervisor.delete_child/2` was called. [#114](https://github.com/derekkraan/horde/pull/114)
