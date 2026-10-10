## Overview

This demo illustrates how the [zgrid](https://github.com/cottonears/zgrid) library can be used for broad-phase collision detection in a simple particle simulation.

## Acknowledgement
This demo borrows heavily from [an excellent YouTube video by Pezzza's Work](https://www.youtube.com/watch?v=9IULfQH7E90), which inspired this project.
Most of the physics code was adapted directly from [their original repository](https://github.com/johnBuffer/VerletSFML-Multithread).

## Dependencies
- [Zig 0.17](https://ziglang.org/download/#release-0.17.0)
- [translate_c](https://codeberg.org/ziglang/translate-c)
- [SDL3](https://github.com/libsdl-org/SDL)
- [castholm's SDL build integration](https://github.com/castholm/SDL) 
- [zgrid](https://github.com/cottonears/zgrid)

## Running / adjusting the demo
Build with `--release=fast` (for best performance) and run the demo as follows:
``` sh
zig build run --release=fast
```

With constants at default values, the frame rate targets 60 Hz.
Frame times (which exclude time spent sleeping for frame pacing) are shown in the top left-hand corner of the screen.

The constants near the top of main.zig control the display settings and key simulation parameters.
There are more constants in physics.zig that adjust physics behaviour.
When experimenting with these, be aware that some might affect simulation stability.

### Controls
- **LMB**: shoot (creates an explosion at the cursor position).
- **SPACE**: pauses the simulation.
- **ESC**: quits the app.
