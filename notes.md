- Background colour can be optimised by using clear color?

## Rendering Logic

Ghostty has multiple threads per Surface, an IO thread, a render thread and main thread.
Rendering in ghostty works by setting a render event to a Surface, invoking the
draw_now async event handler. This allows ghostty to have adaptive FPS or on-demand
rendering instead of a typical game loop renderer with delta time.
Ghostty rendering is inactive so long as there is no blinking cursor, time-dependent rendering and no inputs (key, mouse, text from programs)

So what matters for input-latency is not the running FPS but the input->frame draw latency.

### FPS caps

#### V-Sync

the --window-vsync config is defaulted to true on MacOS and only applies on macos

However on Linux I get fps capped at refresh rate when sending mouse inputs quickly still,
where's the bottleneck?

#### Timers

The looped rendering is done by using a Timer that sends wakeup events.

```zig
const DRAW_INTERVAL = 8; // 120 FPS
const CURSOR_BLINK_INTERVAL = 600;
```

file:///home/fedora/dev/ghostty/src/renderer/Thread.zig:19:18
`DRAW_INTERVAL` is used when a custom shader is active, cursor blink is the timer
interval delay when cursor blinks
