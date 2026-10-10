## Overview

This demo illustrates how the [zgrid](https://github.com/cottonears/zgrid) library can be used for broad-phase collision detection.

**Acknowledgement:** This demo borrows heavily from [an excellent YouTube video by Pezzza's Work](https://www.youtube.com/watch?v=9IULfQH7E90), which inspired this project. Most of the physics code was adaptated from their repository which can be found [here](https://github.com/johnBuffer/VerletSFML-Multithread).


## Dependencies

- [SDL3](https://github.com/libsdl-org/SDL) and [castholm's zig port](https://github.com/castholm/SDL)
- [translate_c](https://codeberg.org/ziglang/translate-c)
- [zgrid](https://github.com/cottonears/zgrid)

## Running the demo
Build with `--release=fast` (for best performance) and run the demo as follows:
``` sh
zig build run --release=fast
```
